import Foundation

public struct StationPreference: Codable, Sendable, Equatable {
	public var direction: String
	public var routes: [String]
	public var view: BoardSortOrder
	public init(direction: String = "ALL", routes: [String] = [], view: BoardSortOrder = .track) {
		self.direction = direction; self.routes = routes; self.view = view
	}

	private enum CodingKeys: String, CodingKey { case direction, routes, view }
	public init(from decoder: Decoder) throws {
		let values = try decoder.container(keyedBy: CodingKeys.self)
		direction = try values.decodeIfPresent(String.self, forKey: .direction) ?? "ALL"
		routes = try values.decodeIfPresent([String].self, forKey: .routes) ?? []
		let savedView = try? values.decode(String.self, forKey: .view)
		view = savedView.flatMap(BoardSortOrder.init(rawValue:)) ?? .track
	}
}

public struct TransitPreferences: Codable, Sendable, Equatable {
	public var lastStation: String
	public var favorites: [String]
	public var theme: String
	public var stations: [String: StationPreference]
	public init(lastStation: String = "602", favorites: [String] = [], theme: String = "subway", stations: [String: StationPreference] = [:]) {
		self.lastStation = lastStation; self.favorites = favorites; self.theme = theme; self.stations = stations
	}
}

/// Durable app preferences that do not rely on UserDefaults or actor-bound UI state.
public actor TransitPreferencesStore {
	private let fileURL: URL
	public init(fileURL: URL) { self.fileURL = fileURL }
	public func load() -> TransitPreferences {
		guard let data = try? Data(contentsOf: fileURL), let value = try? JSONDecoder().decode(TransitPreferences.self, from: data) else { return TransitPreferences() }
		return value
	}
	public func save(_ preferences: TransitPreferences) throws {
		try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
		try JSONEncoder().encode(preferences).write(to: fileURL, options: .atomic)
	}
}

/// Stores favorites and the eight most recently saved other boards. Restoring a
/// board always means last-known data: callers must pass cached=true to Display.
public actor BoardCache {
	private let directory: URL
	private let recentLimit: Int
	private struct IndexEntry: Codable { let stationID: String; let savedAt: TimeInterval }

	public init(directory: URL, recentLimit: Int = 8) { self.directory = directory; self.recentLimit = max(0, recentLimit) }

	public func load(stationID: String) -> Board? {
		guard let data = try? Data(contentsOf: boardURL(stationID)) else { return nil }
		return try? JSONDecoder().decode(Board.self, from: data)
	}

	public func save(_ board: Board, favorites: [String] = []) throws {
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		try JSONEncoder().encode(board).write(to: boardURL(board.station.id), options: .atomic)
		var entries = readIndex().filter { $0.stationID != board.station.id }
		entries.insert(IndexEntry(stationID: board.station.id, savedAt: Date().timeIntervalSince1970), at: 0)
		var recentCount = 0
		let kept = entries.filter { entry in
			if favorites.contains(entry.stationID) { return true }
			recentCount += 1
			return recentCount <= recentLimit
		}
		let retained = Set(kept.map(\.stationID))
		for entry in entries where !retained.contains(entry.stationID) { try? FileManager.default.removeItem(at: boardURL(entry.stationID)) }
		try JSONEncoder().encode(kept).write(to: directory.appendingPathComponent("index.json"), options: .atomic)
	}

	public func saveCatalog(_ stations: [Station]) throws {
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		try JSONEncoder().encode(stations).write(to: directory.appendingPathComponent("stations.json"), options: .atomic)
	}

	public func loadCatalog() -> [Station] {
		guard let data = try? Data(contentsOf: directory.appendingPathComponent("stations.json")) else { return [] }
		return (try? JSONDecoder().decode([Station].self, from: data)) ?? []
	}

	private func boardURL(_ id: String) -> URL {
		let safe = Data(id.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
		return directory.appendingPathComponent("board-\(safe).json")
	}

	private func readIndex() -> [IndexEntry] {
		guard let data = try? Data(contentsOf: directory.appendingPathComponent("index.json")) else { return [] }
		return (try? JSONDecoder().decode([IndexEntry].self, from: data)) ?? []
	}
}
