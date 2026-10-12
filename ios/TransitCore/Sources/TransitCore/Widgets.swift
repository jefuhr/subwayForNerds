import Foundation
import CryptoKit

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
	if options.fields.contains(.location) {
		if let position = row.vehiclePosition {
			if let current = Display.currentVehiclePositions([position], now: now).first { values.append(Display.vehiclePositionLabel(current, now: now, cached: cached)) }
		} else if !row.feed.hasPrefix("njt-"), !row.location.isEmpty { values.append(row.location + (cached ? " · last reported" : "")) }
	}
	return values.joined(separator: " · ")
}

public struct WidgetPreferences: Codable, Sendable, Equatable {
	public var stationSelection = WidgetStationSelection()
	public var display: WidgetDisplayOptions
	public var lockScreen: LockScreenWidgetOptions
	public var matchAppFilters: Bool
	public var stations: [String: StationPreference]
	public init(matchAppFilters: Bool = false, stations: [String: StationPreference] = [:], display: WidgetDisplayOptions = WidgetDisplayOptions(), lockScreen: LockScreenWidgetOptions = LockScreenWidgetOptions()) {
		self.matchAppFilters = matchAppFilters; self.stations = stations; self.display = display; self.lockScreen = lockScreen
	}
	private enum CodingKeys: String, CodingKey { case matchAppFilters, stations, display, lockScreen, stationSelection }
	public init(from decoder: Decoder) throws {
		let values = try decoder.container(keyedBy: CodingKeys.self)
		display = try values.decodeIfPresent(WidgetDisplayOptions.self, forKey: .display) ?? WidgetDisplayOptions()
		lockScreen = try values.decodeIfPresent(LockScreenWidgetOptions.self, forKey: .lockScreen) ?? (values.contains(.display) ? LockScreenWidgetOptions(legacyDisplay: display) : LockScreenWidgetOptions())
		matchAppFilters = try values.decodeIfPresent(Bool.self, forKey: .matchAppFilters) ?? false
		stations = try values.decodeIfPresent([String: StationPreference].self, forKey: .stations) ?? [:]
		stationSelection = try values.decodeIfPresent(WidgetStationSelection.self, forKey: .stationSelection) ?? WidgetStationSelection()
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
		isValid && timestamp.isFinite && timestamp > 0 && now.isFinite && timestamp <= now && now - timestamp < 300
	}
	public static func newestUsable(in coordinates: [WidgetCoordinate?], now: TimeInterval) -> WidgetCoordinate? {
		coordinates.compactMap { $0 }.filter { $0.isUsable(now: now) }.max { $0.timestamp < $1.timestamp }
	}
	public func distanceMeters(to station: Station) -> Double {
		let parts = station.parts.filter { WidgetCoordinate(latitude: $0.lat, longitude: $0.lon).isValid }
		let points = parts.isEmpty ? [(station.lat, station.lon)] : parts.map { ($0.lat, $0.lon) }
		return points.filter { WidgetCoordinate(latitude: $0.0, longitude: $0.1).isValid }.map {
			Display.distanceMeters(lat1: latitude, lon1: longitude, lat2: $0.0, lon2: $0.1)
		}.min() ?? .infinity
	}
	public func closer(_ left: Station, than right: Station) -> Bool { distanceMeters(to: left) < distanceMeters(to: right) }
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
	public var stationSelection: StationSelection
	public var units: UnitPreferences
	public var offline: OfflinePreferences
	public init(favorites: [String] = [], stations: [Station] = [], appFilters: [String: StationPreference] = [:], widgets: WidgetPreferences = WidgetPreferences(), themeID: String = "subway", endpoint: String = TransitAPI.productionBaseURL.absoluteString, appLocation: WidgetCoordinate? = nil, stationSelection: StationSelection = StationSelection(), units: UnitPreferences = UnitPreferences(), offline: OfflinePreferences = OfflinePreferences()) {
		self.favorites = favorites; self.stations = stations; self.appFilters = appFilters
		self.widgets = widgets; self.themeID = themeID; self.endpoint = endpoint; self.appLocation = appLocation
		self.stationSelection = stationSelection; self.units = units
		self.offline = offline
	}
	private enum CodingKeys: String, CodingKey { case favorites, stations, appFilters, widgets, themeID, endpoint, appLocation, stationSelection, units, offline }
	public init(from decoder: Decoder) throws {
		let values = try decoder.container(keyedBy: CodingKeys.self)
		favorites = try values.decode([String].self, forKey: .favorites)
		stations = try values.decode([Station].self, forKey: .stations)
		appFilters = try values.decode([String: StationPreference].self, forKey: .appFilters)
		widgets = try values.decode(WidgetPreferences.self, forKey: .widgets)
		themeID = try values.decode(String.self, forKey: .themeID)
		endpoint = try values.decode(String.self, forKey: .endpoint)
		appLocation = try values.decodeIfPresent(WidgetCoordinate.self, forKey: .appLocation)
		stationSelection = try values.decodeIfPresent(StationSelection.self, forKey: .stationSelection) ?? StationSelection()
		units = values.contains(.units) ? try values.decode(UnitPreferences.self, forKey: .units) : UnitPreferences()
		offline = try values.decodeIfPresent(OfflinePreferences.self, forKey: .offline) ?? OfflinePreferences()
	}
	public var effectiveStationSelection: StationSelection { widgets.stationSelection.followApp ? stationSelection : widgets.stationSelection.selection }
	public func selectedStation(location: WidgetCoordinate?, previous: String?, now: TimeInterval = Date().timeIntervalSince1970) -> Station? {
		effectiveStationSelection.select(stations: stations, favorites: favorites, location: WidgetCoordinate.newestUsable(in: [location, appLocation], now: now), previous: previous, now: now)
	}
}

/// Select the soonest trains in each direction before arranging them into the
/// requested groups. A crowded northbound board cannot consume southbound space.
public func widgetDepartures(_ board: Board, preference: StationPreference, limit: Int, now: TimeInterval, cached: Bool = false) -> [DepartureGroup] {
	var filtered = board
	filtered.departures = board.departures.filter {
		Display.boardable($0) && (preference.routes.isEmpty || preference.routes.contains(Display.displayRoute($0.route))) &&
		(cached || Display.freshness($0, now: now) != .live || ($0.time ?? .infinity) >= now - 30)
	}
	let selected = Dictionary(grouping: filtered.departures, by: \.direction).values.flatMap { departures in
		departures.sorted {
			if cached, (($0.time ?? -.infinity) >= now) != (($1.time ?? -.infinity) >= now) { return ($0.time ?? -.infinity) >= now }
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
	guard let expiry = board.departures.map({ $0.timestamp + Display.predictionStaleAfter($0.staleAfter, feed: $0.feed) + 1 }).filter({ $0 > now }).min() else { return [] }
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

/// Saved predictions continue to age while the extension has no network budget.
/// The final entry always expires the original reports, never the HTTP fetch time.
public func widgetOfflineTimelineDates(_ board: Board, now: TimeInterval, maximumAgeMinutes: Int) -> [TimeInterval] {
	guard now.isFinite else { return [] }
	let age = Double(min(120, max(0, maximumAgeMinutes))) * 60
	// No family can show more than 28 rows. Bound transitions before expanding
	// them, so a crowded board cannot evict a visible row's passed/expiry entry.
	let rows = Array(board.departures.filter { $0.timestamp.isFinite && $0.timestamp > 0 && $0.timestamp <= now && $0.timestamp + age >= now }.sorted {
		let left = $0.time ?? -.infinity, right = $1.time ?? -.infinity
		if (left >= now) != (right >= now) { return left >= now }
		return left == right ? $0.key < $1.key : left < right
	}.prefix(28))
	let positions = (board.vehiclePositions ?? []) + rows.compactMap(\.vehiclePosition)
	let positionDates = Display.currentVehiclePositions(positions, now: now).flatMap { [$0.timestamp + 61, $0.timestamp + 301] }.filter { $0 > now }
	let sourceDates = board.njt.flatMap { state -> TimeInterval? in
		guard state.configured, let timestamp = state.predictions.timestamp, timestamp > 0, timestamp <= now else { return nil }
		let expiry = timestamp + Display.predictionStaleAfter(state.predictions.staleAfter, feed: state.predictions.id) + 1
		return expiry > now ? expiry : nil
	}.map { [$0] } ?? []
	guard let end = (rows.map({ $0.timestamp + age + 1 }) + positionDates + sourceDates).max(), end > now else { return [] }
	var dates: Set<TimeInterval> = Set(positionDates + sourceDates + [end])
	for row in rows {
		for boundary in [row.timestamp + Display.predictionStaleAfter(row.staleAfter, feed: row.feed) + 1, row.timestamp + age + 1] where boundary > now { dates.insert(boundary) }
		if let time = row.time, time.isFinite, time + 1 > now, time + 1 < end { dates.insert(time + 1) }
	}
	var minute = floor(now / 60) * 60 + 60
	while minute < end { dates.insert(minute); minute += 60 }
	return dates.sorted()
}

/// A static minute value must remain conservative until the next local entry.
/// Classification (passed/expired) is decided at `now`; only usable minutes are
/// rounded at the end of this interval. Timers, when live, use the exact time.
public func widgetIntervalCountdown(_ value: Countdown, time: TimeInterval?, now: TimeInterval, displayUntil: TimeInterval?) -> Countdown {
	guard value.unit == "min", let time, time.isFinite, let displayUntil, displayUntil.isFinite, displayUntil > now else { return value }
	let seconds = time - max(now, displayUntil - 1)
	return Countdown(value: seconds < 60 ? "<1" : String(Int(floor(seconds / 60))), unit: "min")
}

public enum WidgetLink {
	public static func ride(tripKey: String) -> URL {
		var components = URLComponents()
		components.scheme = "subwaynerds"; components.host = "ride"
		components.queryItems = [URLQueryItem(name: "key", value: tripKey)]
		return components.url!
	}
	public static func tripKey(from url: URL) -> String? {
		guard url.scheme == "subwaynerds", url.host == "ride", let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
			let key = components.queryItems?.first(where: { $0.name == "key" })?.value, !key.isEmpty else { return nil }
		return key
	}
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
	private struct RideEnvelope: Codable { let endpoint: String; let ride: ActiveRide?; let trip: CachedTrip? }
	public func load() throws -> WidgetSharedState { try read(WidgetSharedState.self, name: "state.json") }
	public func save(_ state: WidgetSharedState) throws { try write(state, name: "state.json") }
	public func board(stationID: String, endpoint: String = TransitAPI.productionBaseURL.absoluteString) -> Board? {
		let saved = (try? read(CachedBoard.self, name: boardName(stationID, endpoint: endpoint)))
			?? (try? read(CachedBoard.self, name: legacyBoardName(stationID)))
		guard let saved, OfflineEndpoint.key(saved.endpoint) == OfflineEndpoint.key(endpoint) else { return nil }
		return saved.board
	}
	/// Returns the merged live board before applying the offline storage quota.
	/// Large live widgets must retain all available rows even with a small cache limit.
	@discardableResult
	public func saveBoard(_ board: Board, endpoint: String = TransitAPI.productionBaseURL.absoluteString) throws -> Board {
		var displayed = board
		try coordinate(name: boardName(board.station.id, endpoint: endpoint)) { url in
			let previous = self.board(stationID: board.station.id, endpoint: endpoint)
			let merged = OfflinePlanner.mergeBoard(board, into: previous)
			displayed = merged.board
			let preferences = (try? load())?.offline ?? OfflinePreferences()
			var saved = OfflinePlanner.retainedBoard(merged.board, preferences: preferences)
			if let previous, !merged.advanced {
				saved.generatedAt = previous.generatedAt
				saved.sources = saved.sources.map { source in
					var source = source
					if let old = previous.sources.first(where: { $0.id == source.id }), old.timestamp == source.timestamp { source.fetchedAt = old.fetchedAt }
					return source
				}
			}
			// The extension renders arrival rows, not complete stop lists or raw alerts.
			// Keep its shared copy small; full trip snapshots live in the app's store.
			saved.alerts = []
			saved.departures = saved.departures.map { row in var row = row; row.onward = []; row.alerts = []; return row }
			guard saved != previous else { return }
			try encode(CachedBoard(board: saved, endpoint: endpoint), at: url)
		}
		return displayed
	}
	public func ride(endpoint: String = TransitAPI.productionBaseURL.absoluteString) -> WidgetRideSnapshot? {
		guard let saved = try? read(RideEnvelope.self, name: "active-ride.json"),
			OfflineEndpoint.key(saved.endpoint) == OfflineEndpoint.key(endpoint), let ride = saved.ride, let trip = saved.trip,
			trip.tripKey == ride.tripKey, OfflineEndpoint.key(trip.endpoint) == OfflineEndpoint.key(endpoint) else { return nil }
		return WidgetRideSnapshot(ride: ride, trip: trip)
	}
	/// App-owned selection. A tombstone prevents a late widget fetch reviving a ride.
	public func saveRide(_ ride: ActiveRide?, trip: CachedTrip?, endpoint: String = TransitAPI.productionBaseURL.absoluteString) throws {
		try coordinate(name: "active-ride.json") { url in
			guard let ride, let trip, ride.tripKey == trip.tripKey, OfflineEndpoint.key(trip.endpoint) == OfflineEndpoint.key(endpoint) else {
				try encode(RideEnvelope(endpoint: endpoint, ride: nil, trip: nil), at: url); return
			}
			if let previous = self.ride(endpoint: endpoint), previous.ride == ride,
				(previous.trip.sourceTimestamp ?? 0) > (trip.sourceTimestamp ?? 0) || (previous.trip.isComplete && !trip.isComplete) { return }
			try encode(RideEnvelope(endpoint: endpoint, ride: ride, trip: WidgetRideSnapshot(ride: ride, trip: trip).trip), at: url)
		}
	}
	/// Both processes coordinate on the selection file and compare the full ride ID.
	@discardableResult public func updateRideTrip(_ trip: CachedTrip, for ride: ActiveRide, endpoint: String) throws -> Bool {
		var updated = false
		try coordinate(name: "active-ride.json") { url in
			guard let current = self.ride(endpoint: endpoint), current.ride == ride,
				trip.tripKey == ride.tripKey, OfflineEndpoint.key(trip.endpoint) == OfflineEndpoint.key(endpoint),
				!current.trip.isComplete || trip.isComplete,
				(trip.sourceTimestamp ?? 0) >= (current.trip.sourceTimestamp ?? 0) else { return }
			try encode(RideEnvelope(endpoint: endpoint, ride: ride, trip: WidgetRideSnapshot(ride: ride, trip: trip).trip), at: url)
			updated = true
		}
		return updated
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
	private func legacyBoardName(_ id: String) -> String { "board-" + Data(id.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_") + ".json" }
	private func boardName(_ id: String, endpoint: String) -> String {
		let identity = OfflineEndpoint.key(endpoint) + "\u{0}" + id
		return "board-" + SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
	}
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
