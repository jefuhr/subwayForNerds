import CryptoKit
import Foundation

/// Versioned, file-backed offline cache for boards, trip snapshots, saved trips
/// and the active ride. Every snapshot is its own atomically written file, so a
/// failed write leaves the previous snapshot readable. The snapshot files are the
/// source of truth: the index only records sizes, save and access times. It is
/// rebuilt from the files when lost, reconciled against them once per launch, and
/// repaired whenever a save finds it out of step with a file. Protection lives in
/// the snapshot (manual saves) and ride files, never only in the index.
///
/// Replacement rule: only strictly newer source data replaces stored data. An
/// unchanged (or older) response keeps the stored snapshot and its source time.
/// Board feeds are compared one source group at a time (`OfflinePlanner.mergeBoard`),
/// and only a newer prediction feed renews a board's save time.
/// Saved trips and the active ride's trip are never expired or evicted for space.
public actor OfflineTransitStore {
	public static let formatVersion = 1
	/// Access times are best effort: they are kept in memory and written with the
	/// next index write, or at most this often on reads alone.
	public static let accessFlushInterval: TimeInterval = 60
	private let root: URL
	private let legacyBoardDirectory: URL?
	private let readOnly: Bool
	private let clock: @Sendable () -> TimeInterval
	private var preferences = OfflinePreferences()
	private var recordedFailures: [OfflineSaveFailure] = []
	private var cachedIndex: (stamp: Date, index: Index)?
	private var reconciled = false
	private var pendingAccess: [String: TimeInterval] = [:]
	private var lastAccessFlush: TimeInterval?
	/// Test hook: the next N index writes fail as if the disk were full.
	var failingIndexWrites = 0

	/// - Parameters:
	///   - directory: the store's own directory (it writes into a `v1` subdirectory).
	///   - legacyBoardDirectory: where the previous cache wrote `board-*.json`; imported once per endpoint, never modified.
	///   - readOnly: for widget extensions reading the app group copy. Reads never write access times.
	public init(directory: URL, legacyBoardDirectory: URL? = nil, readOnly: Bool = false, clock: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }) {
		root = directory.appendingPathComponent("v\(Self.formatVersion)", isDirectory: true)
		self.legacyBoardDirectory = legacyBoardDirectory
		self.readOnly = readOnly
		self.clock = clock
	}

	public func setPreferences(_ preferences: OfflinePreferences) { self.preferences = preferences }

	func injectIndexWriteFailures(_ count: Int) { failingIndexWrites = count }

	// MARK: Boards

	/// Merges the board into the stored snapshot. `.stored` means some source group
	/// moved forward; the save time renews only when a prediction feed did, so an
	/// alerts or car-assignment update never makes stale predictions look fresh.
	@discardableResult
	public func saveBoard(_ board: Board, endpoint: String, viewedStationID: String? = nil, distanceMeters: Double? = nil) throws -> OfflineSaveResult {
		migrateLegacyBoardsIfNeeded(endpoint: endpoint)
		let identity = OfflineIdentity.board(endpoint: endpoint, stationID: board.station.id)
		return try recording(.board, identity) {
			let now = clock()
			let existing: CachedBoard? = read(.board, identity)
			let merged = OfflinePlanner.mergeBoard(board, into: existing?.board)
			guard merged.advanced else {
				try repairIndexEntry(.board, identity)
				noteAccess(identity, now: now)
				return .unchanged
			}
			let savedAt = merged.predictionsAdvanced ? now : existing?.savedAt ?? now
			let retained = OfflinePlanner.retainedBoard(merged.board, preferences: preferences)
			try write(CachedBoard(endpoint: endpoint, board: retained, savedAt: savedAt, accessedAt: now, viewedStationID: viewedStationID ?? existing?.viewedStationID, distanceMeters: distanceMeters ?? existing?.distanceMeters), kind: .board, identity: identity, endpoint: endpoint, key: board.station.id, savedAt: savedAt, manual: false)
			evictAfterSave()
			return .stored
		}
	}

	public func board(stationID: String, endpoint: String) -> CachedBoard? {
		migrateLegacyBoardsIfNeeded(endpoint: endpoint)
		let identity = OfflineIdentity.board(endpoint: endpoint, stationID: stationID)
		guard var value: CachedBoard = read(.board, identity) else { return nil }
		value.accessedAt = markAccessed(identity) ?? value.accessedAt
		return value
	}

	// MARK: Trips

	/// Stores a trip detail when it is newer than the snapshot. `manuallySaved: true`
	/// adds it to the saved list, `false` removes it, `nil` keeps the current flag.
	/// A manually saved PATH snapshot is immutable: its key is positional. The first
	/// manual save of a PATH key stores the candidate the user saw, even over a newer
	/// automatic snapshot that may describe the next train in that position.
	@discardableResult
	public func saveTrip(_ detail: TripDetail, endpoint: String, departure: Departure? = nil, manuallySaved: Bool? = nil) throws -> OfflineSaveResult {
		var candidate = CachedTrip(tripKey: detail.train.key, endpoint: endpoint, detail: detail, departure: departure, savedAt: 0, accessedAt: 0)
		return try recording(manuallySaved == true ? .savedTrip : .trip, candidate.id) {
			let existing: CachedTrip? = read(.trip, candidate.id)
			if candidate.departure == nil, !Self.isFirstPositionalSave(candidate.tripKey, existing: existing, manuallySaved: manuallySaved) { candidate.departure = existing?.departure }
			candidate.boardingStationID = existing?.boardingStationID
			candidate.boardingStationName = existing?.boardingStationName
			return try store(candidate, existing: existing, manuallySaved: manuallySaved) { old, new in
				guard let newTime = new.sourceTimestamp else { return false }
				guard let oldTime = old.sourceTimestamp else { return true }
				return newTime > oldTime || (!old.isComplete && newTime >= oldTime)
			}
		}
	}

	/// Board onward stops as a fallback when no trip detail is available. Never
	/// replaces a complete snapshot. Pass the board's `station` so the boarding stop
	/// is named; the departure's position text is never used as a stop name.
	@discardableResult
	public func savePartialTrip(_ departure: Departure, endpoint: String, manuallySaved: Bool? = nil, station: Station? = nil) throws -> OfflineSaveResult {
		let candidate = CachedTrip(tripKey: departure.tripKey, endpoint: endpoint, departure: departure, savedAt: 0, accessedAt: 0, boardingStationID: station?.id, boardingStationName: station?.name)
		return try recording(manuallySaved == true ? .savedTrip : .trip, candidate.id) {
			try store(candidate, existing: read(.trip, candidate.id), manuallySaved: manuallySaved) { old, new in
				guard !old.isComplete, let newTime = new.sourceTimestamp else { return false }
				return old.sourceTimestamp.map { newTime > $0 } ?? true
			}
		}
	}

	public func trip(key: String, endpoint: String) -> CachedTrip? {
		let identity = OfflineIdentity.trip(endpoint: endpoint, tripKey: key)
		guard var value: CachedTrip = read(.trip, identity) else { return nil }
		value.accessedAt = markAccessed(identity) ?? value.accessedAt
		return value
	}

	/// Manual saves, newest snapshot first.
	public func savedTrips(endpoint: String) -> [CachedTrip] { trips(endpoint: endpoint) { $0.manual } }

	/// Every cached trip for the endpoint, most recently used first.
	public func cachedTrips(endpoint: String) -> [CachedTrip] {
		trips(endpoint: endpoint) { _ in true }.sorted { $0.accessedAt == $1.accessedAt ? $0.tripKey < $1.tripKey : $0.accessedAt > $1.accessedAt }
	}

	/// `false` is the explicit removal from the saved list; the snapshot then
	/// becomes an automatic entry that expires normally.
	public func setManuallySaved(_ saved: Bool, tripKey: String, endpoint: String) throws {
		let identity = OfflineIdentity.trip(endpoint: endpoint, tripKey: tripKey)
		try recording(.savedTrip, identity) {
			guard var trip: CachedTrip = read(.trip, identity) else { throw OfflineStoreError.notCached }
			guard trip.manuallySaved != saved else {
				// The file already agrees; make sure the index does too.
				try repairIndexEntry(.trip, identity)
				return
			}
			trip.manuallySaved = saved
			try write(trip, kind: .trip, identity: identity, endpoint: endpoint, key: tripKey, savedAt: trip.savedAt, manual: saved)
		}
	}

	/// Explicitly deletes a snapshot. The active ride's trip is kept (unsaved) until the ride ends.
	public func removeTrip(key: String, endpoint: String) throws {
		let identity = OfflineIdentity.trip(endpoint: endpoint, tripKey: key)
		try recording(.savedTrip, identity) {
			if activeRide(endpoint: endpoint)?.tripKey == key {
				if (read(.trip, identity) as CachedTrip?) != nil { try setManuallySaved(false, tripKey: key, endpoint: endpoint) }
				return
			}
			try requireWritable()
			let url = fileURL(.trip, identity)
			if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
			var index = loadIndex()
			if index.entries.removeValue(forKey: identity) != nil { try saveIndex(index) }
		}
	}

	// MARK: Active ride

	public func activeRide(endpoint: String) -> ActiveRide? { readRide(rideURL(endpoint))?.ride }

	/// One active ride per endpoint partition, replacing any previous ride. `nil`
	/// ends the ride; its trip becomes automatic unless it was also saved manually.
	/// PATH trips cannot be ridden: their keys do not follow a train.
	public func setActiveRide(_ ride: ActiveRide?, endpoint: String) throws {
		try recording(.activeRide, OfflineEndpoint.key(endpoint)) {
			try requireWritable()
			let url = rideURL(endpoint)
			guard let ride else {
				if let previous = activeRide(endpoint: endpoint) { _ = markAccessed(OfflineIdentity.trip(endpoint: endpoint, tripKey: previous.tripKey)) }
				if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
				return
			}
			guard !OfflineIdentity.isPositionalTrip(ride.tripKey) else { throw OfflineStoreError.positionalTrip }
			try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
			try Self.writeAtomically(JSONEncoder().encode(Envelope(version: Self.formatVersion, value: RideRecord(endpoint: endpoint, ride: ride))), to: url)
		}
	}

	// MARK: Maintenance

	/// Uses explicit preferences and time, for callers that prune on their own schedule.
	@discardableResult
	public func prune(preferences: OfflinePreferences, now: TimeInterval) throws -> OfflineEvictionReport {
		self.preferences = preferences
		return try evict(now: now)
	}

	/// Expires automatic entries saved longer ago than the retention period, then
	/// evicts the least recently used automatic entries until the cache fits.
	@discardableResult
	public func evict() throws -> OfflineEvictionReport { try evict(now: clock()) }

	/// Removes every automatic board and trip for the endpoint partition. Saved trips
	/// and the active ride's trip stay. Removed entries are reported as evicted.
	@discardableResult
	public func removeAutomaticEntries(endpoint: String) throws -> OfflineEvictionReport {
		try recording(.eviction, OfflineEndpoint.key(endpoint)) {
			try requireWritable()
			let partition = OfflineEndpoint.key(endpoint)
			var index = loadIndex()
			let protected = protectedIdentities()
			var report = OfflineEvictionReport()
			for entry in index.entries.values.sorted(by: { $0.identity < $1.identity }) where entry.endpoint == partition && !entry.manual && !protected.contains(entry.identity) {
				if entry.kind == .trip, let trip: CachedTrip = read(.trip, entry.identity), trip.manuallySaved {
					index.entries[entry.identity]?.manual = true
					continue
				}
				let url = fileURL(entry.kind, entry.identity)
				if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
				index.entries.removeValue(forKey: entry.identity)
				if entry.kind == .trip { report.evictedTripKeys.append(entry.key) } else { report.evictedStationIDs.append(entry.key) }
			}
			try saveIndex(index)
			return report
		}
	}

	/// Writes in-memory access times now, for example when the app moves to the background.
	public func flushAccessTimes() throws {
		guard !readOnly, !pendingAccess.isEmpty else { return }
		try saveIndex(loadIndex())
	}

	private func evict(now: TimeInterval) throws -> OfflineEvictionReport {
		try recording(.eviction, "cache") {
			try requireWritable()
			var index = loadIndex()
			let protected = protectedIdentities()
			var report = OfflineEvictionReport()
			var changed = false
			/// Returns whether the entry's bytes left the cache.
			func remove(_ entry: IndexEntry, expired: Bool) -> Bool {
				// A snapshot written as manual since the index was read stays protected,
				// and the stale index entry is corrected.
				if entry.kind == .trip, let trip: CachedTrip = read(.trip, entry.identity), trip.manuallySaved {
					index.entries[entry.identity]?.manual = true
					changed = true
					return false
				}
				let url = fileURL(entry.kind, entry.identity)
				if FileManager.default.fileExists(atPath: url.path) {
					do { try FileManager.default.removeItem(at: url) } catch { return false }
				}
				index.entries.removeValue(forKey: entry.identity)
				changed = true
				switch (entry.kind, expired) {
				case (.trip, true): report.expiredTripKeys.append(entry.key)
				case (.trip, false): report.evictedTripKeys.append(entry.key)
				case (.board, true): report.expiredStationIDs.append(entry.key)
				case (.board, false): report.evictedStationIDs.append(entry.key)
				}
				return true
			}
			let candidates = index.entries.values.filter { !$0.manual && !protected.contains($0.identity) }
				.sorted { $0.accessedAt == $1.accessedAt ? $0.identity < $1.identity : $0.accessedAt < $1.accessedAt }
			for entry in candidates where now - entry.savedAt > preferences.retention { _ = remove(entry, expired: true) }
			var total = index.entries.values.reduce(0) { $0 + $1.bytes }
			for entry in candidates where index.entries[entry.identity] != nil && total > preferences.storageLimitBytes {
				if remove(entry, expired: false) { total -= entry.bytes }
			}
			if changed { try saveIndex(index) }
			return report
		}
	}

	public func usage() -> OfflineStorageUsage {
		let entries = Array(loadIndex().entries.values)
		let protected = protectedIdentities()
		let total = entries.reduce(0) { $0 + $1.bytes }
		let protectedBytes = entries.filter { $0.manual || protected.contains($0.identity) }.reduce(0) { $0 + $1.bytes }
		return OfflineStorageUsage(totalBytes: total, protectedBytes: protectedBytes, boardCount: entries.filter { $0.kind == .board }.count, tripCount: entries.filter { $0.kind == .trip }.count, savedTripCount: entries.filter { $0.kind == .trip && $0.manual }.count, overLimit: total > preferences.storageLimitBytes)
	}

	/// Saves that could not be written, newest last. Shown to the user; never silently dropped.
	public func failures() -> [OfflineSaveFailure] { recordedFailures }
	public func clearFailures() { recordedFailures.removeAll() }

	/// Imports boards written by the previous per-station cache. Files are matched by
	/// decoding their contents (not by name) and are never modified or deleted.
	/// Runs once per endpoint partition.
	@discardableResult
	public func importLegacyBoards(from directory: URL, endpoint: String) -> Int {
		guard !readOnly else { return 0 }
		let marker = root.appendingPathComponent("legacy-\(Self.digest(OfflineEndpoint.key(endpoint))).json")
		guard !FileManager.default.fileExists(atPath: marker.path) else { return 0 }
		var imported = 0
		let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
			.filter { $0.lastPathComponent.hasPrefix("board-") && $0.pathExtension == "json" }
			.sorted { $0.lastPathComponent < $1.lastPathComponent }
		for url in files {
			guard let data = try? Data(contentsOf: url), let board = try? JSONDecoder().decode(Board.self, from: data) else { continue }
			let identity = OfflineIdentity.board(endpoint: endpoint, stationID: board.station.id)
			let existing: CachedBoard? = read(.board, identity)
			let merged = OfflinePlanner.mergeBoard(board, into: existing?.board)
			if existing != nil, !merged.advanced { continue }
			// Legacy files carry no save time: their modification date ages them out normally.
			// Merged into a stored board, newer stored groups stay, and the save time only
			// moves forward, and only when a prediction feed advanced, as for a fetched board.
			let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? clock()
			let savedAt = existing.map { merged.predictionsAdvanced ? max($0.savedAt, modified) : $0.savedAt } ?? modified
			let accessedAt = existing.map { max($0.accessedAt, modified) } ?? modified
			do {
				try write(CachedBoard(endpoint: endpoint, board: OfflinePlanner.retainedBoard(merged.board, preferences: preferences), savedAt: savedAt, accessedAt: accessedAt, viewedStationID: existing?.viewedStationID, distanceMeters: existing?.distanceMeters), kind: .board, identity: identity, endpoint: endpoint, key: board.station.id, savedAt: savedAt, manual: false)
				imported += 1
			} catch { record(.migration, identity, error) }
		}
		do {
			try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
			try Self.writeAtomically(JSONEncoder().encode(Envelope(version: Self.formatVersion, value: imported)), to: marker)
		} catch { record(.migration, OfflineEndpoint.key(endpoint), error) }
		return imported
	}

	private func migrateLegacyBoardsIfNeeded(endpoint: String) {
		guard let legacyBoardDirectory else { return }
		importLegacyBoards(from: legacyBoardDirectory, endpoint: endpoint)
	}

	// MARK: Replacement

	private func store(_ candidate: CachedTrip, existing: CachedTrip?, manuallySaved: Bool?, isNewer: (CachedTrip, CachedTrip) -> Bool) throws -> OfflineSaveResult {
		let now = clock()
		let frozen = existing.map { $0.manuallySaved && OfflineIdentity.isPositionalTrip($0.tripKey) } ?? false
		let firstPositionalSave = Self.isFirstPositionalSave(candidate.tripKey, existing: existing, manuallySaved: manuallySaved)
		if let existing, frozen || (!firstPositionalSave && !isNewer(existing, candidate)) {
			var kept = existing
			if kept.boardingStationName == nil, candidate.boardingStationName != nil {
				kept.boardingStationID = candidate.boardingStationID
				kept.boardingStationName = candidate.boardingStationName
			}
			if let manuallySaved { kept.manuallySaved = manuallySaved }
			if kept != existing {
				try write(kept, kind: .trip, identity: existing.id, endpoint: existing.endpoint, key: existing.tripKey, savedAt: existing.savedAt, manual: kept.manuallySaved)
			} else {
				// An earlier save may have written this file but not its index entry.
				try repairIndexEntry(.trip, existing.id)
				noteAccess(existing.id, now: now)
			}
			return .unchanged
		}
		var value = candidate
		value.savedAt = now
		value.accessedAt = now
		value.manuallySaved = manuallySaved ?? existing?.manuallySaved ?? false
		try write(value, kind: .trip, identity: value.id, endpoint: value.endpoint, key: value.tripKey, savedAt: now, manual: value.manuallySaved)
		evictAfterSave()
		return .stored
	}

	/// A positional key cannot tell trains apart, so the first manual save keeps what
	/// the user saw rather than a newer automatic snapshot of that position.
	private static func isFirstPositionalSave(_ tripKey: String, existing: CachedTrip?, manuallySaved: Bool?) -> Bool {
		manuallySaved == true && OfflineIdentity.isPositionalTrip(tripKey) && existing?.manuallySaved != true
	}

	/// Eviction failures are recorded by `evict`; the save itself already succeeded.
	private func evictAfterSave() { _ = try? evict() }

	private func trips(endpoint: String, where include: (IndexEntry) -> Bool) -> [CachedTrip] {
		let partition = OfflineEndpoint.key(endpoint)
		return loadIndex().entries.values.filter { $0.kind == .trip && $0.endpoint == partition && include($0) }
			.compactMap { entry -> CachedTrip? in
				guard var trip: CachedTrip = read(.trip, entry.identity) else { return nil }
				trip.accessedAt = max(trip.accessedAt, entry.accessedAt)
				return trip
			}
			.sorted { $0.savedAt == $1.savedAt ? $0.tripKey < $1.tripKey : $0.savedAt > $1.savedAt }
	}

	// MARK: Files

	enum Kind: String, Codable, CaseIterable { case board, trip }
	struct IndexEntry: Codable, Equatable {
		var identity: String
		var kind: Kind
		/// The endpoint partition key, not the raw endpoint.
		var endpoint: String
		var key: String
		var bytes: Int
		var savedAt: TimeInterval
		var accessedAt: TimeInterval
		var manual: Bool
	}
	struct Index: Codable {
		var version = OfflineTransitStore.formatVersion
		var entries: [String: IndexEntry] = [:]
	}
	struct Envelope<Value: Codable>: Codable {
		var version: Int
		var value: Value
	}
	struct RideRecord: Codable {
		var endpoint: String
		var ride: ActiveRide
	}
	private struct SnapshotHeader: Decodable {
		struct Value: Decodable { var endpoint: String; var savedAt: TimeInterval; var accessedAt: TimeInterval; var tripKey: String?; var manuallySaved: Bool?; var board: BoardHeader? }
		struct BoardHeader: Decodable { var station: StationHeader }
		struct StationHeader: Decodable { var id: String }
		var version: Int
		var value: Value
	}

	private var indexURL: URL { root.appendingPathComponent("index.json") }
	private var ridesDirectory: URL { root.appendingPathComponent("rides", isDirectory: true) }
	private func directory(_ kind: Kind) -> URL { root.appendingPathComponent(kind == .board ? "boards" : "trips", isDirectory: true) }
	private func fileURL(_ kind: Kind, _ identity: String) -> URL { directory(kind).appendingPathComponent(Self.digest(identity) + ".json") }
	private func rideURL(_ endpoint: String) -> URL { ridesDirectory.appendingPathComponent(Self.digest(OfflineEndpoint.key(endpoint)) + ".json") }
	/// SHA-256 file names avoid path length limits and case-insensitive collisions.
	static func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }

	static func writeAtomically(_ data: Data, to url: URL) throws {
		#if os(iOS)
		try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
		#else
		try data.write(to: url, options: .atomic)
		#endif
	}

	private func read<Value: Codable>(_ kind: Kind, _ identity: String) -> Value? {
		guard let data = try? Data(contentsOf: fileURL(kind, identity)), let envelope = try? JSONDecoder().decode(Envelope<Value>.self, from: data), envelope.version == Self.formatVersion else { return nil }
		return envelope.value
	}

	private func readRide(_ url: URL) -> RideRecord? {
		guard let data = try? Data(contentsOf: url), let envelope = try? JSONDecoder().decode(Envelope<RideRecord>.self, from: data), envelope.version == Self.formatVersion else { return nil }
		return envelope.value
	}

	private func write<Value: Codable>(_ value: Value, kind: Kind, identity: String, endpoint: String, key: String, savedAt: TimeInterval, manual: Bool) throws {
		try requireWritable()
		let url = fileURL(kind, identity)
		try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		let data = try JSONEncoder().encode(Envelope(version: Self.formatVersion, value: value))
		try Self.writeAtomically(data, to: url)
		var index = loadIndex()
		let accessed = max(index.entries[identity]?.accessedAt ?? 0, clock())
		index.entries[identity] = IndexEntry(identity: identity, kind: kind, endpoint: OfflineEndpoint.key(endpoint), key: key, bytes: data.count, savedAt: savedAt, accessedAt: accessed, manual: manual)
		try saveIndex(index)
	}

	/// Makes the index entry match the snapshot file (adding, correcting or removing it).
	/// Writes the index only when they disagree.
	private func repairIndexEntry(_ kind: Kind, _ identity: String) throws {
		guard !readOnly else { return }
		var index = loadIndex()
		let fromFile = entry(kind, at: fileURL(kind, identity))
		var expected = fromFile
		if let current = index.entries[identity] { expected?.accessedAt = max(current.accessedAt, fromFile?.accessedAt ?? 0) }
		guard index.entries[identity] != expected else { return }
		index.entries[identity] = expected
		try saveIndex(index)
	}

	/// Records an access in memory. Flushed with the next index write, or once the
	/// flush interval has passed, so frequent reads do not rewrite the index.
	private func noteAccess(_ identity: String, now: TimeInterval) {
		guard !readOnly else { return }
		pendingAccess[identity] = max(pendingAccess[identity] ?? 0, now)
		if let last = lastAccessFlush, now - last < Self.accessFlushInterval { return }
		if lastAccessFlush == nil { lastAccessFlush = now; return }
		try? saveIndex(loadIndex())
	}

	private func markAccessed(_ identity: String) -> TimeInterval? {
		guard !readOnly else { return nil }
		let now = clock()
		noteAccess(identity, now: now)
		return now
	}

	/// Reads the index (cached until the file changes on disk, so the app and widget
	/// processes still see each other's writes) and overlays unwritten access times.
	/// A missing or unreadable index is rebuilt from the snapshot files; the first
	/// load in each process also reconciles the index against those files.
	private func loadIndex() -> Index {
		let stamp = (try? FileManager.default.attributesOfItem(atPath: indexURL.path))?[.modificationDate] as? Date
		var index: Index
		if let stamp, let cachedIndex, cachedIndex.stamp == stamp {
			index = cachedIndex.index
		} else if let data = try? Data(contentsOf: indexURL), let decoded = try? JSONDecoder().decode(Index.self, from: data), decoded.version == Self.formatVersion {
			index = decoded
			if let stamp { cachedIndex = (stamp, decoded) }
		} else {
			index = Index()
			reconcile(&index)
			reconciled = true
		}
		if !reconciled {
			reconciled = true
			var repaired = index
			reconcile(&repaired)
			if repaired.entries != index.entries {
				index = repaired
				if !readOnly { try? saveIndex(index) }
			}
		}
		for (identity, time) in pendingAccess where index.entries[identity] != nil {
			index.entries[identity]!.accessedAt = max(index.entries[identity]!.accessedAt, time)
		}
		return index
	}

	/// Runs once per launch (or on rebuild). Adds entries for snapshot files the
	/// index lacks, drops entries whose file is gone, and repairs the metadata of
	/// existing entries from their file headers: a snapshot rewritten just before a
	/// failed index write (a manual save, or a newer snapshot with a new size and
	/// save time) is corrected here even if the app never retried. The index's own
	/// newer access time is kept.
	private func reconcile(_ index: inout Index) {
		for kind in Kind.allCases {
			let files = ((try? FileManager.default.contentsOfDirectory(at: directory(kind), includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "json" }
			let names = Set(files.map(\.lastPathComponent))
			var indexed: [String: String] = [:]
			for entry in index.entries.values where entry.kind == kind { indexed[Self.digest(entry.identity) + ".json"] = entry.identity }
			for (name, identity) in indexed where !names.contains(name) { index.entries.removeValue(forKey: identity) }
			for url in files {
				guard var fromFile = entry(kind, at: url) else { continue }
				if let identity = indexed[url.lastPathComponent], let current = index.entries[identity] {
					fromFile.accessedAt = max(current.accessedAt, fromFile.accessedAt)
					if identity != fromFile.identity { index.entries.removeValue(forKey: identity) }
				}
				index.entries[fromFile.identity] = fromFile
			}
		}
	}

	/// An index entry built from a snapshot file, or nil when it is missing or unreadable.
	private func entry(_ kind: Kind, at url: URL) -> IndexEntry? {
		guard let data = try? Data(contentsOf: url), let header = try? JSONDecoder().decode(SnapshotHeader.self, from: data), header.version == Self.formatVersion else { return nil }
		let value = header.value
		guard let key = kind == .trip ? value.tripKey : value.board?.station.id else { return nil }
		let identity = kind == .trip ? OfflineIdentity.trip(endpoint: value.endpoint, tripKey: key) : OfflineIdentity.board(endpoint: value.endpoint, stationID: key)
		guard fileURL(kind, identity).lastPathComponent == url.lastPathComponent else { return nil }
		return IndexEntry(identity: identity, kind: kind, endpoint: OfflineEndpoint.key(value.endpoint), key: key, bytes: data.count, savedAt: value.savedAt, accessedAt: value.accessedAt, manual: value.manuallySaved ?? false)
	}

	private func saveIndex(_ index: Index) throws {
		try requireWritable()
		if failingIndexWrites > 0 {
			failingIndexWrites -= 1
			throw CocoaError(.fileWriteOutOfSpace)
		}
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		var written = index
		for (identity, time) in pendingAccess where written.entries[identity] != nil {
			written.entries[identity]!.accessedAt = max(written.entries[identity]!.accessedAt, time)
		}
		try Self.writeAtomically(JSONEncoder().encode(written), to: indexURL)
		pendingAccess.removeAll()
		lastAccessFlush = clock()
		if let stamp = (try? FileManager.default.attributesOfItem(atPath: indexURL.path))?[.modificationDate] as? Date { cachedIndex = (stamp, written) }
		else { cachedIndex = nil }
	}

	/// Every active ride's trip, read from the ride files themselves so protection
	/// does not depend on the index or on which endpoint is current.
	private func protectedIdentities() -> Set<String> {
		let files = (try? FileManager.default.contentsOfDirectory(at: ridesDirectory, includingPropertiesForKeys: nil)) ?? []
		return Set(files.compactMap(readRide).map { OfflineIdentity.trip(endpoint: $0.endpoint, tripKey: $0.ride.tripKey) })
	}

	private func requireWritable() throws { if readOnly { throw OfflineStoreError.readOnly } }

	private func recording<T>(_ kind: OfflineSaveFailure.Kind, _ identity: String, _ body: () throws -> T) throws -> T {
		do { return try body() }
		catch { record(kind, identity, error); throw error }
	}

	private func record(_ kind: OfflineSaveFailure.Kind, _ identity: String, _ error: Error) {
		let failure = OfflineSaveFailure(kind: kind, identity: identity, message: error.localizedDescription, failedAt: clock())
		recordedFailures.removeAll { $0.id == failure.id }
		recordedFailures.append(failure)
		if recordedFailures.count > 50 { recordedFailures.removeFirst(recordedFailures.count - 50) }
	}
}

public enum OfflineStoreError: Error, LocalizedError, Sendable, Equatable {
	case readOnly, notCached, positionalTrip
	public var errorDescription: String? {
		switch self {
		case .readOnly: "Offline data is read-only here."
		case .notCached: "This trip is not saved on this device yet."
		case .positionalTrip: "PATH arrival estimates are not linked to a train, so they cannot be followed as a ride."
		}
	}
}
