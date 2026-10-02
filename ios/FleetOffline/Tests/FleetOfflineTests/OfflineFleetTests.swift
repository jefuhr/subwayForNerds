import Testing
import Foundation
import CryptoKit
import CSQLite
import TransitCore
@testable import FleetOffline

@Suite struct OfflineFleetTests {
	@Test func testCompleteHistoryAndHistoricalStatus() async throws {
		let fixture = try makeFixture()
		defer { try? FileManager.default.removeItem(at: fixture.directory) }
		let store = try OfflineFleetStore(directory: fixture.directory.appendingPathComponent("installed"))
		try await store.install(file: fixture.file, manifest: fixture.manifest)
		let page = try await store.page(query: ["view": "cars", "retired": "true"])
		#expect(page.total == 2)
		#expect(!page.rows.contains { $0.reporting })
		let reporting = try await store.page(query: ["status": "reporting"])
		#expect(reporting.total == 0)
		let first = try await store.detail(id: "nyct:R1:1")
		let second = try await store.detail(id: "nyct:R1:1", offset: 200)
		#expect(first.history.count == 200)
		#expect(second.history.count == 5)
		let consist = try await store.detail(id: "observed:test")
		#expect(consist.cars.count == 2)
		#expect(consist.history.count == 200, "shared events must not duplicate per member")
		let reopened = try OfflineFleetStore(directory: fixture.directory.appendingPathComponent("installed"))
		let restored = await reopened.manifest()
		#expect(restored?.id == fixture.manifest.id)
	}

	@Test func testRejectedUpdatePreservesPreviousDownload() async throws {
		let fixture = try makeFixture()
		defer { try? FileManager.default.removeItem(at: fixture.directory) }
		let store = try OfflineFleetStore(directory: fixture.directory.appendingPathComponent("installed"))
		try await store.install(file: fixture.file, manifest: fixture.manifest)
		let corrupt = fixture.directory.appendingPathComponent("corrupt.sqlite")
		try Data("invalid".utf8).write(to: corrupt)
		do { try await store.install(file: corrupt, manifest: fixture.manifest); Issue.record("accepted corruption") } catch {}
		let current = await store.manifest()
		#expect(current?.id == fixture.manifest.id)
		let preserved = try await store.page(query: [:])
		#expect(preserved.total == 2)
		try await store.delete()
		let deleted = await store.manifest()
		#expect(deleted == nil)
	}

	private func makeFixture() throws -> (directory: URL, file: URL, manifest: FleetOfflineManifest) {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let file = directory.appendingPathComponent("fixture.sqlite")
		var db: OpaquePointer?
		#expect(sqlite3_open(file.path, &db) == SQLITE_OK)
		defer { sqlite3_close(db) }
		func execute(_ sql: String) throws {
			guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
				throw NSError(domain: "SQLite", code: 1, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
			}
		}
		try execute("""
		PRAGMA user_version=1;
		CREATE TABLE meta(key TEXT PRIMARY KEY,data TEXT);
		CREATE TABLE cars(id TEXT PRIMARY KEY,data TEXT);
		CREATE TABLE assertions(id TEXT PRIMARY KEY,car_id TEXT,data TEXT);
		CREATE TABLE consists(id TEXT PRIMARY KEY,data TEXT);
		CREATE TABLE events(id TEXT PRIMARY KEY,timestamp INTEGER,data TEXT);
		CREATE TABLE event_cars(event_id TEXT REFERENCES events(id),car_id TEXT REFERENCES cars(id));
		INSERT INTO consists VALUES('observed:test','["nyct:R1:1","nyct:R1:2"]');
		INSERT INTO meta VALUES('roster','{"url":"https://example.com","date":"2026-09-28","note":"Fixture"}');
		INSERT INTO meta VALUES('snapshot','{"schemaVersion":1,"generatedAt":1001000,"historyStart":0,"historyEnd":1001000}');
		""")
		for number in 1...2 {
			let car: [String: Any] = ["id": "nyct:R1:\(number)", "number": "\(number)", "equipment": "R1", "category": "passenger", "aliases": [], "lifecycle": "Active", "evidence": [], "reporting": true]
			let data = String(decoding: try JSONSerialization.data(withJSONObject: car), as: UTF8.self)
			try execute("INSERT INTO cars VALUES('nyct:R1:\(number)','\(data)')")
		}
		for number in 0..<205 {
			let value: [String: Any] = ["timestamp": 1_000_000 + number / 2, "location": "Union Square", "route": "L", "tripKey": "test", "consistId": "observed:test", "cars": ["nyct:R1:1", "nyct:R1:2"]]
			let data = String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
			try execute("INSERT INTO events VALUES('\(number)',\(1_000_000 + number / 2),'\(data)'); INSERT INTO event_cars VALUES('\(number)','nyct:R1:1'),('\(number)','nyct:R1:2')")
		}
		let bytes = try Data(contentsOf: file)
		let manifest: [String: Any] = ["schemaVersion": 1, "id": "fixture", "generatedAt": 1_001_000, "historyStart": 0, "historyEnd": 1_001_000, "counts": ["cars": 2,"consists": 1,"events": 205,"assertions": 0], "byteLength": bytes.count, "sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), "downloadURL": "/subwaysForNerds/api/v1/fleet/offline/snapshots/fixture.sqlite"]
		return (directory, file, try JSONDecoder().decode(FleetOfflineManifest.self, from: JSONSerialization.data(withJSONObject: manifest)))
	}
}
