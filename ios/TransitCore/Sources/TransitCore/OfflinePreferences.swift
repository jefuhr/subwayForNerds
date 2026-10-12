import Foundation

/// Portable offline caching preferences. JSON keys are frozen and shared with
/// shared/settings.ts; cached content and the active ride never sync.
public struct OfflinePreferences: Codable, Sendable, Equatable {
	public static let departuresRange = 1...20
	public static let tripDetailsRange = 0...20
	public static let nearbyRadiusRange = 0...26400
	public static let estimateLimitChoices = [5, 15, 30, 60, 120]
	public static let retentionChoices = [1, 6, 12, 24]
	public static let storageLimitChoices = [25, 50, 100, 250]

	/// Departures retained for each route and direction on a cached board.
	public var departuresPerLineDirection = 5
	/// Full next trip snapshots for each route and direction (0...20). Validated on its
	/// own so synced edits never strand each other; use `effectiveTripDetailsPerLineDirection`.
	public var tripDetailsPerLineDirection = 2
	/// Automatically cache trips the user opens.
	public var saveOpenedTrips = true
	/// Surrounding boards are cached by distance from the viewed station, never GPS. 0 disables.
	public var nearbyRadiusFeet = 2640
	/// Also snapshot trips for surrounding (not selected) stations.
	public var preloadOtherStationTrips = false
	/// Cached predictions count down only while their source is at most this old.
	public var estimateLimitMinutes = 30
	/// Automatic entries expire after this many hours. Saved trips and the active ride never expire.
	public var retentionHours = 6
	/// Automatic entries are evicted, least recently used first, above this size.
	public var storageLimitMiB = 50
	public var widgetsFollowActiveRide = false

	public init(departuresPerLineDirection: Int = 5, tripDetailsPerLineDirection: Int = 2, saveOpenedTrips: Bool = true, nearbyRadiusFeet: Int = 2640, preloadOtherStationTrips: Bool = false, estimateLimitMinutes: Int = 30, retentionHours: Int = 6, storageLimitMiB: Int = 50, widgetsFollowActiveRide: Bool = false) {
		self.departuresPerLineDirection = departuresPerLineDirection
		self.tripDetailsPerLineDirection = tripDetailsPerLineDirection
		self.saveOpenedTrips = saveOpenedTrips
		self.nearbyRadiusFeet = nearbyRadiusFeet
		self.preloadOtherStationTrips = preloadOtherStationTrips
		self.estimateLimitMinutes = estimateLimitMinutes
		self.retentionHours = retentionHours
		self.storageLimitMiB = storageLimitMiB
		self.widgetsFollowActiveRide = widgetsFollowActiveRide
	}

	public static let keys: Set<String> = ["departuresPerLineDirection", "tripDetailsPerLineDirection", "saveOpenedTrips", "nearbyRadiusFeet", "preloadOtherStationTrips", "estimateLimitMinutes", "retentionHours", "storageLimitMiB", "widgetsFollowActiveRide"]
	private enum CodingKeys: String, CodingKey { case departuresPerLineDirection, tripDetailsPerLineDirection, saveOpenedTrips, nearbyRadiusFeet, preloadOtherStationTrips, estimateLimitMinutes, retentionHours, storageLimitMiB, widgetsFollowActiveRide }
	private struct AnyKey: CodingKey {
		let stringValue: String
		var intValue: Int? { nil }
		init?(stringValue: String) { self.stringValue = stringValue }
		init?(intValue: Int) { return nil }
	}

	public init(from decoder: Decoder) throws {
		guard Set(try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue)) == Self.keys else { throw SettingsError.invalid }
		let values = try decoder.container(keyedBy: CodingKeys.self)
		departuresPerLineDirection = try values.decode(Int.self, forKey: .departuresPerLineDirection)
		tripDetailsPerLineDirection = try values.decode(Int.self, forKey: .tripDetailsPerLineDirection)
		saveOpenedTrips = try values.decode(Bool.self, forKey: .saveOpenedTrips)
		nearbyRadiusFeet = try values.decode(Int.self, forKey: .nearbyRadiusFeet)
		preloadOtherStationTrips = try values.decode(Bool.self, forKey: .preloadOtherStationTrips)
		estimateLimitMinutes = try values.decode(Int.self, forKey: .estimateLimitMinutes)
		retentionHours = try values.decode(Int.self, forKey: .retentionHours)
		storageLimitMiB = try values.decode(Int.self, forKey: .storageLimitMiB)
		widgetsFollowActiveRide = try values.decode(Bool.self, forKey: .widgetsFollowActiveRide)
		guard isValid else { throw SettingsError.invalid }
	}

	public var isValid: Bool {
		Self.departuresRange.contains(departuresPerLineDirection)
			&& Self.tripDetailsRange.contains(tripDetailsPerLineDirection)
			&& Self.nearbyRadiusRange.contains(nearbyRadiusFeet)
			&& Self.estimateLimitChoices.contains(estimateLimitMinutes)
			&& Self.retentionChoices.contains(retentionHours)
			&& Self.storageLimitChoices.contains(storageLimitMiB)
	}

	public func validated() throws -> OfflinePreferences {
		guard isValid else { throw SettingsError.invalid }
		return self
	}

	public var effectiveTripDetailsPerLineDirection: Int { min(tripDetailsPerLineDirection, departuresPerLineDirection) }
	public var estimateLimit: TimeInterval { TimeInterval(estimateLimitMinutes * 60) }
	public var retention: TimeInterval { TimeInterval(retentionHours * 3600) }
	public var storageLimitBytes: Int { storageLimitMiB * 1_048_576 }
	public var nearbyRadiusMeters: Double { Double(nearbyRadiusFeet) * 0.3048 }
}
