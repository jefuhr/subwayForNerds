import Foundation
import Testing
@testable import TransitCore

/// Mid-review fixes: index/snapshot divergence, partial stop names, save-time
/// renewal, access-time batching, merge regressions and awaited prefetch requests.
struct OfflineMergeTests {
	let t0 = OfflineFixtures.start

	private func board(_ sources: [SourceState], _ departures: [Departure], alerts: [ServiceAlert] = []) -> Board {
		var value = OfflineFixtures.board(sources: sources, departures: departures)
		value.alerts = alerts
		return value
	}

	@Test func storedErrorsKeepTheirTimeSoOlderSuccessesCannotRegress() {
		let good = board([SourceState(id: "gtfs", timestamp: 1000)], [OfflineFixtures.departure("good", timestamp: 1000)])
		let failed = OfflinePlanner.mergeBoard(board([SourceState(id: "gtfs", timestamp: nil, error: "timeout")], []), into: good)
		#expect(!failed.advanced)
		var stored = failed.board
		#expect(stored.departures.map(\.tripKey) == ["good"])
		#expect(stored.sources.first?.timestamp == 1000 && stored.sources.first?.error == "timeout")
		let older = OfflinePlanner.mergeBoard(board([SourceState(id: "gtfs", timestamp: 900)], [OfflineFixtures.departure("older", timestamp: 900)]), into: stored)
		#expect(!older.advanced && older.board.departures.map(\.tripKey) == ["good"])
		// Recovery at the same time clears the error without renewing the save time.
		let recovered = OfflinePlanner.mergeBoard(good, into: stored)
		#expect(recovered.advanced && !recovered.predictionsAdvanced)
		stored = recovered.board
		#expect(stored.sources.first?.error == nil)
		let newer = OfflinePlanner.mergeBoard(board([SourceState(id: "gtfs", timestamp: 1100)], [OfflineFixtures.departure("newer", timestamp: 1100)]), into: stored)
		#expect(newer.advanced && newer.predictionsAdvanced && newer.board.departures.map(\.tripKey) == ["newer"])
	}

	@Test func alertsAndCarAssignmentsAloneAreNotNewerPredictions() {
		let alert = ServiceAlert(id: "a", title: "Delays", description: "")
		let stored = board([SourceState(id: "gtfs", timestamp: t0), SourceState(id: "subway-alerts", timestamp: t0), SourceState(id: "helium", timestamp: t0)], [OfflineFixtures.departure("one", timestamp: t0)])
		let alerts = OfflinePlanner.mergeBoard(board([SourceState(id: "gtfs", timestamp: t0), SourceState(id: "subway-alerts", timestamp: t0 + 60), SourceState(id: "helium", timestamp: t0 + 60)], [OfflineFixtures.departure("one", timestamp: t0)], alerts: [alert]), into: stored)
		#expect(alerts.advanced && !alerts.predictionsAdvanced)
		#expect(alerts.board.alerts == [alert])
		// Alerts follow their own source: an older alerts feed keeps the stored alerts.
		let olderAlerts = OfflinePlanner.mergeBoard(board([SourceState(id: "gtfs", timestamp: t0 + 30), SourceState(id: "subway-alerts", timestamp: t0 - 60)], [OfflineFixtures.departure("one", timestamp: t0 + 30)]), into: alerts.board)
		#expect(olderAlerts.predictionsAdvanced && olderAlerts.board.alerts == [alert])
		#expect(OfflinePlanner.mergeBoard(stored, into: nil) == OfflineBoardMerge(board: stored, advanced: true, predictionsAdvanced: true))
	}
}

struct OfflineStoreIntegrityTests {
	let endpoint = OfflineFixtures.endpoint
	let t0 = OfflineFixtures.start

	private func makeStore(_ directory: URL, clock: TestClock) -> OfflineTransitStore {
		OfflineTransitStore(directory: directory, clock: clock.function)
	}

	@Test func partialTripsNameTheBoardingStopFromTheStationNeverThePosition() async throws {
		let directory = OfflineFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
		let store = makeStore(directory, clock: TestClock(t0))
		var departure = OfflineFixtures.departure("p", onward: [OnwardStop(stationId: "L02", stopId: "L02N", name: "6 Av", time: t0 + 900)])
		departure.stopId = "L03N"; departure.location = "In transit to 14 St"
		try await store.savePartialTrip(departure, endpoint: endpoint, station: Station(id: "L03", name: "Union Sq", borough: "M", lat: 40.73, lon: -73.99))
		let trip = try #require(await store.trip(key: "p", endpoint: endpoint))
		#expect(trip.stops.map(\.name) == ["Union Sq", "6 Av"])
		#expect(trip.stops[0].stationId == "L03")
		#expect(!trip.stops.contains { $0.name == departure.location })
		// Unnamed partial trips use a neutral label, and a later detail keeps the station.
		try await store.savePartialTrip(OfflineFixtures.departure("q"), endpoint: endpoint)
		#expect(await store.trip(key: "q", endpoint: endpoint)?.stops.first?.name == CachedTrip.boardingStopFallbackName)
		try await store.saveTrip(OfflineFixtures.detail("p", timestamp: t0 + 60), endpoint: endpoint)
		#expect(await store.trip(key: "p", endpoint: endpoint)?.boardingStationName == "Union Sq")
	}

	@Test func aFailedIndexWriteNeverHidesAManualSaveAfterRetry() async throws {
		let directory = OfflineFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
		let store = makeStore(directory, clock: TestClock(t0))
		try await store.saveTrip(OfflineFixtures.detail("seed"), endpoint: endpoint)
		await store.injectIndexWriteFailures(1)
		await #expect(throws: (any Error).self) { try await store.saveTrip(OfflineFixtures.detail("t"), endpoint: endpoint, manuallySaved: true) }
		#expect(await store.failures().map(\.kind) == [.savedTrip])
		#expect(await store.savedTrips(endpoint: endpoint).isEmpty)
		#expect(try await store.saveTrip(OfflineFixtures.detail("t"), endpoint: endpoint, manuallySaved: true) == .unchanged)
		#expect(await store.savedTrips(endpoint: endpoint).map(\.tripKey) == ["t"])
		#expect(await store.usage().savedTripCount == 1)
		// The same repair applies when only the manual flag change lost its index write.
		try await store.saveTrip(OfflineFixtures.detail("u"), endpoint: endpoint)
		await store.injectIndexWriteFailures(1)
		await #expect(throws: (any Error).self) { try await store.setManuallySaved(true, tripKey: "u", endpoint: endpoint) }
		try await store.setManuallySaved(true, tripKey: "u", endpoint: endpoint)
		#expect(await store.usage().savedTripCount == 2)
	}

	@Test func indexedSnapshotsChangedBeforeAFailedIndexWriteAreRepairedOnRelaunch() async throws {
		let directory = OfflineFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
		let clock = TestClock(t0)
		let big = JSONValue.string(String(repeating: "x", count: 100_000))
		do {
			let store = makeStore(directory, clock: clock)
			try await store.saveTrip(OfflineFixtures.detail("saved", timestamp: t0), endpoint: endpoint)
			try await store.saveTrip(OfflineFixtures.detail("updated", timestamp: t0), endpoint: endpoint)
			clock.advance(30)
			_ = await store.trip(key: "saved", endpoint: endpoint)
			try await store.flushAccessTimes()
			// Both snapshot files change, but neither index write lands; no retry before quitting.
			clock.advance(30)
			await store.injectIndexWriteFailures(2)
			await #expect(throws: (any Error).self) { try await store.setManuallySaved(true, tripKey: "saved", endpoint: endpoint) }
			await #expect(throws: (any Error).self) { try await store.saveTrip(OfflineFixtures.detail("updated", timestamp: t0 + 60, raw: big), endpoint: endpoint) }
			#expect(await store.savedTrips(endpoint: endpoint).isEmpty)
		}
		clock.advance(30)
		let relaunched = makeStore(directory, clock: clock)
		let saved = await relaunched.savedTrips(endpoint: endpoint)
		#expect(saved.map(\.tripKey) == ["saved"])
		// The newer access time from the index survives the repair.
		#expect(saved.first?.accessedAt == t0 + 30)
		let usage = await relaunched.usage()
		#expect(usage.savedTripCount == 1 && usage.tripCount == 2)
		#expect(usage.totalBytes > 100_000)
		let files = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("v1/trips"), includingPropertiesForKeys: [.fileSizeKey])
		#expect(usage.totalBytes == files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) })
		// The updated snapshot's save time was repaired too: it does not expire from its old one.
		let report = try await relaunched.prune(preferences: OfflinePreferences(retentionHours: 1), now: t0 + 3601)
		#expect(report.isEmpty)
		#expect(try await relaunched.prune(preferences: OfflinePreferences(retentionHours: 1), now: t0 + 60 + 3601).expiredTripKeys == ["updated"])
		#expect(await relaunched.trip(key: "saved", endpoint: endpoint)?.manuallySaved == true)
	}

	@Test func orphanedSnapshotsAreReconciledOnTheNextLaunch() async throws {
		let directory = OfflineFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
		let clock = TestClock(t0)
		do {
			let store = makeStore(directory, clock: clock)
			try await store.saveTrip(OfflineFixtures.detail("kept"), endpoint: endpoint)
			await store.injectIndexWriteFailures(1)
			_ = try? await store.saveTrip(OfflineFixtures.detail("orphan"), endpoint: endpoint, manuallySaved: true)
		}
		// A snapshot deleted behind the index's back is dropped from it too.
		let trips = directory.appendingPathComponent("v1/trips")
		let kept = trips.appendingPathComponent(OfflineTransitStore.digest(OfflineIdentity.trip(endpoint: endpoint, tripKey: "kept")) + ".json")
		try FileManager.default.removeItem(at: kept)
		let relaunched = makeStore(directory, clock: clock)
		#expect(await relaunched.savedTrips(endpoint: endpoint).map(\.tripKey) == ["orphan"])
		let usage = await relaunched.usage()
		#expect(usage.tripCount == 1 && usage.savedTripCount == 1)
	}

	@Test func evictionOnlyCountsBytesItActuallyRemoved() async throws {
		let directory = OfflineFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
		let clock = TestClock(t0), store = makeStore(directory, clock: clock)
		let big = JSONValue.string(String(repeating: "x", count: 9 * 1_048_576))
		await store.setPreferences(OfflinePreferences(storageLimitMiB: 250))
		for key in ["a", "b", "c"] {
			try await store.saveTrip(OfflineFixtures.detail(key, raw: big), endpoint: endpoint)
			clock.advance(10)
		}
		// "a" is saved manually on disk but its index entry still says automatic.
		await store.injectIndexWriteFailures(1)
		await #expect(throws: (any Error).self) { try await store.setManuallySaved(true, tripKey: "a", endpoint: endpoint) }
		let report = try await store.prune(preferences: OfflinePreferences(storageLimitMiB: 25), now: clock.now)
		#expect(report.evictedTripKeys == ["b"])
		let usage = await store.usage()
		#expect(!usage.overLimit && usage.savedTripCount == 1 && usage.tripCount == 2)
		#expect(await store.trip(key: "a", endpoint: endpoint)?.manuallySaved == true)
	}

	@Test func alertsOnlyBoardUpdatesKeepTheSaveTime() async throws {
		let directory = OfflineFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
		let clock = TestClock(t0), store = makeStore(directory, clock: clock)
		let sources = [SourceState(id: "gtfs", timestamp: t0), SourceState(id: "subway-alerts", timestamp: t0)]
		try await store.saveBoard(OfflineFixtures.board(sources: sources, departures: [OfflineFixtures.departure("one")]), endpoint: endpoint)
		clock.advance(600)
		var alerted = OfflineFixtures.board(sources: [sources[0], SourceState(id: "subway-alerts", timestamp: t0 + 600)], departures: [OfflineFixtures.departure("one")])
		alerted.alerts = [ServiceAlert(id: "a", title: "Delays", description: "")]
		#expect(try await store.saveBoard(alerted, endpoint: endpoint) == .stored)
		var cached = try #require(await store.board(stationID: "101", endpoint: endpoint))
		#expect(cached.savedAt == t0 && cached.board.alerts.count == 1)
		// Expiry still counts from the last prediction update.
		#expect(try await store.prune(preferences: OfflinePreferences(retentionHours: 1), now: t0 + 3601).expiredStationIDs == ["101"])
		try await store.saveBoard(OfflineFixtures.board(sources: sources, departures: [OfflineFixtures.departure("one")]), endpoint: endpoint)
		clock.advance(60)
		try await store.saveBoard(OfflineFixtures.board(sources: [SourceState(id: "gtfs", timestamp: t0 + 660)], departures: [OfflineFixtures.departure("two", timestamp: t0 + 660)]), endpoint: endpoint)
		cached = try #require(await store.board(stationID: "101", endpoint: endpoint))
		#expect(cached.savedAt == t0 + 660)
	}

	@Test func readsBatchAccessTimesInsteadOfRewritingTheIndex() async throws {
		let directory = OfflineFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
		let clock = TestClock(t0), store = makeStore(directory, clock: clock)
		try await store.saveTrip(OfflineFixtures.detail("t"), endpoint: endpoint)
		try await store.saveBoard(OfflineFixtures.board(departures: [OfflineFixtures.departure("t")]), endpoint: endpoint)
		let indexURL = directory.appendingPathComponent("v1/index.json")
		let written = try Data(contentsOf: indexURL)
		for _ in 0..<5 {
			clock.advance(10)
			_ = await store.trip(key: "t", endpoint: endpoint)
			_ = await store.board(stationID: "101", endpoint: endpoint)
			try await store.saveTrip(OfflineFixtures.detail("t"), endpoint: endpoint)
		}
		#expect(try Data(contentsOf: indexURL) == written)
		// In-memory access times still order eviction and listings.
		#expect(await store.cachedTrips(endpoint: endpoint).first?.accessedAt == t0 + 50)
		clock.advance(11)
		_ = await store.trip(key: "t", endpoint: endpoint)
		#expect(try Data(contentsOf: indexURL) != written)
		let flushed = try JSONDecoder().decode(OfflineTransitStore.Index.self, from: Data(contentsOf: indexURL))
		#expect(flushed.entries[OfflineIdentity.trip(endpoint: endpoint, tripKey: "t")]?.accessedAt == t0 + 61)
		clock.advance(5)
		_ = await store.trip(key: "t", endpoint: endpoint)
		try await store.flushAccessTimes()
		let explicit = try JSONDecoder().decode(OfflineTransitStore.Index.self, from: Data(contentsOf: indexURL))
		#expect(explicit.entries[OfflineIdentity.trip(endpoint: endpoint, tripKey: "t")]?.accessedAt == t0 + 66)
	}

	@Test func removingAutomaticEntriesKeepsSavedTripsRidesAndOtherEndpoints() async throws {
		let directory = OfflineFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
		let store = makeStore(directory, clock: TestClock(t0))
		let debug = "http://127.0.0.1:8092/api/v1/"
		try await store.saveTrip(OfflineFixtures.detail("auto"), endpoint: endpoint)
		try await store.saveTrip(OfflineFixtures.detail("saved"), endpoint: endpoint, manuallySaved: true)
		try await store.saveTrip(OfflineFixtures.detail("ride"), endpoint: endpoint)
		try await store.saveTrip(OfflineFixtures.detail("other"), endpoint: debug)
		try await store.saveBoard(OfflineFixtures.board(departures: [OfflineFixtures.departure("auto")]), endpoint: endpoint)
		try await store.setActiveRide(ActiveRide(tripKey: "ride", startedAt: t0), endpoint: endpoint)
		let report = try await store.removeAutomaticEntries(endpoint: "https://subwaysfornerds.juliet.nyc/api/v1/")
		#expect(report.evictedTripKeys == ["auto"] && report.evictedStationIDs == ["101"])
		#expect(await store.cachedTrips(endpoint: endpoint).map(\.tripKey).sorted() == ["ride", "saved"])
		#expect(await store.trip(key: "other", endpoint: debug) != nil)
		#expect(await store.board(stationID: "101", endpoint: endpoint) == nil)
	}
}

/// Opens per-key gates for fetch closures and records what started.
actor FetchGates {
	private var open: Set<String> = []
	private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]
	private(set) var started: [String] = []
	private(set) var finished: [String] = []
	func run(_ key: String) async {
		started.append(key)
		if !open.contains(key) { await withCheckedContinuation { waiting[key, default: []].append($0) } }
		finished.append(key)
	}
	func release(_ key: String) {
		open.insert(key)
		for waiter in waiting.removeValue(forKey: key) ?? [] { waiter.resume() }
	}
	func releaseAll() { for key in waiting.keys { release(key) } }
	var running: Int { started.count - finished.count }
}

struct OfflinePrefetcherTests {
	let endpoint = OfflineFixtures.endpoint
	func trip(_ key: String, _ priority: OfflineFetchPriority = .explicit) -> OfflineFetchRequest { OfflineFetchRequest(endpoint: endpoint, target: .trip(key: key), priority: priority) }
	static func key(_ request: OfflineFetchRequest) -> String {
		switch request.target { case .trip(let key): key; case .board(let id): id }
	}

	private func waitUntil(_ condition: () async -> Bool) async {
		for _ in 0..<500 where !(await condition()) { try? await Task.sleep(nanoseconds: 2_000_000) }
	}

	private func make(_ gates: FetchGates) -> OfflinePrefetcher {
		OfflinePrefetcher(clock: { 0 }) { request in await gates.run(Self.key(request)) }
	}

	@Test func requestReturnsOnlyAfterItsFetchFinishes() async {
		let gates = FetchGates(), prefetcher = make(gates)
		await gates.release("t")
		#expect(await prefetcher.request(trip("t")) == .completed)
		#expect(await gates.finished == ["t"])
	}

	@Test func concurrentRequestsJoinOneFetch() async {
		let gates = FetchGates(), prefetcher = make(gates)
		async let first = prefetcher.request(trip("t"))
		async let second = prefetcher.request(trip("t"))
		await waitUntil { await gates.started.count == 1 }
		try? await Task.sleep(nanoseconds: 20_000_000)
		await gates.release("t")
		#expect(await [first, second] == [.completed, .completed])
		#expect(await gates.started == ["t"])
		await prefetcher.stop()
	}

	@Test func requestsJoinTrackedWorkAlreadyInFlight() async {
		let gates = FetchGates(), prefetcher = make(gates)
		await prefetcher.track([trip("selected", .selected)])
		await waitUntil { await gates.started.count == 1 }
		async let joined = prefetcher.request(trip("selected"))
		try? await Task.sleep(nanoseconds: 20_000_000)
		await gates.release("selected")
		#expect(await joined == .completed)
		try? await Task.sleep(nanoseconds: 20_000_000)
		#expect(await gates.started == ["selected"])
		#expect(await prefetcher.state.inFlight.isEmpty)
		await prefetcher.stop()
	}

	@Test func pausedRequestsReturnAtOnceWithoutFetching() async {
		let gates = FetchGates(), prefetcher = make(gates)
		await prefetcher.setConnected(false)
		#expect(await prefetcher.request(trip("offline")) == .paused)
		await prefetcher.setConnected(true)
		await prefetcher.setForeground(false)
		#expect(await prefetcher.request(trip("background")) == .paused)
		#expect(await gates.started.isEmpty)
	}

	@Test func queuedRequestsResolveAsPausedWhenConnectivityDrops() async {
		let gates = FetchGates(), prefetcher = make(gates)
		async let a = prefetcher.request(trip("a"))
		async let b = prefetcher.request(trip("b"))
		async let c = prefetcher.request(trip("c"))
		await waitUntil { await gates.started.count == 3 }
		async let d = prefetcher.request(trip("d"))
		try? await Task.sleep(nanoseconds: 20_000_000)
		#expect(await gates.running == 3)
		await prefetcher.setConnected(false)
		#expect(await d == .paused)
		await gates.releaseAll()
		#expect(await [a, b, c] == [.completed, .completed, .completed])
		#expect(await gates.started.count == 3)
	}

	@Test func explicitRequestsUseTheSlotBackgroundWorkLeavesFreeThenTheNextFreeSlot() async {
		let gates = FetchGates(), prefetcher = make(gates)
		await prefetcher.track((1...4).map { trip("near\($0)", .background) })
		await waitUntil { await gates.started.count == 2 }
		try? await Task.sleep(nanoseconds: 20_000_000)
		#expect(await gates.started == ["near1", "near2"])
		// Hung background fetches never hold the last slot.
		async let explicit = prefetcher.request(trip("opened"))
		await waitUntil { await gates.started.count == 3 }
		#expect(await gates.started == ["near1", "near2", "opened"])
		// With all three busy, the next explicit request takes the next free slot ahead of background work.
		async let second = prefetcher.request(trip("second"))
		try? await Task.sleep(nanoseconds: 20_000_000)
		#expect(await gates.running == 3)
		await gates.release("near1")
		await waitUntil { await gates.started.count == 4 }
		#expect(await gates.started.last == "second")
		await gates.release("opened")
		await gates.release("second")
		#expect(await [explicit, second] == [.completed, .completed])
		await waitUntil { await gates.started.count == 5 }
		await gates.releaseAll()
		await waitUntil { await gates.started.count == 6 }
		await gates.releaseAll()
		#expect(Array(await gates.started.suffix(2)) == ["near3", "near4"])
		await prefetcher.stop()
	}
}
