import Foundation

/// Direction and line filters for one transfer station. Unlike board filters,
/// a transfer entry has no grouping view: connections keep arrival-relative groups.
public struct TransferStationPreference: Codable, Sendable, Equatable {
	public var direction: String
	public var routes: [String]
	public init(direction: String = "ALL", routes: [String] = []) { self.direction = direction; self.routes = routes }
}

/// Whether transfers share each station's board filters or keep their own.
/// Entries are kept while separate filters are off, so turning them back on reuses them.
public struct TransferPreferences: Codable, Sendable, Equatable {
	public var separateFilters = false
	public var stations: [String: TransferStationPreference] = [:]
	public init(separateFilters: Bool = false, stations: [String: TransferStationPreference] = [:]) {
		self.separateFilters = separateFilters; self.stations = stations
	}
}

/// Station-ID-specific transfer filters. Callers always name the transfer station;
/// the board's currently selected station is never implied.
extension PortableSettings {
	public func transferFilter(for stationID: String) -> TransferStationPreference {
		if transfers.separateFilters, let saved = transfers.stations[stationID] { return saved }
		let board = stations[stationID] ?? StationPreference()
		return TransferStationPreference(direction: board.direction, routes: board.routes)
	}

	/// In separate mode, copies the station's board filters into a missing entry.
	/// Returns whether the settings changed and need saving.
	@discardableResult
	public mutating func seedTransferFilter(for stationID: String) -> Bool {
		guard transfers.separateFilters, transfers.stations[stationID] == nil else { return false }
		transfers.stations[stationID] = transferFilter(for: stationID)
		return true
	}

	/// Shared mode edits the station's board filters and keeps its grouping view;
	/// separate mode edits only the transfer entry, seeding it first when missing.
	public mutating func updateTransferFilter(for stationID: String, _ change: (inout TransferStationPreference) -> Void) {
		if transfers.separateFilters {
			seedTransferFilter(for: stationID)
			change(&transfers.stations[stationID]!)
		} else {
			var board = stations[stationID] ?? StationPreference()
			var value = TransferStationPreference(direction: board.direction, routes: board.routes)
			change(&value)
			board.direction = value.direction; board.routes = value.routes
			stations[stationID] = board
		}
	}
}

public enum TransferFilters {
	/// Stable line choices: the station's own lines plus any reported connection,
	/// normalized like board filters and without lines hidden in settings.
	public static func choices(stationRoutes: [String], connections: [Departure], hiddenRoutes: [String]) -> [String] {
		LineVisibility.routes(Array(Set((stationRoutes + connections.map(\.route)).map(Display.displayRoute))).sorted(), hiddenRoutes: hiddenRoutes)
	}

	/// Visible, live, future connections before station filters are applied.
	public static func usable(_ connections: [Departure], hiddenRoutes: [String], now: TimeInterval) -> [Departure] {
		connections.filter { LineVisibility.isEnabled($0.route, hiddenRoutes: hiddenRoutes) && Display.freshness($0, now: now) == .live && ($0.time ?? -.infinity) >= now }
	}

	public static func filter(_ connections: [Departure], by preference: TransferStationPreference) -> [Departure] {
		let routes = Set(preference.routes.map(Display.displayRoute))
		return connections.filter { (preference.direction == "ALL" || $0.direction == preference.direction) && (routes.isEmpty || routes.contains(Display.displayRoute($0.route))) }
	}

	/// Toggles a normalized chip. Stored aliases such as GS or SI count as their chip,
	/// so tapping a selected chip removes them rather than adding the canonical name.
	public static func toggle(_ route: String, in preference: inout TransferStationPreference) {
		let key = Display.displayRoute(route)
		if preference.routes.contains(where: { Display.displayRoute($0) == key }) { preference.routes.removeAll { Display.displayRoute($0) == key } }
		else { preference.routes.append(key) }
	}

	/// Selected chips, compared by normalized route.
	public static func selectedChips(_ preference: TransferStationPreference) -> [String] {
		Array(Set(preference.routes.map(Display.displayRoute))).sorted()
	}
}
