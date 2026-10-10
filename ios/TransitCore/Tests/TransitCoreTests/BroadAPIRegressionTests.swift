import Foundation
import Testing
@testable import TransitCore

@Suite(.serialized)
struct BroadAPIRegressionTests {
	@Test
	func notModifiedWithoutAnAcceptedBodyFails() async throws {
		let (api, session) = makeAPI([.init(status: 304)])
		defer { session.invalidateAndCancel() }
		await #expect(throws: TransitAPIError.unexpectedNotModified) { try await api.stations() }
	}

	@Test
	func malformedReplacementDoesNotPoisonTheLastValidatedResponse() async throws {
		let (api, session) = makeAPI([
			.init(headers: ["ETag": "\"valid\""], body: catalog("602")),
			.init(headers: ["ETag": "\"malformed\""], body: Data("not JSON".utf8)),
			.init(status: 304)
		])
		defer { session.invalidateAndCancel() }
		_ = try await api.stations()
		await #expect(throws: DecodingError.self) { try await api.stations() }
		#expect(try await api.stations().map(\.id) == ["602"])
		#expect(BroadAPIProtocol.state.requests.last?.value(forHTTPHeaderField: "If-None-Match") == "\"valid\"")
	}

	@Test
	func untaggedReplacementDropsThePreviousValidator() async throws {
		let (api, session) = makeAPI([
			.init(headers: ["ETag": "\"old\""], body: catalog("602")),
			.init(body: catalog("617")),
			.init(status: 304)
		])
		defer { session.invalidateAndCancel() }
		_ = try await api.stations()
		#expect(try await api.stations().map(\.id) == ["617"])
		await #expect(throws: TransitAPIError.unexpectedNotModified) { try await api.stations() }
		#expect(BroadAPIProtocol.state.requests.last?.value(forHTTPHeaderField: "If-None-Match") == nil)
	}

	@Test
	func explicitCacheClearDropsBodiesAndValidators() async throws {
		let (api, session) = makeAPI([.init(headers: ["ETag": "\"old\""], body: catalog("602")), .init(status: 304)])
		defer { session.invalidateAndCancel() }
		_ = try await api.stations()
		await api.clearResponseCache()
		await #expect(throws: TransitAPIError.unexpectedNotModified) { try await api.stations() }
		#expect(BroadAPIProtocol.state.requests.last?.value(forHTTPHeaderField: "If-None-Match") == nil)
	}

	@Test
	func stationResponsesNeverShareValidatorsOrPayloads() async throws {
		let first = Board(station: Station(id: "602", name: "Union Square", borough: "M", lat: 0, lon: 0), generatedAt: 1000)
		let second = Board(station: Station(id: "617", name: "Atlantic Avenue", borough: "Bk", lat: 0, lon: 0), generatedAt: 1000)
		let (api, session) = makeAPI([
			.init(headers: ["ETag": "\"union\""], body: try JSONEncoder().encode(first)),
			.init(headers: ["ETag": "\"atlantic\""], body: try JSONEncoder().encode(second)),
			.init(status: 304), .init(status: 304)
		])
		defer { session.invalidateAndCancel() }
		_ = try await api.board(stationID: "602")
		_ = try await api.board(stationID: "617")
		#expect(try await api.board(stationID: "602").station.id == "602")
		#expect(try await api.board(stationID: "617").station.id == "617")
		let validators = BroadAPIProtocol.state.requests.map { $0.value(forHTTPHeaderField: "If-None-Match") }
		#expect(validators == [nil, nil, "\"union\"", "\"atlantic\""])
	}

	@Test(arguments: [401, 404, 429, 500, 503])
	func httpFailuresNeverReturnCachedData(status: Int) async throws {
		let (api, session) = makeAPI([.init(headers: ["ETag": "\"accepted\""], body: catalog("602")), .init(status: status)])
		defer { session.invalidateAndCancel() }
		_ = try await api.stations()
		await #expect(throws: status == 404 ? TransitAPIError.notFound : .httpStatus(status)) { try await api.stations() }
	}

	private func catalog(_ id: String) -> Data {
		try! JSONEncoder().encode([Station(id: id, name: id, borough: "M", lat: 0, lon: 0)])
	}
	private func makeAPI(_ replies: [BroadAPIReply]) -> (TransitAPI, URLSession) {
		BroadAPIProtocol.state.reset(replies)
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [BroadAPIProtocol.self]
		let session = URLSession(configuration: configuration)
		return (TransitAPI(baseURL: URL(string: "https://broad-audit.test/api/")!, session: session), session)
	}
}

private struct BroadAPIReply: Sendable {
	var status = 200
	var headers: [String: String] = [:]
	var body = Data()
}

private final class BroadAPIState: @unchecked Sendable {
	private let lock = NSLock()
	private var replies: [BroadAPIReply] = []
	private var captured: [URLRequest] = []
	var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return captured }
	func reset(_ replies: [BroadAPIReply]) { lock.lock(); defer { lock.unlock() }; self.replies = replies; captured = [] }
	func next(_ request: URLRequest) -> BroadAPIReply {
		lock.lock(); defer { lock.unlock() }
		captured.append(request)
		return replies.isEmpty ? BroadAPIReply(status: 500) : replies.removeFirst()
	}
}

private final class BroadAPIProtocol: URLProtocol, @unchecked Sendable {
	static let state = BroadAPIState()
	override class func canInit(with request: URLRequest) -> Bool { true }
	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
	override func startLoading() {
		let reply = Self.state.next(request)
		client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!, cacheStoragePolicy: .notAllowed)
		client?.urlProtocol(self, didLoad: reply.body)
		client?.urlProtocolDidFinishLoading(self)
	}
	override func stopLoading() {}
}
