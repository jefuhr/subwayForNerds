import Foundation

/// Reviewed rail paths in top-left PDF points. An empty path set is intentionally unmapped.
/// The inherited SlowZone fields are flattened on the wire, as in shared/track-map.ts.
@dynamicMemberLookup
public struct TrackMapSlowZone: Codable, Sendable, Equatable, Identifiable {
	public var id: String
	public var routes: [String]
	public var paths: [[TrackMapPoint]]
	public var zone: SlowZone
	public subscript<Value>(dynamicMember keyPath: KeyPath<SlowZone, Value>) -> Value { zone[keyPath: keyPath] }

	public init(id: String, routes: [String], paths: [[TrackMapPoint]], zone: SlowZone) {
		self.id = id; self.routes = routes; self.paths = paths; self.zone = zone
	}
	private enum CodingKeys: String, CodingKey { case id, routes, paths }
	public init(from decoder: Decoder) throws {
		zone = try SlowZone(from: decoder)
		let container = try decoder.container(keyedBy: CodingKeys.self)
		id = try container.decode(String.self, forKey: .id)
		routes = try container.decode([String].self, forKey: .routes)
		paths = try container.decode([[TrackMapPoint]].self, forKey: .paths)
	}
	public func encode(to encoder: Encoder) throws {
		try zone.encode(to: encoder)
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(id, forKey: .id)
		try container.encode(routes, forKey: .routes)
		try container.encode(paths, forKey: .paths)
	}
}

public struct TrackMapSlowZones: Codable, Sendable, Equatable {
	public var dataThrough: String?
	public var expiresAt: TimeInterval?
	public var zones: [TrackMapSlowZone]
	public var unmappedCount: Int
	public init(dataThrough: String?, expiresAt: TimeInterval?, zones: [TrackMapSlowZone], unmappedCount: Int) {
		self.dataThrough = dataThrough; self.expiresAt = expiresAt; self.zones = zones; self.unmappedCount = unmappedCount
	}
}

public struct TrackMapSlowZoneState: Sendable, Equatable, Identifiable {
	public var zone: TrackMapSlowZone
	public var unplottedReason: String?
	public var id: String { zone.id }
	public var paths: [[TrackMapPoint]] { unplottedReason == nil ? zone.paths : [] }
	public var kindLabel: String { SlowZoneDisplay.isDisruption(zone.zone) ? "Estimated major slowdown" : "Estimated slow zone" }
	public var typicalDelay: String { "Typically +\(SlowZoneDisplay.seconds(zone.extraSeconds)) on a \(SlowZoneDisplay.seconds(zone.baselineSeconds)) run" }
	public var accessibilityLabel: String {
		[zone.segment, kindLabel, typicalDelay, "Source: Transit Lab", unplottedReason].compactMap { $0 }.joined(separator: ". ")
	}
}

public enum TrackMapSlowZoneStatus: Sendable, Equatable { case unavailable, expired, active }

public struct TrackMapSlowZonePresentation: Sendable, Equatable {
	public var status: TrackMapSlowZoneStatus
	public var zones: [TrackMapSlowZoneState]
	public var dataThrough: String?
	/// Server-wide coverage, not a route-filtered count.
	public var unmappedCount: Int
	public var cached: Bool
	public var highlightedPaths: [[TrackMapPoint]] { zones.flatMap(\.paths) }
}

public enum TrackMapSlowZonePresenter {
	/// Independent from train observation age, source health, animation and frozen time.
	/// Cached data expires against the actual device clock, including while offline.
	public static func state(_ accepted: TrackMapAcceptedSnapshot?, now: TimeInterval, routes: Set<String> = [], frozenAt: TimeInterval? = nil) -> TrackMapSlowZonePresentation {
		guard let accepted, let payload = accepted.snapshot.slowZones else {
			return TrackMapSlowZonePresentation(status: .unavailable, zones: [], dataThrough: nil, unmappedCount: 0, cached: false)
		}
		func empty(_ status: TrackMapSlowZoneStatus) -> TrackMapSlowZonePresentation {
			TrackMapSlowZonePresentation(status: status, zones: [], dataThrough: payload.dataThrough, unmappedCount: 0, cached: frozenAt != nil)
		}
		guard now.isFinite, let expiry = payload.expiresAt, expiry.isFinite, expiry > 0 else { return empty(.unavailable) }
		guard now < expiry else { return empty(.expired) }
		let zones = accepted.slowZones.filter { routes.isEmpty || !routes.isDisjoint(with: $0.routes) }.map {
			TrackMapSlowZoneState(zone: $0, unplottedReason: accepted.invalidSlowZoneGeometry[$0.id])
		}
		return TrackMapSlowZonePresentation(status: .active, zones: zones, dataThrough: payload.dataThrough, unmappedCount: max(0, payload.unmappedCount), cached: frozenAt != nil)
	}
}
