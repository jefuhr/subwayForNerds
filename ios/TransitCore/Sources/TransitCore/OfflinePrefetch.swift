import Foundation

public enum OfflineFetchTarget: Hashable, Sendable {
	case board(stationID: String)
	case trip(key: String)
}

/// Lower raw values run first.
public enum OfflineFetchPriority: Int, Comparable, Sendable {
	case explicit, activeRide, selected, background
	public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
	/// Minimum time between automatic fetches of the same identity.
	public var interval: TimeInterval { self == .background ? OfflineFetchQueue.backgroundInterval : OfflineFetchQueue.liveInterval }
}

public struct OfflineFetchRequest: Hashable, Sendable {
	public var endpoint: String
	public var target: OfflineFetchTarget
	public var priority: OfflineFetchPriority
	public init(endpoint: String, target: OfflineFetchTarget, priority: OfflineFetchPriority) {
		self.endpoint = endpoint
		self.target = target
		self.priority = priority
	}
	public struct Identity: Hashable, Sendable { public var endpoint: String; public var target: OfflineFetchTarget }
	public var identity: Identity { Identity(endpoint: endpoint, target: target) }
}

/// Deterministic scheduling for automatic board and trip fetches: at most three
/// in flight overall, one per identity, explicit and active-ride work first, the
/// selected board and ride every 10 s, surrounding prefetch no more than every
/// 30 s. Background work never takes the last slot, so hung surrounding fetches
/// cannot hold up explicit, ride or selected work. Everything pauses without a
/// connection or while the app is backgrounded, and reconnecting makes every
/// tracked identity due at once.
public struct OfflineFetchQueue: Sendable {
	public static let maxConcurrent = 3
	/// One slot stays free for priorities up to `.selected`.
	public static let maxBackgroundConcurrent = maxConcurrent - 1
	public static let liveInterval: TimeInterval = 10
	public static let backgroundInterval: TimeInterval = 30

	public private(set) var connected = true
	public private(set) var foreground = true
	public private(set) var inFlight: Set<OfflineFetchRequest.Identity> = []
	/// The in-flight identities that started as background work.
	private var backgroundInFlight: Set<OfflineFetchRequest.Identity> = []
	private var tracked: [OfflineFetchRequest] = []
	private var oneShots: [OfflineFetchRequest] = []
	private var lastStarted: [OfflineFetchRequest.Identity: TimeInterval] = [:]
	/// Start order, so "least recently started" is exact even within one clock tick.
	private var startSequence: [OfflineFetchRequest.Identity: Int] = [:]
	private var nextSequence = 0

	public init() {}

	public var isPaused: Bool { !connected || !foreground }
	public var trackedRequests: [OfflineFetchRequest] { tracked }

	public mutating func setConnected(_ value: Bool) {
		if value && !connected { lastStarted.removeAll() }
		connected = value
	}

	public mutating func setForeground(_ value: Bool) { foreground = value }

	/// Replaces the recurring set. Duplicate identities keep their highest priority.
	public mutating func track(_ requests: [OfflineFetchRequest]) {
		var result: [OfflineFetchRequest] = []
		for request in requests {
			if let index = result.firstIndex(where: { $0.identity == request.identity }) {
				result[index].priority = min(result[index].priority, request.priority)
			} else { result.append(request) }
		}
		tracked = result
		let identities = Set(result.map(\.identity)).union(oneShots.map(\.identity)).union(inFlight)
		lastStarted = lastStarted.filter { identities.contains($0.key) }
		startSequence = startSequence.filter { identities.contains($0.key) }
	}

	/// A one-time fetch that ignores the refresh interval. A request for an identity
	/// already in flight is satisfied by that fetch and is not queued again.
	public mutating func request(_ request: OfflineFetchRequest) {
		guard !inFlight.contains(request.identity) else { return }
		if let index = oneShots.firstIndex(where: { $0.identity == request.identity }) {
			oneShots[index].priority = min(oneShots[index].priority, request.priority)
		} else { oneShots.append(request) }
	}

	/// Starts as many due requests as capacity allows and marks them in flight.
	public mutating func next(now: TimeInterval) -> [OfflineFetchRequest] {
		guard !isPaused else { return [] }
		var started: [OfflineFetchRequest] = []
		for request in ready(now: now) {
			guard inFlight.count < Self.maxConcurrent else { break }
			guard !inFlight.contains(request.identity) else { continue }
			if request.priority == .background {
				guard backgroundInFlight.count < Self.maxBackgroundConcurrent else { continue }
				backgroundInFlight.insert(request.identity)
			}
			inFlight.insert(request.identity)
			lastStarted[request.identity] = now
			nextSequence += 1
			startSequence[request.identity] = nextSequence
			oneShots.removeAll { $0.identity == request.identity }
			started.append(request)
		}
		return started
	}

	/// Drops one-shot requests that have not started, returning their identities.
	public mutating func cancelPendingRequests() -> [OfflineFetchRequest.Identity] {
		defer { oneShots.removeAll() }
		return oneShots.map(\.identity)
	}

	/// Success or failure, the next automatic attempt waits a full interval.
	public mutating func finish(_ request: OfflineFetchRequest, now: TimeInterval) {
		inFlight.remove(request.identity)
		backgroundInFlight.remove(request.identity)
	}

	/// The earliest time another request could start, or nil when nothing is waiting.
	/// Background work held back only by its own cap is ignored: a finishing fetch
	/// pumps again, and counting it as due now would keep the caller from scheduling
	/// the next selected or ride refresh for the reserved slot.
	public func nextDue(now: TimeInterval) -> TimeInterval? {
		guard !isPaused else { return nil }
		let backgroundBlocked = backgroundInFlight.count >= Self.maxBackgroundConcurrent
		func eligible(_ request: OfflineFetchRequest) -> Bool {
			!inFlight.contains(request.identity) && !(backgroundBlocked && request.priority == .background)
		}
		if oneShots.contains(where: eligible) { return now }
		return tracked.filter(eligible).map { request in
			lastStarted[request.identity].map { $0 + request.priority.interval } ?? now
		}.min().map { max(now, $0) }
	}

	private func ready(now: TimeInterval) -> [OfflineFetchRequest] {
		let due = tracked.filter { request in
			guard let last = lastStarted[request.identity] else { return true }
			return now - last >= request.priority.interval
		}
		var merged: [(request: OfflineFetchRequest, oneShot: Bool)] = oneShots.map { ($0, true) }
		for request in due {
			if let index = merged.firstIndex(where: { $0.request.identity == request.identity }) {
				merged[index].request.priority = min(merged[index].request.priority, request.priority)
			} else { merged.append((request, false)) }
		}
		// Priority first, then one-time requests ahead of equal-priority recurring work.
		// Within a priority, identities never started go first, then the least recently
		// started, so a long surrounding list rotates instead of the first few stations
		// becoming due again before later ones are ever fetched. The caller's order
		// (for example nearest station first) breaks ties.
		return merged.enumerated().sorted { lhs, rhs in
			let left = lhs.element, right = rhs.element
			if left.request.priority != right.request.priority { return left.request.priority < right.request.priority }
			if left.oneShot != right.oneShot { return left.oneShot }
			let leftStarted = startSequence[left.request.identity] ?? 0, rightStarted = startSequence[right.request.identity] ?? 0
			if leftStarted != rightStarted { return leftStarted < rightStarted }
			return lhs.offset < rhs.offset
		}.map(\.element.request)
	}
}

public enum OfflineFetchOutcome: Sendable, Equatable {
	/// A fetch of this identity ran to completion (its own, or one it joined).
	case completed
	/// Not fetched: the app was offline or in the background before it could start.
	case paused
}

/// Drives an `OfflineFetchQueue` with real tasks. The fetch closure performs the
/// network call and the store save; it should return normally on failure too.
public actor OfflinePrefetcher {
	private var queue = OfflineFetchQueue()
	private let clock: @Sendable () -> TimeInterval
	private let fetch: @Sendable (OfflineFetchRequest) async -> Void
	private var wake: Task<Void, Never>?
	private var waiters: [OfflineFetchRequest.Identity: [CheckedContinuation<OfflineFetchOutcome, Never>]] = [:]

	public init(clock: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }, fetch: @escaping @Sendable (OfflineFetchRequest) async -> Void) {
		self.clock = clock
		self.fetch = fetch
	}

	public var state: OfflineFetchQueue { queue }

	public func track(_ requests: [OfflineFetchRequest]) { queue.track(requests); pump() }

	/// Fetches now, ahead of automatic work (within the three-fetch cap), and returns
	/// once a fetch of the same identity has finished. A matching fetch already in
	/// flight or queued is joined instead of repeated. Returns `.paused` at once when
	/// offline or backgrounded, or if that happens before the fetch starts.
	@discardableResult
	public func request(_ request: OfflineFetchRequest) async -> OfflineFetchOutcome {
		guard !queue.isPaused else { return .paused }
		queue.request(request)
		return await withCheckedContinuation { continuation in
			waiters[request.identity, default: []].append(continuation)
			pump()
		}
	}

	public func setConnected(_ value: Bool) { queue.setConnected(value); pausePendingIfNeeded(); pump() }
	public func setForeground(_ value: Bool) { queue.setForeground(value); pausePendingIfNeeded(); pump() }

	public func stop() {
		wake?.cancel(); wake = nil
		queue.track([]); queue.setForeground(false)
		pausePendingIfNeeded()
	}

	/// Requests that have not started resolve as paused; in-flight fetches finish normally.
	private func pausePendingIfNeeded() {
		guard queue.isPaused else { return }
		for identity in queue.cancelPendingRequests() where !queue.inFlight.contains(identity) {
			for waiter in waiters.removeValue(forKey: identity) ?? [] { waiter.resume(returning: .paused) }
		}
	}

	private func pump() {
		let now = clock()
		for request in queue.next(now: now) {
			Task { [fetch] in
				await fetch(request)
				self.finished(request)
			}
		}
		wake?.cancel()
		wake = nil
		guard let due = queue.nextDue(now: now), due > now else { return }
		let delay = due - now
		wake = Task { [weak self] in
			try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
			guard !Task.isCancelled else { return }
			await self?.pump()
		}
	}

	private func finished(_ request: OfflineFetchRequest) {
		queue.finish(request, now: clock())
		for waiter in waiters.removeValue(forKey: request.identity) ?? [] { waiter.resume(returning: .completed) }
		pump()
	}
}
