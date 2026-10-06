import Foundation

public enum Freshness: String, Codable, Sendable { case live, stale, expired, unavailable }

public struct Countdown: Sendable, Equatable {
	public let value: String
	public let unit: String
	public init(value: String, unit: String) { self.value = value; self.unit = unit }
}

public struct RegionalRoute: Sendable, Equatable {
	public let label: String
	public let name: String
	public let colors: [UInt32]
}

public enum TransitLinks {
	public static let njtDepartures = URL(string: "https://www.njtransit.com/dv-to")!
	public static let njtSchedules = URL(string: "https://www.njtransit.com/light-rail-to")!
	public static let njtAlerts = URL(string: "https://www.njtransit.com/travel-alerts-to")!
	public static let njtAccessibility = URL(string: "https://www.njtransit.com/ride-lightrail")!
}

public enum Display {
	public static func freshness(_ timestamp: TimeInterval?, now: TimeInterval) -> Freshness {
		guard let timestamp, timestamp != 0 else { return .unavailable }
		return now - timestamp > 300 ? .expired : now - timestamp > 90 ? .stale : .live
	}

	public static func countdown(_ time: TimeInterval?, timestamp: TimeInterval, now: TimeInterval, cached: Bool = false) -> Countdown {
		guard let time else { return Countdown(value: "—", unit: "no estimate") }
		guard !cached, freshness(timestamp, now: now) == .live else { return Countdown(value: clockTime(time), unit: "last estimate") }
		let seconds = time - now
		if seconds < -30 { return Countdown(value: "—", unit: "awaiting update") }
		return Countdown(value: seconds < 60 ? "<1" : String(Int(floor(seconds / 60))), unit: "min")
	}

	/// Widgets format every row of every timeline entry, so the formatter is created once.
	/// DateFormatter is thread-safe for formatting.
	private static let clockFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US")
		formatter.timeZone = TimeZone(identifier: "America/New_York")
		formatter.dateFormat = "h:mm a"
		return formatter
	}()

	public static func clockTime(_ seconds: TimeInterval?) -> String {
		guard let seconds else { return "—" }
		return clockFormatter.string(from: Date(timeIntervalSince1970: seconds))
	}

	public static func ageLabel(_ timestamp: TimeInterval?, now: TimeInterval) -> String {
		guard let timestamp, timestamp != 0 else { return "not received" }
		let seconds = max(0, Int(now - timestamp))
		if seconds < 60 { return "\(seconds)s ago" }
		if seconds < 3600 { return "\(seconds / 60)m ago" }
		return "\(seconds / 3600)h ago"
	}

	public static func boardable(_ departure: Departure) -> Bool {
		!["SKIPPED", "CANCELED", "DELETED"].contains(departure.relationship ?? "")
	}

	/// The API's area usually already ends in its track; preserve that boarding
	/// context and add provenance without repeating the same track number.
	public static func boardingLabel(_ departure: Departure) -> String {
		func nonempty(_ value: String?) -> String? {
			guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
			return text
		}
		let area = nonempty(departure.area) ?? departure.partId
		let actualTrack = nonempty(departure.actualTrack)
		guard let track = actualTrack ?? nonempty(departure.scheduledTrack) else { return "\(area) · Track unknown" }
		let trackLabel = "Track \(track)"
		let provenance = actualTrack == nil ? "scheduled" : "reported"
		let includesTrack = area == trackLabel || area.hasSuffix(" · " + trackLabel)
		return includesTrack ? "\(area) · \(provenance)" : "\(area) · \(trackLabel) · \(provenance)"
	}

	public static func currentConsist(_ consist: Consist?, now: TimeInterval) -> Bool {
		guard let consist else { return false }
		return [consist.updatedAt, consist.fetchedAt].allSatisfy { $0 > 0 && now - $0 <= 300 && $0 <= now + 60 }
	}

	public static func consistSummary(_ cars: [ConsistCar]) -> String {
		var ranges: [String] = []
		var start = 0
		while start < cars.count {
			var end = start
			if start + 1 < cars.count, let first = Int(cars[start].number), let next = Int(cars[start + 1].number), abs(next - first) == 1 {
				let step = next - first
				while end + 1 < cars.count, let current = Int(cars[end].number), let following = Int(cars[end + 1].number), following - current == step { end += 1 }
			}
			ranges.append(end == start ? cars[start].number : "\(cars[start].number)–\(cars[end].number)")
			start = end + 1
		}
		return ranges.joined(separator: ", ")
	}

	public static func displayRoute(_ route: String) -> String {
		["GS": "S", "FS": "S", "H": "S", "SI": "SIR"][route] ?? route
	}

	public static func regionalRoute(_ route: String) -> RegionalRoute? {
		switch route {
		case "NJT-HBLR": RegionalRoute(label: "HBLR", name: "NJ Transit Hudson–Bergen Light Rail", colors: [0x70452B])
		case "NJT-NLR": RegionalRoute(label: "NLR", name: "NJ Transit Newark Light Rail", colors: [0x2767AD])
		case "NJT-RIVER": RegionalRoute(label: "River LINE", name: "NJ Transit River LINE", colors: [0x327448])
		case "PATH-NWK-WTC": RegionalRoute(label: "NWK–WTC", name: "PATH NWK–WTC", colors: [0xD93A30])
		case "PATH-HOB-WTC": RegionalRoute(label: "HOB–WTC", name: "PATH HOB–WTC", colors: [0x65C100])
		case "PATH-JSQ-33": RegionalRoute(label: "JSQ–33", name: "PATH JSQ–33", colors: [0xFF9900])
		case "PATH-HOB-33": RegionalRoute(label: "HOB–33", name: "PATH HOB–33", colors: [0x4D92FB])
		case "PATH-JSQ-33-HOB": RegionalRoute(label: "JSQ–33 via HOB", name: "PATH JSQ–33 via HOB", colors: [0x4D92FB, 0xFF9900])
		default: route.hasPrefix("PATH") ? RegionalRoute(label: "PATH", name: "PATH", colors: [0x62666B]) : nil
		}
	}

	public static func routeLabel(_ route: String) -> String {
		regionalRoute(route)?.label ?? displayRoute(route)
	}

	public static func directionLabel(_ direction: String) -> String {
		switch direction {
		case "NORTH": "Northbound"
		case "SOUTH": "Southbound"
		case "TO_NY": "To New York"
		case "TO_NJ": "To New Jersey"
		case "ALL": "All directions"
		default: "Direction unknown"
		}
	}

	public static func stationMatches(_ station: Station, query: String) -> Bool {
		let boroughs = ["NJ": "New Jersey", "M": "Manhattan", "B": "Brooklyn", "Bk": "Brooklyn", "Bx": "Bronx", "Q": "Queens", "SI": "Staten Island"]
		let system = station.routes.contains { $0.hasPrefix("NJT-") } ? "NJT light rail lightrail" : ""
		let fields = [station.name, station.municipality ?? "", boroughs[station.borough] ?? station.borough, system,
			station.routes.joined(separator: " "), station.routes.map(routeLabel).joined(separator: " "),
			station.parts.map(\.line).joined(separator: " "), station.parts.map(\.stationId).joined(separator: " ")]
		func normalized(_ text: String) -> String {
			text.lowercased().replacingOccurrences(of: "–", with: " ").replacingOccurrences(of: "—", with: " ").replacingOccurrences(of: "-", with: " ")
		}
		let haystack = normalized(fields.joined(separator: " "))
		return normalized(query).split(whereSeparator: \.isWhitespace).allSatisfy { haystack.contains($0) }
	}

	public static func distanceMeters(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
		let rad = Double.pi / 180
		let a = pow(sin((lat2 - lat1) * rad / 2), 2) + cos(lat1 * rad) * cos(lat2 * rad) * pow(sin((lon2 - lon1) * rad / 2), 2)
		return 6_371_000 * 2 * atan2(sqrt(min(1, a)), sqrt(max(0, 1 - a)))
	}

	public static func changeStale(_ change: TripChange, now: TimeInterval, cached: Bool = false) -> Bool {
		cached || change.evidence.contains { $0.unavailable == true || $0.timestamp == 0 || now - $0.timestamp > $0.staleAfter }
	}

	public static func changesAhead(_ changes: [TripChange]?, index: Int) -> [TripChange] {
		(changes ?? []).filter { $0.stopIndices.contains { $0 >= index } }.sorted {
			let left = changeRank($0, index: index), right = changeRank($1, index: index)
			return left == right ? $0.id < $1.id : left < right
		}.map { change in
			var result = change
			if ["track", "boarding"].contains(change.kind), !change.stopIndices.contains(index) {
				result.label += " · ahead" + (change.location.map { " at \($0)" } ?? "")
			}
			return result
		}
	}

	private static func changeRank(_ change: TripChange, index: Int) -> Int {
		if ["track", "boarding"].contains(change.kind) && change.stopIndices.contains(index) { return 0 }
		if change.kind == "cancellation" { return 1 }
		if ["unplanned", "unknown"].contains(change.classification) { return change.advisory == true ? 3 : 2 }
		return change.classification == "planned" ? 4 : 5
	}
}
