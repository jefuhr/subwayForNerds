import Foundation

/// Global exclusions are independent of per-station inclusion filters.
public enum LineVisibility {
	public static func key(_ route: String) -> String {
		["4X": "4", "5X": "5", "6X": "6", "7X": "7", "FX": "F", "GS": "S", "FS": "S", "H": "S", "SI": "SIR"][route] ?? route
	}
	public static func isEnabled(_ route: String, hiddenRoutes: [String]) -> Bool { !hiddenRoutes.contains { key($0) == key(route) } }
	public static func routes(_ routes: [String], hiddenRoutes: [String]) -> [String] { routes.filter { isEnabled($0, hiddenRoutes: hiddenRoutes) } }
	public static func station(_ station: Station, hiddenRoutes: [String]) -> Station? {
		var value = station
		value.routes = routes(station.routes, hiddenRoutes: hiddenRoutes)
		guard station.routes.isEmpty || !value.routes.isEmpty else { return nil }
		value.parts = station.parts.compactMap { part in
			var value = part; value.routes = routes(part.routes, hiddenRoutes: hiddenRoutes)
			return !part.routes.isEmpty && value.routes.isEmpty ? nil : value
		}
		return value
	}
	public static func alerts(_ alerts: [ServiceAlert], hiddenRoutes: [String]) -> [ServiceAlert] {
		alerts.compactMap { alert in
			let selectors = alert.selectors + (alert.affectedSelectors ?? [])
			let scopedRoutes = alert.routes + selectors.compactMap(\.route)
			guard scopedRoutes.isEmpty || selectors.contains(where: { $0.route == nil }) || scopedRoutes.contains(where: { isEnabled($0, hiddenRoutes: hiddenRoutes) }) else { return nil }
			var value = alert; value.routes = routes(alert.routes, hiddenRoutes: hiddenRoutes); return value
		}
	}
	public static func board(_ board: Board, hiddenRoutes: [String]) -> Board {
		var value = board
		value.departures = board.departures.filter { isEnabled($0.route, hiddenRoutes: hiddenRoutes) }
		value.alerts = alerts(board.alerts, hiddenRoutes: hiddenRoutes)
		value.vehiclePositions = board.vehiclePositions?.filter { isEnabled($0.route, hiddenRoutes: hiddenRoutes) }
		value.station.routes = routes(board.station.routes, hiddenRoutes: hiddenRoutes)
		return value
	}
}

private func combinedIdentity(_ stationID: String, _ key: String) -> String { "\(stationID.utf8.count):\(stationID)\(key.utf8.count):\(key)" }

public enum CombinedStationResolver {
	public static func station(id: String, name: String, stationIDs: [String], catalog: [Station]) -> Station? {
		var seen = Set<String>()
		let members = stationIDs.compactMap { id -> Station? in
			guard !id.hasPrefix("combined:"), seen.insert(id).inserted else { return nil }
			return catalog.first { $0.id == id }
		}
		guard !members.isEmpty else { return nil }
		let parts = members.flatMap { member -> [StationPart] in
			let parts = member.parts.isEmpty ? [StationPart(id: member.id, stationId: member.id, name: member.name, line: member.routes.joined(separator: " / "), routes: member.routes, lat: member.lat, lon: member.lon, ada: "", north: "Northbound", south: "Southbound")] : member.parts
			var seen = Set<String>()
			return parts.compactMap { part in
				guard seen.insert(part.id).inserted else { return nil }
				var value = part; value.id = combinedIdentity(member.id, part.id); return value
			}
		}
		return Station(id: id, name: name, borough: Set(members.map(\.borough)).count == 1 ? members[0].borough : "NYC",
			routes: Array(Set(members.flatMap(\.routes))).sorted(), lat: members.map(\.lat).reduce(0, +) / Double(members.count),
			lon: members.map(\.lon).reduce(0, +) / Double(members.count), parts: parts)
	}
}

public struct MemberBoardSnapshot: Sendable, Equatable {
	public var station: Station
	public var board: Board?
	public var cached: Bool
	public var savedAt: TimeInterval?
	public var error: String?
	public init(station: Station, board: Board?, cached: Bool, savedAt: TimeInterval? = nil, error: String? = nil) {
		self.station = station; self.board = board; self.cached = cached; self.savedAt = savedAt; self.error = error
	}
}

public struct DepartureOrigin: Sendable, Equatable {
	public var station: Station
	public var departure: Departure
	public var cached: Bool
	public var savedAt: TimeInterval?
	public init(station: Station, departure: Departure, cached: Bool, savedAt: TimeInterval? = nil) {
		self.station = station; self.departure = departure; self.cached = cached; self.savedAt = savedAt
	}
}

/// A presentation snapshot, never an API request or replacement for physical caches.
public struct CombinedBoardSnapshot: Sendable, Equatable {
	public let board: Board
	public let members: [MemberBoardSnapshot]
	public let origins: [String: DepartureOrigin]
	public var cachedDepartureKeys: Set<String> { Set(origins.filter { $0.value.cached }.map(\.key)) }
	public var warnings: [String] { warnings(includeSaved: true) }
	/// Widgets use the default, which names every member that is saved or failed. The app's board passes
	/// `includeSaved: false`: a member that shows a saved board is an offline estimate the board already labels,
	/// so neither its "saved" note nor an error that only kept it from refreshing (such as "Feed unavailable")
	/// is a notice. Members with no board to show, and external members, still warn.
	public func warnings(includeSaved: Bool) -> [String] {
		members.compactMap { member in
			if !includeSaved, member.cached, let board = member.board, !board.usesExternalDepartures { return nil }
			let message = member.error ?? (member.board == nil ? "Departures unavailable" : member.board?.usesExternalDepartures == true ? "Use official departure tools" : member.cached ? "Saved departures · offline estimates" : nil)
			return message.map { "\(member.station.name): \($0)" }
		}
	}
	public init(station: Station, members: [MemberBoardSnapshot]) {
		var seenMembers = Set<String>()
		self.members = members.filter { seenMembers.insert($0.station.id).inserted }
		var departures: [Departure] = []
		var origins: [String: DepartureOrigin] = [:]
		var sources: [String: SourceState] = [:]
		var alerts: [String: ServiceAlert] = [:]
		var positions: [String: VehiclePosition] = [:]
		for member in self.members {
			guard let board = member.board else { continue }
			if !board.usesExternalDepartures {
				for departure in board.departures {
					let key = combinedIdentity(member.station.id, departure.key)
					guard origins[key] == nil else { continue }
					origins[key] = DepartureOrigin(station: member.station, departure: departure, cached: member.cached, savedAt: member.savedAt)
					var row = departure; row.key = key; row.partId = combinedIdentity(member.station.id, departure.partId)
					departures.append(row)
				}
			}
			for source in board.sources {
				if let previous = sources[source.id] {
					let errors = Set([previous.error, source.error].compactMap { $0 }).sorted()
					sources[source.id] = SourceState(id: source.id,
						timestamp: previous.timestamp.flatMap { a in source.timestamp.map { min(a, $0) } },
						fetchedAt: previous.fetchedAt.flatMap { a in source.fetchedAt.map { min(a, $0) } },
						error: errors.isEmpty ? nil : errors.joined(separator: "; "), staleAfter: [previous.staleAfter, source.staleAfter].compactMap { $0 }.min())
				} else { sources[source.id] = source }
			}
			for alert in board.alerts {
				if let previous = alerts[alert.id], (previous.updatedAt ?? 0) > (alert.updatedAt ?? 0) { continue }
				alerts[alert.id] = alert
			}
			for position in board.vehiclePositions ?? [] {
				if let previous = positions[position.id], previous.timestamp > position.timestamp { continue }
				positions[position.id] = position
			}
		}
		self.origins = origins
		board = Board(station: station, generatedAt: self.members.compactMap { $0.board?.generatedAt }.min() ?? 0,
			sources: sources.values.sorted { $0.id < $1.id }, departures: departures.sorted { ($0.time ?? .infinity) == ($1.time ?? .infinity) ? $0.key < $1.key : ($0.time ?? .infinity) < ($1.time ?? .infinity) },
			alerts: alerts.values.sorted { $0.id < $1.id }, vehiclePositions: positions.values.sorted { $0.id < $1.id })
	}
}
