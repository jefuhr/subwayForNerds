import Foundation
import Testing
@testable import TransitCore

@Suite(.serialized)
struct TransitCoreTests {
	@Test
	func testOptionalWireValuesPreserveFalseAndZero() throws {
		let data = Data(#"{"key":"trip","feed":"gtfs","tripId":"0","route":"4","destination":"Woodlawn","direction":"NORTH","timestamp":1000,"assigned":false,"position":{"name":"Station","timestamp":0},"stops":[{"id":"x","name":"Stop","arrival":0,"departure":null,"sequence":0}],"alerts":[]}"#.utf8)
		let train = try JSONDecoder().decode(Train.self, from: data)
		#expect((train.assigned) == (false))
		#expect((train.trainId) == nil)
		#expect((train.position?.timestamp) == (0))
		#expect((train.stops.first?.arrival) == (0))
		#expect((train.stops.first?.sequence) == (0))
		#expect((train.stops.first?.departure) == nil)
		#expect((try JSONDecoder().decode(Train.self, from: JSONEncoder().encode(train))) == (train))
	}

	@Test
	func testRawJSONRoundTripsNestedValues() throws {
		let raw = Data(#"{"false":false,"zero":0,"null":null,"nested":[{"name":"a"},42]}"#.utf8)
		let value = try JSONDecoder().decode(JSONValue.self, from: raw)
		#expect((try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))) == (value))
		#expect(value.prettyPrinted.contains("false"))
	}

	@Test
	func testFreshnessBoundariesAndCachedCountdowns() {
		#expect((Display.freshness(nil, now: 1000)) == (.unavailable))
		#expect((Display.freshness(0, now: 1000)) == (.unavailable))
		#expect((Display.freshness(910, now: 1000)) == (.live))
		#expect((Display.freshness(909, now: 1000)) == (.stale))
		#expect((Display.freshness(700, now: 1000)) == (.stale))
		#expect((Display.freshness(699, now: 1000)) == (.expired))
		#expect((Display.countdown(1060, timestamp: 1000, now: 1000)) == (Countdown(value: "1", unit: "min")))
		#expect((Display.countdown(1059, timestamp: 1000, now: 1000).value) == ("<1"))
		#expect((Display.countdown(969, timestamp: 1000, now: 1000).unit) == ("awaiting update"))
		#expect((Display.countdown(nil, timestamp: 1000, now: 1000).unit) == ("no estimate"))
		#expect((Display.countdown(1060, timestamp: 1000, now: 1000, cached: true).unit) == ("last estimate"))
		#expect((Display.countdown(1060, timestamp: 909, now: 1000).unit) == ("last estimate"))
	}

	@Test
	func testClockAlwaysUsesEasternAndHandlesMissingTime() {
		#expect((Display.clockTime(0)) == ("7:00 PM"))
		#expect((Display.clockTime(nil)) == ("—"))
		#expect((Display.ageLabel(900, now: 1000)) == ("1m ago"))
	}

	@Test
	func testConsistExpiryAndReportedOrder() {
		let cars = ["100", "101", "102", "98", "97", "42"].map { ConsistCar(number: $0) }
		#expect((Display.consistSummary(cars)) == ("100–102, 98–97, 42"))
		#expect(Display.currentConsist(Consist(cars: cars, updatedAt: 700, fetchedAt: 1000), now: 1000))
		#expect(!(Display.currentConsist(Consist(cars: cars, updatedAt: 699, fetchedAt: 1000), now: 1000)))
		#expect(!(Display.currentConsist(Consist(cars: cars, updatedAt: 1000, fetchedAt: 1061), now: 1000)))
	}

	@Test
	func testBoardGroupingFiltersAndCancellation() {
		var board = sampleBoard()
		var canceled = sampleDeparture(key: "canceled", route: "4", time: 1100)
		canceled.relationship = "CANCELED"
		var unknown = sampleDeparture(key: "unknown", route: "5", time: 1100)
		unknown.actualTrack = nil; unknown.scheduledTrack = nil
		board.departures = [sampleDeparture(key: "old", time: 900), canceled, unknown]
		let groups = groupDepartures(board, now: 1000)
		#expect((groups.count) == (2))
		#expect((groups.flatMap(\.departures).count) == (2))
		#expect((groups.filter { $0.track == nil }.first?.departures.first?.key) == ("unknown"))
		#expect(!(Display.boardable(canceled)))
		#expect((groupDepartures(board, routes: ["4"], now: 1000).flatMap(\.departures).count) == (1))
		#expect((groupDepartures(board, direction: "SOUTH", now: 1000).count) == (0))
		#expect((groupDepartures(board, now: 1000, cached: true).flatMap(\.departures).count) == (3))
		#expect((Display.displayRoute("GS")) == ("S"))
		#expect((Display.displayRoute("SI")) == ("SIR"))
	}

	@Test
	func testServiceChangeOrderingAheadAndEvidenceExpiry() {
		let ahead = TripChange(id: "ahead", kind: "track", classification: "planned", label: "Track changed", location: "Canal St", stopIndices: [2], evidence: [ChangeEvidence(source: "gtfs", timestamp: 950, staleAfter: 90)])
		let current = TripChange(id: "current", kind: "boarding", classification: "unknown", label: "Board here", stopIndices: [0])
		let values = Display.changesAhead([ahead, current], index: 0)
		#expect((values.first?.id) == ("current"))
		#expect((values.last?.label) == ("Track changed · ahead at Canal St"))
		#expect(!(Display.changeStale(ahead, now: 1000)))
		#expect(Display.changeStale(ahead, now: 1041))
		#expect(Display.changeStale(ahead, now: 1000, cached: true))
	}

	@Test
	func testFileCacheSurvivesRelaunchAndEvictsOnlyRecentBoards() async throws {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: directory) }
		let cache = BoardCache(directory: directory, recentLimit: 2)
		for id in ["favorite", "old", "middle", "new"] {
			var board = sampleBoard(); board.station.id = id
			try await cache.save(board, favorites: ["favorite"])
		}
		try await cache.saveCatalog([sampleBoard().station])
		let relaunched = BoardCache(directory: directory, recentLimit: 2)
		let favorite = await relaunched.load(stationID: "favorite")
		let old = await relaunched.load(stationID: "old")
		let current = await relaunched.load(stationID: "new")
		let catalog = await relaunched.loadCatalog()
		#expect((favorite) != nil); #expect((old) == nil); #expect((current) != nil)
		#expect((catalog.count) == (1))
		#expect((Display.countdown(current?.departures.first?.time, timestamp: 1000, now: 1000, cached: true).unit) == ("last estimate"))
		let preferences = TransitPreferences(lastStation: "new", favorites: ["favorite"], theme: "night", stations: ["new": StationPreference(direction: "SOUTH", routes: ["4"])])
		let file = directory.appendingPathComponent("preferences.json")
		try await TransitPreferencesStore(fileURL: file).save(preferences)
		let restored = await TransitPreferencesStore(fileURL: file).load()
		#expect((restored) == (preferences))
	}

	@Test
	func testAPIEncodesOpaquePathAndQueryIdentifiers() throws {
		let api = TransitAPI(baseURL: URL(string: "https://example.test/subwaysForNerds/api/v1/")!)
		let url = try api.requestURL(components: ["fleet", "cars", "nyct:R160/1?x#%"], query: ["key": "A+B/100%?&x=1"])
		#expect(url.absoluteString.contains("nyct%3AR160%2F1%3Fx%23%25"))
		#expect(url.absoluteString.contains("A%2BB"))
		#expect((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value) == ("A+B/100%?&x=1"))
		#expect(throws: Error.self) { try api.requestURL(components: ["..", "secret"]) }
	}

	@Test
	func testAPIReusesETagResponseOnlyAfterServerValidation() async throws {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [StubProtocol.self]
		let session = URLSession(configuration: configuration)
		defer { session.invalidateAndCancel() }
		let body = try JSONEncoder().encode([sampleBoard().station])
		StubProtocol.state.reset([.init(status: 200, headers: ["ETag": "\"first\""], body: body), .init(status: 304), .init(status: 503)])
		let api = TransitAPI(baseURL: URL(string: "https://example.test/api/")!, session: session)
		let first = try await api.stations()
		let second = try await api.stations()
		#expect((first) == (second))
		let requests = StubProtocol.state.requests
		#expect((requests[0].value(forHTTPHeaderField: "If-None-Match")) == nil)
		#expect((requests[1].value(forHTTPHeaderField: "If-None-Match")) == ("\"first\""))
		do { _ = try await api.stations(); Issue.record("An error must not masquerade as a live cached response") }
		catch { #expect((error as? TransitAPIError) == (.httpStatus(503))) }
	}

	@Test
	func testAPIReportsMissingTrip() async throws {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [StubProtocol.self]
		let session = URLSession(configuration: configuration)
		defer { session.invalidateAndCancel() }
		StubProtocol.state.reset([.init(status: 404)])
		let api = TransitAPI(baseURL: URL(string: "https://example.test/api/")!, session: session)
		do { _ = try await api.trip(key: "gone"); Issue.record("Expected missing trip") }
		catch { #expect((error as? TransitAPIError) == (.notFound)) }
	}

	@Test
	func testOfflineManifestWireContract() throws {
		let bytes = Data(#"{"schemaVersion":1,"id":"snapshot-1","generatedAt":1000,"historyStart":100,"historyEnd":1000,"counts":{"cars":12,"consists":4,"events":20,"assertions":3},"byteLength":4096,"sha256":"abc","downloadURL":"/subwaysForNerds/api/v1/fleet/offline/snapshot-1.sqlite","observedAt":900}"#.utf8)
		let manifest = try JSONDecoder().decode(FleetOfflineManifest.self, from: bytes)
		#expect((manifest.counts.cars) == (12))
		#expect((manifest.byteLength) == (4096))
		#expect((manifest.observedAt) == (900))
	}

	private func sampleBoard() -> Board {
		Board(station: Station(id: "602", name: "14 St-Union Sq", borough: "M", routes: ["4", "5"], lat: 40.735, lon: -73.99), generatedAt: 1000, departures: [sampleDeparture()])
	}

	private func sampleDeparture(key: String = "d1", route: String = "4", time: TimeInterval = 1060) -> Departure {
		Departure(key: key, tripKey: "trip", route: route, destination: "Woodlawn", direction: "NORTH", stopId: "635N", partId: "635", area: "Lexington Av", time: time, arrival: time, scheduledTrack: "1", actualTrack: "2", pattern: "Express", patternSource: "inferred", location: "Near Canal St", stopsAway: 2, assigned: false, feed: "gtfs", timestamp: 1000)
	}
}

private struct StubResponse: Sendable {
	let status: Int
	var headers: [String: String] = [:]
	var body = Data()
}

private final class StubState: @unchecked Sendable {
	private let lock = NSLock()
	private var responses: [StubResponse] = []
	private var captured: [URLRequest] = []
	var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return captured }
	func reset(_ responses: [StubResponse]) { lock.lock(); defer { lock.unlock() }; self.responses = responses; captured = [] }
	func next(_ request: URLRequest) -> StubResponse {
		lock.lock(); defer { lock.unlock() }
		captured.append(request)
		return responses.isEmpty ? StubResponse(status: 500) : responses.removeFirst()
	}
}

private final class StubProtocol: URLProtocol, @unchecked Sendable {
	static let state = StubState()
	override class func canInit(with request: URLRequest) -> Bool { true }
	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
	override func startLoading() {
		let stub = Self.state.next(request)
		let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers)!
		client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
		client?.urlProtocol(self, didLoad: stub.body)
		client?.urlProtocolDidFinishLoading(self)
	}
	override func stopLoading() {}
}
