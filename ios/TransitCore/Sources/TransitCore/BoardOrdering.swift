import Foundation

/// Matches the departure views offered by the web board.
public enum BoardSortOrder: String, Codable, CaseIterable, Identifiable, Sendable {
	case track, direction, family, corridor, service

	public var id: String { rawValue }
	public var title: String {
		switch self {
		case .track: "Track"
		case .direction: "Direction"
		case .family: "Families"
		case .corridor: "Corridors"
		case .service: "Service"
		}
	}
	public var label: String {
		switch self {
		case .track: "By track"
		case .direction: "By direction · all platforms"
		case .family: "By direction · route families"
		case .corridor: "By direction · station corridors"
		case .service: "By service"
		}
	}
}

public struct DepartureGroup: Identifiable, Sendable, Equatable {
	public let id: String
	public let direction: String
	public let partId: String
	public let track: String?
	public let reportedTrack: Bool
	public let label: String
	public let service: String?
	public let departures: [Departure]
}

/// Filters first, then groups and sorts estimates within each group. Cached boards
/// retain their last-known departures rather than aging them out as live trains.
public func groupDepartures(_ board: Board, direction: String = "ALL", routes: [String] = [], order: BoardSortOrder = .track, now: TimeInterval, cached: Bool = false) -> [DepartureGroup] {
	struct Key: Hashable {
		let direction: String
		let identity: [String]
		let label: String
	}
	let selected = board.departures.filter {
		(direction == "ALL" || $0.direction == direction) &&
		(routes.isEmpty || routes.contains(Display.displayRoute($0.route))) &&
		(cached || Display.freshness($0.timestamp, now: now) != .live || ($0.time ?? .infinity) >= now - 30)
	}
	let groups = Dictionary(grouping: selected) { departure in
		let direction = boardDirections.contains(departure.direction) ? departure.direction : "UNKNOWN"
		let label: String
		switch order {
		case .family: label = routeFamily(departure.route)
		case .corridor: label = board.station.parts.first { $0.id == departure.partId }?.line ?? departure.partId
		case .service: label = departure.route
		case .track, .direction: label = ""
		}
		let identity: [String]
		switch order {
		case .track: identity = [departure.partId, departure.actualTrack ?? departure.scheduledTrack ?? "?"]
		case .corridor: identity = [departure.partId]
		case .direction, .family, .service: identity = [label]
		}
		return Key(direction: direction, identity: identity, label: label)
	}.map { key, departures in
		let sorted = departures.sorted {
			let left = $0.time ?? .infinity, right = $1.time ?? .infinity
			return left == right ? $0.key < $1.key : left < right
		}
		let first = sorted[0]
		// Length prefixes keep identities distinct even if a future feed adds a
		// separator to a station, track, or route identifier.
		let id = ([order.rawValue, key.direction] + key.identity).map { "\($0.utf8.count):\($0)" }.joined()
		return DepartureGroup(id: id, direction: key.direction, partId: first.partId,
			track: order == .track ? first.actualTrack ?? first.scheduledTrack : nil,
			reportedTrack: order == .track && first.actualTrack != nil, label: key.label,
			service: order == .service ? first.route : nil, departures: sorted)
	}
	return groups.sorted { left, right in
		if order == .track {
			if left.departures[0].direction != right.departures[0].direction { return left.departures[0].direction < right.departures[0].direction }
			if left.partId != right.partId { return left.partId < right.partId }
			if left.track != right.track { return (left.track ?? "") < (right.track ?? "") }
			return left.id < right.id
		}
		let labelComparison = left.label.compare(right.label, options: .numeric, locale: Locale(identifier: "en"))
		if order == .service, labelComparison != .orderedSame { return labelComparison == .orderedAscending }
		if left.direction != right.direction { return directionRank(left.direction) < directionRank(right.direction) }
		if labelComparison != .orderedSame { return labelComparison == .orderedAscending }
		return left.id < right.id
	}
}

private let boardDirections = ["NORTH", "SOUTH", "TO_NY", "TO_NJ", "UNKNOWN"]
private func directionRank(_ direction: String) -> Int { boardDirections.firstIndex(of: direction) ?? boardDirections.count }

private func routeFamily(_ route: String) -> String {
	switch route {
	case "1", "2", "3": "1 / 2 / 3"
	case "4", "5", "6", "4X", "5X", "6X": "4 / 5 / 6"
	case "7", "7X": "7"
	case "A", "C", "E": "A / C / E"
	case "B", "D", "F", "FX", "M": "B / D / F / M"
	case "N", "Q", "R", "W": "N / Q / R / W"
	case "J", "Z": "J / Z"
	case "GS": "42 St Shuttle"
	case "FS": "Franklin Shuttle"
	case "H": "Rockaway Shuttle"
	case "SI": "SIR"
	default: route
	}
}
