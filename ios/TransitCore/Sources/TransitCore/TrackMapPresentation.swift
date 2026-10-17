import Foundation

public struct TrackMapEvidenceDeadlines: Sendable, Equatable {
	public var staleAt: TimeInterval
	public var expiresAt: TimeInterval
}

/// What the client knows beyond the snapshot when it draws trains.
public struct TrackMapConditions: Sendable, Equatable {
	public var now: TimeInterval
	/// False with Reduce Motion: estimates show where the server placed them and do not move.
	public var animationAllowed: Bool
	/// Set while offline or after a failed poll: estimates hold where they were at this time.
	public var frozenAt: TimeInterval?
	public init(now: TimeInterval, animationAllowed: Bool = true, frozenAt: TimeInterval? = nil) {
		self.now = now; self.animationAllowed = animationAllowed; self.frozenAt = frozenAt
	}
}

/// How sure the feed is about which track the train uses.
public enum TrackMapTrackCertainty: Sendable, Equatable {
	case reported(String?)
	case scheduled(String?)
	case inferred(String?)
	case unknown

	public init(basis: TrackMapTrackBasis, code: String?) {
		let code = code.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
		switch basis {
		case .reported: self = .reported(code)
		case .scheduled: self = .scheduled(code)
		case .inferred: self = .inferred(code)
		case .unknown: self = .unknown
		}
	}

	public var label: String {
		func track(_ code: String?, _ basis: String) -> String { code.map { "Track \($0) \(basis)" } ?? "Track \(basis)" }
		switch self {
		case .reported(let code): return track(code, "reported")
		case .scheduled(let code): return track(code, "scheduled")
		case .inferred(let code): return track(code, "inferred")
		case .unknown: return "Track unknown"
		}
	}
}

/// How sure the map is about where along the track the train is.
public enum TrackMapPositionCertainty: Sendable, Equatable {
	case reported, estimated, nearStop, unknown

	public init(basis: TrackMapPositionBasis, placement: TrackMapPlacement) {
		switch (placement, basis) {
		case (.nearStop, _): self = .nearStop
		case (.unplaced, _), (.track, .unknown): self = .unknown
		case (.track, .reported): self = .reported
		case (.track, .estimated): self = .estimated
		}
	}

	public var label: String {
		switch self {
		case .reported: return "Position reported"
		case .estimated: return "Position estimated"
		case .nearStop: return "Near stop, exact position unknown"
		case .unknown: return "Position unknown"
		}
	}
}

/// One train as the map should draw and describe it right now.
public struct TrackMapTrainState: Sendable, Equatable, Identifiable {
	public let train: TrackMapTrain
	/// Nil when the train must not be plotted; `unplottedReason` says why.
	public let point: TrackMapPoint?
	public let heading: Double?
	public let freshness: TrackMapFreshness
	public let animating: Bool
	public let unplottedReason: String?
	public let trackCertainty: TrackMapTrackCertainty
	public let positionCertainty: TrackMapPositionCertainty
	public var id: String { train.key }
	public var isPlotted: Bool { point != nil }
	public var isUncertain: Bool { positionCertainty != .reported }

	public var accessibilityLabel: String {
		var parts = ["Line \(Display.displayRoute(train.route)) to \(train.destination)"]
		let direction = Display.directionLabel(train.direction)
		if direction != "Direction unknown" { parts.append(direction) }
		parts.append(trackCertainty.label)
		parts.append(isPlotted ? positionCertainty.label : "Not on map")
		if isPlotted && freshness != .live { parts.append("Stale") }
		return parts.joined(separator: ". ")
	}
}

public enum TrackMapPresenter {
	/// Deadlines from the oldest of the observation, the feed header and the source's last
	/// success, never later than the server's own. Nil when any of those clocks is missing,
	/// so a train with unknown evidence age is never plotted.
	public static func evidenceDeadlines(_ train: TrackMapTrain, sources: [SourceState]) -> TrackMapEvidenceDeadlines? {
		func valid(_ value: TimeInterval?) -> TimeInterval? { value.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } }
		guard let observedAt = valid(train.observedAt), let header = valid(train.feedTimestamp),
			let source = valid(sources.first(where: { $0.id == train.feed })?.timestamp),
			let serverStale = valid(train.staleAt), let serverExpiry = valid(train.expiresAt) else { return nil }
		let evidence = min(observedAt, header, source)
		let expiresAt = min(serverExpiry, evidence + TrackMapContract.expirySeconds)
		return TrackMapEvidenceDeadlines(staleAt: min(serverStale, evidence + TrackMapContract.liveSeconds, expiresAt), expiresAt: expiresAt)
	}

	public static func effectiveExpiry(_ train: TrackMapTrain, sources: [SourceState]) -> TimeInterval? { evidenceDeadlines(train, sources: sources)?.expiresAt }

	public static func state(for train: TrackMapTrain, in accepted: TrackMapAcceptedSnapshot, conditions: TrackMapConditions) -> TrackMapTrainState {
		let track = TrackMapTrackCertainty(basis: train.trackBasis, code: train.trackCode)
		let position = TrackMapPositionCertainty(basis: train.positionBasis, placement: train.placement)
		func hidden(_ reason: String) -> TrackMapTrainState {
			TrackMapTrainState(train: train, point: nil, heading: nil, freshness: .unavailable, animating: false, unplottedReason: reason, trackCertainty: track, positionCertainty: position)
		}
		let now = conditions.now, generatedAt = accepted.snapshot.generatedAt
		if let problem = accepted.invalidGeometry[train.key] { return hidden(problem) }
		guard TrackMapRoutes.isMapRoute(train.route) else { return hidden("Not a subway route on this map") }
		guard train.freshness != .unavailable, train.placement != .unplaced else { return hidden(train.reason ?? "No reliable position") }
		guard now.isFinite else { return hidden("Device clock unavailable") }
		guard let observedAt = train.observedAt, observedAt.isFinite else { return hidden("No observation time") }
		guard observedAt <= generatedAt + TrackMapContract.futureTolerance else { return hidden("Observation time is in the future") }
		guard let deadlines = evidenceDeadlines(train, sources: accepted.snapshot.sources) else { return hidden("Position evidence time is unknown") }
		guard now < deadlines.expiresAt else { return hidden("Position evidence expired") }
		// Every original clock must also be behind this device's clock, within the tolerance.
		let sourceTime = accepted.source(for: train)?.timestamp ?? .infinity
		guard [observedAt, train.feedTimestamp, sourceTime].allSatisfy({ $0 <= now + TrackMapContract.futureTolerance }) else { return hidden("Evidence time is ahead of this device") }

		let sourceFailed = accepted.source(for: train)?.error != nil
		// An outage makes every held marker stale at once; expiry still follows the evidence.
		let live = train.freshness == .live && !sourceFailed && conditions.frozenAt == nil && now < deadlines.staleAt
		// The server holds a failed or stale source in place; the client never advances it.
		var sampleTime: TimeInterval
		if sourceFailed || train.freshness != .live { sampleTime = generatedAt }
		else if let frozenAt = conditions.frozenAt { sampleTime = frozenAt }
		else if !conditions.animationAllowed { sampleTime = generatedAt }
		else { sampleTime = now }
		sampleTime = min(sampleTime, deadlines.staleAt)

		let held = sourceFailed || train.freshness != .live
		let point: TrackMapPoint, heading: Double?, animating: Bool
		if held, let fixed = train.point {
			// The server's sampled point stays exactly where it is; only its heading comes from the path.
			point = fixed
			heading = train.motion.map { TrackMapPolyline($0.points).sample(TrackMapMotionMath.progress($0, at: sampleTime)).heading } ?? accepted.stoppedHeadings[train.key]
			animating = false
		} else if let motion = train.motion {
			let sample = TrackMapPolyline(motion.points).sample(TrackMapMotionMath.progress(motion, at: sampleTime))
			point = sample.point
			heading = sample.heading
			animating = live && conditions.animationAllowed && now < motion.endTime && motion.fromProgress != motion.toProgress
		} else if let fixed = train.point {
			point = fixed; heading = accepted.stoppedHeadings[train.key]; animating = false
		} else {
			return hidden(train.reason ?? "No map position")
		}
		return TrackMapTrainState(train: train, point: point, heading: heading, freshness: live ? .live : .stale, animating: animating, unplottedReason: nil, trackCertainty: track, positionCertainty: position)
	}

	/// Subway trains in server order, limited to `routes` when any are chosen.
	public static func states(_ accepted: TrackMapAcceptedSnapshot, conditions: TrackMapConditions, routes: Set<String> = []) -> [TrackMapTrainState] {
		accepted.trains
			.filter { TrackMapRoutes.isMapRoute($0.route) && (routes.isEmpty || routes.contains($0.route)) }
			.map { state(for: $0, in: accepted, conditions: conditions) }
	}
}

/// Full-time and part-time subway routes and shuttles drawn on the track map.
/// Staten Island Railway, PATH and regional rail are not.
public enum TrackMapRoutes {
	public static let order = ["1", "2", "3", "4", "5", "6", "6X", "7", "7X", "A", "C", "E", "B", "D", "F", "FX", "M", "G", "J", "Z", "L", "N", "Q", "R", "W", "GS", "FS", "H"]
	private static let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })

	public static func isMapRoute(_ route: String) -> Bool { rank[route] != nil }

	public static func routes(in accepted: TrackMapAcceptedSnapshot, now: TimeInterval = Date().timeIntervalSince1970) -> [String] {
		let zones = TrackMapSlowZonePresenter.state(accepted, now: now).zones.flatMap { $0.zone.routes }
		return Set((accepted.trains.map(\.route) + zones).filter(isMapRoute)).sorted { rank[$0]! < rank[$1]! }
	}

	/// The same colors as the app's route bullets.
	public static func color(_ route: String) -> UInt32 {
		switch route {
		case "1", "2", "3": 0xEE352E
		case "4", "5", "6", "6X": 0x00933C
		case "7", "7X": 0xB933AD
		case "A", "C", "E": 0x0039A6
		case "B", "D", "F", "FX", "M": 0xFF6319
		case "N", "Q", "R", "W": 0xFCCC0A
		case "G": 0x6CBE45
		case "J", "Z": 0x996633
		default: 0x62666B
		}
	}

	public static func darkInk(_ route: String) -> Bool { ["N", "Q", "R", "W", "G", "B", "D", "F", "FX", "M"].contains(route) }
}

/// How often the map overlay redraws: per frame only while a train in view is moving,
/// once a second to fade and expire held trains, and never while hidden or in the background.
public enum TrackMapRenderClock: Sendable, Equatable {
	case stopped, seconds, frames

	public static func mode(visible: Bool, foreground: Bool, hasSnapshot: Bool, animating: Bool, reduceMotion: Bool) -> TrackMapRenderClock {
		guard visible, foreground, hasSnapshot else { return .stopped }
		return animating && !reduceMotion ? .frames : .seconds
	}
}
