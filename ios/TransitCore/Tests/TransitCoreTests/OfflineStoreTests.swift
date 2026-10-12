import Foundation
import Testing
@testable import TransitCore

struct OfflinePlannerTests {
	@Test func boardsKeepTheConfiguredDeparturesPerRouteAndDirection() {
		let departures = (0..<4).flatMap { index in [
			OfflineFixtures.departure("n\(index)", route: "1", direction: "NORTH", time: OfflineFixtures.start + Double(index) * 60),
			OfflineFixtures.departure("s\(index)", route: "1", direction: "SOUTH", time: OfflineFixtures.start + Double(index) * 60),
			OfflineFixtures.departure("x\(index)", route: "2", direction: "NORTH", time: OfflineFixtures.start + Double(index) * 60),
		] }
		let board = OfflineFixtures.board(departures: departures)
		let retained = OfflinePlanner.retainedBoard(board, preferences: OfflinePreferences(departuresPerLineDirection: 2))
		#expect(retained.departures.map(\.tripKey) == ["n0", "s0", "x0", "n1", "s1", "x1"])
		#expect(OfflinePlanner.retainedBoard(board, preferences: OfflinePreferences(departuresPerLineDirection: 20)).departures.count == 12)
	}

	@Test func tripSnapshotsTakeTheNextBoardableTripsPerLineDirection() {
		let board = OfflineFixtures.board(departures: [
			OfflineFixtures.departure("canceled", relationship: "CANCELED"),
			OfflineFixtures.departure("a"), OfflineFixtures.departure("a"), OfflineFixtures.departure("b"), OfflineFixtures.departure("c"),
			OfflineFixtures.departure("south", direction: "SOUTH"),
		])
		#expect(OfflinePlanner.tripKeysToSnapshot(board, preferences: OfflinePreferences()) == ["a", "b", "south"])
		#expect(OfflinePlanner.tripKeysToSnapshot(board, preferences: OfflinePreferences(departuresPerLineDirection: 1, tripDetailsPerLineDirection: 20)) == ["a", "south"])
		#expect(OfflinePlanner.tripKeysToSnapshot(board, preferences: OfflinePreferences(tripDetailsPerLineDirection: 0)).isEmpty)
	}

	@Test func positionalPATHTripsAreNeverSnapshottedAutomatically() {
		let board = OfflineFixtures.board(departures: [
			OfflineFixtures.departure("path|unknown|26731-ToNY-33S-0|", route: "HOB-33"), OfflineFixtures.departure("a"),
			OfflineFixtures.departure("path|unknown|26731-ToNY-33S-1|", route: "HOB-33"),
		])
		#expect(OfflinePlanner.tripKeysToSnapshot(board, preferences: OfflinePreferences()) == ["a"])
	}

	@Test func surroundingStationsAreMeasuredFromTheViewedStationNotTheDevice() {
		let viewed = OfflineFixtures.station("viewed", lat: 40.75, lon: -73.99)
		// One degree of latitude is about 111 km; 0.001 degree is about 364 ft.
		let near = OfflineFixtures.station("near", lat: 40.751, lon: -73.99)
		let nearer = OfflineFixtures.station("nearer", lat: 40.7505, lon: -73.99)
		let far = OfflineFixtures.station("far", lat: 40.80, lon: -73.99)
		let result = OfflinePlanner.surroundingStations(of: viewed, catalog: [far, near, viewed, nearer], preferences: OfflinePreferences())
		#expect(result.map(\.station.id) == ["nearer", "near"])
		let exact = Display.distanceMeters(lat1: viewed.lat, lon1: viewed.lon, lat2: near.lat, lon2: near.lon) / 0.3048
		#expect(OfflinePlanner.surroundingStations(of: viewed, catalog: [near], preferences: OfflinePreferences(nearbyRadiusFeet: Int(exact.rounded(.up)))).count == 1)
		#expect(OfflinePlanner.surroundingStations(of: viewed, catalog: [near], preferences: OfflinePreferences(nearbyRadiusFeet: Int(exact.rounded(.down)))).isEmpty)
		#expect(OfflinePlanner.surroundingStations(of: viewed, catalog: [near, nearer], preferences: OfflinePreferences(nearbyRadiusFeet: 0)).isEmpty)
	}
}

struct OfflineEndpointTests {
	@Test func productionAliasesSharePartitionWhileOtherOriginsStayIsolated() {
		#expect(OfflineEndpoint.key("https://juliet.nyc/subwaysForNerds/api/v1/") == OfflineEndpoint.productionKey)
		#expect(OfflineEndpoint.key("https://subwaysfornerds.juliet.nyc/api/v1") == OfflineEndpoint.productionKey)
		#expect(OfflineEndpoint.key(TransitAPI.productionBaseURL) == OfflineEndpoint.productionKey)
		#expect(OfflineEndpoint.key("https://JULIET.nyc/subwaysForNerds/api/v1/") == OfflineEndpoint.productionKey)
		#expect(OfflineEndpoint.key("http://juliet.nyc/subwaysForNerds/api/v1/") != OfflineEndpoint.productionKey)
		#expect(OfflineEndpoint.key("https://juliet.nyc/subwaysfornerds/api/v1/") != OfflineEndpoint.productionKey)
		#expect(OfflineEndpoint.key("http://127.0.0.1:8092/api/v1") == "http://127.0.0.1:8092/api/v1/")
		#expect(OfflineEndpoint.key("http://127.0.0.1:8092/api/v1/") != OfflineEndpoint.key("http://127.0.0.1:8093/api/v1/"))
	}
}

struct OfflineStoreTests {
	let endpoint = OfflineFixtures.endpoint
	let t0 = OfflineFixtures.start

	private func makeStore(_ directory: URL, clock: TestClock, legacy: URL? = nil, readOnly: Bool = false) -> OfflineTransitStore {
		OfflineTransitStore(directory: directory, legacyBoardDirectory: legacy, readOnly: readOnly, clock: clock.function)
	}

	@Test func onlyNewerSourceDataReplacesATripSnapshot() async throws {
		let directory = OfflineFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
		let clock = TestClock(t0 + 10), store = makeStore(directory, clock: clock)
		#expect(try await store.saveTrip(OfflineFixtures.detail("t", timestamp: t0), endpoint: endpoint) == .stored)
		clock.advance(60)
		// An unchanged (for example 304) response keeps the snapshot and its source and save times.
		#expect(try await store.saveTrip(OfflineFixtures.detail("t", timestamp: t0), endpoint: endpoint) == .unchanged)
		#expect(try await store.saveTrip(OfflineFixtures.detail("t", timestamp: t0 - 30), endpoint: endpoint) == .unchanged)
		var trip = try #require(await store.trip(key: "t", endpoint: endpoint))
		#expect(trip.savedAt == t0 + 10 && trip.sourceTimestamp == t0)
		#expect(trip.accessedAt == t0 + 70)
		#expect(trip.detail?.raw == .object(["entity": .string("raw")]))
		#expect(try await store.saveTrip(OfflineFixtures.detail("t", timestamp: t0 + 30), endpoint: endpoint) == .stored)
		trip = try #require(await store.trip(key: "t", endpoint: endpoint))
		#expect(trip.savedAt == t0 + 70 && trip.sourceTimestamp == t0 + 30 && trip.isComplete)
		// The production alias reads the same partition; a debug origin does not.
		#expect(await store.trip(key: "t", endpoint: "https://subwaysfornerds.juliet.nyc/api/v1/") != nil)
		#expect(await store.trip(key: "t", endpoint: "http://127.0.0.1:8092/api/v1/") == nil)
	}

	@Test func partialTripsFallBackToBoardStopsAndNeverReplaceCompleteOnes() async throws {
		let directory = OfflineFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
		let clock = TestClock(t0), store = makeStore(directory, clock: clock)
		let onward = [OnwardStop(stationId: "102", stopId: "102N", name: "Station 102", time: t0 + 900)]
		#expect(try await store.savePartialTrip(OfflineFixtures.departure("p", timestamp: t0, onward: onward), endpoint: endpoint) == .stored)
		#expect(try await store.trip(key: "p", endpoint: endpoint)?.isComplete == false)
		#expect(try await store.savePartialTrip(OfflineFixtures.departure("p", timestamp: t0, onward: onward), endpoint: endpoint) == .unchanged)
		// A complete detail at the same source time upgrades the partial snapshot and keeps its departure.
		#expect(try await store.saveTrip(OfflineFixtures.detail("p", timestamp: t0), endpoint: endpoint) == .stored)
		let trip = try #require(await store.trip(key: "p", endpoint: endpoint))
		#expect(trip.isComplete && trip.departure?.tripKey == "p")
		#expect(try await store.savePartialTrip(OfflineFixtures.departure("p", timestamp: t0 + 600), endpoint: endpoint) == .unchanged)
		#expect(try await store.trip(key: "p", endpoint: endpoint)?.isComplete == true)
	}

	@Test func automaticEntriesExpireAtTheRetentionBoundaryWhileSavedAndRiddenTripsStay() async throws {
		let directory = OfflineFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
		let clock = TestClock(t0), store = makeStore(directory, clock: clock)
		let prefs = OfflinePreferences(retentionHours: 1)
		await store.setPreferences(prefs)
		try await store.saveTrip(OfflineFixtures.detail("auto"), endpoint: endpoint)
		try await store.saveTrip(OfflineFixtures.detail("saved"), endpoint: endpoint, manuallySaved: true)
		try await store.saveTrip(OfflineFixtures.detail("ride"), endpoint: endpoint)
		try await store.saveBoard(OfflineFixtures.board(departures: [OfflineFixtures.departure("auto")]), endpoint: endpoint)
		try await store.setActiveRide(ActiveRide(tripKey: "ride", boardingStationID: "101", startedAt: t0), endpoint: endpoint)
		#expect(try await store.prune(preferences: prefs, now: t0 + 3600).isEmpty)
		let report = try await store.prune(preferences: prefs, now: t0 + 3601)
		#expect(report.expiredTripKeys == ["auto"] && report.expiredStationIDs == ["101"])
		#expect(await store.trip(key: "auto", endpoint: endpoint) == nil)
		#expect(await store.board(stationID: "101", endpoint: endpoint) == nil)
		#expect(await store.trip(key: "saved", endpoint: endpoint)?.manuallySaved == true)
		#expect(await store.trip(key: "ride", endpoint: endpoint) != nil)
		// Ending the ride and explicitly unsaving make both ordinary automatic entries.
		try await store.setActiveRide(nil, endpoint: endpoint)
		try await store.setManuallySaved(false, tripKey: "saved", endpoint: endpoint)
		#expect(await store.savedTrips(endpoint: endpoint).isEmpty)
		#expect(Set(try await store.prune(preferences: prefs, now: t0 + 7200).expiredTripKeys) == ["saved", "ride"])
	}

	@Test func sizeEvictionRemovesLeastRecentlyUsedAutomaticEntriesOnly() async throws {
		let directory = OfflineFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
		let clock = TestClock(t0), store = makeStore(directory, clock: clock)
		let prefs = OfflinePreferences(storageLimitMiB: 25)
		let big = JSONValue.string(String(repeating: "x", count: 9 * 1_048_576))
		await store.setPreferences(OfflinePreferences(storageLimitMiB: 250))
		for key in ["saved", "old", "recent"] {
			try await store.saveTrip(OfflineFixtures.detail(key, raw: big), endpoint: endpoint, manuallySaved: key == "saved" ? true : nil)
			clock.advance(10)
		}
		_ = await store.trip(key: "old", endpoint: endpoint)
		clock.advance(10)
		_ = await store.trip(key: "recent", endpoint: endpoint)
		#expect(await store.usage().totalBytes > prefs.storageLimitBytes)
		let report = try await store.prune(preferences: prefs, now: clock.now)
		#expect(report.evictedTripKeys == ["old"] && report.expiredTripKeys.isEmpty)
		let usage = await store.usage()
		#expect(usage.tripCount == 2 && usage.savedTripCount == 1 && !usage.overLimit)
		// Protected entries alone may exceed the limit; they are reported, not evicted.
		try await store.setManuallySaved(true, tripKey: "recent", endpoint: endpoint)
		try await store.saveTrip(OfflineFixtures.detail("third", raw: big), endpoint: endpoint, manuallySaved: true)
		#expect(try await store.prune(preferences: prefs, now: clock.now).isEmpty)
		#expect(await store.usage().overLimit)
		#expect(await store.savedTrips(endpoint: endpoint).count == 3)
	}

	@Test func activeRideSurvivesRelaunchIsOnePerEndpointAndRejectsPATH() async throws {
		let directory = OfflineFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
		let clock = TestClock(t0)
		do {
			let store = makeStore(directory, clock: clock)
			try await store.setActiveRide(ActiveRide(tripKey: "first", startedAt: t0), endpoint: endpoint)
			try await store.setActiveRide(ActiveRide(tripKey: "second", boardingStationID: "101", startedAt: t0 + 5), endpoint: endpoint)
			await #expect(throws: OfflineStoreError.positionalTrip) { try await store.setActiveRide(ActiveRide(tripKey: "path|unknown|26731-ToNY-33S-0|", startedAt: t0), endpoint: endpoint) }
		}
		let relaunched = makeStore(directory, clock: clock)
		#expect(await relaunched.activeRide(endpoint: "https://subwaysfornerds.juliet.nyc/api/v1/") == ActiveRide(tripKey: "second", boardingStationID: "101", startedAt: t0 + 5))
		#expect(await relaunched.activeRide(endpoint: "http://127.0.0.1:8092/api/v1/") == nil)
		#expect(await relaunched.failures().isEmpty)
	}

	@Test func manuallySavedPATHSnapshotsAreImmutable() async throws {
		let directory = OfflineFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
		let clock = TestClock(t0), store = makeStore(directory, clock: clock)
		let key = "path|unknown|26731-ToNY-33S-0|"
		try await store.saveTrip(OfflineFixtures.detail(key, timestamp: t0), endpoint: endpoint, manuallySaved: true)
		#expect(try await store.saveTrip(OfflineFixtures.detail(key, timestamp: t0 + 60), endpoint: endpoint) == .unchanged)
		#expect(await store.trip(key: key, endpoint: endpoint)?.sourceTimestamp == t0)
		// Automatic PATH snapshots still follow normal replacement.
		try await store.saveTrip(OfflineFixtures.detail(key + "auto", timestamp: t0), endpoint: endpoint)
		#expect(try await store.saveTrip(OfflineFixtures.detail(key + "auto", timestamp: t0 + 60), endpoint: endpoint) == .stored)
	}

	@Test func firstManualPATHSaveStoresTheTrainTheUserSaw() async throws {
		let directory = OfflineFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
		let clock = TestClock(t0), store = makeStore(directory, clock: clock)
		let key = "path|unknown|26731-ToNY-33S-0|"
		// A newer automatic snapshot at the same position may already describe the next train.
		try await store.saveTrip(OfflineFixtures.detail(key, timestamp: t0 + 60), endpoint: endpoint)
		let seen = OfflineFixtures.departure(key, route: "HOB-33", timestamp: t0)
		#expect(try await store.saveTrip(OfflineFixtures.detail(key, timestamp: t0), endpoint: endpoint, departure: seen, manuallySaved: true) == .stored)
		var trip = try #require(await store.trip(key: key, endpoint: endpoint))
		#expect(trip.manuallySaved && trip.sourceTimestamp == t0 && trip.departure == seen)
		// Once saved it stays frozen, against both automatic and repeated manual saves.
		#expect(try await store.saveTrip(OfflineFixtures.detail(key, timestamp: t0 + 120), endpoint: endpoint) == .unchanged)
		#expect(try await store.saveTrip(OfflineFixtures.detail(key, timestamp: t0 + 180), endpoint: endpoint, manuallySaved: true) == .unchanged)
		#expect(try await store.savePartialTrip(OfflineFixtures.departure(key, timestamp: t0 + 240), endpoint: endpoint, manuallySaved: true) == .unchanged)
		trip = try #require(await store.trip(key: key, endpoint: endpoint))
		#expect(trip.sourceTimestamp == t0 && trip.departure == seen)
		// After removal the next manual save is a new first save, from the board row alone too.
		try await store.removeTrip(key: key, endpoint: endpoint)
		try await store.saveTrip(OfflineFixtures.detail(key, timestamp: t0 + 300), endpoint: endpoint)
		let row = OfflineFixtures.departure(key, route: "HOB-33", timestamp: t0 + 200)
		#expect(try await store.savePartialTrip(row, endpoint: endpoint, manuallySaved: true) == .stored)
		trip = try #require(await store.trip(key: key, endpoint: endpoint))
		#expect(trip.manuallySaved && !trip.isComplete && trip.departure == row)
	}

	@Test func failedSavesAreVisibleAndKeepThePreviousSnapshot() async throws {
		let directory = OfflineFixtures.temporaryDirectory(); defer {
			try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.appendingPathComponent("v1/trips").path)
			try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.appendingPathComponent("v1").path)
			try? FileManager.default.removeItem(at: directory)
		}
		let clock = TestClock(t0), store = makeStore(directory, clock: clock)
		try await store.saveTrip(OfflineFixtures.detail("t", timestamp: t0), endpoint: endpoint)
		try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.appendingPathComponent("v1/trips").path)
		await #expect(throws: (any Error).self) { try await store.saveTrip(OfflineFixtures.detail("t", timestamp: t0 + 60), endpoint: endpoint) }
		await #expect(throws: (any Error).self) { try await store.saveTrip(OfflineFixtures.detail("new", timestamp: t0 + 60), endpoint: endpoint, manuallySaved: true) }
		let failures = await store.failures()
		#expect(failures.map(\.kind) == [.trip, .savedTrip])
		#expect(failures.allSatisfy { !$0.message.isEmpty && $0.failedAt == t0 })
		#expect(await store.trip(key: "t", endpoint: endpoint)?.sourceTimestamp == t0)
		#expect(await store.trip(key: "new", endpoint: endpoint) == nil)
		try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.appendingPathComponent("v1").path)
		await #expect(throws: (any Error).self) { try await store.setActiveRide(ActiveRide(tripKey: "t", startedAt: t0), endpoint: endpoint) }
		#expect(await store.failures().last?.kind == .activeRide)
		await store.clearFailures()
		#expect(await store.failures().isEmpty)
	}

	@Test func protectionSurvivesIndexLossAndEndpointSwitches() async throws {
		let directory = OfflineFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
		let clock = TestClock(t0), store = makeStore(directory, clock: clock)
		let debug = "http://127.0.0.1:8092/api/v1/"
		try await store.saveTrip(OfflineFixtures.detail("saved"), endpoint: endpoint, manuallySaved: true)
		try await store.saveTrip(OfflineFixtures.detail("ride"), endpoint: endpoint)
		try await store.saveTrip(OfflineFixtures.detail("auto"), endpoint: debug)
		try await store.setActiveRide(ActiveRide(tripKey: "ride", startedAt: t0), endpoint: endpoint)
		try FileManager.default.removeItem(at: directory.appendingPathComponent("v1/index.json"))
		try Data("not json".utf8).write(to: directory.appendingPathComponent("v1/index.json"))
		// The app now talks to a different endpoint and prunes everything automatic.
		let report = try await store.prune(preferences: OfflinePreferences(retentionHours: 1), now: t0 + 86_400)
		#expect(report.expiredTripKeys == ["auto"])
		#expect(await store.savedTrips(endpoint: endpoint).map(\.tripKey) == ["saved"])
		#expect(await store.trip(key: "ride", endpoint: endpoint) != nil)
	}

	@Test func boardFeedsMergeOneSourceGroupAtATime() async throws {
		let directory = OfflineFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
		let clock = TestClock(t0), store = makeStore(directory, clock: clock)
		let first = OfflineFixtures.board(sources: [SourceState(id: "gtfs", timestamp: t0), SourceState(id: "gtfs-l", timestamp: t0)], departures: [
			OfflineFixtures.departure("one", feed: "gtfs", time: t0 + 100, timestamp: t0),
			OfflineFixtures.departure("L1", route: "L", feed: "gtfs-l", time: t0 + 200, timestamp: t0),
		])
		#expect(try await store.saveBoard(first, endpoint: endpoint) == .stored)
		clock.advance(30)
		var regenerated = first; regenerated.generatedAt += 30
		#expect(try await store.saveBoard(regenerated, endpoint: endpoint) == .unchanged)
		#expect(await store.board(stationID: "101", endpoint: endpoint)?.savedAt == t0)
		// gtfs advances; gtfs-l fails and its departures disappear from the response.
		let second = OfflineFixtures.board(sources: [SourceState(id: "gtfs", timestamp: t0 + 30), SourceState(id: "gtfs-l", timestamp: nil, error: "timeout")], departures: [
			OfflineFixtures.departure("two", feed: "gtfs", time: t0 + 150, timestamp: t0 + 30),
		])
		#expect(try await store.saveBoard(second, endpoint: endpoint) == .stored)
		let merged = try #require(await store.board(stationID: "101", endpoint: endpoint))
		#expect(merged.board.departures.map(\.tripKey) == ["two", "L1"])
		#expect(merged.board.departures.first { $0.tripKey == "L1" }?.timestamp == t0)
		let failing = try #require(merged.board.sources.first { $0.id == "gtfs-l" })
		#expect(failing.timestamp == t0 && failing.error == "timeout")
		#expect(merged.savedAt == t0 + 30)
		// An older feed never replaces newer stored departures.
		let older = OfflineFixtures.board(sources: [SourceState(id: "gtfs", timestamp: t0 + 10)], departures: [OfflineFixtures.departure("stale", feed: "gtfs", timestamp: t0 + 10)])
		#expect(try await store.saveBoard(older, endpoint: endpoint) == .unchanged)
		#expect(await store.board(stationID: "101", endpoint: endpoint)?.board.departures.map(\.tripKey) == ["two", "L1"])
	}

	@Test func aTripMissingFromANewerBoardKeepsItsSnapshotUnchanged() async throws {
		let directory = OfflineFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
		let clock = TestClock(t0), store = makeStore(directory, clock: clock)
		try await store.saveTrip(OfflineFixtures.detail("gone", timestamp: t0), endpoint: endpoint)
		try await store.saveBoard(OfflineFixtures.board(departures: [OfflineFixtures.departure("gone")]), endpoint: endpoint)
		let before = await store.trip(key: "gone", endpoint: endpoint)
		clock.advance(60)
		try await store.saveBoard(OfflineFixtures.board(sources: [SourceState(id: "gtfs", timestamp: t0 + 60)], departures: []), endpoint: endpoint)
		let after = try #require(await store.trip(key: "gone", endpoint: endpoint))
		#expect(after.detail == before?.detail && after.savedAt == before?.savedAt)
		#expect(after.train?.relationship == nil)
	}

	@Test func boardsAreTrimmedToThePreferredDeparturesPerLineDirection() async throws {
		let directory = OfflineFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
		let store = makeStore(directory, clock: TestClock(t0))
		await store.setPreferences(OfflinePreferences(departuresPerLineDirection: 1))
		try await store.saveBoard(OfflineFixtures.board(departures: [OfflineFixtures.departure("a"), OfflineFixtures.departure("b"), OfflineFixtures.departure("c", direction: "SOUTH")]), endpoint: endpoint, viewedStationID: "100", distanceMeters: 120)
		let cached = try #require(await store.board(stationID: "101", endpoint: endpoint))
		#expect(cached.board.departures.map(\.tripKey) == ["a", "c"])
		#expect(cached.viewedStationID == "100" && cached.distanceMeters == 120)
	}

	@Test func legacyBoardsMigrateOnceWithoutTouchingOriginals() async throws {
		let directory = OfflineFixtures.temporaryDirectory(), legacy = OfflineFixtures.temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: legacy) }
		try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
		// Names are not trusted: the station comes from the decoded contents.
		let original = try JSONEncoder().encode(OfflineFixtures.board("602", departures: [OfflineFixtures.departure("legacy")]))
		let url = legacy.appendingPathComponent("board-unexpected-name.json")
		try original.write(to: url)
		try Data("{}".utf8).write(to: legacy.appendingPathComponent("board-broken.json"))
		try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: t0 - 100)], ofItemAtPath: url.path)
		let clock = TestClock(t0), store = makeStore(directory, clock: clock, legacy: legacy)
		let migrated = try #require(await store.board(stationID: "602", endpoint: endpoint))
		#expect(migrated.board.departures.map(\.tripKey) == ["legacy"])
		#expect(migrated.savedAt == t0 - 100)
		#expect(try Data(contentsOf: url) == original)
		#expect(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("board-broken.json").path))
		#expect(await store.importLegacyBoards(from: legacy, endpoint: endpoint) == 0)
		#expect(await store.importLegacyBoards(from: legacy, endpoint: "http://127.0.0.1:8092/api/v1/") == 1)
		// Migrated boards age out like any other automatic entry.
		#expect(try await store.prune(preferences: OfflinePreferences(retentionHours: 1), now: t0 + 3600).expiredStationIDs.count == 2)
		#expect(FileManager.default.fileExists(atPath: url.path))
	}

	@Test func legacyImportMergesFeedGroupsIntoANewerStoredBoard() async throws {
		let directory = OfflineFixtures.temporaryDirectory(), legacy = OfflineFixtures.temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: legacy) }
		try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
		let clock = TestClock(t0 + 100), store = makeStore(directory, clock: clock)
		// The store already holds a newer gtfs group and an older gtfs-ace group (for example after a failed marker write).
		try await store.saveBoard(OfflineFixtures.board(sources: [SourceState(id: "gtfs", timestamp: t0 + 100), SourceState(id: "gtfs-ace", timestamp: t0)], departures: [
			OfflineFixtures.departure("store-1", feed: "gtfs", time: t0 + 600, timestamp: t0 + 100),
			OfflineFixtures.departure("store-a", route: "A", feed: "gtfs-ace", time: t0 + 700, timestamp: t0),
		]), endpoint: endpoint, viewedStationID: "100", distanceMeters: 50)
		// The legacy board is older for gtfs but advances gtfs-ace.
		let url = legacy.appendingPathComponent("board-101.json")
		try JSONEncoder().encode(OfflineFixtures.board(sources: [SourceState(id: "gtfs", timestamp: t0), SourceState(id: "gtfs-ace", timestamp: t0 + 50)], departures: [
			OfflineFixtures.departure("legacy-1", feed: "gtfs", time: t0 + 500, timestamp: t0),
			OfflineFixtures.departure("legacy-a", route: "A", feed: "gtfs-ace", time: t0 + 800, timestamp: t0 + 50),
		])).write(to: url)
		try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: t0 + 60)], ofItemAtPath: url.path)
		clock.advance(30)
		#expect(await store.importLegacyBoards(from: legacy, endpoint: endpoint) == 1)
		let merged = try #require(await store.board(stationID: "101", endpoint: endpoint))
		#expect(merged.board.departures.map(\.tripKey) == ["store-1", "legacy-a"])
		#expect(merged.board.sources.map(\.timestamp) == [t0 + 100, t0 + 50])
		// The import never makes the snapshot look older than the stored newer data.
		#expect(merged.savedAt == t0 + 100)
		#expect(merged.viewedStationID == "100" && merged.distanceMeters == 50)
	}

	@Test func readOnlyStoresReadWithoutWriting() async throws {
		let directory = OfflineFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
		let clock = TestClock(t0), writer = makeStore(directory, clock: clock)
		try await writer.saveTrip(OfflineFixtures.detail("t"), endpoint: endpoint)
		try await writer.setActiveRide(ActiveRide(tripKey: "t", startedAt: t0), endpoint: endpoint)
		let index = try Data(contentsOf: directory.appendingPathComponent("v1/index.json"))
		clock.advance(60)
		let widget = makeStore(directory, clock: clock, readOnly: true)
		#expect(await widget.trip(key: "t", endpoint: endpoint)?.accessedAt == t0)
		#expect(await widget.activeRide(endpoint: endpoint)?.tripKey == "t")
		await #expect(throws: OfflineStoreError.readOnly) { try await widget.saveTrip(OfflineFixtures.detail("t", timestamp: t0 + 60), endpoint: endpoint) }
		#expect(try Data(contentsOf: directory.appendingPathComponent("v1/index.json")) == index)
	}

	@Test func unknownFormatVersionsAreIgnoredNotDeleted() async throws {
		let directory = OfflineFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
		let store = makeStore(directory, clock: TestClock(t0))
		try await store.saveTrip(OfflineFixtures.detail("t"), endpoint: endpoint, manuallySaved: true)
		let trips = directory.appendingPathComponent("v1/trips")
		let file = try #require(FileManager.default.contentsOfDirectory(at: trips, includingPropertiesForKeys: nil).first)
		var json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
		json["version"] = 99
		try JSONSerialization.data(withJSONObject: json).write(to: file)
		#expect(await store.trip(key: "t", endpoint: endpoint) == nil)
		#expect(FileManager.default.fileExists(atPath: file.path))
	}

	@Test func removingTripsIsExplicitAndKeepsTheActiveRide() async throws {
		let directory = OfflineFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
		let store = makeStore(directory, clock: TestClock(t0))
		try await store.saveTrip(OfflineFixtures.detail("a"), endpoint: endpoint, manuallySaved: true)
		try await store.saveTrip(OfflineFixtures.detail("ride"), endpoint: endpoint, manuallySaved: true)
		try await store.setActiveRide(ActiveRide(tripKey: "ride", startedAt: t0), endpoint: endpoint)
		try await store.removeTrip(key: "a", endpoint: endpoint)
		try await store.removeTrip(key: "ride", endpoint: endpoint)
		#expect(await store.trip(key: "a", endpoint: endpoint) == nil)
		#expect(await store.trip(key: "ride", endpoint: endpoint)?.manuallySaved == false)
		#expect(await store.savedTrips(endpoint: endpoint).isEmpty)
		#expect(await store.cachedTrips(endpoint: endpoint).map(\.tripKey) == ["ride"])
		await #expect(throws: OfflineStoreError.notCached) { try await store.setManuallySaved(true, tripKey: "missing", endpoint: endpoint) }
	}
}
