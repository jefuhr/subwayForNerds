import Foundation

public enum TransitAPIError: Error, LocalizedError, Sendable, Equatable {
	case invalidURL
	case invalidResponse
	case notFound
	case httpStatus(Int)
	case unexpectedNotModified

	public var errorDescription: String? {
		switch self {
		case .invalidURL: return "The train feed address is invalid."
		case .invalidResponse: return "The train feed returned an invalid response."
		case .notFound: return "No longer available in the current feed."
		case .httpStatus: return "Could not reach the train feed."
		case .unexpectedNotModified: return "The train feed cache is unavailable. Try again."
		}
	}
}

/// The server remains the source of normalized feed data. Cached responses are
/// reused only after server validation; offline data is explicitly owned by the UI cache.
public actor TransitAPI {
	public static let productionBaseURL = URL(string: "https://subwaysfornerds.juliet.nyc/api/v1/")!
	public let baseURL: URL
	private let session: URLSession
	private let progressInterval: Duration
	private struct CachedResponse { let data: Data; let etag: String }
	private var responses: [URL: CachedResponse] = [:]

	/// `progressInterval` is how often a watched request samples its received bytes.
	public init(baseURL: URL = TransitAPI.productionBaseURL, session: URLSession = .shared, progressInterval: Duration = .milliseconds(100)) {
		self.baseURL = baseURL
		self.session = session
		self.progressInterval = progressInterval
	}

	public func stations() async throws -> [Station] { try await get(["stations"]) }
	public func board(stationID: String, progress: TransferProgressHandler? = nil) async throws -> Board {
		try await get(["stations", stationID, "board"], progress: progress)
	}
	public func trip(key: String, progress: TransferProgressHandler? = nil) async throws -> TripDetail {
		try await get(["trips"], query: ["key": key], progress: progress)
	}
	public func transfers(key: String, stopID: String, sequence: Int? = nil, progress: TransferProgressHandler? = nil) async throws -> TransferResult {
		var query = ["key": key, "stopId": stopID]
		if let sequence { query["sequence"] = String(sequence) }
		return try await get(["trips", "transfers"], query: query, progress: progress)
	}
	public func context(stationID: String, progress: TransferProgressHandler? = nil) async throws -> StationContext {
		try await get(["stations", stationID, "context"], progress: progress)
	}
	public func fleet(query: [String: String] = [:], progress: TransferProgressHandler? = nil) async throws -> FleetPage {
		try await get(["fleet"], query: query, progress: progress)
	}
	public func fleetDetail(kind: String, id: String, progress: TransferProgressHandler? = nil) async throws -> FleetDetail {
		try await get(["fleet", kind, id], progress: progress)
	}
	public func offlineManifest() async throws -> FleetOfflineManifest { try await get(["fleet", "offline", "manifest"]) }
	public func clearResponseCache() { responses.removeAll() }

	private func get<T: Decodable & Sendable>(_ components: [String], query: [String: String] = [:], progress: TransferProgressHandler? = nil) async throws -> T {
		let url = try requestURL(components: components, query: query)
		let host = url.host ?? baseURL.absoluteString
		var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
		request.setValue("application/json", forHTTPHeaderField: "Accept")
		let cached = responses[url]
		if let cached { request.setValue(cached.etag, forHTTPHeaderField: "If-None-Match") }
		await progress?(TransferProgress(phase: .requesting, host: host))
		let (data, raw) = try await load(request, host: host, progress: progress)
		guard let response = raw as? HTTPURLResponse else { throw TransitAPIError.invalidResponse }
		let payload: Data
		switch response.statusCode {
		case 304:
			guard let cached else { throw TransitAPIError.unexpectedNotModified }
			payload = cached.data
			await progress?(TransferProgress(phase: .validated, receivedBytes: Int64(payload.count), expectedBytes: Int64(payload.count), host: host))
		case 200..<300:
			payload = data
			await progress?(TransferProgress(phase: .decoding, receivedBytes: Int64(payload.count), expectedBytes: Int64(payload.count), host: host))
		case 404: throw TransitAPIError.notFound
		default: throw TransitAPIError.httpStatus(response.statusCode)
		}
		let decoded = try JSONDecoder().decode(T.self, from: payload)
		if response.statusCode != 304 {
			if let etag = response.value(forHTTPHeaderField: "ETag") { responses[url] = CachedResponse(data: payload, etag: etag) }
			else { responses.removeValue(forKey: url) }
			// Search and trip URLs can grow indefinitely in a long-running session.
			if responses.count > 128, let evicted = responses.keys.first(where: { $0 != url }) { responses.removeValue(forKey: evicted) }
		}
		await progress?(TransferProgress(phase: .finished, receivedBytes: Int64(payload.count), expectedBytes: Int64(payload.count), host: host))
		return decoded
	}

	/// URLSession hands over the decompressed body and reports no length for a gzip
	/// response, so the server states the decoded size in its own header.
	static func decodedLength(_ response: HTTPURLResponse) -> Int64? {
		if let header = response.value(forHTTPHeaderField: "X-Uncompressed-Length"), let value = Int64(header), value > 0 { return value }
		return response.expectedContentLength > 0 ? response.expectedContentLength : nil
	}

	/// Always reads the body with `data(for:)`. While someone watches, the task's own byte
	/// count is sampled alongside, so progress adds no work per byte received.
	private func load(_ request: URLRequest, host: String, progress: TransferProgressHandler?) async throws -> (Data, URLResponse) {
		guard let progress else { return try await session.data(for: request) }
		let watch = TaskWatch()
		let interval = progressInterval
		let sampler = Task {
			var reported: Int64 = -1
			while !Task.isCancelled {
				if let sample = watch.receiving(), sample.received != reported {
					reported = sample.received
					await progress(TransferProgress(phase: .receiving, receivedBytes: sample.received, expectedBytes: sample.expected, host: host))
				}
				try? await Task.sleep(for: interval)
			}
		}
		let result: (Data, URLResponse)
		do { result = try await session.data(for: request, delegate: watch) }
		catch { sampler.cancel(); await sampler.value; throw error }
		// Stop sampling before the final count, so no sample can follow the later phases.
		sampler.cancel()
		await sampler.value
		if let response = result.1 as? HTTPURLResponse, (200..<300).contains(response.statusCode) {
			await progress(TransferProgress(phase: .receiving, receivedBytes: Int64(result.0.count), expectedBytes: Self.decodedLength(response), host: host))
		}
		return result
	}

	/// Encode identifiers as whole path components, so slash/percent/query characters stay opaque.
	public nonisolated func requestURL(components: [String], query: [String: String] = [:]) throws -> URL {
		guard var result = URLComponents(url: baseURL, resolvingAgainstBaseURL: false), ["https", "http"].contains(result.scheme), result.host != nil else { throw TransitAPIError.invalidURL }
		let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
		let encoded = try components.map { value in
			guard value != ".", value != "..", let escaped = value.addingPercentEncoding(withAllowedCharacters: allowed) else { throw TransitAPIError.invalidURL }
			return escaped
		}
		let prefix = result.percentEncodedPath.hasSuffix("/") ? result.percentEncodedPath : result.percentEncodedPath + "/"
		result.percentEncodedPath = prefix + encoded.joined(separator: "/")
		result.queryItems = query.isEmpty ? nil : query.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
		// URLQueryItem permits '+', but server query parsers interpret it as a space.
		result.percentEncodedQuery = result.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
		result.fragment = nil
		guard let url = result.url else { throw TransitAPIError.invalidURL }
		return url
	}
}

/// Remembers the task a request runs on, so its received bytes can be sampled.
private final class TaskWatch: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
	private let lock = NSLock()
	private var task: URLSessionTask?
	func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) { lock.withLock { self.task = task } }
	/// Bytes of a successful response's body received so far, and its announced size.
	func receiving() -> (received: Int64, expected: Int64?)? {
		guard let task = lock.withLock({ self.task }), let response = task.response as? HTTPURLResponse,
			(200..<300).contains(response.statusCode) else { return nil }
		return (task.countOfBytesReceived, TransitAPI.decodedLength(response))
	}
}
