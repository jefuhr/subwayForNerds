import Foundation
import CoreFoundation
import CSQLite
import TransitCore

/// Imports one bounded JSON line at a time, directly into the candidate database.
/// The local query schema stays at version 1; the transport and snapshot metadata are v2.
final class FleetPackImporter {
	private var db: OpaquePointer?
	private let pack: FleetPackManifest
	private let directory: URL
	private var lowSpace = false
	private var statements: [String: OpaquePointer] = [:]
	private var pending = Data()
	private var sawHeader = false
	private var sawEnd = false
	private var metaCount = 0
	private var counts = FleetPackCounts(cars: 0, consists: 0, events: 0, assertions: 0, eventCars: 0, matchedCars: 0, linkedCars: 0)
	private let decoder = JSONDecoder()
	static let maximumLineBytes = 1_048_576

	init(file: URL, pack: FleetPackManifest) throws {
		self.pack = pack
		self.directory = file.deletingLastPathComponent()
		guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
			if db != nil { sqlite3_close(db) }; db = nil
			throw OfflineFleetError.invalid("The fleet pack could not be saved.")
		}
		sqlite3_progress_handler(db, 10_000, { context in
			guard let context else { return 1 }
			let importer = Unmanaged<FleetPackImporter>.fromOpaque(context).takeUnretainedValue()
			if Task.isCancelled { return 1 }
			do { try importer.checkSpace(); return 0 }
			catch { return 1 }
		}, Unmanaged.passUnretained(self).toOpaque())
		do {
			try execute("""
			PRAGMA journal_mode=DELETE;
			PRAGMA foreign_keys=ON;
			PRAGMA user_version=1;
			PRAGMA cache_size=-4096;
			CREATE TABLE meta(key TEXT PRIMARY KEY NOT NULL,data TEXT NOT NULL);
			CREATE TABLE cars(id TEXT PRIMARY KEY NOT NULL,data TEXT NOT NULL);
			CREATE TABLE assertions(id TEXT PRIMARY KEY NOT NULL,car_id TEXT NOT NULL REFERENCES cars(id) DEFERRABLE INITIALLY DEFERRED,data TEXT NOT NULL);
			CREATE TABLE consists(id TEXT PRIMARY KEY NOT NULL,data TEXT NOT NULL);
			CREATE TABLE events(id TEXT PRIMARY KEY NOT NULL,timestamp INTEGER NOT NULL,data TEXT NOT NULL);
			CREATE TABLE event_cars(event_id TEXT NOT NULL REFERENCES events(id) DEFERRABLE INITIALLY DEFERRED,car_id TEXT NOT NULL REFERENCES cars(id) DEFERRABLE INITIALLY DEFERRED,PRIMARY KEY(event_id,car_id));
			BEGIN;
			""")
		} catch { sqlite3_close(db); db = nil; throw error }
	}
	deinit {
		for statement in statements.values { sqlite3_finalize(statement) }
		sqlite3_close(db)
	}

	func consume(_ block: Data) throws {
		try checkSpace()
		var start = block.startIndex
		while start < block.endIndex {
			try Task.checkCancellation()
			let newline = block[start...].firstIndex(of: 10)
			let end = newline ?? block.endIndex
			guard end - start <= Self.maximumLineBytes - pending.count else {
				throw OfflineFleetError.invalid("A fleet pack record exceeds the supported size.")
			}
			pending.append(contentsOf: block[start..<end])
			if let newline {
				try record(pending)
				pending.removeAll(keepingCapacity: true)
				start = newline + 1
			} else { break }
		}
	}

	func finish() throws {
		try Task.checkCancellation()
		if !pending.isEmpty { try record(pending); pending.removeAll() }
		guard sawHeader, sawEnd else { throw invalidRecords }
		let metadata: [String: Any] = ["schemaVersion": 2, "generatedAt": pack.generatedAt,
			"historyStart": pack.historyStart, "historyEnd": pack.historyEnd,
			"selection": try JSONSerialization.jsonObject(with: JSONEncoder().encode(pack.selection))]
		let raw = String(decoding: try JSONSerialization.data(withJSONObject: metadata), as: UTF8.self)
		try insert("INSERT INTO meta(key,data) VALUES('snapshot',?) ON CONFLICT(key) DO UPDATE SET data=excluded.data", [raw])
		try execute("""
		CREATE INDEX car_category ON cars(json_extract(data,'$.category'));
		CREATE INDEX car_equipment ON cars(json_extract(data,'$.equipment'));
		CREATE INDEX car_fixed_set ON cars(json_extract(data,'$.fixedSet'));
		CREATE INDEX assertion_car_lookup ON assertions(car_id);
		CREATE INDEX event_car_lookup ON event_cars(car_id,event_id);
		CREATE INDEX event_time ON events(timestamp DESC,id DESC);
		CREATE INDEX event_consist_time ON events(json_extract(data,'$.consistId'),timestamp DESC,id DESC);
		COMMIT;
		""")
		try Task.checkCancellation()
	}

	private func record(_ bytes: Data) throws {
		guard !sawEnd, !bytes.isEmpty,
			let values = try? JSONSerialization.jsonObject(with: bytes) as? [Any],
			let kind = values.first as? String else { throw invalidRecords }
		if !sawHeader {
			guard kind == "header", values.count == 6, integer(values[1]) == 2,
				number(values[2]) == pack.generatedAt, number(values[3]) == pack.historyStart,
				number(values[4]) == pack.historyEnd,
				try decoded(FleetPackSelection.self, values[5]) == pack.selection else { throw invalidRecords }
			sawHeader = true
			return
		}
		switch kind {
		case "meta":
			guard values.count == 3, metaCount < 256 else { throw invalidRecords }
			let key = try identifier(values[1]), raw = try rawJSON(values[2])
			if key == "snapshot" {
				guard let metadata = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
					metadata["schemaVersion"].flatMap(integer) == 2,
					metadata["generatedAt"].flatMap(number) == pack.generatedAt,
					metadata["historyStart"].flatMap(number) == pack.historyStart,
					metadata["historyEnd"].flatMap(number) == pack.historyEnd else { throw invalidRecords }
			}
			try insert("INSERT INTO meta VALUES(?,?)", [key, raw]); metaCount += 1
		case "car":
			guard values.count == 3, counts.cars < pack.counts.cars else { throw invalidRecords }
			let id = try identifier(values[1]), raw = try rawJSON(values[2])
			guard let car = try? decoder.decode(FleetCar.self, from: Data(raw.utf8)), car.id == id else { throw invalidRecords }
			try insert("INSERT INTO cars VALUES(?,?)", [id, raw]); counts.cars += 1
		case "assertion":
			guard values.count == 4, counts.assertions < pack.counts.assertions else { throw invalidRecords }
			try insert("INSERT INTO assertions VALUES(?,?,?)", [try identifier(values[1]), try identifier(values[2]), try rawJSON(values[3])]); counts.assertions += 1
		case "consist":
			guard values.count == 3, counts.consists < pack.counts.consists else { throw invalidRecords }
			let raw = try rawJSON(values[2])
			guard let members = try? decoder.decode([String].self, from: Data(raw.utf8)),
				!members.isEmpty, Set(members).count == members.count else { throw invalidRecords }
			for member in members { _ = try identifier(member) }
			try insert("INSERT INTO consists VALUES(?,?)", [try identifier(values[1]), raw]); counts.consists += 1
		case "event":
			guard values.count == 5, counts.events < pack.counts.events,
				let timestamp = number(values[2]), timestamp >= pack.historyStart, timestamp <= pack.historyEnd,
				let members = values[4] as? [String], !members.isEmpty,
				members.count <= pack.counts.eventCars - counts.eventCars else { throw invalidRecords }
			let id = try identifier(values[1]), raw = try rawJSON(values[3])
			guard let observation = try? decoder.decode(FleetObservation.self, from: Data(raw.utf8)), observation.timestamp == timestamp else { throw invalidRecords }
			try insert("INSERT INTO events VALUES(?,?,?)", [id, String(timestamp), raw]); counts.events += 1
			for member in members {
				try insert("INSERT INTO event_cars VALUES(?,?)", [id, try identifier(member)]); counts.eventCars += 1
			}
		case "end":
			guard values.count == 2, try decoded(FleetPackCounts.self, values[1]) == pack.counts,
				counts.cars == pack.counts.cars, counts.assertions == pack.counts.assertions,
				counts.consists == pack.counts.consists, counts.events == pack.counts.events,
				counts.eventCars == pack.counts.eventCars else { throw invalidRecords }
			sawEnd = true
		default: throw invalidRecords
		}
	}

	private func rawJSON(_ value: Any) throws -> String {
		guard let raw = value as? String, !raw.contains("\0"),
			(try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed])) != nil else { throw invalidRecords }
		return raw
	}
	private func identifier(_ value: Any) throws -> String {
		guard let id = value as? String, !id.isEmpty, id.utf8.count <= 1024, !id.contains("\0") else { throw invalidRecords }
		return id
	}
	private func number(_ value: Any) -> Double? {
		guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
		return number.doubleValue
	}
	private func integer(_ value: Any) -> Int? {
		guard let number = number(value), number.rounded(.towardZero) == number, number >= 0, number < Double(Int.max) else { return nil }
		return Int(number)
	}
	private func decoded<T: Decodable>(_ type: T.Type, _ value: Any) throws -> T {
		do { return try decoder.decode(type, from: JSONSerialization.data(withJSONObject: value)) }
		catch { throw invalidRecords }
	}
	private func execute(_ sql: String) throws {
		guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
	}
	private func insert(_ sql: String, _ values: [String]) throws {
		try Task.checkCancellation()
		let statement: OpaquePointer
		if let cached = statements[sql] { statement = cached }
		else {
			var prepared: OpaquePointer?
			guard sqlite3_prepare_v2(db, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else { throw failure() }
			statements[sql] = prepared; statement = prepared
		}
		defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
		for (index, value) in values.enumerated() {
			guard sqlite3_bind_text(statement, Int32(index + 1), value, Int32(value.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK else { throw failure() }
		}
		guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
	}
	private var invalidRecords: OfflineFleetError { .invalid("The fleet pack contains invalid or missing records. Your previous download is still available.") }
	private func checkSpace() throws {
		do { try SnapshotFiles.requireSpace(in: directory, bytes: 16 * 1_024 * 1_024) }
		catch { lowSpace = true; throw error }
	}
	private func failure() -> any Error {
		if Task.isCancelled { return CancellationError() }
		if lowSpace { return OfflineFleetError.invalid("Free more device space to save this fleet pack. Your previous download is still available.") }
		return OfflineFleetError.invalid("The fleet pack database could not be built: \(String(cString: sqlite3_errmsg(db)))")
	}
}
