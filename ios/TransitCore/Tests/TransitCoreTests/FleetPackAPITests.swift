import Foundation
import Testing
import TransitCore

@Suite(.serialized) struct FleetPackAPITests {
	@Test func defaultsAreAllCarsAndSevenDays() throws {
		let selection = FleetPackSelection()
		let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(selection)) as? [String: Any]
		#expect(json?["equipment"] as? [String] == [])
		#expect(json?["yards"] as? [String] == [])
		#expect(json?["historyDays"] as? Int == 7)
	}

	@Test func postPreservesExactMultiSelectionAndGetPollsTheJob() async throws {
		let recorder = PackRequestRecorder()
		PackAPIProtocol.handler = { request in
			recorder.append(request)
			if request.httpMethod == "POST" {
				return (202, Data("{\"jobId\":\"job:1/2\",\"state\":\"preparing\"}".utf8))
			}
			return (200, try JSONEncoder().encode(FleetPackJob(jobId: "job:1/2", state: .ready, manifest: Self.manifest)))
		}
		let api = makeAPI()
		let selection = FleetPackSelection(equipment: ["R211A", "R46"], yards: ["207 St", "unknown"], historyDays: 30)
		let preparing = try await api.prepare(selection: selection)
		#expect(preparing.state == .preparing && preparing.manifest == nil)
		let ready = try await api.status(jobID: preparing.jobId)
		#expect(ready.manifest == Self.manifest)
		let requests = recorder.requests
		#expect(requests.count == 2)
		#expect(requests[0].url?.path == "/api/v1/fleet/offline/v2/packs")
		#expect(requests[0].value(forHTTPHeaderField: "Content-Type") == "application/json")
		#expect(requests[1].url?.absoluteString.hasSuffix("/packs/job%3A1%2F2") == true)
		let body = try #require(requests[0].httpBody)
		#expect(try JSONDecoder().decode(FleetPackSelection.self, from: body) == selection)
	}

	@Test func preparingJobsCarryBuildProgressWhenTheServerSendsIt() async throws {
		let api = makeAPI()
		PackAPIProtocol.handler = { _ in (202, Data(#"{"jobId":"job","state":"preparing","progress":{"stage":"cars","label":"Writing car records","step":4,"steps":8,"done":12,"total":40,"fraction":0.107}}"#.utf8)) }
		let job = try await api.status(jobID: "job")
		#expect(job.progress?.stage == "cars" && job.progress?.done == 12 && job.progress?.total == 40)
		PackAPIProtocol.handler = { _ in (202, Data(#"{"jobId":"job","state":"preparing","progress":"soon"}"#.utf8)) }
		let tolerated = try await api.status(jobID: "job")
		#expect(tolerated.state == .preparing && tolerated.progress == nil)
	}

	@Test func busyAndUnavailableHaveDistinctActionableErrors() async throws {
		let api = makeAPI()
		for (status, expected) in [(429, FleetPackAPIError.busy), (503, .unavailable)] {
			PackAPIProtocol.handler = { _ in (status, Data()) }
			do { _ = try await api.prepare(selection: FleetPackSelection()); Issue.record("Accepted an unavailable pack") }
			catch let error as FleetPackAPIError { #expect(error == expected) }
		}
	}

	@Test func malformedJobsAndMismatchedPollingIdentityAreRejected() async throws {
		let api = makeAPI()
		for payload in ["{\"jobId\":\"job\",\"state\":\"ready\"}", "{\"jobId\":\"other\",\"state\":\"preparing\"}", "{\"jobId\":\"\",\"state\":\"preparing\"}"] {
			PackAPIProtocol.handler = { _ in (202, Data(payload.utf8)) }
			do { _ = try await api.status(jobID: "job"); Issue.record("Accepted a malformed pack job") }
			catch let error as FleetPackAPIError { #expect(error == .invalidResponse) }
		}
	}

	@Test func incompatibleReadyManifestIsRejectedBeforeShowingDownloadInformation() async throws {
		var invalid = Self.manifest
		invalid.archiveByteLength = -1
		PackAPIProtocol.handler = { [invalid] _ in
			(200, try JSONEncoder().encode(FleetPackJob(jobId: "job", state: .ready, manifest: invalid)))
		}
		do { _ = try await makeAPI().prepare(selection: FleetPackSelection()); Issue.record("Accepted an invalid ready manifest") }
		catch let error as FleetPackAPIError { #expect(error == .invalidResponse) }
	}

	@Test func invalidHistoryWindowDoesNotSendARequest() async throws {
		PackAPIProtocol.handler = { _ in Issue.record("Sent unsupported history window"); return (202, Data()) }
		do { _ = try await makeAPI().prepare(selection: FleetPackSelection(historyDays: 90)); Issue.record("Accepted unsupported history window") }
		catch let error as FleetPackAPIError { #expect(error == .invalidSelection) }
	}

	@Test func expiredJobsAreReportedForRepreparation() async throws {
		PackAPIProtocol.handler = { _ in (404, Data()) }
		do { _ = try await makeAPI().status(jobID: "expired"); Issue.record("Accepted an expired job") }
		catch let error as FleetPackAPIError { #expect(error == .expired) }
	}

	@Test func v2ManifestRoundTripsWithoutLegacySQLiteFields() throws {
		let encoded = try JSONEncoder().encode(Self.manifest)
		let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
		#expect(json["schemaVersion"] as? Int == 2)
		#expect(json["format"] as? String == "fleet-jsonl-v2")
		#expect(json["compression"] as? String == "gzip")
		#expect(json["byteLength"] == nil && json["sha256"] == nil)
		#expect(try JSONDecoder().decode(FleetPackManifest.self, from: encoded) == Self.manifest)
	}

	private static var manifest: FleetPackManifest {
		FleetPackManifest(id: String(repeating: "a", count: 64), generatedAt: 1000, historyStart: 0, historyEnd: 1000, selection: FleetPackSelection(), counts: FleetPackCounts(cars: 2, consists: 1, events: 1, assertions: 0, eventCars: 2, matchedCars: 2, linkedCars: 0), archiveByteLength: 1024, archiveSha256: String(repeating: "a", count: 64), uncompressedByteLength: 4096, estimatedSavedByteLength: 8192, downloadURL: "/api/v1/fleet/offline/v2/archives/a.gz")
	}
	private func makeAPI() -> FleetPackAPI {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [PackAPIProtocol.self]
		return FleetPackAPI(baseURL: URL(string: "https://fleet.example/api/v1/")!, session: URLSession(configuration: configuration))
	}
}

private final class PackRequestRecorder: @unchecked Sendable {
	private let lock = NSLock()
	private var storage: [URLRequest] = []
	var requests: [URLRequest] { lock.withLock { storage } }
	func append(_ request: URLRequest) {
		var copy = request
		if copy.httpBody == nil, let stream = request.httpBodyStream {
			stream.open(); defer { stream.close() }
			var body = Data(), buffer = [UInt8](repeating: 0, count: 4096)
			while stream.hasBytesAvailable {
				let count = stream.read(&buffer, maxLength: buffer.count)
				if count <= 0 { break }
				body.append(contentsOf: buffer.prefix(count))
			}
			copy.httpBody = body
		}
		lock.withLock { storage.append(copy) }
	}
}

private final class PackAPIProtocol: URLProtocol, @unchecked Sendable {
	nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?
	override class func canInit(with request: URLRequest) -> Bool { true }
	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
	override func startLoading() {
		do {
			let (status, data) = try Self.handler!(request)
			let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
			client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
			client?.urlProtocol(self, didLoad: data)
			client?.urlProtocolDidFinishLoading(self)
		} catch { client?.urlProtocol(self, didFailWithError: error) }
	}
	override func stopLoading() {}
}
