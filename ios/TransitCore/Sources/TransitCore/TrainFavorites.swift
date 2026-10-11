import Foundation

public struct TrainFavoriteMatch: Sendable, Equatable {
	public var carIDs: [String]
	public var exactConsist: Bool
}
public struct TrainFavorites: Codable, Sendable, Equatable {
	public enum Match: String, Codable, Sendable, CaseIterable, Identifiable {
		case exact, anyCar
		public var id: String { rawValue }
		public var title: String { self == .exact ? "Exact consist" : "Any member car" }
	}
	public var cars: [String] = []
	public var consists: [[String]] = []
	public var match: Match = .exact
	public init() {}
	public static func validCarID(_ id: String) -> Bool {
		let parts = id.split(separator: ":", omittingEmptySubsequences: false)
		return id.utf16.count <= 128 && parts.count == 3 && ["nyct", "sir"].contains(String(parts[0])) &&
			!["R160A", "R160B"].contains(String(parts[1])) &&
			parts.dropFirst().allSatisfy { !$0.isEmpty && $0.unicodeScalars.allSatisfy { scalar in
				(65...90).contains(scalar.value) || (97...122).contains(scalar.value) || (48...57).contains(scalar.value) || [45, 46, 95].contains(scalar.value)
			} }
	}
	public static func carID(number: String, type: String?, feed: String) -> String? {
		guard let type, !type.isEmpty else { return nil }
		let family = ["R160", "R160A", "R160B"].contains(type) ? "R160" : type
		let id = "\(feed == "gtfs-si" ? "sir" : "nyct"):\(family):\(number)"
		return validCarID(id) ? id : nil
	}
	public static func consistIDs(_ consist: Consist?, feed: String) -> [String]? {
		guard let consist, (1...20).contains(consist.cars.count) else { return nil }
		let ids = consist.cars.compactMap { carID(number: $0.number, type: $0.type, feed: feed) }
		guard ids.count == consist.cars.count, Set(ids).count == ids.count else { return nil }
		return ids.sorted()
	}
	public static func consistKey(_ ids: [String]) -> String {
		// IDs cannot contain control characters, so this separator is unambiguous.
		ids.sorted().joined(separator: "\u{1f}")
	}
	public func containsConsist(_ ids: [String]) -> Bool { consists.contains { Self.consistKey($0) == Self.consistKey(ids) } }
	public func match(_ consist: Consist?, feed: String, now: TimeInterval, cached: Bool = false) -> TrainFavoriteMatch? {
		guard !cached, Display.currentConsist(consist, now: now), let ids = Self.consistIDs(consist, feed: feed) else { return nil }
		let exact = containsConsist(ids)
		let saved = Set(cars + (match == .anyCar ? consists.flatMap { $0 } : []))
		let matches = exact ? ids : ids.filter { saved.contains($0) }
		return matches.isEmpty ? nil : TrainFavoriteMatch(carIDs: matches, exactConsist: exact)
	}
	public static func label(_ id: String) -> String {
		let parts = id.split(separator: ":")
		guard parts.count == 3 else { return id }
		return "\(parts[1]) \(parts[2])\(parts[0] == "sir" ? " · SIR" : "")"
	}
}
