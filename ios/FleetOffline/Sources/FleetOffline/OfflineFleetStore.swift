import Foundation
import CSQLite
import TransitCore

public enum OfflineFleetError: LocalizedError, Sendable {
	case unavailable, expired, invalid(String)
	public var errorDescription: String? {
		switch self {
		case .unavailable: return "Download a fleet snapshot while connected to browse it offline."
		case .expired: return "This fleet pack expired. Prepare a fresh pack to download. Your previous download is still available."
		case .invalid(let message): return message
		}
	}
}

private struct SavedSnapshot: Codable, Sendable {
	let manifest: FleetOfflineManifest
	let fileName: String
}

/// Owns downloaded files. Downloading and validation never replace the usable snapshot early.
public actor OfflineFleetStore {
	private let directory: URL
	private var saved: SavedSnapshot?
	private var downloadID: UUID?
	private let decoder = JSONDecoder()

	public init(directory: URL) throws {
		self.directory = directory
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		var excluded = directory
		var values = URLResourceValues(); values.isExcludedFromBackup = true
		try excluded.setResourceValues(values)
		if let data = try? Data(contentsOf: directory.appendingPathComponent("active.json")),
			let active = try? JSONDecoder().decode(SavedSnapshot.self, from: data),
			active.fileName == URL(fileURLWithPath: active.fileName).lastPathComponent,
			FileManager.default.fileExists(atPath: directory.appendingPathComponent(active.fileName).path) {
			saved = active
		}
		// A terminated update can leave a large candidate behind before pointer activation.
		// This directory is owned by one store; keep only the snapshot named by the pointer.
		for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
			if let database = SnapshotFiles.databaseName(for: file.lastPathComponent), database != saved?.fileName {
				SnapshotFiles.removeDatabase(at: directory.appendingPathComponent(database))
			}
		}
	}

	public func manifest() -> FleetOfflineManifest? { saved?.manifest }

	public func download(manifest: FleetOfflineManifest, apiBaseURL: URL,
		progress: @escaping @Sendable (FleetDownloadProgress) -> Void = { _ in }) async throws {
		try SnapshotFiles.validate(manifest)
		let url = try SnapshotFiles.downloadURL(manifest.downloadURL, relativeTo: apiBaseURL)
		try await performDownload(id: manifest.id, url: url, expectedBytes: manifest.downloadByteLength,
			spaceBytes: manifest.byteLength + manifest.downloadByteLength, progress: progress) {
			try install(file: $0, manifest: manifest, progress: progress)
		}
	}

	public func download(pack: FleetPackManifest, apiBaseURL: URL,
		progress: @escaping @Sendable (FleetDownloadProgress) -> Void = { _ in }) async throws {
		try SnapshotFiles.validate(pack)
		let url = try SnapshotFiles.downloadURL(pack.downloadURL, relativeTo: apiBaseURL)
		try await performDownload(id: pack.id, url: url, expectedBytes: pack.archiveByteLength,
			spaceBytes: pack.archiveByteLength + pack.estimatedSavedByteLength, progress: progress) {
			try install(file: $0, pack: pack, progress: progress)
		}
	}

	private func performDownload(id: String, url: URL, expectedBytes: Int64, spaceBytes: Int64,
		progress: @escaping @Sendable (FleetDownloadProgress) -> Void, install: (URL) throws -> Void) async throws {
		guard downloadID == nil else { throw OfflineFleetError.invalid("A fleet download is already running.") }
		try SnapshotFiles.requireSpace(in: directory, bytes: spaceBytes)
		let token = UUID(); downloadID = token
		defer { if downloadID == token { downloadID = nil } }
		// Resume data belongs to one exact archive URL, never a different endpoint.
		let resumeFile = directory.appendingPathComponent("resume-\(safeID(id)).json")
		let configuration = URLSessionConfiguration.default
		configuration.timeoutIntervalForRequest = 60
		configuration.timeoutIntervalForResource = 3_600
		let session = URLSession(configuration: configuration)
		defer { session.invalidateAndCancel() }
		let delegate = DownloadProgress(expectedBytes: expectedBytes, url: url, progress: progress)
		progress(FleetDownloadProgress(stage: .downloading, completedBytes: 0, totalBytes: expectedBytes))
		// The async download API never calls didWriteData, so progress is read from the task's own counters.
		let watcher = Task {
			while !Task.isCancelled {
				delegate.reportReceived()
				try? await Task.sleep(for: .milliseconds(200))
			}
		}
		defer { watcher.cancel() }
		do {
			let result: (URL, URLResponse)
			if let resume = SnapshotFiles.resumeData(at: resumeFile, for: url) {
				result = try await session.download(resumeFrom: resume, delegate: delegate)
			} else {
				result = try await session.download(from: url, delegate: delegate)
			}
			defer { try? FileManager.default.removeItem(at: result.0) }
			// Stop the watcher before the final count, so no download report follows the install stages.
			watcher.cancel()
			await watcher.value
			delegate.reportReceived()
			guard let response = result.1 as? HTTPURLResponse,
				response.url?.host == url.host, response.url?.scheme == url.scheme,
				response.url?.port == url.port, response.url?.user == nil, response.url?.password == nil else { throw OfflineFleetError.invalid("The fleet download is unavailable. Try updating its information.") }
			if response.statusCode == 404 { throw OfflineFleetError.expired }
			guard [200, 206].contains(response.statusCode) else { throw OfflineFleetError.invalid("The fleet download is unavailable. Try preparing it again.") }
			try Task.checkCancellation()
			guard downloadID == token else { throw CancellationError() }
			try install(result.0)
			try? FileManager.default.removeItem(at: resumeFile)
		} catch {
			if delegate.expired {
				try? FileManager.default.removeItem(at: resumeFile)
				throw OfflineFleetError.expired
			}
			if downloadID == token {
				if let resume = (error as NSError).userInfo["NSURLSessionDownloadTaskResumeData"] as? Data, resume.count <= 1_048_576 {
					try? SnapshotFiles.saveResumeData(resume, at: resumeFile, for: url)
				} else { try? FileManager.default.removeItem(at: resumeFile) }
			}
			throw error
		}
	}

	public func install(file: URL, pack: FleetPackManifest, progress: @Sendable (FleetDownloadProgress) -> Void = { _ in }) throws {
		try SnapshotFiles.validate(pack)
		try Task.checkCancellation()
		try SnapshotFiles.requireSpace(in: directory, bytes: 16 * 1_024 * 1_024)
		progress(FleetDownloadProgress(stage: .verifying, completedBytes: 0, totalBytes: pack.archiveByteLength))
		try SnapshotFiles.verify(file, bytes: pack.archiveByteLength, sha256: pack.archiveSha256) {
			progress(FleetDownloadProgress(stage: .verifying, completedBytes: $0, totalBytes: pack.archiveByteLength))
		}
		let name = "\(safeID(pack.id))-\(UUID().uuidString).sqlite"
		let destination = directory.appendingPathComponent(name)
		var activated = false
		defer {
			if !activated {
				SnapshotFiles.removeDatabase(at: destination)
			}
		}
		// Release SQLite and its journal before integrity validation and pointer activation.
		do {
			let importer = try FleetPackImporter(file: destination, pack: pack)
			var imported: Int64 = 0
			progress(FleetDownloadProgress(stage: .importing, completedBytes: 0, totalBytes: pack.uncompressedByteLength))
			try SnapshotFiles.inflateGzip(file, expectedBytes: pack.uncompressedByteLength) { block in
				try importer.consume(block)
				imported += Int64(block.count)
				progress(FleetDownloadProgress(stage: .importing, completedBytes: imported, totalBytes: pack.uncompressedByteLength))
			}
			try importer.finish()
		}
		let database = try SnapshotDatabase(file: destination)
		try database.validate(pack: pack)
		let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) ?? 0
		progress(FleetDownloadProgress(stage: .checking, completedBytes: 0, totalBytes: size))
		let sha256 = try SnapshotFiles.digest(destination) { progress(FleetDownloadProgress(stage: .checking, completedBytes: $0, totalBytes: size)) }
		let manifest = FleetOfflineManifest(schemaVersion: 2, id: pack.id, generatedAt: pack.generatedAt,
			historyStart: pack.historyStart, historyEnd: pack.historyEnd,
			counts: FleetOfflineCounts(cars: pack.counts.cars, consists: pack.counts.consists, events: pack.counts.events, assertions: pack.counts.assertions),
			byteLength: size, sha256: sha256, downloadURL: pack.downloadURL,
			observedAt: pack.observedAt, pack: pack)
		progress(FleetDownloadProgress(stage: .activating, completedBytes: 0, totalBytes: 0))
		try activate(SavedSnapshot(manifest: manifest, fileName: name))
		activated = true
	}

	/// Also used by integration tests and fixture-based UI tests.
	public func install(file: URL, manifest: FleetOfflineManifest, progress: @Sendable (FleetDownloadProgress) -> Void = { _ in }) throws {
		try SnapshotFiles.validate(manifest)
		try Task.checkCancellation()
		try SnapshotFiles.requireSpace(in: directory, bytes: manifest.byteLength)
		let name = "\(safeID(manifest.id))-\(UUID().uuidString).sqlite"
		let destination = directory.appendingPathComponent(name)
		var activated = false
		defer { if !activated { SnapshotFiles.removeDatabase(at: destination) } }
		let download = manifest.compression == "gzip" ? manifest.compressedByteLength! : manifest.byteLength
		func verifying(_ bytes: Int64) { progress(FleetDownloadProgress(stage: .verifying, completedBytes: bytes, totalBytes: download)) }
		func importing(_ bytes: Int64) { progress(FleetDownloadProgress(stage: .importing, completedBytes: bytes, totalBytes: manifest.byteLength)) }
		verifying(0)
		if manifest.compression == "gzip" {
			try SnapshotFiles.verify(file, bytes: manifest.compressedByteLength!, sha256: manifest.compressedSha256!, progress: verifying)
			importing(0)
			try SnapshotFiles.inflateGzip(file, to: destination, expectedBytes: manifest.byteLength, progress: importing)
		} else {
			try SnapshotFiles.verify(file, bytes: manifest.byteLength, sha256: manifest.sha256, progress: verifying)
			importing(0)
			try FileManager.default.copyItem(at: file, to: destination)
			importing(manifest.byteLength)
		}
		progress(FleetDownloadProgress(stage: .checking, completedBytes: 0, totalBytes: manifest.byteLength))
		try SnapshotFiles.verify(destination, bytes: manifest.byteLength, sha256: manifest.sha256) {
			progress(FleetDownloadProgress(stage: .checking, completedBytes: $0, totalBytes: manifest.byteLength))
		}
		try validateDatabase(at: destination, manifest: manifest)
		progress(FleetDownloadProgress(stage: .activating, completedBytes: 0, totalBytes: 0))
		try activate(SavedSnapshot(manifest: manifest, fileName: name))
		activated = true
	}

	private func activate(_ next: SavedSnapshot) throws {
		try Task.checkCancellation()
		try JSONEncoder().encode(next).write(to: directory.appendingPathComponent("active.json"), options: .atomic)
		let previous = saved
		saved = next
		if let previous { SnapshotFiles.removeDatabase(at: directory.appendingPathComponent(previous.fileName)) }
	}

	private func validateDatabase(at file: URL, manifest: FleetOfflineManifest) throws {
		let database = try SnapshotDatabase(file: file)
		try database.validate(manifest: manifest)
	}

	public func delete() throws {
		// Invalidates an in-flight download before it can activate a replacement.
		downloadID = nil
		let pointer = directory.appendingPathComponent("active.json")
		if FileManager.default.fileExists(atPath: pointer.path) { try FileManager.default.removeItem(at: pointer) }
		saved = nil
		for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
			try? FileManager.default.removeItem(at: file)
		}
	}

	public func page(query: [String: String]) throws -> FleetPage {
		guard let saved else { throw OfflineFleetError.unavailable }
		let db = try SnapshotDatabase(file: directory.appendingPathComponent(saved.fileName))
		let grouping = query["view"] == "cars" ? "id" : "COALESCE(json_extract(data,'$.fixedSet'),id)"
		let (condition, arguments) = selection(query: query)
		// Filter with SQLite, then sort only compact group/number keys. Decode JSON only for this page.
		let keys = try db.rows("SELECT \(grouping),json_extract(data,'$.number') FROM cars WHERE \(grouping) IN (SELECT \(grouping) FROM cars WHERE \(condition))", values: arguments)
		var firstNumbers: [String: String] = [:]
		for key in keys {
			if let previous = firstNumbers[key[0]], !naturalLess(key[1], previous) { continue }
			firstNumbers[key[0]] = key[1]
		}
		let ordered = firstNumbers.keys.sorted {
			let a = firstNumbers[$0]!, b = firstNumbers[$1]!
			return a == b ? $0 < $1 : naturalLess(a, b)
		}
		let pages = max(1, (ordered.count + 99) / 100)
		let page = min(pages, max(1, Int(query["page"] ?? "1") ?? 1))
		let start = min(ordered.count, (page - 1) * 100)
		let end = min(ordered.count, start + 100)
		let pageIDs = Array(ordered[start..<end])
		var groups: [String: [[String: Any]]] = [:]
		if !pageIDs.isEmpty {
			let placeholders = pageIDs.map { _ in "?" }.joined(separator: ",")
			for row in try db.rows("SELECT \(grouping),data FROM cars WHERE \(grouping) IN (\(placeholders))", values: pageIDs) {
				groups[row[0], default: []].append(try carJSON(row[1]))
			}
		}
		let rows: [[String: Any]] = pageIDs.map { id in
			let sorted = (groups[id] ?? []).sorted { naturalLess($0["number"] as? String ?? "", $1["number"] as? String ?? "") }
			return ["id": id, "kind": id.hasPrefix("set:") ? "consist" : "car", "cars": sorted, "reporting": false]
		}
		func facet(_ path: String) throws -> [String] {
			try db.rows("SELECT DISTINCT json_extract(data,'\(path)') AS value FROM cars WHERE value IS NOT NULL AND value != '' ORDER BY value").map { $0[0] }
		}
		let counts = Dictionary(uniqueKeysWithValues: try db.rows("SELECT json_extract(data,'$.category'),COUNT(*) FROM cars GROUP BY json_extract(data,'$.category')").map { ($0[0], Int($0[1]) ?? 0) })
		let coverage: [[String: Any]] = ["passenger", "sir", "work", "museum"].map { category in
			["category": category, "count": counts[category] ?? 0,
			 "note": category == "passenger" ? "Saved NYCT roster and observed cars; source records can conflict." : "Partial documented inventory; saved reports are historical."]
		}
		var sources: [Any] = []
		if let raw = try db.rows("SELECT data FROM meta WHERE key='roster'").first?.first,
			let source = try? JSONSerialization.jsonObject(with: Data(raw.utf8)), source is [String: Any] { sources.append(source) }
		if let raw = try db.rows("SELECT data FROM meta WHERE key='supplement'").first?.first,
			let values = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [Any] { sources += values }
		let json: [String: Any] = ["rows": rows, "total": ordered.count, "page": page, "pages": pages,
			"generatedAt": saved.manifest.generatedAt, "coverage": coverage, "sources": sources,
			"facets": ["equipment": try facet("$.equipment"), "route": try facet("$.last.route"), "yard": try facet("$.estimatedYard.name")]]
		return try decoder.decode(FleetPage.self, from: JSONSerialization.data(withJSONObject: json))
	}

	public func detail(id: String, offset: Int = 0, limit: Int = 200) throws -> FleetDetail {
		guard let saved else { throw OfflineFleetError.unavailable }
		let db = try SnapshotDatabase(file: directory.appendingPathComponent(saved.fileName))
		let membership = try db.rows("SELECT data FROM consists WHERE id=?", values: [id]).first?.first
		let memberIDs = membership.flatMap { try? decoder.decode([String].self, from: Data($0.utf8)) } ?? []
		var cars: [[String: Any]] = []
		if !memberIDs.isEmpty {
			for member in memberIDs {
				for row in try db.rows("SELECT data FROM cars WHERE id=?", values: [member]) { cars.append(try carJSON(row[0])) }
			}
		} else {
			cars = try db.rows("SELECT data FROM cars WHERE id=? OR json_extract(data,'$.fixedSet')=? ORDER BY id", values: [id, id]).map { try carJSON($0[0]) }
		}
		guard !cars.isEmpty else { throw OfflineFleetError.invalid("This car or consist is not in the saved fleet.") }
		let ids = cars.compactMap { $0["id"] as? String }
		let placeholders = ids.map { _ in "?" }.joined(separator: ",")
		let restriction = memberIDs.isEmpty ? "" : " AND json_extract(e.data,'$.consistId')=?"
		let historySQL = "SELECT e.data FROM events e WHERE e.id IN (SELECT ec.event_id FROM event_cars ec WHERE ec.car_id IN (\(placeholders)))\(restriction) ORDER BY e.timestamp DESC,e.id DESC LIMIT ? OFFSET ?"
		let values = ids + (memberIDs.isEmpty ? [] : [id]) + [String(min(200, max(1, limit))), String(max(0, offset))]
		let history = try db.rows(historySQL, values: values).map { try JSONSerialization.jsonObject(with: Data($0[0].utf8)) }
		let json: [String: Any] = ["cars": cars, "history": history, "generatedAt": saved.manifest.generatedAt]
		return try decoder.decode(FleetDetail.self, from: JSONSerialization.data(withJSONObject: json))
	}

	private func carJSON(_ raw: String) throws -> [String: Any] {
		guard var car = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { throw OfflineFleetError.invalid("Invalid saved car record.") }
		car["reporting"] = false
		return car
	}
	private func safeID(_ id: String) -> String { String(id.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }.prefix(128)) }
	private func naturalLess(_ a: String, _ b: String) -> Bool { a.compare(b, options: .numeric, locale: Locale(identifier: "en_US_POSIX")) == .orderedAscending }
	private func selection(query: [String: String]) -> (String, [String]) {
		var clauses = ["1=1"], values: [String] = []
		if query["status"] == "reporting" { clauses.append("0=1") }
		if let category = query["category"], !category.isEmpty {
			clauses.append("json_extract(data,'$.category')=?"); values.append(category)
		}
		for (key, path) in [("equipment", "$.equipment"), ("yard", "$.estimatedYard.name"), ("route", "$.last.route")] {
			if let filter = query[key], !filter.isEmpty {
				let expression = "COALESCE(json_extract(data,'\(path)'),'')"
				if filter == "unknown" { clauses.append("\(expression)=''") }
				else if key == "route" { clauses.append("\(expression)=?"); values.append(filter) }
				else { clauses.append("instr(lower(\(expression)),?)>0"); values.append(filter.lowercased()) }
			}
		}
		if query["retired"] != "true" {
			let lifecycle = "lower(COALESCE(json_extract(data,'$.lifecycle'),''))"
			clauses.append("instr(\(lifecycle),'retired')=0 AND instr(\(lifecycle),'scrapped')=0 AND \(lifecycle) NOT GLOB '[0-9][0-9]/[0-9][0-9]/[0-9][0-9][0-9][0-9]'")
		}
		let searchable = ["$.number", "$.aliases", "$.equipment", "$.last.location", "$.estimatedYard.name"].map { "COALESCE(json_extract(data,'\($0)'),'')" }.joined(separator: " || ' ' || ")
		for term in (query["q"] ?? "").lowercased().split(whereSeparator: \.isWhitespace) {
			clauses.append("instr(lower(\(searchable)),?)>0"); values.append(String(term))
		}
		return (clauses.joined(separator: " AND "), values)
	}
}

private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
	private let lock = NSLock()
	private var statusCode: Int?
	private var task: URLSessionTask?
	var expired: Bool { lock.withLock { statusCode == 404 } }
	let expectedBytes: Int64
	let url: URL
	let progress: @Sendable (FleetDownloadProgress) -> Void
	init(expectedBytes: Int64, url: URL, progress: @escaping @Sendable (FleetDownloadProgress) -> Void) { self.expectedBytes = expectedBytes; self.url = url; self.progress = progress }
	func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) { lock.withLock { self.task = task } }
	func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
	/// Only delegate-based downloads call this; the async download API never does, so
	/// `reportReceived` enforces the same limit and records the status for `expired`.
	func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
		lock.withLock { statusCode = (downloadTask.response as? HTTPURLResponse)?.statusCode }
		if totalBytesWritten > expectedBytes { downloadTask.cancel(); return }
	}
	/// Reports the archive bytes on hand so far, including the part a resumed (206) download
	/// already had, and stops a download that grows past the archive's announced size.
	func reportReceived() {
		guard let task = lock.withLock({ self.task }) else { return }
		let status = (task.response as? HTTPURLResponse)?.statusCode
		lock.withLock { if status != nil { statusCode = status } }
		let resumed = status == 206 && task.countOfBytesExpectedToReceive > 0 ? max(0, expectedBytes - task.countOfBytesExpectedToReceive) : 0
		let received = resumed + task.countOfBytesReceived
		if received > expectedBytes { task.cancel(); return }
		progress(FleetDownloadProgress(stage: .downloading, completedBytes: received, totalBytes: expectedBytes))
	}
	func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
		completionHandler(request.url?.host == url.host && request.url?.scheme == url.scheme && request.url?.port == url.port && request.url?.user == nil && request.url?.password == nil ? request : nil)
	}
}

final class SnapshotDatabase {
	private var db: OpaquePointer?
	init(file: URL) throws {
		guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
			if db != nil { sqlite3_close(db) }
			db = nil
			throw OfflineFleetError.invalid("The saved fleet database could not be opened.")
		}
		sqlite3_progress_handler(db, 10_000, { _ in Task.isCancelled ? 1 : 0 }, nil)
		do {
			try execute("PRAGMA trusted_schema=OFF")
			try execute("PRAGMA query_only=ON")
		} catch {
			sqlite3_close(db); db = nil
			throw error
		}
	}
	deinit { sqlite3_close(db) }
	func execute(_ sql: String) throws {
		guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
	}
	func rows(_ sql: String, values: [String] = []) throws -> [[String]] {
		var statement: OpaquePointer?
		guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
		defer { sqlite3_finalize(statement) }
		for (index, value) in values.enumerated() {
			guard sqlite3_bind_text(statement, Int32(index + 1), value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK else { throw failure() }
		}
		var result: [[String]] = []
		while true {
			let step = sqlite3_step(statement)
			if step == SQLITE_DONE { break }
			guard step == SQLITE_ROW else { throw failure() }
			result.append((0..<sqlite3_column_count(statement)).map { column in
				guard let text = sqlite3_column_text(statement, column) else { return "" }
				return String(cString: text)
			})
		}
		return result
	}
	func validate(manifest: FleetOfflineManifest) throws {
		guard try rows("PRAGMA user_version").first?.first == "1",
			try rows("PRAGMA quick_check") == [["ok"]], try rows("PRAGMA foreign_key_check").isEmpty else {
			throw OfflineFleetError.invalid("The downloaded fleet database is incompatible or damaged.")
		}
		for (table, count) in [("cars", manifest.counts.cars), ("consists", manifest.counts.consists), ("events", manifest.counts.events), ("assertions", manifest.counts.assertions)] {
			guard try rows("SELECT COUNT(*) FROM \(table)").first?.first == String(count) else {
				throw OfflineFleetError.invalid("The fleet download is missing records.")
			}
		}
		guard let raw = try rows("SELECT data FROM meta WHERE key='snapshot'").first?.first,
			let metadata = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
			metadata["schemaVersion"] as? Int == manifest.schemaVersion,
			metadata["generatedAt"] as? Double == manifest.generatedAt,
			metadata["historyStart"] as? Double == manifest.historyStart,
			metadata["historyEnd"] as? Double == manifest.historyEnd else {
			throw OfflineFleetError.invalid("The fleet database does not match its download information.")
		}
		_ = try rows("SELECT event_id,car_id FROM event_cars LIMIT 1")
	}
	func validate(pack: FleetPackManifest) throws {
		guard try rows("PRAGMA user_version") == [["1"]], try rows("PRAGMA quick_check") == [["ok"]],
			try rows("PRAGMA foreign_key_check").isEmpty else {
			throw OfflineFleetError.invalid("The saved fleet pack is incompatible or damaged.")
		}
		for (table, count) in [("cars", pack.counts.cars), ("consists", pack.counts.consists), ("events", pack.counts.events), ("assertions", pack.counts.assertions), ("event_cars", pack.counts.eventCars)] {
			guard try rows("SELECT COUNT(*) FROM \(table)") == [[String(count)]] else {
				throw OfflineFleetError.invalid("The fleet pack is missing records.")
			}
		}
		var conditions: [String] = [], values: [String] = []
		for (selected, expression) in [(pack.selection.equipment, "json_extract(data,'$.equipment')"),
			(pack.selection.yards, "COALESCE(NULLIF(json_extract(data,'$.estimatedYard.name'),''),'unknown')")] where !selected.isEmpty {
			conditions.append("\(expression) IN (\(selected.map { _ in "?" }.joined(separator: ",")))")
			values += selected
		}
		let condition = conditions.isEmpty ? "1=1" : conditions.joined(separator: " AND ")
		guard try rows("SELECT COUNT(*) FROM cars WHERE \(condition)", values: values) == [[String(pack.counts.matchedCars)]] else {
			throw OfflineFleetError.invalid("The fleet pack does not match its selected car types and yards.")
		}
		guard let raw = try rows("SELECT data FROM meta WHERE key='snapshot'").first?.first,
			let metadata = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
			metadata["schemaVersion"] as? Int == 2, metadata["generatedAt"] as? Double == pack.generatedAt,
			metadata["historyStart"] as? Double == pack.historyStart, metadata["historyEnd"] as? Double == pack.historyEnd else {
			throw OfflineFleetError.invalid("The fleet pack does not match its download information.")
		}
	}
	private func failure() -> any Error {
		if sqlite3_errcode(db) == SQLITE_INTERRUPT, Task.isCancelled { return CancellationError() }
		return OfflineFleetError.invalid("Saved fleet query failed: \(String(cString: sqlite3_errmsg(db)))")
	}
}
