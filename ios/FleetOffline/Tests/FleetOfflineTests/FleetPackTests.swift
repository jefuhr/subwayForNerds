import Foundation
import Testing
import CryptoKit
import CSQLite
import TransitCore
@testable import FleetOffline

@Suite struct FleetPackTests {
	@Test func selectivePackBuildsExistingQuerySchemaAndSurvivesRelaunch() async throws {
		let fixture = try PackFixture()
		defer { fixture.remove() }
		let directory = fixture.directory.appendingPathComponent("installed")
		let store = try OfflineFleetStore(directory: directory)
		try await store.install(file: fixture.file, pack: fixture.manifest)
		let saved = try #require(await store.manifest())
		#expect(saved.pack == fixture.manifest)
		#expect(saved.byteLength > 0)
		let page = try await store.page(query: [:])
		#expect(page.rows.first?.cars.map(\.id) == ["car:1", "car:2"])
		#expect(page.rows.allSatisfy { !$0.reporting && $0.cars.allSatisfy { $0.reporting == false } })
		let detail = try await store.detail(id: "observed:pair")
		#expect(detail.cars.map(\.id) == ["car:2", "car:1"])
		#expect(detail.history.count == 1)
		#expect(detail.history.first?.cars == ["car:2", "car:1", "car:context"])
		let reopened = try OfflineFleetStore(directory: directory)
		#expect(await reopened.manifest() == saved)
		#expect(try await reopened.detail(id: "car:1").history.count == 1)
		#expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".sqlite") }.count == 1)
	}

	@Test func invalidPackNeverReplacesLegacySnapshot() async throws {
		let legacy = try IntegrityFixture()
		defer { legacy.remove() }
		let fixture = try PackFixture()
		defer { fixture.remove() }
		let store = try OfflineFleetStore(directory: legacy.directory.appendingPathComponent("installed"))
		try await store.install(file: legacy.file, manifest: legacy.manifest)
		var hash = fixture.manifest; hash.archiveSha256 = String(repeating: "0", count: 64)
		var bytes = fixture.manifest; bytes.archiveByteLength += 1
		var expansion = fixture.manifest; expansion.uncompressedByteLength -= 1
		var counts = fixture.manifest; counts.counts.eventCars += 1
		var linked = fixture.manifest; linked.counts.linkedCars = 0; linked.counts.matchedCars = 2
		var header = fixture.manifest; header.historyStart += 1
		for invalid in [hash, bytes, expansion, counts, linked, header] {
			do { try await store.install(file: fixture.file, pack: invalid); Issue.record("Accepted an invalid pack") }
			catch is OfflineFleetError {}
			#expect(await store.manifest() == legacy.manifest)
		}
		#expect(try await store.detail(id: "car:1").history.count == 2)
	}

	@Test func malformedRecordsCountsAndReferencesPreservePreviousPack() async throws {
		let fixture = try PackFixture()
		defer { fixture.remove() }
		let store = try OfflineFleetStore(directory: fixture.directory.appendingPathComponent("installed"))
		try await store.install(file: fixture.file, pack: fixture.manifest)
		let saved = await store.manifest()
		let invalidLines: [[[Any]]] = [
			Array(fixture.lines.dropLast()),
			fixture.lines + [["meta", "after-end", "{}"]],
			fixture.lines.enumerated().map { index, line in index == 1 ? ["car", "car:1", "{bad json"] : line },
			fixture.lines.enumerated().map { index, line in index == 3 ? ["assertion", "assertion:1", "car:missing", "{}"] : line },
			fixture.lines.enumerated().map { index, line in index == 5 ? ["event", "event:1", 999, fixture.eventJSON, ["car:missing", "car:1"]] : line },
			fixture.lines.enumerated().map { index, line in index == 5 ? ["event", "event:1", 999, fixture.eventJSON, ["car:1", "car:1"]] : line },
			fixture.lines.enumerated().map { index, line in index == 5 ? ["event", "event:1", 1001, fixture.eventJSON, ["car:1", "car:2"]] : line },
			fixture.lines.enumerated().map { index, line in index == 6 ? ["end", ["cars": 2, "consists": 1, "events": 2, "assertions": 1, "eventCars": 2, "matchedCars": 1, "linkedCars": 1]] : line }
		]
		for lines in invalidLines {
			let (file, manifest) = try fixture.archive(lines: lines)
			do { try await store.install(file: file, pack: manifest); Issue.record("Accepted malformed pack records") }
			catch is OfflineFleetError {}
			#expect(await store.manifest() == saved)
		}
		#expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.appendingPathComponent("installed").path).filter { $0.hasSuffix(".sqlite") }.count == 1)
	}

	@Test func gzipTrailerTrailingBytesAndLongLinesAreRejected() async throws {
		let fixture = try PackFixture()
		defer { fixture.remove() }
		let store = try OfflineFleetStore(directory: fixture.directory.appendingPathComponent("installed"))
		let compressed = try Data(contentsOf: fixture.file)
		for bytes in [Data(compressed.dropLast(4)), compressed + Data([0])] {
			let file = fixture.directory.appendingPathComponent(UUID().uuidString + ".gz")
			try bytes.write(to: file)
			var pack = fixture.manifest
			pack.archiveByteLength = Int64(bytes.count)
			pack.archiveSha256 = PackFixture.hash(bytes); pack.id = pack.archiveSha256
			do { try await store.install(file: file, pack: pack); Issue.record("Accepted a damaged gzip stream") }
			catch is OfflineFleetError {}
		}
		var lines = fixture.lines
		lines.insert(["meta", "large", "\"" + String(repeating: "x", count: 1_048_576) + "\""], at: 1)
		let (file, pack) = try fixture.archive(lines: lines)
		do { try await store.install(file: file, pack: pack); Issue.record("Accepted an unbounded JSON line") }
		catch is OfflineFleetError {}
		#expect(await store.manifest() == nil)
	}

	@Test func canceledPackInstallPreservesLegacyData() async throws {
		let legacy = try IntegrityFixture()
		defer { legacy.remove() }
		let fixture = try PackFixture()
		defer { fixture.remove() }
		let store = try OfflineFleetStore(directory: legacy.directory.appendingPathComponent("installed"))
		try await store.install(file: legacy.file, manifest: legacy.manifest)
		let task = Task {
			withUnsafeCurrentTask { $0?.cancel() }
			try await store.install(file: fixture.file, pack: fixture.manifest)
		}
		do { try await task.value; Issue.record("Activated a canceled pack") }
		catch is CancellationError {}
		#expect(await store.manifest() == legacy.manifest)
	}

	@Test func relaunchRemovesCandidateSidecarsAndPreservesActiveDatabase() async throws {
		let fixture = try PackFixture()
		defer { fixture.remove() }
		let directory = fixture.directory.appendingPathComponent("installed")
		let store = try OfflineFleetStore(directory: directory)
		try await store.install(file: fixture.file, pack: fixture.manifest)
		let saved = await store.manifest()
		let active = try #require(FileManager.default.contentsOfDirectory(atPath: directory.path).first { $0.hasSuffix(".sqlite") })
		for name in ["interrupted.sqlite", "interrupted.sqlite-journal", "interrupted.sqlite-wal", "interrupted.sqlite-shm", "orphan.sqlite-wal", active + "-shm"] {
			try Data([1, 2, 3]).write(to: directory.appendingPathComponent(name))
		}
		let reopened = try OfflineFleetStore(directory: directory)
		let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
		#expect(!names.contains { $0.hasPrefix("interrupted.") || $0.hasPrefix("orphan.") })
		#expect(names.contains(active + "-shm"), "The active database and its sidecars belong to the saved copy")
		#expect(await reopened.manifest() == saved)
		#expect(try await reopened.detail(id: "car:1").cars.count == 1)
	}

	@Test func recordsCanCrossEveryInputChunkBoundary() throws {
		let fixture = try PackFixture()
		defer { fixture.remove() }
		for chunkSize in [1, 31, 1024] {
			let output = fixture.directory.appendingPathComponent("chunks-\(chunkSize).sqlite")
			do {
				let importer = try FleetPackImporter(file: output, pack: fixture.manifest)
				try SnapshotFiles.inflateGzip(fixture.file, expectedBytes: fixture.manifest.uncompressedByteLength) { block in
					for start in stride(from: 0, to: block.count, by: chunkSize) {
						try importer.consume(block.subdata(in: start..<min(start + chunkSize, block.count)))
					}
				}
				try importer.finish()
			}
			try SnapshotDatabase(file: output).validate(pack: fixture.manifest)
		}
	}

	@Test func manifestBudgetAndCountsAreValidatedBeforeArithmetic() throws {
		let fixture = try PackFixture()
		defer { fixture.remove() }
		var huge = fixture.manifest; huge.estimatedSavedByteLength = Int64.max
		var days = fixture.manifest; days.selection.historyDays = 90
		var counts = fixture.manifest; counts.counts.matchedCars = -1
		var identity = fixture.manifest; identity.id = String(repeating: "0", count: 64)
		for invalid in [huge, days, counts, identity] {
			#expect(throws: OfflineFleetError.self) { try SnapshotFiles.validate(invalid) }
		}
	}
}

struct PackFixture: Sendable {
	let directory: URL
	let file: URL
	let manifest: FleetPackManifest
	var eventJSON: String { "{\"timestamp\":999,\"location\":\"Union Square\",\"route\":\"L\",\"tripKey\":\"trip\",\"consistId\":\"observed:pair\",\"cars\":[\"car:2\",\"car:1\",\"car:context\"]}" }
	var lines: [[Any]] {
		let car1 = "{\"id\":\"car:1\",\"number\":\"1\",\"equipment\":\"R1\",\"category\":\"passenger\",\"aliases\":[],\"lifecycle\":\"Active\",\"evidence\":[],\"fixedSet\":\"set:pair\",\"reporting\":true}"
		let car2 = car1.replacingOccurrences(of: "car:1", with: "car:2").replacingOccurrences(of: "\"number\":\"1\"", with: "\"number\":\"2\"").replacingOccurrences(of: "\"R1\"", with: "\"R10\"")
		return [
			["header", 2, 1000, 0, 1000, ["equipment": ["R1"], "yards": ["unknown"], "historyDays": 7]],
			["car", "car:1", car1], ["car", "car:2", car2],
			["assertion", "assertion:1", "car:1", "{}"],
			["consist", "observed:pair", "[\"car:2\",\"car:1\"]"],
			["event", "event:1", 999, eventJSON, ["car:1", "car:2"]],
			["end", ["cars": 2, "consists": 1, "events": 1, "assertions": 1, "eventCars": 2, "matchedCars": 1, "linkedCars": 1]]
		]
	}
	init() throws {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let file = directory.appendingPathComponent("initial.gz")
		let manifest = FleetPackManifest(id: String(repeating: "0", count: 64), generatedAt: 1000, historyStart: 0, historyEnd: 1000, selection: FleetPackSelection(equipment: ["R1"], yards: ["unknown"]), counts: FleetPackCounts(cars: 2, consists: 1, events: 1, assertions: 1, eventCars: 2, matchedCars: 1, linkedCars: 1), archiveByteLength: 1, archiveSha256: String(repeating: "0", count: 64), uncompressedByteLength: 1, estimatedSavedByteLength: 131_072, downloadURL: "/pack.gz")
		let seed = PackFixture(directory: directory, file: file, manifest: manifest)
		let result = try seed.archive(lines: seed.lines, destination: file)
		self = PackFixture(directory: directory, file: result.0, manifest: result.1)
	}
	private init(directory: URL, file: URL, manifest: FleetPackManifest) {
		self.directory = directory; self.file = file; self.manifest = manifest
	}
	func archive(lines: [[Any]], destination: URL? = nil) throws -> (URL, FleetPackManifest) {
		let bytes = try lines.reduce(into: Data()) { result, line in
			result.append(try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]))
			result.append(10)
		}
		let file = destination ?? directory.appendingPathComponent(UUID().uuidString + ".gz")
		let output = try #require(gzopen(file.path, "wb"))
		let written = bytes.withUnsafeBytes { gzwrite(output, $0.baseAddress, UInt32($0.count)) }
		#expect(gzclose(output) == Z_OK && written == bytes.count)
		let compressed = try Data(contentsOf: file)
		var pack = manifest
		pack.archiveByteLength = Int64(compressed.count)
		pack.archiveSha256 = Self.hash(compressed); pack.id = pack.archiveSha256
		pack.uncompressedByteLength = Int64(bytes.count)
		return (file, pack)
	}
	static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
	func remove() { try? FileManager.default.removeItem(at: directory) }
}
