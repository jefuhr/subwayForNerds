import Foundation

/// A trip snapshot identified by endpoint plus the opaque server trip key.
/// `detail` is the normalized trip response (including raw feed data when the
/// server sent it). Without a detail, `departure` holds the board's onward stops
/// and the snapshot is partial: callers must label it as such.
public struct CachedTrip: Codable, Sendable, Equatable, Identifiable {
	public var tripKey: String
	public var endpoint: String
	public var detail: TripDetail?
	public var departure: Departure?
	/// When the current source snapshot was stored. Unchanged responses never move it.
	public var savedAt: TimeInterval
	public var accessedAt: TimeInterval
	/// Saved with "Save trip offline". Kept until explicitly removed.
	public var manuallySaved: Bool
	/// The board's station for a partial trip's boarding stop. `Departure.location`
	/// describes the train's reported position and never names a stop.
	public var boardingStationID: String?
	public var boardingStationName: String?

	public init(tripKey: String, endpoint: String, detail: TripDetail? = nil, departure: Departure? = nil, savedAt: TimeInterval, accessedAt: TimeInterval, manuallySaved: Bool = false, boardingStationID: String? = nil, boardingStationName: String? = nil) {
		self.tripKey = tripKey
		self.endpoint = endpoint
		self.detail = detail
		self.departure = departure
		self.savedAt = savedAt
		self.accessedAt = accessedAt
		self.manuallySaved = manuallySaved
		self.boardingStationID = boardingStationID
		self.boardingStationName = boardingStationName
	}

	public static let boardingStopFallbackName = "Boarding stop"

	public var id: String { OfflineIdentity.trip(endpoint: endpoint, tripKey: tripKey) }
	public var isComplete: Bool { detail != nil }

	/// The full trip, or a partial trip assembled only from the board departure.
	/// A partial trip has no observed position and no invented stops.
	public var train: Train? {
		if let detail { return detail.train }
		guard let departure else { return nil }
		return Train(changes: departure.changes, key: tripKey, feed: departure.feed, tripId: tripKey, route: departure.route, destination: departure.destination, direction: departure.direction, assigned: departure.assigned, timestamp: departure.timestamp, position: nil, stops: stops, relationship: departure.relationship, alerts: departure.alerts, consist: departure.consist, scheduledPattern: nil)
	}

	public var stops: [StopPrediction] {
		if let detail { return detail.train.stops }
		guard let departure else { return [] }
		let boarding = StopPrediction(id: departure.stopId, name: boardingStationName ?? Self.boardingStopFallbackName, stationId: boardingStationID, arrival: departure.arrival, departure: departure.departure ?? departure.time, scheduledTrack: departure.scheduledTrack, actualTrack: departure.actualTrack, relationship: departure.relationship)
		let onward = departure.onward.map { StopPrediction(id: $0.stopId, name: $0.name, stationId: $0.stationId, arrival: $0.time) }
		return onward.first?.id == departure.stopId ? onward : [boarding] + onward
	}

	/// The feed time the predictions came from. Never the save or fetch time.
	public var sourceTimestamp: TimeInterval? {
		let value = detail?.train.timestamp ?? departure?.timestamp
		guard let value, value > 0 else { return nil }
		return value
	}
}

/// "I'm on this train": at most one per endpoint, protected from eviction and
/// restored across relaunch. Never synced.
public struct ActiveRide: Codable, Sendable, Equatable {
	public var tripKey: String
	public var boardingStationID: String?
	public var startedAt: TimeInterval

	public init(tripKey: String, boardingStationID: String? = nil, startedAt: TimeInterval) {
		self.tripKey = tripKey
		self.boardingStationID = boardingStationID
		self.startedAt = startedAt
	}
}

/// A board snapshot. `viewedStationID` is the station whose view caused a
/// surrounding board to be cached; it is nil for the viewed station itself.
public struct CachedBoard: Codable, Sendable, Equatable, Identifiable {
	public var endpoint: String
	public var board: Board
	public var savedAt: TimeInterval
	public var accessedAt: TimeInterval
	public var viewedStationID: String?
	public var distanceMeters: Double?

	public init(endpoint: String, board: Board, savedAt: TimeInterval, accessedAt: TimeInterval, viewedStationID: String? = nil, distanceMeters: Double? = nil) {
		self.endpoint = endpoint
		self.board = board
		self.savedAt = savedAt
		self.accessedAt = accessedAt
		self.viewedStationID = viewedStationID
		self.distanceMeters = distanceMeters
	}

	public var id: String { OfflineIdentity.board(endpoint: endpoint, stationID: board.station.id) }
	public var stationID: String { board.station.id }
	public var sourceTimestamp: TimeInterval? { OfflineIdentity.boardSourceTimestamp(board) }
}

public enum OfflineSaveResult: String, Codable, Sendable, Equatable {
	/// A newer source snapshot replaced the previous one (or none existed).
	case stored
	/// The response carried the same or older source data; the snapshot and its source time were kept.
	case unchanged
}

/// A save that could not be written. Surfaced instead of silently dropped.
public struct OfflineSaveFailure: Codable, Sendable, Equatable, Identifiable {
	public enum Kind: String, Codable, Sendable { case board, trip, activeRide, savedTrip, eviction, migration }
	public var kind: Kind
	public var identity: String
	public var message: String
	public var failedAt: TimeInterval
	public var id: String { "\(kind.rawValue):\(identity)" }

	public init(kind: Kind, identity: String, message: String, failedAt: TimeInterval) {
		self.kind = kind
		self.identity = identity
		self.message = message
		self.failedAt = failedAt
	}
}

public struct OfflineStorageUsage: Sendable, Equatable {
	public var totalBytes: Int
	public var protectedBytes: Int
	public var boardCount: Int
	public var tripCount: Int
	public var savedTripCount: Int
	/// Protected entries alone can exceed the limit; they are never evicted for space.
	public var overLimit: Bool

	public init(totalBytes: Int, protectedBytes: Int, boardCount: Int, tripCount: Int, savedTripCount: Int, overLimit: Bool) {
		self.totalBytes = totalBytes
		self.protectedBytes = protectedBytes
		self.boardCount = boardCount
		self.tripCount = tripCount
		self.savedTripCount = savedTripCount
		self.overLimit = overLimit
	}
}

public struct OfflineEvictionReport: Sendable, Equatable {
	public var expiredTripKeys: [String] = []
	public var expiredStationIDs: [String] = []
	public var evictedTripKeys: [String] = []
	public var evictedStationIDs: [String] = []
	public init() {}
	public var isEmpty: Bool { expiredTripKeys.isEmpty && expiredStationIDs.isEmpty && evictedTripKeys.isEmpty && evictedStationIDs.isEmpty }
}

/// Cache partition for an API endpoint. The known production URLs share one
/// partition; every other origin (debug servers, fixtures) stays isolated. The raw
/// endpoint is still what callers use for networking.
public enum OfflineEndpoint {
	public static let productionKey = "production"
	public static let productionURLs = ["https://juliet.nyc/subwaysForNerds/api/v1/", "https://subwaysfornerds.juliet.nyc/api/v1/"]

	public static func key(_ endpoint: String) -> String {
		var text = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
		if !text.hasSuffix("/") { text += "/" }
		if var components = URLComponents(string: text), let scheme = components.scheme, let host = components.host {
			components.scheme = scheme.lowercased()
			components.host = host.lowercased()
			if let normalized = components.string, productionURLs.contains(normalized) { return productionKey }
		}
		return text
	}

	public static func key(_ url: URL) -> String { key(url.absoluteString) }
}

public enum OfflineIdentity {
	public static func trip(endpoint: String, tripKey: String) -> String { "trip\u{1f}" + OfflineEndpoint.key(endpoint) + "\u{1f}" + tripKey }
	public static func board(endpoint: String, stationID: String) -> String { "board\u{1f}" + OfflineEndpoint.key(endpoint) + "\u{1f}" + stationID }

	/// PATH trip keys name a station-arrival position, not a train journey: the same
	/// key can describe a different train on the next refresh.
	public static func isPositionalTrip(_ tripKey: String) -> Bool { tripKey.hasPrefix("path|") }

	/// Newest feed timestamp a board was built from. Missing source times fall back
	/// to departure timestamps; generatedAt is not source data and is never used.
	public static func boardSourceTimestamp(_ board: Board) -> TimeInterval? {
		let values = board.sources.compactMap(\.timestamp).filter { $0 > 0 } + board.departures.map(\.timestamp).filter { $0 > 0 }
		return values.max()
	}
}
