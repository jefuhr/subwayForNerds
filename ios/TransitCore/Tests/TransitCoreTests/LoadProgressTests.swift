import Foundation
import Testing
@testable import TransitCore

@Suite(.serialized)
struct LoadProgressTests {
	private let base = URL(string: "https://example.test/api/")!

	@Test
	func transferPercentIsExactBytesAndTextNamesTheWork() {
		let requesting = TransferProgress(phase: .requesting, host: "example.test")
		#expect(requesting.load("departures") == LoadProgress(fraction: 0, detail: "Requesting departures from example.test…"))
		let half = TransferProgress(phase: .receiving, receivedBytes: 1_000, expectedBytes: 2_000, host: "example.test")
		#expect(half.load("departures") == LoadProgress(fraction: 0.5, detail: "Receiving departures · \(TransferProgress.bytes(1_000)) of \(TransferProgress.bytes(2_000))"))
		// Without an announced size nothing is measurable, so no percent is claimed.
		let unknown = TransferProgress(phase: .receiving, receivedBytes: 1_000, host: "example.test")
		#expect(unknown.load("departures") == LoadProgress(fraction: nil, detail: "Receiving departures · \(TransferProgress.bytes(1_000)) so far"))
		// A body larger than announced stays full rather than moving the bar back.
		let outgrown = TransferProgress(phase: .receiving, receivedBytes: 3_000, expectedBytes: 2_000, host: "example.test")
		#expect(outgrown.load("departures") == LoadProgress(fraction: 1, detail: "Receiving departures · \(TransferProgress.bytes(3_000)) so far, more than the \(TransferProgress.bytes(2_000)) announced"))
		let decoding = TransferProgress(phase: .decoding, receivedBytes: 2_000, expectedBytes: 2_000, host: "example.test")
		#expect(decoding.load("departures") == LoadProgress(fraction: 1, detail: "Decoding \(TransferProgress.bytes(2_000)) of departures…"))
		#expect(TransferProgress(phase: .validated, host: "example.test").load("departures").detail == "No changes since the last check · reusing the departures already on this device")
		#expect(TransferProgress(phase: .finished, host: "example.test").load("departures").percentLabel == "100%")
	}

	@Test
	func percentIsBoundedEstimatesAreMarkedAndUnmeasuredWorkShowsNone() {
		#expect(LoadProgress(fraction: 0.999, detail: "").percent == 99)
		#expect(LoadProgress(fraction: 1, detail: "").percent == 100)
		#expect(LoadProgress(fraction: 0.426, detail: "").percentLabel == "42%")
		#expect(LoadProgress(fraction: 0.426, detail: "", estimated: true).percentLabel == "~42%")
		#expect(LoadProgress(fraction: 0.426, detail: "", estimated: true).spokenPercent == "about 42 percent")
		#expect(LoadProgress(fraction: 0.426, detail: "").spokenPercent == "42 percent")
		#expect(LoadProgress(fraction: nil, detail: "").percentLabel == nil)
		#expect(LoadProgress(fraction: -1, detail: "").fraction == 0)
		#expect(LoadProgress(fraction: .nan, detail: "").fraction == nil)
		#expect(LoadProgress(fraction: 7, detail: "").fraction == 1)
		#expect(LoadProgress.step(1, of: 3, "Reading saved trains") == LoadProgress(fraction: 1.0 / 3, detail: "Step 2 of 3 · Reading saved trains", estimated: true))
		#expect(LoadProgress.step(3, of: 3, "Done").detail == "Step 3 of 3 · Done")
	}

	@Test
	func apiReportsExactByteProgressFromTheUncompressedLength() async throws {
		let body = try JSONEncoder().encode(largeBoard())
		ChunkedProtocol.state.reset([.init(status: 200, headers: ["X-Uncompressed-Length": String(body.count)], body: body)])
		let (api, session) = makeAPI()
		defer { session.invalidateAndCancel() }
		let log = ProgressLog()
		let board = try await api.board(stationID: "602") { await log.append($0) }
		#expect(board.departures.count == 600)
		let values = await log.values
		#expect(values.first == TransferProgress(phase: .requesting, host: "example.test"))
		#expect(values.last?.phase == .finished)
		let receiving = values.filter { $0.phase == .receiving }
		// The body trickles in, so samples land mid-download, not only at the end.
		#expect(receiving.filter { $0.receivedBytes > 0 && $0.receivedBytes < Int64(body.count) }.count >= 2)
		#expect(receiving.allSatisfy { $0.expectedBytes == Int64(body.count) })
		#expect(receiving.last?.receivedBytes == Int64(body.count))
		#expect(values.contains { $0.phase == .decoding && $0.receivedBytes == Int64(body.count) })
		Self.expectNeverBackwards(values)
	}

	@Test
	func apiFallsBackToStepsWhenTheServerOmitsTheLength() async throws {
		let body = try JSONEncoder().encode(largeBoard())
		ChunkedProtocol.state.reset([.init(status: 200, body: body)])
		let (api, session) = makeAPI()
		defer { session.invalidateAndCancel() }
		let log = ProgressLog()
		_ = try await api.board(stationID: "602") { await log.append($0) }
		let receiving = await log.values.filter { $0.phase == .receiving }
		#expect(!receiving.isEmpty)
		#expect(receiving.allSatisfy { $0.expectedBytes == nil && $0.fraction == nil })
		#expect(receiving.last?.receivedBytes == Int64(body.count))
		#expect(await log.values.last?.phase == .finished)
	}

	@Test
	func apiNeverMovesBackwardsWhenTheBodyOutgrowsItsAnnouncedSize() async throws {
		let body = try JSONEncoder().encode(largeBoard())
		ChunkedProtocol.state.reset([.init(status: 200, headers: ["X-Uncompressed-Length": String(body.count / 2)], body: body)])
		let (api, session) = makeAPI()
		defer { session.invalidateAndCancel() }
		let log = ProgressLog()
		let board = try await api.board(stationID: "602") { await log.append($0) }
		#expect(board.departures.count == 600)
		let values = await log.values
		Self.expectNeverBackwards(values)
		let last = try #require(values.last { $0.phase == .receiving })
		#expect(last.receivedBytes == Int64(body.count) && last.fraction == 1)
		#expect(last.load("departures").detail.contains("more than the"))
	}

	@Test
	func apiReportsAValidatedCopyForNotModified() async throws {
		let body = try JSONEncoder().encode(largeBoard())
		ChunkedProtocol.state.reset([
			.init(status: 200, headers: ["ETag": "\"board\"", "X-Uncompressed-Length": String(body.count)], body: body),
			.init(status: 304),
		])
		let (api, session) = makeAPI()
		defer { session.invalidateAndCancel() }
		let first = try await api.board(stationID: "602")
		let log = ProgressLog()
		let second = try await api.board(stationID: "602") { await log.append($0) }
		#expect(first == second)
		#expect(await log.values.map(\.phase) == [.requesting, .validated, .finished])
	}

	@Test
	func apiReportsOnlyTheRequestBeforeAnHTTPFailure() async throws {
		ChunkedProtocol.state.reset([.init(status: 404)])
		let (api, session) = makeAPI()
		defer { session.invalidateAndCancel() }
		let log = ProgressLog()
		do { _ = try await api.trip(key: "gone") { await log.append($0) }; Issue.record("Expected missing trip") }
		catch { #expect((error as? TransitAPIError) == .notFound) }
		#expect(await log.values.map(\.phase) == [.requesting])
	}

	@Test
	func packBuildProgressDescribesTheStageAndIgnoresMalformedProgress() throws {
		let job = try JSONDecoder().decode(FleetPackJob.self, from: Data(#"{"jobId":"j","state":"preparing","progress":{"stage":"history","label":"Scanning movement history","step":6,"steps":8,"done":41200,"total":98000,"fraction":0.4127}}"#.utf8))
		let progress = try #require(job.progress)
		#expect(progress.stage == "history")
		#expect(progress.load == LoadProgress(fraction: 0.4127, detail: "Step 6 of 8 · Scanning movement history · \(41_200.formatted()) of \(98_000.formatted())", estimated: true))
		let uncounted = FleetPackBuildProgress(stage: "opening", label: "Opening the fleet database", step: 2, steps: 8, done: 0, total: 0, fraction: 0.01)
		#expect(uncounted.load.detail == "Step 2 of 8 · Opening the fleet database")
		let malformed = try JSONDecoder().decode(FleetPackJob.self, from: Data(#"{"jobId":"j","state":"preparing","progress":{"stage":7}}"#.utf8))
		#expect(malformed.jobId == "j" && malformed.progress == nil)
		let ready = try JSONDecoder().decode(FleetPackJob.self, from: Data(#"{"jobId":"j","state":"ready"}"#.utf8))
		#expect(ready.progress == nil)
	}

	private func makeAPI() -> (TransitAPI, URLSession) {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [ChunkedProtocol.self]
		let session = URLSession(configuration: configuration)
		return (TransitAPI(baseURL: base, session: session, progressInterval: .milliseconds(2)), session)
	}

	/// Unmeasured reports (nil) never pull the bar back either; they only hide the percent.
	private static func expectNeverBackwards(_ values: [TransferProgress]) {
		let fractions = values.compactMap(\.fraction)
		#expect(zip(fractions, fractions.dropFirst()).allSatisfy { $0 <= $1 }, "\(fractions)")
	}

	/// About 300 KB of JSON, so the body arrives as many progress-sized chunks.
	private func largeBoard() -> Board {
		let departures = (0..<600).map { index in
			Departure(key: "d\(index)", tripKey: "trip\(index)", route: "4", destination: "Woodlawn", direction: "NORTH", stopId: "635N", partId: "635", area: "Lexington Av", time: 1060, arrival: 1060, scheduledTrack: "1", actualTrack: "2", pattern: "Express", patternSource: "inferred", location: "Near Canal St", stopsAway: 2, assigned: false, feed: "gtfs", timestamp: 1000)
		}
		return Board(station: Station(id: "602", name: "14 St-Union Sq", borough: "M", routes: ["4", "5"], lat: 40.735, lon: -73.99), generatedAt: 1000, departures: departures)
	}
}

private actor ProgressLog {
	private(set) var values: [TransferProgress] = []
	func append(_ value: TransferProgress) { values.append(value) }
}

private struct ChunkedResponse: Sendable {
	let status: Int
	var headers: [String: String] = [:]
	var body = Data()
}

private final class ChunkedState: @unchecked Sendable {
	private let lock = NSLock()
	private var responses: [ChunkedResponse] = []
	func reset(_ responses: [ChunkedResponse]) { lock.withLock { self.responses = responses } }
	func next() -> ChunkedResponse { lock.withLock { responses.isEmpty ? ChunkedResponse(status: 500) : responses.removeFirst() } }
}

/// Delivers each body in 16 KB pieces a few milliseconds apart, like a slow network would.
private final class ChunkedProtocol: URLProtocol, @unchecked Sendable {
	static let state = ChunkedState()
	private let stopped = NSLock()
	private var isStopped = false
	override class func canInit(with request: URLRequest) -> Bool { true }
	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
	override func startLoading() {
		let stub = Self.state.next()
		let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers)!
		client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
		let pieces = stride(from: 0, to: stub.body.count, by: 16_384).map { stub.body.subdata(in: $0..<min(stub.body.count, $0 + 16_384)) }
		deliver(pieces[...])
	}
	private func deliver(_ pieces: ArraySlice<Data>) {
		guard !stopped.withLock({ isStopped }) else { return }
		guard let piece = pieces.first else { client?.urlProtocolDidFinishLoading(self); return }
		client?.urlProtocol(self, didLoad: piece)
		DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(4)) { self.deliver(pieces.dropFirst()) }
	}
	override func stopLoading() { stopped.withLock { isStopped = true } }
}
