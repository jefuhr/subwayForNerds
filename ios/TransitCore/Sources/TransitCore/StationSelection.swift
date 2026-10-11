import Foundation

public struct StationSelection: Codable, Sendable, Equatable {
	public enum Mode: String, Codable, Sendable, CaseIterable, Identifiable {
		case favorite, closest, nearbyFavorite
		public var id: String { rawValue }
		public var title: String {
			switch self { case .favorite: "Closest favorite"; case .closest: "Closest station"; case .nearbyFavorite: "Favorite within radius" }
		}
	}
	public var mode: Mode = .favorite
	public var radiusFeet: Int = 5280
	public init(mode: Mode = .favorite, radiusFeet: Int = 5280) { self.mode = mode; self.radiusFeet = radiusFeet }
	public func includesFavorite(distanceMeters: Double) -> Bool { distanceMeters < Double(radiusFeet) * 0.3048 }
	public func select(stations: [Station], favorites: [String], location: WidgetCoordinate?, previous: String? = nil, now: TimeInterval = Date().timeIntervalSince1970) -> Station? {
		let favoriteStations = favorites.compactMap { id in stations.first { $0.id == id } }
		let candidates = mode == .favorite ? favoriteStations : stations
		guard !candidates.isEmpty else { return nil }
		let fallback = candidates.first { $0.id == previous } ?? favoriteStations.first ?? candidates.first
		guard let location, location.isUsable(now: now) else { return fallback }
		func nearest(_ options: [Station]) -> (station: Station, distance: Double)? {
			options.map { (station: $0, distance: location.distanceMeters(to: $0)) }.filter { $0.distance.isFinite }.min {
				$0.distance == $1.distance ? $0.station.id < $1.station.id : $0.distance < $1.distance
			}
		}
		if mode == .nearbyFavorite, let favorite = nearest(favoriteStations), includesFavorite(distanceMeters: favorite.distance) { return favorite.station }
		return nearest(candidates)?.station ?? fallback
	}
}
public struct WidgetStationSelection: Codable, Sendable, Equatable {
	public var followApp = true
	public var selection = StationSelection()
	public init() {}
}
