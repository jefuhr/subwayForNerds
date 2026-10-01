import Foundation
import Testing
import CryptoKit
import CSQLite
import TransitCore
import FleetOffline

@Suite struct IntegrityTests {
	@Test func filtersMatchOneMemberAndKeepTheWholeDocumentedSet() async throws {
		let fixture = try IntegrityFixture()
		defer { fixture.remove() }
		let store = try OfflineFleetStore(directory: fixture.directory.appendingPathComponent("installed"))
		try await store.install(file: fixture.file, manifest: fixture.manifest)
		let all = try await store.page(query: [:])
		#expect(all.total == 2)
		#expect(all.rows.map(\.id) == ["set:pair", "car:10"])
		let matchingMember = try await store.page(query: ["equipment": "R2"])
		#expect(matchingMember.rows.first?.cars.map(\.id) == ["car:1", "car:2"])
		let crossedMembers = try await store.page(query: ["equipment": "R1", "q": "two"])
		#expect(crossedMembers.total == 0, "A group matches only when one member satisfies all filters")
		let individual = try await store.page(query: ["view": "cars", "q": "two"])
		#expect(individual.rows.map(\.id) == ["car:2"])
		let retired = try await store.page(query: ["retired": "true", "view": "cars"])
		#expect(retired.total == 4)
		let current = try await store.page(query: ["status": "reporting"])
		#expect(current.total == 0)
		#expect(all.rows.allSatisfy { !$0.reporting && $0.cars.allSatisfy { $0.reporting == false } })
	}

	@Test func consistHistoryExcludesOtherFormationsAndTiedPagesDoNotOverlap() async throws {
		let fixture = try IntegrityFixture()
		defer { fixture.remove() }
		let store = try OfflineFleetStore(directory: fixture.directory.appendingPathComponent("installed"))
		try await store.install(file: fixture.file, manifest: fixture.manifest)
		let consist = try await store.detail(id: "observed:pair")
		#expect(consist.cars.map(\.id) == ["car:2", "car:1"], "Preserve reported order")
		#expect(consist.history.map(\.consistId) == ["observed:pair"])
		let first = try await store.detail(id: "car:1", limit: 1)
		let second = try await store.detail(id: "car:1", offset: 1, limit: 1)
		#expect(first.history.count == 1 && second.history.count == 1)
		#expect(first.history[0].consistId != second.history[0].consistId)
	}

	@Test func checksumCountsAndMetadataMismatchNeverReplaceActiveSnapshot() async throws {
		let fixture = try IntegrityFixture()
		defer { fixture.remove() }
		let store = try OfflineFleetStore(directory: fixture.directory.appendingPathComponent("installed"))
		try await store.install(file: fixture.file, manifest: fixture.manifest)
		var checksum = fixture.manifest; checksum.sha256 = String(repeating: "0", count: 64)
		var counts = fixture.manifest; counts.counts.cars += 1
		var metadata = fixture.manifest; metadata.generatedAt += 1
		for invalid in [checksum, counts, metadata] {
			do { try await store.install(file: fixture.file, manifest: invalid); Issue.record("Accepted mismatched snapshot") }
			catch is OfflineFleetError { }
			let active = await store.manifest()
			#expect(active == fixture.manifest)
		}
		let usable = try await store.page(query: ["view": "cars"])
		#expect(usable.total == 3)
	}

	@Test func canceledValidationPreservesThePreviousDownload() async throws {
		let fixture = try IntegrityFixture()
		defer { fixture.remove() }
		let store = try OfflineFleetStore(directory: fixture.directory.appendingPathComponent("installed"))
		try await store.install(file: fixture.file, manifest: fixture.manifest)
		let task = Task {
			withUnsafeCurrentTask { $0?.cancel() }
			try await store.install(file: fixture.file, manifest: fixture.manifest)
		}
		do { try await task.value; Issue.record("Canceled installation must not activate") }
		catch is CancellationError { }
		let active = await store.manifest()
		#expect(active == fixture.manifest)
		let files = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.appendingPathComponent("installed").path)
		#expect(files.filter { $0.hasSuffix(".sqlite") }.count == 1)
	}
}

struct IntegrityFixture: Sendable {
	let directory: URL
	let file: URL
	let manifest: FleetOfflineManifest

	init() throws {
		directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		file = directory.appendingPathComponent("fixture.sqlite")
		var db: OpaquePointer?
		guard sqlite3_open(file.path, &db) == SQLITE_OK else { throw FixtureError.sqlite }
		defer { sqlite3_close(db) }
		func execute(_ sql: String) throws {
			guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw FixtureError.sqlite }
		}
		func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }
		func json<T: Encodable>(_ value: T) throws -> String { quote(String(decoding: try JSONEncoder().encode(value), as: UTF8.self)) }
		try execute("""
		PRAGMA user_version=1;
		CREATE TABLE meta(key TEXT PRIMARY KEY,data TEXT);
		CREATE TABLE cars(id TEXT PRIMARY KEY,data TEXT);
		CREATE TABLE assertions(id TEXT PRIMARY KEY,car_id TEXT,data TEXT);
		CREATE TABLE consists(id TEXT PRIMARY KEY,data TEXT);
		CREATE TABLE events(id TEXT PRIMARY KEY,timestamp INTEGER,data TEXT);
		CREATE TABLE event_cars(event_id TEXT REFERENCES events(id),car_id TEXT REFERENCES cars(id));
		INSERT INTO meta VALUES('snapshot','{"schemaVersion":1,"generatedAt":1000,"historyStart":0,"historyEnd":1000,"counts":{"cars":4,"consists":2,"events":2,"assertions":0}}');
		INSERT INTO consists VALUES('observed:pair','["car:2","car:1"]');
		INSERT INTO consists VALUES('observed:other','["car:1","car:10"]');
		""")
		let cars = [
			FleetCar(id: "car:1", number: "1", equipment: "R1", category: "passenger", lifecycle: "Active", fixedSet: "set:pair", reporting: true),
			FleetCar(id: "car:2", number: "2", equipment: "R2", category: "passenger", aliases: ["Two"], lifecycle: "Active", fixedSet: "set:pair", reporting: true),
			FleetCar(id: "car:10", number: "10", equipment: "R1", category: "work", lifecycle: "Active"),
			FleetCar(id: "car:99", number: "99", equipment: "R1", category: "museum", lifecycle: "Retired")
		]
		for car in cars { try execute("INSERT INTO cars VALUES(\(quote(car.id)),\(try json(car)))") }
		for (index, members) in [["car:2", "car:1"], ["car:1", "car:10"]].enumerated() {
			let eventID = "event\(index)"
			let event = FleetObservation(timestamp: 950, location: "Union Square", route: "L", tripKey: "trip", consistId: index == 0 ? "observed:pair" : "observed:other", cars: members)
			try execute("INSERT INTO events VALUES(\(quote(eventID)),950,\(try json(event)))")
			for member in members { try execute("INSERT INTO event_cars VALUES(\(quote(eventID)),\(quote(member)))") }
		}
		let bytes = try Data(contentsOf: file)
		let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
		manifest = FleetOfflineManifest(schemaVersion: 1, id: digest, generatedAt: 1000, historyStart: 0, historyEnd: 1000, counts: FleetOfflineCounts(cars: 4, consists: 2, events: 2, assertions: 0), byteLength: Int64(bytes.count), sha256: digest, downloadURL: "/snapshot.sqlite")
	}

	func remove() { try? FileManager.default.removeItem(at: directory) }
	private enum FixtureError: Error { case sqlite }
}
