import CoreGraphics
import Foundation
import Testing
@testable import TransitCore

/// Failure modes: a newer or malformed payload decoding as if valid, a snapshot for a
/// different map version or PDF plotting onto this artwork, broken topology references,
/// and coordinates outside the page or not finite.
struct TrackMapContractTests {
	private func decodeSnapshot(_ json: String) throws -> TrackMapSnapshot { try JSONDecoder().decode(TrackMapSnapshot.self, from: Data(json.utf8)) }
	private func replacing(_ old: String, with new: String) -> String { TrackMapFixture.snapshotJSON.replacingOccurrences(of: old, with: new) }

	@Test func decodesTheWireFormatIncludingNulls() throws {
		let snapshot = try decodeSnapshot(TrackMapFixture.snapshotJSON)
		#expect(snapshot.schemaVersion == 1)
		#expect(snapshot.mapVersion == TrackMapContract.mapVersion)
		#expect(snapshot.trains.count == 2)
		let first = snapshot.trains[0]
		#expect(first.placement == .track)
		#expect(first.positionBasis == .estimated)
		#expect(first.trackBasis == .reported)
		#expect(first.motion?.points.count == 3)
		#expect(first.observedAt == 990)
		let second = snapshot.trains[1]
		#expect(second.placement == .unplaced)
		#expect(second.observedAt == nil)
		#expect(second.expiresAt == nil)
		#expect(second.point == nil)
		#expect(second.reason == "No vehicle observation")
		#expect(snapshot.sources[0].error == nil)
		#expect(snapshot.coverage == TrackMapSnapshotCoverage(placed: 1, uncertain: 0, unplaced: 1))
	}

	@Test func roundTripsThroughEncoding() throws {
		let snapshot = TrackMapFixture.snapshot()
		let decoded = try JSONDecoder().decode(TrackMapSnapshot.self, from: JSONEncoder().encode(snapshot))
		#expect(decoded == snapshot)
		let topology = TrackMapFixture.topology()
		#expect(try JSONDecoder().decode(TrackMapTopology.self, from: JSONEncoder().encode(topology)) == topology)
	}

	@Test func rejectsAnotherSchemaVersionBeforeReadingOtherFields() {
		#expect(throws: TrackMapError.unsupportedSchema(2)) { try decodeSnapshot(#"{"schemaVersion": 2, "somethingNew": true}"#) }
		#expect(throws: TrackMapError.unsupportedSchema(2)) { try JSONDecoder().decode(TrackMapTopology.self, from: Data(#"{"schemaVersion": 2}"#.utf8)) }
	}

	@Test func rejectsMalformedSnapshots() {
		#expect(throws: DecodingError.self) { try decodeSnapshot(replacing(#""placement": "track""#, with: #""placement": "teleported""#)) }
		#expect(throws: DecodingError.self) { try decodeSnapshot(replacing(#""freshness": "live""#, with: #""freshness": "fresh""#)) }
		#expect(throws: DecodingError.self) { try decodeSnapshot(replacing(#""generatedAt": 1000,"#, with: "")) }
		#expect(throws: DecodingError.self) { try decodeSnapshot(replacing(#""x": 100, "y": 100}"#, with: #""x": "100", "y": 100}"#)) }
		#expect(throws: DecodingError.self) { try decodeSnapshot("[]") }
	}

	@Test func acceptsTheCanonicalTopology() throws {
		let index = try TrackMapFixture.index()
		#expect(index.topology.mapVersion == "nyc-2.6.8-v1")
		#expect(index.pageRect == TrackMapRect(x: 0, y: 0, width: 7344, height: 11540.6))
		#expect(index.attribution.contains("Vanshnookenraggen"))
	}

	@Test func rejectsTopologyForAnotherMapOrPDF() {
		#expect(throws: TrackMapError.mapVersionMismatch("nyc-2.7.0-v1")) { try TrackMapIndex(topology: TrackMapFixture.topology(mapVersion: "nyc-2.7.0-v1"), pdfDigest: TrackMapContract.pdfSHA256) }
		#expect(throws: TrackMapError.pdfDigestMismatch) { try TrackMapIndex(topology: TrackMapFixture.topology(pdfSha256: String(repeating: "0", count: 64)), pdfDigest: TrackMapContract.pdfSHA256) }
		// The bundled PDF itself must be the artwork the topology was traced from.
		#expect(throws: TrackMapError.pdfDigestMismatch) { try TrackMapIndex(topology: TrackMapFixture.topology(), pdfDigest: String(repeating: "a", count: 64)) }
		#expect(throws: TrackMapError.pageMismatch) { try TrackMapIndex(topology: TrackMapFixture.topology(page: TrackMapPage(width: 612, height: 792)), pdfDigest: TrackMapContract.pdfSHA256) }
	}

	@Test func digestComparisonIgnoresCase() throws {
		_ = try TrackMapIndex(topology: TrackMapFixture.topology(), pdfDigest: TrackMapContract.pdfSHA256.uppercased())
	}

	@Test func rejectsBrokenTopologyGeometry() {
		let missingNode = [TrackMapEdge(id: "e1", from: "n1", to: "nowhere", points: [TrackMapPoint(x: 1, y: 1), TrackMapPoint(x: 2, y: 2)], bidirectional: true, revenue: true)]
		#expect(throws: TrackMapError.self) { try TrackMapIndex(topology: TrackMapFixture.topology(edges: missingNode), pdfDigest: TrackMapContract.pdfSHA256) }
		let onePoint = [TrackMapEdge(id: "e1", from: "n1", to: "n2", points: [TrackMapPoint(x: 1, y: 1)], bidirectional: true, revenue: true)]
		#expect(throws: TrackMapError.self) { try TrackMapIndex(topology: TrackMapFixture.topology(edges: onePoint), pdfDigest: TrackMapContract.pdfSHA256) }
		let offPage = [TrackMapNode(id: "n1", point: TrackMapPoint(x: 100, y: 99_999)), TrackMapNode(id: "n2", point: TrackMapPoint(x: 100, y: 1100)), TrackMapNode(id: "n3", point: TrackMapPoint(x: 1100, y: 1100))]
		#expect(throws: TrackMapError.self) { try TrackMapIndex(topology: TrackMapFixture.topology(nodes: offPage), pdfDigest: TrackMapContract.pdfSHA256) }
		let notFinite = [TrackMapNode(id: "n1", point: TrackMapPoint(x: .nan, y: 1)), TrackMapNode(id: "n2", point: TrackMapPoint(x: 100, y: 1100)), TrackMapNode(id: "n3", point: TrackMapPoint(x: 1100, y: 1100))]
		#expect(throws: TrackMapError.self) { try TrackMapIndex(topology: TrackMapFixture.topology(nodes: notFinite), pdfDigest: TrackMapContract.pdfSHA256) }
		let duplicate = [TrackMapNode(id: "n1", point: TrackMapPoint(x: 1, y: 1)), TrackMapNode(id: "n1", point: TrackMapPoint(x: 2, y: 2)), TrackMapNode(id: "n2", point: TrackMapPoint(x: 100, y: 1100)), TrackMapNode(id: "n3", point: TrackMapPoint(x: 1100, y: 1100))]
		#expect(throws: TrackMapError.self) { try TrackMapIndex(topology: TrackMapFixture.topology(nodes: duplicate), pdfDigest: TrackMapContract.pdfSHA256) }
	}

	@Test func rejectsSnapshotsForAnotherMapVersionOrPDF() throws {
		let index = try TrackMapFixture.index()
		#expect(throws: TrackMapError.mapVersionMismatch("nyc-2.7.0-v1")) { try index.accept(TrackMapFixture.snapshot(mapVersion: "nyc-2.7.0-v1")) }
		#expect(throws: TrackMapError.pdfDigestMismatch) { try index.accept(TrackMapFixture.snapshot(pdfSha256: String(repeating: "f", count: 64))) }
		var newer = TrackMapFixture.snapshot()
		newer.schemaVersion = 2
		#expect(throws: TrackMapError.unsupportedSchema(2)) { try index.accept(newer) }
	}

	@Test func keepsInvalidTrainsOffTheMapWithAReason() throws {
		let offPage = TrackMapFixture.train("off", point: TrackMapPoint(x: -50, y: 10), motion: nil)
		let nan = TrackMapFixture.train("nan", point: TrackMapPoint(x: .infinity, y: 10), motion: nil)
		var badProgress = TrackMapFixture.motion; badProgress.toProgress = 1.5
		let progress = TrackMapFixture.train("progress", motion: badProgress)
		var backwards = TrackMapFixture.motion; backwards.endTime = 900
		let reversedTime = TrackMapFixture.train("time", motion: backwards)
		var unknownEdge = TrackMapFixture.motion; unknownEdge.edgeIds = ["e1", "e99"]
		let edge = TrackMapFixture.train("edge", motion: unknownEdge)
		var short = TrackMapFixture.motion; short.points = [TrackMapPoint(x: 100, y: 100)]
		let onePoint = TrackMapFixture.train("short", motion: short)
		let good = TrackMapFixture.train("good")
		let duplicate = TrackMapFixture.train("good", route: "5")
		let accepted = try TrackMapFixture.accepted([offPage, nan, progress, reversedTime, edge, onePoint, good, duplicate])
		#expect(accepted.trains.map(\.key) == ["off", "nan", "progress", "time", "edge", "short", "good"])
		#expect(accepted.trains.last?.route == "4")
		for key in ["off", "nan", "progress", "time", "edge", "short"] { #expect(accepted.invalidGeometry[key] != nil, "\(key) should be rejected") }
		#expect(accepted.invalidGeometry["good"] == nil)
	}

	@Test func transformsTopLeftContractPointsToBottomLeftPDFSpace() throws {
		let page = TrackMapPage(width: TrackMapContract.pageWidth, height: TrackMapContract.pageHeight)
		let transform = try TrackMapPageTransform(cropBox: CGRect(x: 0, y: 0, width: 7344, height: 11540.6), rotation: 0, page: page)
		#expect(transform.pdfPoint(TrackMapPoint(x: 0, y: 0)) == CGPoint(x: 0, y: 11540.6))
		#expect(transform.pdfPoint(TrackMapPoint(x: 7344, y: 11540.6)) == CGPoint(x: 7344, y: 0))
		let p = transform.pdfPoint(TrackMapPoint(x: 100, y: 1100))
		#expect(p.x == 100)
		#expect(abs(p.y - 10440.6) < 1e-9)
		let back = transform.mapPoint(p)
		#expect(abs(back.x - 100) < 1e-9 && abs(back.y - 1100) < 1e-9)
		let rect = transform.pdfRect(TrackMapRect(x: 100, y: 100, width: 200, height: 50))
		#expect(rect.minX == 100 && rect.width == 200 && rect.height == 50)
		#expect(abs(rect.maxY - (11540.6 - 100)) < 1e-9)
	}

	@Test func transformHonorsACropBoxOrigin() throws {
		let page = TrackMapPage(width: TrackMapContract.pageWidth, height: TrackMapContract.pageHeight)
		let transform = try TrackMapPageTransform(cropBox: CGRect(x: 20, y: 30, width: 7344, height: 11540.6), rotation: 0, page: page)
		let p = transform.pdfPoint(TrackMapPoint(x: 0, y: 0))
		#expect(p.x == 20)
		#expect(abs(p.y - (30 + 11540.6)) < 1e-9)
		let q = transform.mapPoint(CGPoint(x: 20, y: 30))
		#expect(abs(q.x) < 1e-9 && abs(q.y - 11540.6) < 1e-9)
	}

	@Test func transformRejectsARotatedOrResizedPage() {
		let page = TrackMapPage(width: TrackMapContract.pageWidth, height: TrackMapContract.pageHeight)
		#expect(throws: TrackMapError.pageRotated(90)) { try TrackMapPageTransform(cropBox: CGRect(x: 0, y: 0, width: 7344, height: 11540.6), rotation: 90, page: page) }
		#expect(throws: TrackMapError.pageMismatch) { try TrackMapPageTransform(cropBox: CGRect(x: 0, y: 0, width: 7344, height: 11000), rotation: 0, page: page) }
		_ = try? TrackMapPageTransform(cropBox: CGRect(x: 0, y: 0, width: 7344.3, height: 11540.6), rotation: 360, page: page)
	}

	@Test func hashesBytesAsLowercaseHex() {
		#expect(TrackMapDigest.sha256Hex(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
	}

	@Test func snapshotEndpointUsesTheVersionedPath() throws {
		let api = TransitAPI(baseURL: URL(string: "https://example.test/api/v1/")!)
		let url = try api.requestURL(components: TransitAPI.trackMapSnapshotPath(mapVersion: TrackMapContract.mapVersion))
		#expect(url.absoluteString == "https://example.test/api/v1/track-map/nyc-2.6.8-v1/snapshot")
	}

	@Test func snapshotEndpointDecodesThroughTheAPI() async throws {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [TrackMapStubProtocol.self]
		let api = TransitAPI(baseURL: URL(string: "https://trackmap.test/api/v1/")!, session: URLSession(configuration: configuration))
		let snapshot = try await api.trackMapSnapshot(mapVersion: TrackMapContract.mapVersion)
		#expect(snapshot.trains.count == 2)
		#expect(TrackMapStubProtocol.paths.values.contains("/api/v1/track-map/nyc-2.6.8-v1/snapshot"))
	}
}

private final class TrackMapStubProtocol: URLProtocol, @unchecked Sendable {
	static let paths = TrackMapRequestLog()
	override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "trackmap.test" }
	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
	override func startLoading() {
		Self.paths.append(request.url!.path)
		client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
		client?.urlProtocol(self, didLoad: Data(TrackMapFixture.snapshotJSON.utf8))
		client?.urlProtocolDidFinishLoading(self)
	}
	override func stopLoading() {}
}

private final class TrackMapRequestLog: @unchecked Sendable {
	private let lock = NSLock()
	private var paths: [String] = []
	var values: [String] { lock.withLock { paths } }
	func append(_ path: String) { lock.withLock { paths.append(path) } }
}

/// Opt-in: validates a reviewed topology file and, when given, the PDF it was traced from.
/// SFN_TRACK_MAP_TOPOLOGY=/path/topology.json SFN_TRACK_MAP_PDF=/path/NYC_full_trackmap.pdf swift test --filter TrackMapResourceTests
struct TrackMapResourceTests {
	private static let environment = ProcessInfo.processInfo.environment

	@Test(.enabled(if: environment["SFN_TRACK_MAP_TOPOLOGY"] != nil))
	func reviewedTopologyPassesNativeValidation() throws {
		let topology = try JSONDecoder().decode(TrackMapTopology.self, from: Data(contentsOf: URL(fileURLWithPath: Self.environment["SFN_TRACK_MAP_TOPOLOGY"]!)))
		let digest = try Self.environment["SFN_TRACK_MAP_PDF"].map { TrackMapDigest.sha256Hex(try Data(contentsOf: URL(fileURLWithPath: $0))) } ?? TrackMapContract.pdfSHA256
		let index = try TrackMapIndex(topology: topology, pdfDigest: digest)
		#expect(!index.topology.stations.isEmpty)
		#expect(!index.attribution.isEmpty)
		for edge in topology.edges { #expect(TrackMapPolyline(edge.points).length > 0, "\(edge.id) has no length") }
	}
}
