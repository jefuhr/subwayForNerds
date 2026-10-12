import Foundation

/// A compact, coordinated projection; the extension never opens the app cache index.
public struct WidgetRideSnapshot: Codable, Sendable, Equatable {
	public var ride: ActiveRide
	public var trip: CachedTrip
	public init(ride: ActiveRide, trip: CachedTrip) {
		self.ride = ride
		self.trip = trip
		self.trip.detail?.raw = nil
		self.trip.detail?.source = nil
	}
	public func nextStop(now: TimeInterval) -> StopPrediction? {
		guard !["CANCELED", "DELETED", "NO_DATA"].contains(trip.train?.relationship ?? ""), trip.train?.assigned != false,
			let index = OfflineDisplay.estimatedNextStopIndex(trip.stops, now: now) else { return nil }
		return trip.stops[index]
	}
	public func timelineBoard() -> Board {
		let train = trip.train
		let station = Station(id: ride.boardingStationID ?? "ride", name: train?.destination ?? "Your ride", borough: "", routes: train.map { [$0.route] } ?? [], lat: 0, lon: 0)
		let rows = trip.stops.enumerated().map { index, stop in
			Departure(key: "\(trip.tripKey)|\(index)", tripKey: trip.tripKey, route: train?.route ?? "", destination: stop.name,
				direction: train?.direction ?? "UNKNOWN", stopId: stop.id, partId: stop.stationId ?? "", area: "", time: stop.arrival ?? stop.departure,
				pattern: "", patternSource: "static", location: "", feed: train?.feed ?? "", timestamp: trip.sourceTimestamp ?? 0, relationship: stop.relationship, staleAfter: train?.staleAfter, vehiclePosition: train?.vehiclePosition)
		}
		return Board(station: station, generatedAt: trip.savedAt, departures: rows)
	}
}
