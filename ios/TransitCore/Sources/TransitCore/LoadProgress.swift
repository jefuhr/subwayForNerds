import Foundation

/// What a loading bar shows: how much of the work is done and a sentence naming the work in progress.
public struct LoadProgress: Sendable, Equatable {
	/// Share of the work done, or nil when nothing about it can be measured yet.
	public var fraction: Double?
	public var detail: String
	/// The fraction weighs several stages by estimate, so its percent is shown as approximate.
	public var estimated: Bool
	public init(fraction: Double?, detail: String, estimated: Bool = false) {
		self.fraction = fraction.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
		self.detail = detail
		self.estimated = estimated
	}
	/// Whole percent, rounded down so the bar never reads 100% before the work is done.
	public var percent: Int? { fraction.map { $0 >= 1 ? 100 : min(99, Int($0 * 100)) } }
	/// "42%", or "~42%" for an estimate.
	public var percentLabel: String? { percent.map { "\(estimated ? "~" : "")\($0)%" } }
	/// "42 percent", or "about 42 percent" for an estimate.
	public var spokenPercent: String? { percent.map { "\(estimated ? "about " : "")\($0) percent" } }

	/// Local work measured only in steps: `completed` of `count` steps are done and `detail` is the next one.
	public static func step(_ completed: Int, of count: Int, _ detail: String) -> LoadProgress {
		LoadProgress(fraction: Double(completed) / Double(max(1, count)), detail: "Step \(min(completed + 1, count)) of \(count) · \(detail)", estimated: true)
	}
}

/// How far one HTTP request has come, reported while it runs.
public struct TransferProgress: Sendable, Equatable {
	public enum Phase: Sendable, Equatable {
		/// Sending the request and waiting for the response headers.
		case requesting
		/// Receiving the body.
		case receiving
		/// The server confirmed the copy already in memory is current (HTTP 304).
		case validated
		/// Turning the received JSON into app data.
		case decoding
		case finished
	}
	public var phase: Phase
	public var receivedBytes: Int64
	/// The decoded body size the server announced, if any.
	public var expectedBytes: Int64?
	public var host: String
	public init(phase: Phase, receivedBytes: Int64 = 0, expectedBytes: Int64? = nil, host: String) {
		self.phase = phase; self.receivedBytes = receivedBytes; self.expectedBytes = expectedBytes; self.host = host
	}

	/// The share of the body received: exact bytes, never an estimate. Nil while receiving
	/// a body of unknown size; a body larger than announced stays at 1 rather than going back.
	public var fraction: Double? {
		switch phase {
		case .requesting: return 0
		case .receiving:
			guard let expectedBytes, expectedBytes > 0 else { return nil }
			return min(1, Double(receivedBytes) / Double(expectedBytes))
		case .validated, .decoding, .finished: return 1
		}
	}

	/// The bar for this request; `subject` names what is loading, such as "departures".
	public func load(_ subject: String) -> LoadProgress {
		let detail: String
		switch phase {
		case .requesting: detail = "Requesting \(subject) from \(host)…"
		case .receiving:
			if let expectedBytes, expectedBytes > 0 {
				detail = receivedBytes > expectedBytes
					? "Receiving \(subject) · \(Self.bytes(receivedBytes)) so far, more than the \(Self.bytes(expectedBytes)) announced"
					: "Receiving \(subject) · \(Self.bytes(receivedBytes)) of \(Self.bytes(expectedBytes))"
			} else { detail = "Receiving \(subject) · \(Self.bytes(receivedBytes)) so far" }
		case .validated: detail = "No changes since the last check · reusing the \(subject) already on this device"
		case .decoding: detail = "Decoding \(Self.bytes(receivedBytes)) of \(subject)…"
		case .finished: detail = "Loaded \(subject)"
		}
		return LoadProgress(fraction: fraction, detail: detail)
	}

	public static func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
}

public typealias TransferProgressHandler = @Sendable (TransferProgress) async -> Void

/// Server-side build progress of a preparing fleet pack. Counts are exact within a stage;
/// the overall fraction weighs stages by their estimated share of build time.
public struct FleetPackBuildProgress: Codable, Sendable, Equatable {
	public var stage: String
	public var label: String
	public var step: Int
	public var steps: Int
	public var done: Int
	public var total: Int
	public var fraction: Double
	public init(stage: String, label: String, step: Int, steps: Int, done: Int, total: Int, fraction: Double) {
		self.stage = stage; self.label = label; self.step = step; self.steps = steps; self.done = done; self.total = total; self.fraction = fraction
	}

	public var load: LoadProgress {
		let counts = total > 0 ? " · \(min(done, total).formatted()) of \(total.formatted())" : ""
		return LoadProgress(fraction: fraction, detail: "Step \(step) of \(steps) · \(label)\(counts)", estimated: true)
	}
}
