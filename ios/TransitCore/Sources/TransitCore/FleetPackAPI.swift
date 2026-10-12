import Foundation

public enum FleetPackAPIError: LocalizedError, Sendable, Equatable {
	case busy, unavailable, expired, invalidSelection, invalidResponse
	case httpStatus(Int)
	public var errorDescription: String? {
		switch self {
		case .busy: return "Another fleet pack is being prepared. Try again in a moment. Your saved fleet is still available."
		case .unavailable: return "Fleet packs are temporarily unavailable. Your saved fleet is still available."
		case .expired: return "This fleet pack expired. Prepare a fresh pack to download. Your saved fleet is still available."
		case .invalidSelection: return "Choose exact car types and yards, with 7 or 30 days of history."
		case .invalidResponse: return "The fleet pack information is incomplete or incompatible. Please try preparing it again."
		case .httpStatus: return "Could not prepare the fleet pack. Please try again. Your saved fleet is still available."
		}
	}
}

/// Separate from the cached transit feed: preparing a pack is an explicit user action.
public actor FleetPackAPI {
	public let baseURL: URL
	private let session: URLSession
	public init(baseURL: URL = TransitAPI.productionBaseURL, session: URLSession = .shared) {
		self.baseURL = baseURL; self.session = session
	}

	public func prepare(selection: FleetPackSelection) async throws -> FleetPackJob {
		guard selection.isValid else { throw FleetPackAPIError.invalidSelection }
		return try await request(jobID: nil, selection: selection)
	}

	public func status(jobID: String) async throws -> FleetPackJob {
		guard !jobID.isEmpty, jobID.utf8.count <= 256 else { throw FleetPackAPIError.invalidResponse }
		return try await request(jobID: jobID, selection: nil)
	}

	private func request(jobID: String?, selection: FleetPackSelection?) async throws -> FleetPackJob {
		let components = ["fleet", "offline", "v2", "packs"] + (jobID.map { [$0] } ?? [])
		let url = try TransitAPI(baseURL: baseURL).requestURL(components: components)
		guard url.user == nil, url.password == nil else { throw TransitAPIError.invalidURL }
		var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
		request.setValue("application/json", forHTTPHeaderField: "Accept")
		if let selection {
			request.httpMethod = "POST"
			request.setValue("application/json", forHTTPHeaderField: "Content-Type")
			request.httpBody = try JSONEncoder().encode(selection)
		}
		let (bytes, response) = try await session.bytes(for: request, delegate: PackRedirectGuard(origin: baseURL))
		guard let response = response as? HTTPURLResponse, let responseURL = response.url,
			PackRedirectGuard.sameOrigin(responseURL, baseURL) else { throw FleetPackAPIError.invalidResponse }
		switch response.statusCode {
		case 200, 202: break
		case 404: throw FleetPackAPIError.expired
		case 429: throw FleetPackAPIError.busy
		case 503: throw FleetPackAPIError.unavailable
		default: throw FleetPackAPIError.httpStatus(response.statusCode)
		}
		var data = Data()
		for try await byte in bytes {
			guard data.count < 1_048_576 else { throw FleetPackAPIError.invalidResponse }
			data.append(byte)
		}
		try Task.checkCancellation()
		guard let job = try? JSONDecoder().decode(FleetPackJob.self, from: data),
			!job.jobId.isEmpty, job.jobId.utf8.count <= 256, jobID == nil || jobID == job.jobId,
			(response.statusCode == 202 && job.state == .preparing && job.manifest == nil) ||
			(response.statusCode == 200 && job.state == .ready && job.manifest?.isValid == true) else {
			throw FleetPackAPIError.invalidResponse
		}
		return job
	}
}

private final class PackRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
	let origin: URL
	init(origin: URL) { self.origin = origin }
	static func sameOrigin(_ url: URL, _ origin: URL) -> Bool {
		url.scheme == origin.scheme && url.host == origin.host && url.port == origin.port && url.user == nil && url.password == nil
	}
	func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
		completionHandler(request.url.map { Self.sameOrigin($0, origin) } == true ? request : nil)
	}
}
