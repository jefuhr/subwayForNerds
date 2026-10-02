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
	public static let productionBaseURL = URL(string: "https://juliet.nyc/subwaysForNerds/api/v1/")!
	public let baseURL: URL
	private let session: URLSession
	private struct CachedResponse { let data: Data; let etag: String }
	private var responses: [URL: CachedResponse] = [:]

	public init(baseURL: URL = TransitAPI.productionBaseURL, session: URLSession = .shared) {
		self.baseURL = baseURL
		self.session = session
	}

	public func stations() async throws -> [Station] { try await get(["stations"]) }
	public func board(stationID: String) async throws -> Board { try await get(["stations", stationID, "board"]) }
	public func trip(key: String) async throws -> TripDetail { try await get(["trips"], query: ["key": key]) }
	public func transfers(key: String, stopID: String, sequence: Int? = nil) async throws -> TransferResult {
		var query = ["key": key, "stopId": stopID]
		if let sequence { query["sequence"] = String(sequence) }
		return try await get(["trips", "transfers"], query: query)
	}
	public func context(stationID: String) async throws -> StationContext { try await get(["stations", stationID, "context"]) }
	public func fleet(query: [String: String] = [:]) async throws -> FleetPage { try await get(["fleet"], query: query) }
	public func fleetDetail(kind: String, id: String) async throws -> FleetDetail { try await get(["fleet", kind, id]) }
	public func offlineManifest() async throws -> FleetOfflineManifest { try await get(["fleet", "offline", "manifest"]) }
	public func clearResponseCache() { responses.removeAll() }

	private func get<T: Decodable & Sendable>(_ components: [String], query: [String: String] = [:]) async throws -> T {
		let url = try requestURL(components: components, query: query)
		var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
		request.setValue("application/json", forHTTPHeaderField: "Accept")
		let cached = responses[url]
		if let cached { request.setValue(cached.etag, forHTTPHeaderField: "If-None-Match") }
		let (data, response) = try await session.data(for: request)
		guard let response = response as? HTTPURLResponse else { throw TransitAPIError.invalidResponse }
		let payload: Data
		switch response.statusCode {
		case 304:
			guard let cached else { throw TransitAPIError.unexpectedNotModified }
			payload = cached.data
		case 200..<300: payload = data
		case 404: throw TransitAPIError.notFound
		default: throw TransitAPIError.httpStatus(response.statusCode)
		}
		let decoded = try JSONDecoder().decode(T.self, from: payload)
		if response.statusCode != 304 {
			if let etag = response.value(forHTTPHeaderField: "ETag") { responses[url] = CachedResponse(data: data, etag: etag) }
			else { responses.removeValue(forKey: url) }
			// Search and trip URLs can grow indefinitely in a long-running session.
			if responses.count > 128, let evicted = responses.keys.first(where: { $0 != url }) { responses.removeValue(forKey: evicted) }
		}
		return decoded
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
