import Foundation

public enum WidgetField: String, Codable, Sendable, CaseIterable, Identifiable {
	case stationName, destination, track, service, carType, carCount, carNumbers, location, updatedAt, refreshButton, groupHeaders
	public var id: String { rawValue }
	public var title: String {
		switch self {
		case .stationName: "Station name"
		case .destination: "Destinations"
		case .track: "Tracks"
		case .service: "Service patterns"
		case .carType: "Car types"
		case .carCount: "Car counts"
		case .carNumbers: "Car numbers"
		case .location: "Train locations"
		case .updatedAt: "Report time"
		case .refreshButton: "Refresh button"
		case .groupHeaders: "Grouping labels"
		}
	}
}
public enum WidgetTimeStyle: String, Codable, Sendable, CaseIterable, Identifiable {
	case countdown, minutes, clock
	public var id: String { rawValue }
	public var title: String { switch self { case .countdown: "Minutes and seconds"; case .minutes: "Minutes"; case .clock: "Arrival clock time" } }
}
/// A preferred data reload interval. WidgetKit controls the actual schedule.
public enum WidgetRefreshInterval: Int, Codable, Sendable, CaseIterable, Identifiable {
	case oneMinute = 1, twoMinutes = 2, fiveMinutes = 5, tenMinutes = 10, fifteenMinutes = 15, thirtyMinutes = 30, sixtyMinutes = 60
	public var id: Int { rawValue }
	public var title: String { rawValue == 1 ? "1 minute" : "\(rawValue) minutes" }
	public var seconds: TimeInterval { TimeInterval(rawValue * 60) }
}
public struct WidgetDisplayOptions: Codable, Sendable, Equatable {
	public var fields: Set<WidgetField> = [.stationName, .destination, .track, .carType, .updatedAt, .refreshButton, .groupHeaders]
	public var compact = true
	public var trainsPerDirection = 0
	public var timeStyle: WidgetTimeStyle = .countdown
	public var refreshInterval: WidgetRefreshInterval = .fiveMinutes
	public init() {}
	private enum CodingKeys: String, CodingKey { case fields, compact, trainsPerDirection, timeStyle, refreshInterval }
	public init(from decoder: Decoder) throws {
		self.init()
		let values = try decoder.container(keyedBy: CodingKeys.self)
		fields = try values.decodeIfPresent(Set<WidgetField>.self, forKey: .fields) ?? fields
		compact = try values.decodeIfPresent(Bool.self, forKey: .compact) ?? compact
		trainsPerDirection = try values.decodeIfPresent(Int.self, forKey: .trainsPerDirection) ?? trainsPerDirection
		timeStyle = try values.decodeIfPresent(WidgetTimeStyle.self, forKey: .timeStyle) ?? timeStyle
		// Missing or unsupported intervals must not discard existing display choices.
		refreshInterval = (try? values.decode(WidgetRefreshInterval.self, forKey: .refreshInterval)) ?? .fiveMinutes
	}
	/// Try the richest layout first; the view measures which candidate actually fits.
	/// A chosen train count is an upper limit, as is the widget size's maximum.
	public func candidateCounts(maximum: Int) -> [Int] {
		let limit = max(1, trainsPerDirection == 0 ? maximum : min(maximum, trainsPerDirection))
		return Array(stride(from: limit, through: 1, by: -1))
	}
}

public enum LockScreenDirectionOrder: String, Codable, Sendable, CaseIterable, Identifiable {
	case downtownLeft, uptownLeft
	public var id: String { rawValue }
	public var title: String {
		switch self { case .downtownLeft: "Downtown left, uptown right"; case .uptownLeft: "Uptown left, downtown right" }
	}
}

/// Lock Screen presentation is independent of Home Screen display and route filters.
public struct LockScreenWidgetOptions: Codable, Sendable, Equatable {
	public static let fields: [WidgetField] = [.stationName, .destination, .track, .service, .carType, .carCount, .carNumbers, .location, .updatedAt]
	public var display: WidgetDisplayOptions
	public var directionOrder: LockScreenDirectionOrder = .downtownLeft
	public var showService = true
	public init() {
		display = WidgetDisplayOptions()
		display.fields = [.stationName, .carType]
		display.trainsPerDirection = 2
		display.timeStyle = .minutes
	}
	/// Preserve information previously visible in accessories when splitting settings.
	public init(legacyDisplay: WidgetDisplayOptions) {
		self.init()
		display.fields = legacyDisplay.fields.intersection([.stationName, .carType, .carCount])
		display.timeStyle = legacyDisplay.timeStyle
	}
	private enum CodingKeys: String, CodingKey { case display, directionOrder, showService }
	public init(from decoder: Decoder) throws {
		self.init()
		let values = try decoder.container(keyedBy: CodingKeys.self)
		display = try values.decodeIfPresent(WidgetDisplayOptions.self, forKey: .display) ?? display
		directionOrder = try values.decodeIfPresent(LockScreenDirectionOrder.self, forKey: .directionOrder) ?? .downtownLeft
		showService = try values.decodeIfPresent(Bool.self, forKey: .showService) ?? true
	}
	public func orderedDirections(regional: Bool = false) -> [String] {
		let directions = regional ? ["TO_NJ", "TO_NY"] : ["SOUTH", "NORTH"]
		return directionOrder == .downtownLeft ? directions : directions.reversed()
	}
	public var candidateCounts: [Int] { display.candidateCounts(maximum: 6) }
}
/// Car details retain the existing freshness rules; missing reports stay blank.
public func widgetTrainDetails(_ row: Departure, options: WidgetDisplayOptions, now: TimeInterval, cached: Bool = false) -> String {
	var values: [String] = []
	if options.fields.contains(.track), let track = row.actualTrack ?? row.scheduledTrack { values.append("T\(track)") }
	if options.fields.contains(.service), !row.pattern.isEmpty { values.append(row.pattern + (row.patternSource == "inferred" ? " · est." : "")) }
	if !cached, Display.currentConsist(row.consist, now: now), let consist = row.consist {
		let beforeCars = values.count
		if options.fields.contains(.carType) {
			let types = Array(Set(consist.cars.compactMap(\.type))).sorted().joined(separator: "/")
			if !types.isEmpty { values.append(types) }
		}
		if options.fields.contains(.carCount), !consist.cars.isEmpty { values.append("\(consist.cars.count) cars") }
		if options.fields.contains(.carNumbers), !consist.cars.isEmpty { values.append(Display.consistSummary(consist.cars)) }
		if values.count > beforeCars, Display.freshness(consist.updatedAt, now: now) != .live { values.append("last reported") }
	}
	if options.fields.contains(.location), !row.location.isEmpty { values.append(row.location) }
	return values.joined(separator: " · ")
}

public struct WidgetPreferences: Codable, Sendable, Equatable {
	public var display: WidgetDisplayOptions
	public var lockScreen: LockScreenWidgetOptions
	public var matchAppFilters: Bool
	public var stations: [String: StationPreference]
	public init(matchAppFilters: Bool = false, stations: [String: StationPreference] = [:], display: WidgetDisplayOptions = WidgetDisplayOptions(), lockScreen: LockScreenWidgetOptions = LockScreenWidgetOptions()) {
		self.matchAppFilters = matchAppFilters; self.stations = stations; self.display = display; self.lockScreen = lockScreen
	}
	private enum CodingKeys: String, CodingKey { case matchAppFilters, stations, display, lockScreen }
	public init(from decoder: Decoder) throws {
		let values = try decoder.container(keyedBy: CodingKeys.self)
		display = try values.decodeIfPresent(WidgetDisplayOptions.self, forKey: .display) ?? WidgetDisplayOptions()
		lockScreen = try values.decodeIfPresent(LockScreenWidgetOptions.self, forKey: .lockScreen) ?? (values.contains(.display) ? LockScreenWidgetOptions(legacyDisplay: display) : LockScreenWidgetOptions())
		matchAppFilters = try values.decodeIfPresent(Bool.self, forKey: .matchAppFilters) ?? false
		stations = try values.decodeIfPresent([String: StationPreference].self, forKey: .stations) ?? [:]
	}
	public func preference(for stationID: String, app: [String: StationPreference]) -> StationPreference {
		var value = matchAppFilters ? app[stationID] ?? StationPreference() : stations[stationID] ?? StationPreference(view: .direction)
		value.direction = "ALL"
		return value
	}
}

public struct WidgetCoordinate: Codable, Sendable, Equatable {
	public var latitude: Double
	public var longitude: Double
	public var timestamp: TimeInterval
	public init(latitude: Double, longitude: Double, timestamp: TimeInterval = Date().timeIntervalSince1970) {
		self.latitude = latitude; self.longitude = longitude; self.timestamp = timestamp
	}
	public var isValid: Bool { latitude.isFinite && longitude.isFinite && abs(latitude) <= 90 && abs(longitude) <= 180 }
	/// Reuse the extension's five-minute ceiling for every location source.
	/// Future or nonfinite timestamps must not outrank a real location fix.
	public func isUsable(now: TimeInterval) -> Bool {
		isValid && timestamp.isFinite && now.isFinite && timestamp <= now && now - timestamp < 300
	}
	public static func newestUsable(in coordinates: [WidgetCoordinate?], now: TimeInterval) -> WidgetCoordinate? {
		coordinates.compactMap { $0 }.filter { $0.isUsable(now: now) }.max { $0.timestamp < $1.timestamp }
	}
	private func distance(to station: Station) -> Double {
		let radians = Double.pi / 180
		let a = latitude * radians, b = station.lat * radians
		let value = pow(sin((b - a) / 2), 2) + cos(a) * cos(b) * pow(sin((station.lon - longitude) * radians / 2), 2)
		return 2 * asin(sqrt(min(1, max(0, value))))
	}
	public func closer(_ left: Station, than right: Station) -> Bool { distance(to: left) < distance(to: right) }
}

/// The app owns this snapshot. Widget refreshes never rewrite app settings.
public struct WidgetSharedState: Codable, Sendable, Equatable {
	public var favorites: [String]
	public var stations: [Station]
	public var appFilters: [String: StationPreference]
	public var widgets: WidgetPreferences
	public var themeID: String
	public var endpoint: String
	public var appLocation: WidgetCoordinate?
	public init(favorites: [String] = [], stations: [Station] = [], appFilters: [String: StationPreference] = [:], widgets: WidgetPreferences = WidgetPreferences(), themeID: String = "subway", endpoint: String = TransitAPI.productionBaseURL.absoluteString, appLocation: WidgetCoordinate? = nil) {
		self.favorites = favorites; self.stations = stations; self.appFilters = appFilters
		self.widgets = widgets; self.themeID = themeID; self.endpoint = endpoint; self.appLocation = appLocation
	}
	public func selectedStation(location: WidgetCoordinate?, previous: String?, now: TimeInterval = Date().timeIntervalSince1970) -> Station? {
		let candidates = favorites.compactMap { id in stations.first { $0.id == id } }
		if let location = WidgetCoordinate.newestUsable(in: [location, appLocation], now: now) {
			return candidates.min { location.closer($0, than: $1) }
		}
		return candidates.first { $0.id == previous } ?? candidates.first
	}
}

/// Select the soonest trains in each direction before arranging them into the
/// requested groups. A crowded northbound board cannot consume southbound space.
public func widgetDepartures(_ board: Board, preference: StationPreference, limit: Int, now: TimeInterval, cached: Bool = false) -> [DepartureGroup] {
	var filtered = board
	filtered.departures = board.departures.filter {
		Display.boardable($0) && (preference.routes.isEmpty || preference.routes.contains(Display.displayRoute($0.route))) &&
		(cached || Display.freshness($0.timestamp, now: now) != .live || ($0.time ?? .infinity) >= now - 30)
	}
	let selected = Dictionary(grouping: filtered.departures, by: \.direction).values.flatMap { departures in
		departures.sorted {
			let a = $0.time ?? .infinity, b = $1.time ?? .infinity
			return a == b ? $0.key < $1.key : a < b
		}.prefix(max(0, limit))
	}
	filtered.departures = Array(selected)
	return groupDepartures(filtered, direction: "ALL", order: preference.view, now: now, cached: cached)
}

/// Local timeline transitions keep rounded minutes and departed trains current
/// without consuming a network refresh. Source expiry always ends live estimates.
public func widgetTimelineDates(_ board: Board, now: TimeInterval) -> [TimeInterval] {
	guard let expiry = board.departures.map({ $0.timestamp + 91 }).filter({ $0 > now }).min() else { return [] }
	var dates: Set<TimeInterval> = [expiry]
	for row in board.departures {
		guard let arrival = row.time else { continue }
		if arrival > now {
			var boundary = arrival - floor((arrival - now) / 60) * 60 + 1
			while boundary > now && boundary < expiry { dates.insert(boundary); boundary += 60 }
		}
		let gone = arrival + 31
		if gone > now && gone < expiry { dates.insert(gone) }
	}
	return dates.sorted()
}

public enum WidgetLink {
	public static func board(stationID: String) -> URL {
		var components = URLComponents()
		components.scheme = "subwaynerds"; components.host = "board"
		components.queryItems = [URLQueryItem(name: "station", value: stationID)]
		return components.url!
	}
	public static func stationID(from url: URL) -> String? {
		guard url.scheme == "subwaynerds", url.host == "board", let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
			let id = components.queryItems?.first(where: { $0.name == "station" })?.value, !id.isEmpty else { return nil }
		return id
	}
}

/// Atomic, coordinated files support the app and extension in separate processes.
/// The app writes state; both processes may save boards, without replacing newer data.
public struct WidgetSharedStore: Sendable {
	public static let kind = "ClosestFavoriteBoard"
	public static func configured() -> WidgetSharedStore? {
		let identifier = Bundle.main.object(forInfoDictionaryKey: "WidgetAppGroupIdentifier") as? String ?? "group.nyc.juliet.subwaysfornerds"
		guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else { return nil }
		return WidgetSharedStore(directory: container.appendingPathComponent("Widgets", isDirectory: true))
	}
	public let directory: URL
	public init(directory: URL) { self.directory = directory }
	public struct Selection: Codable, Sendable, Equatable {
		public let stationID: String
		public let location: WidgetCoordinate?
		public let savedAt: TimeInterval
	}
	private struct CachedBoard: Codable { let board: Board; let endpoint: String }
	public func load() throws -> WidgetSharedState { try read(WidgetSharedState.self, name: "state.json") }
	public func save(_ state: WidgetSharedState) throws { try write(state, name: "state.json") }
	public func board(stationID: String, endpoint: String = TransitAPI.productionBaseURL.absoluteString) -> Board? {
		guard let saved = try? read(CachedBoard.self, name: boardName(stationID)), saved.endpoint == endpoint else { return nil }
		return saved.board
	}
	public func saveBoard(_ board: Board, endpoint: String = TransitAPI.productionBaseURL.absoluteString) throws {
		try coordinate(name: boardName(board.station.id)) { url in
			if let previous = self.board(stationID: board.station.id, endpoint: endpoint), previous.generatedAt > board.generatedAt { return }
			try encode(CachedBoard(board: board, endpoint: endpoint), at: url)
		}
	}
	public func selection() -> Selection? { try? read(Selection.self, name: "selection.json") }
	/// Return the winning selection so a slower refresh also renders the newer fix.
	@discardableResult
	public func saveSelection(stationID: String, location: WidgetCoordinate?) throws -> Selection {
		let now = Date().timeIntervalSince1970
		let validLocation = location.flatMap { $0.isValid && $0.timestamp.isFinite && $0.timestamp <= now ? $0 : nil }
		var accepted = Selection(stationID: stationID, location: validLocation, savedAt: now)
		try coordinate(name: "selection.json") { url in
			if let previous = selection(), let saved = previous.location,
				saved.isValid, saved.timestamp.isFinite, saved.timestamp <= Date().timeIntervalSince1970,
				saved.timestamp > (validLocation?.timestamp ?? -.infinity) {
				accepted = previous
				return
			}
			try encode(accepted, at: url)
		}
		return accepted
	}
	private func boardName(_ id: String) -> String { "board-" + Data(id.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_") + ".json" }
	private func read<T: Decodable>(_ type: T.Type, name: String) throws -> T {
		try JSONDecoder().decode(type, from: Data(contentsOf: directory.appendingPathComponent(name)))
	}
	private func write<T: Encodable>(_ value: T, name: String) throws { try coordinate(name: name) { try encode(value, at: $0) } }
	private func encode<T: Encodable>(_ value: T, at url: URL) throws {
		#if os(iOS)
		try JSONEncoder().encode(value).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
		#else
		try JSONEncoder().encode(value).write(to: url, options: .atomic)
		#endif
	}
	private func coordinate(name: String, operation: (URL) throws -> Void) throws {
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		var coordinationError: NSError?
		var operationError: Error?
		NSFileCoordinator().coordinate(writingItemAt: directory.appendingPathComponent(name), options: .forReplacing, error: &coordinationError) { url in
			do { try operation(url) } catch { operationError = error }
		}
		if let error = coordinationError ?? operationError as NSError? { throw error }
	}
}
