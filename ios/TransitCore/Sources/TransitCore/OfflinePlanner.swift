import Foundation

/// Decides what a board view caches. Surrounding stations are ranked by distance
/// from the viewed station, never from the device location.
public enum OfflinePlanner {
	public struct LineDirection: Hashable, Sendable {
		public var route: String
		public var direction: String
		public init(route: String, direction: String) { self.route = route; self.direction = direction }
	}

	/// The first `departuresPerLineDirection` departures of each route and direction,
	/// in board order. Other board content (station, sources, alerts) is kept.
	public static func retainedBoard(_ board: Board, preferences: OfflinePreferences) -> Board {
		var counts: [LineDirection: Int] = [:]
		var result = board
		result.departures = board.departures.filter { departure in
			let key = LineDirection(route: departure.route, direction: departure.direction)
			counts[key, default: 0] += 1
			return counts[key]! <= preferences.departuresPerLineDirection
		}
		return result
	}

	/// Trip keys whose full detail should be snapshotted: the first
	/// `effectiveTripDetailsPerLineDirection` boardable departures per route and direction.
	/// Positional (PATH) keys are skipped: they name a board slot, not a train, so an
	/// automatic snapshot could describe whichever train holds that slot later.
	public static func tripKeysToSnapshot(_ board: Board, preferences: OfflinePreferences) -> [String] {
		var counts: [LineDirection: Int] = [:]
		var seen = Set<String>()
		return board.departures.filter { departure in
			guard Display.boardable(departure), !departure.tripKey.isEmpty, !OfflineIdentity.isPositionalTrip(departure.tripKey), !seen.contains(departure.tripKey) else { return false }
			let key = LineDirection(route: departure.route, direction: departure.direction)
			guard counts[key, default: 0] < preferences.effectiveTripDetailsPerLineDirection else { return false }
			counts[key, default: 0] += 1
			seen.insert(departure.tripKey)
			return true
		}.map(\.tripKey)
	}

	/// Sources that annotate a board (alerts, car assignments) without carrying predictions.
	public static let ancillaryBoardSources: Set<String> = ["subway-alerts", "helium"]

	/// Merges a fetched board into the stored one, one source/feed group at a time. A
	/// group comes from `fetched` only when its source reports no error and is not
	/// older than the stored group; otherwise the stored departures (with their
	/// original timestamps) and source state remain, carrying the new error. Alerts
	/// follow the alerts source. Pure: callers apply `retainedBoard` afterwards.
	public static func mergeBoard(_ fetched: Board, into stored: Board?) -> OfflineBoardMerge {
		guard let stored else { return OfflineBoardMerge(board: fetched, advanced: true, predictionsAdvanced: true) }
		// An errored incoming group never counts. A stored source may carry the error
		// of a later failed fetch next to its retained good data, so its time still counts.
		func groupTime(_ board: Board, _ id: String, acceptingErrors: Bool) -> TimeInterval? {
			if let source = board.sources.first(where: { $0.id == id }) {
				guard acceptingErrors || source.error == nil, let time = source.timestamp, time > 0 else { return nil }
				return time
			}
			return board.departures.filter { $0.feed == id }.map(\.timestamp).filter { $0 > 0 }.max()
		}
		var ids: [String] = []
		for id in fetched.sources.map(\.id) + stored.sources.map(\.id) + fetched.departures.map(\.feed) + stored.departures.map(\.feed) where !ids.contains(id) { ids.append(id) }
		var advanced = false, predictionsAdvanced = false
		var alertsFromFetched: Bool?
		var departures: [Departure] = []
		var sources: [SourceState] = []
		for id in ids {
			let newTime = groupTime(fetched, id, acceptingErrors: false), oldTime = groupTime(stored, id, acceptingErrors: true)
			let newSource = fetched.sources.first { $0.id == id }, oldSource = stored.sources.first { $0.id == id }
			let takeNew = newTime.map { new in oldTime.map { new >= $0 } ?? true } ?? false
			if let newTime, oldTime.map({ newTime > $0 }) ?? true {
				advanced = true
				if !ancillaryBoardSources.contains(id), id != fetched.njt?.positions.id, id != stored.njt?.positions.id { predictionsAdvanced = true }
			}
			// A recovered feed clears its stored error; that alone never renews the save time.
			if takeNew, oldSource?.error != nil, newSource?.error == nil { advanced = true }
			if id == "subway-alerts" { alertsFromFetched = takeNew }
			if takeNew {
				departures += fetched.departures.filter { $0.feed == id }
				if let newSource { sources.append(newSource) }
			} else {
				departures += stored.departures.filter { $0.feed == id }
				if var retained = oldSource ?? newSource {
					if let error = newSource?.error { retained.error = error }
					sources.append(retained)
				}
			}
		}
		// Keep board order: by predicted time, stable for equal or missing times.
		departures = departures.enumerated().sorted { lhs, rhs in
			let left = lhs.element.time ?? .infinity, right = rhs.element.time ?? .infinity
			return left == right ? lhs.offset < rhs.offset : left < right
		}.map(\.element)
		let alerts = (alertsFromFetched ?? advanced) ? fetched.alerts : stored.alerts
		// GPS advances independently of arrival predictions, including GPS-only boards.
		// Retain older reports on disk; presentation applies the five-minute ceiling.
		var positions = Dictionary((stored.vehiclePositions ?? []).map { ($0.id, $0) }, uniquingKeysWith: { left, right in left.timestamp >= right.timestamp ? left : right })
		for position in fetched.vehiclePositions ?? [] where position.timestamp >= (positions[position.id]?.timestamp ?? 0) { positions[position.id] = position }
		let vehiclePositions = fetched.vehiclePositions == nil && stored.vehiclePositions == nil ? nil : positions.values.sorted { $0.id < $1.id }
		var njt = fetched.njt ?? stored.njt
		if var next = njt, let previous = stored.njt {
			func retainedSource(_ incoming: SourceState, _ previous: SourceState) -> SourceState {
				guard incoming.error == nil, (incoming.timestamp ?? 0) >= (previous.timestamp ?? 0) else {
					var retained = previous; retained.error = incoming.error ?? retained.error; return retained
				}
				return incoming
			}
			next.predictions = retainedSource(next.predictions, previous.predictions)
			next.positions = retainedSource(next.positions, previous.positions)
			njt = next
		}
		if vehiclePositions != stored.vehiclePositions || njt != stored.njt { advanced = true }
		return OfflineBoardMerge(board: Board(station: fetched.station, generatedAt: fetched.generatedAt, sources: sources, departures: departures, alerts: alerts, njt: njt, vehiclePositions: vehiclePositions), advanced: advanced, predictionsAdvanced: predictionsAdvanced)
	}

	/// Other stations within `nearbyRadiusFeet` of the viewed station, nearest first.
	public static func surroundingStations(of viewed: Station, catalog: [Station], preferences: OfflinePreferences) -> [(station: Station, distanceMeters: Double)] {
		guard preferences.nearbyRadiusFeet > 0 else { return [] }
		let limit = preferences.nearbyRadiusMeters
		return catalog.compactMap { station -> (station: Station, distanceMeters: Double)? in
			guard station.id != viewed.id else { return nil }
			let distance = Display.distanceMeters(lat1: viewed.lat, lon1: viewed.lon, lat2: station.lat, lon2: station.lon)
			return distance <= limit ? (station, distance) : nil
		}.sorted { $0.distanceMeters == $1.distanceMeters ? $0.station.id < $1.station.id : $0.distanceMeters < $1.distanceMeters }
	}
}

public struct OfflineBoardMerge: Sendable, Equatable {
	public var board: Board
	/// Some source group moved forward: persist the merged board.
	public var advanced: Bool
	/// A prediction feed (not only alerts or car assignments) moved forward: only then
	/// does the snapshot's save time renew.
	public var predictionsAdvanced: Bool
	public init(board: Board, advanced: Bool, predictionsAdvanced: Bool) {
		self.board = board
		self.advanced = advanced
		self.predictionsAdvanced = predictionsAdvanced
	}
}
