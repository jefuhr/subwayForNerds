import CoreLocation
#if canImport(CoreTelephony) && os(iOS)
import CoreTelephony
#endif
import Foundation
import Network
import Observation
import TransitCore
import FleetOffline
import WidgetKit

private struct SavedPreferences: Codable {
	var stationID = "602"
	var favorites: [String] = []
	var recent: [String] = []
	var theme = "subway"
	var stations: [String: StationPreference] = [:]
	var endpoint: String?
}

/// Settings screens other tabs can push, such as System status from the offline card.
enum SettingsDestination: Hashable {
	case systemStatus
}

@MainActor @Observable
final class AppModel {
	var stations: [Station] = []
	var stationID: String
	var favorites: [String]
	var trainFavorites: TrainFavorites
	var stationSelection: StationSelection
	var units: UnitPreferences
	var themeID: String
	var stationPreferences: [String: StationPreference]
	var combinedStations: [String: CombinedStation]
	var hiddenRoutes: [String]
	var transferPreferences: TransferPreferences
	var departureRows = DepartureRowSettings()
	var combinedBoard: CombinedBoardSnapshot?
	private var memberBoards: [String: MemberBoardSnapshot] = [:]
	var settingsError: String?
	var pendingSettingsImport: NerdsSettingsFile?
	var settingsSync: SettingsSyncState?
	@ObservationIgnored var settingsDidChange: (() -> Void)?
	var widgetPreferences: WidgetPreferences
	@ObservationIgnored let widgetStore: WidgetSharedStore?
	@ObservationIgnored private var lastWidgetReload: TimeInterval = 0
	@ObservationIgnored private var widgetLocation: WidgetCoordinate?
	@ObservationIgnored private let widgetReloadEnabled: Bool
	@ObservationIgnored private var durableSettings: PortableSettings?
	var board: Board?
	var boardIsCached = true
	var boardError: String?
	var catalogError: String?
	var now = Date().timeIntervalSince1970
	var selectedTab = 0
	/// Screens pushed over Settings by value, so other tabs can open one.
	var settingsPath: [SettingsDestination] = []
	var nearbyLocation: CLLocation?
	var locationError: String?
	var locating = false
	var connected = true
	/// What the phone's network path is doing, shown wherever the app explains being offline.
	private(set) var deviceNetworkStatus = DeviceNetworkStatus(state: .connecting)
	/// Prefetcher fetches running now, and every board and trip it keeps current.
	private(set) var fetchesInFlight = 0
	private(set) var trackedFetches: [OfflineFetchTarget] = []
	var offlineManifest: FleetOfflineManifest?
	var availablePack: FleetPackManifest?
	var fleetPackSelection = FleetPackSelection()
	var fleetPackFacets = FleetFacets()
	var fleetPackFacetsError: String?
	var isPreparingFleetPack = false
	/// The pack job while the server prepares it; nil until the request is accepted.
	var fleetPackJob: FleetPackJob?
	var fleetDownload: FleetDownloadProgress?
	var downloadError: String?
	var useSavedFleet = false
	var endpoint: String
	var api: TransitAPI
	let offlineStore: OfflineFleetStore?
	var offlinePreferences: OfflinePreferences
	/// When the displayed board came from the offline cache, the time it was saved.
	var boardSavedAt: TimeInterval?
	var activeRide: ActiveRide?
	var activeRideTrip: CachedTrip?
	var savedTrips: [CachedTrip] = []
	var offlineUsage: OfflineStorageUsage?
	/// The latest System status reading; nil until that screen first measures.
	private(set) var systemStatus: SystemStatusSnapshot?
	/// The installed bundle cannot change while the app runs, so it is measured once.
	@ObservationIgnored private var appBundleBytes: Int64?
	/// Steps of the first storage check, while the Offline screen has no usage to show yet.
	var storageCheck: LoadProgress?
	@ObservationIgnored private var storageCheckToken: UUID?
	/// Byte progress of board and trip downloads a screen is waiting on.
	var fetchProgress: [OfflineFetchTarget: TransferProgress] = [:]
	@ObservationIgnored private var fetchTokens: [OfflineFetchTarget: UUID] = [:]
	/// Saves that could not be written. Shown until the user dismisses them.
	var offlineFailures: [OfflineSaveFailure] = []
	var offlineActionError: String?
	/// A trip to open on the board tab, independent of the selected station.
	var openTripKey: String?
	/// Latest fetched details for trips whose details are open, kept after the
	/// connection drops so a save or ride can use them.
	var liveTrips: [String: LiveTrip] = [:]
	@ObservationIgnored private var openTrips: [String: Int] = [:]
	/// Trips fetched as automatic next-trip snapshots, stored regardless of "save opened trips".
	@ObservationIgnored private var snapshotKeys = Set<String>()
	/// Outage simulation keeps the same endpoint so its cache stays in use.
	private(set) var outageSimulated = false
	@ObservationIgnored let transitStore: OfflineTransitStore?
	@ObservationIgnored private var prefetcher: OfflinePrefetcher?
	@ObservationIgnored private var apiBeforeOutage: TransitAPI?
	@ObservationIgnored private var restoreTask: Task<Void, Never>?
	@ObservationIgnored private var networkConnected = true
	@ObservationIgnored private var networkPath: NetworkPathSnapshot?
	/// True while the first refresh after the path returned is still running.
	@ObservationIgnored private var reconnecting = false
	@ObservationIgnored private var reconnectGeneration = 0
	#if canImport(CoreTelephony) && os(iOS)
	@ObservationIgnored private var telephony: CTTelephonyNetworkInfo?
	#endif
	/// Next-trip keys of favorite and nearby boards, kept only when other-station trips are preloaded.
	@ObservationIgnored private var surroundingTrips: [String: [String]] = [:]
	@ObservationIgnored private var recent: [String]
	@ObservationIgnored private let directory: URL
	@ObservationIgnored private let locator = LocationProvider()
	@ObservationIgnored private let network = NWPathMonitor()
	@ObservationIgnored private var networkStarted = false
	@ObservationIgnored private var active = false
	@ObservationIgnored private var activeGeneration = 0
	@ObservationIgnored private var boardGeneration = 0
	@ObservationIgnored private var catalogGeneration = 0
	@ObservationIgnored private var favoriteStartupAttempted = false
	@ObservationIgnored private var closestFavoriteTask: Task<CLLocation?, Never>?
	@ObservationIgnored private var locationTask: Task<CLLocation, Error>?
	@ObservationIgnored private var locationGeneration = 0
	@ObservationIgnored private let locationRequest: (@MainActor @Sendable () async throws -> CLLocation)?
	/// Observed, so screens showing `isDownloading` redraw the moment a fleet download starts or ends.
	private var downloadTask: Task<Void, Never>?
	@ObservationIgnored private var downloadGeneration: UUID?
	@ObservationIgnored private var lastCatalogAttempt: TimeInterval = 0
	@ObservationIgnored private let fixedNow: TimeInterval?
	@ObservationIgnored private let locationDisabled: Bool
	#if DEBUG
	@ObservationIgnored private let testLocation: CLLocation?
	#endif

	init(stateDirectory: URL? = nil, locationRequest: (@MainActor @Sendable () async throws -> CLLocation)? = nil) {
		self.locationRequest = locationRequest
		directory = stateDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("SubwaysForNerds", isDirectory: true)
		widgetStore = stateDirectory.map { WidgetSharedStore(directory: $0.appendingPathComponent("Widgets")) } ?? WidgetSharedStore.configured()
		widgetReloadEnabled = stateDirectory == nil
		#if DEBUG
		let environment = ProcessInfo.processInfo.environment
		if environment["SFN_RESET_STATE"] == "1" { try? FileManager.default.removeItem(at: directory) }
		if environment["SFN_RESET_STATE"] == "1", let widgetStore { try? FileManager.default.removeItem(at: widgetStore.directory) }
		fixedNow = environment["SFN_TEST_NOW"].flatMap(Double.init)
		locationDisabled = environment["SFN_DISABLE_LOCATION"] == "1"
		let coordinates = environment["SFN_TEST_LOCATION"]?.split(separator: ",").compactMap { Double($0) } ?? []
		if coordinates.count == 2, CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: coordinates[0], longitude: coordinates[1])) {
			testLocation = CLLocation(latitude: coordinates[0], longitude: coordinates[1])
		} else { testLocation = nil }
		#else
		fixedNow = nil
		locationDisabled = false
		#endif
		now = fixedNow ?? Date().timeIntervalSince1970
		try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let preferencesURL = directory.appendingPathComponent("preferences.json")
		let saved = (try? Data(contentsOf: preferencesURL)).flatMap { try? JSONDecoder().decode(SavedPreferences.self, from: $0) } ?? SavedPreferences()
		let portable = try? DeviceSettingsStore(fileURL: directory.appendingPathComponent("settings.json")).load()
		stationID = portable?.lastStation ?? saved.stationID
		favorites = portable?.settings.favorites ?? saved.favorites
		trainFavorites = portable?.settings.trainFavorites ?? TrainFavorites()
		stationSelection = portable?.settings.stationSelection ?? StationSelection()
		units = portable?.settings.units ?? UnitPreferences()
		recent = portable?.recent ?? saved.recent
		themeID = portable?.settings.theme ?? (AppTheme.all.contains(where: { $0.id == saved.theme }) ? saved.theme : "subway")
		stationPreferences = portable?.settings.stations ?? saved.stations
		combinedStations = portable?.settings.combinedStations ?? [:]
		hiddenRoutes = portable?.settings.hiddenRoutes ?? []
		transferPreferences = portable?.settings.transfers ?? TransferPreferences()
		departureRows = portable?.settings.departureRows ?? DepartureRowSettings()
		widgetPreferences = portable?.settings.widgets ?? Self.read(WidgetPreferences.self, at: directory.appendingPathComponent("widgets.json")) ?? WidgetPreferences()
		offlinePreferences = portable?.settings.offline ?? OfflinePreferences()
		settingsSync = portable?.sync
		#if DEBUG
		let base = environment["SFN_API_BASE_URL"].flatMap(URL.init(string:)) ?? (portable?.endpoint ?? saved.endpoint).flatMap(URL.init(string:)) ?? TransitAPI.productionBaseURL
		#else
		let base = TransitAPI.productionBaseURL
		#endif
		endpoint = base.absoluteString
		api = TransitAPI(baseURL: base)
		offlineStore = try? OfflineFleetStore(directory: directory.appendingPathComponent("FleetDownload", isDirectory: true))
		transitStore = OfflineTransitStore(directory: directory.appendingPathComponent("OfflineTransit", isDirectory: true))
		stations = Self.read([Station].self, at: directory.appendingPathComponent("stations.json")) ?? []
		#if DEBUG
		// Same-endpoint outage for tests; SFN_TEST_OFFLINE is the UI-test spelling.
		outageSimulated = environment["SFN_SIMULATE_OUTAGE"] == "1" || environment["SFN_TEST_OFFLINE"] == "1"
		#endif
		widgetLocation = (try? widgetStore?.load())?.appLocation
		// Legacy board files have no endpoint; they only ever came from production.
		if Self.isProduction(endpoint) {
			for id in Set(favorites + [stationID]) {
				if let board = Self.read(Board.self, at: Self.boardURL(directory: directory, id: id)) { _ = try? widgetStore?.saveBoard(board, endpoint: endpoint) }
			}
		}
		durableSettings = portableSettings
		if !FileManager.default.fileExists(atPath: directory.appendingPathComponent("settings.json").path) { persist() }
		else if portable == nil { settingsError = "Saved settings could not be read. Restore a .nerds backup to recover your preferences." }
		#if DEBUG
		if let encoded = environment["SFN_TEST_SETTINGS_FILE"], let data = Data(base64Encoded: encoded) {
			let url = directory.appendingPathComponent("test-settings.nerds")
			do { try data.write(to: url, options: .atomic); previewSettingsFile(url) }
			catch { settingsError = error.localizedDescription }
		}
		#endif
		syncWidgets(reload: true)
		if outageSimulated { beginSimulatedOutage(); connected = false; deviceNetworkStatus = DeviceNetworkStatus(state: .simulatedOutage) }
		prefetcher = makePrefetcher()
		restoreTask = Task { await restoreOffline() }
	}

	var allStations: [Station] {
		stations + combinedStations.keys.sorted().compactMap { id in
			guard let value = combinedStations[id] else { return nil }
			return CombinedStationResolver.station(id: id, name: value.name, stationIDs: value.stationIDs, catalog: stations)
		}
	}
	var visibleStations: [Station] {
		let visible = stations.compactMap { LineVisibility.station($0, hiddenRoutes: hiddenRoutes) }
		return visible + combinedStations.keys.sorted().compactMap { id in
			guard let value = combinedStations[id] else { return nil }
			return CombinedStationResolver.station(id: id, name: value.name, stationIDs: value.stationIDs, catalog: visible)
		}
	}
	var station: Station? { board?.station ?? allStations.first { $0.id == stationID } }
	var displayBoard: Board? { board.map { LineVisibility.board($0, hiddenRoutes: hiddenRoutes) } }
	var cachedDepartureKeys: Set<String>? { combinedBoard.map { !connected ? Set($0.board.departures.map(\.key)) : $0.cachedDepartureKeys } }
	var selectedMemberIDs: [String] { combinedStations[stationID]?.stationIDs ?? [stationID] }
	func departureOrigin(_ key: String) -> DepartureOrigin? {
		if let origin = combinedBoard?.origins[key] { return origin }
		guard combinedBoard == nil, let board, let departure = board.departures.first(where: { $0.key == key }) else { return nil }
		return DepartureOrigin(station: board.station, departure: departure, cached: boardIsCached, savedAt: boardSavedAt)
	}
	/// Where a trip boards on the selected board right now, captured by train details
	/// before another station is selected.
	func boardOrigin(forTrip key: String) -> DepartureOrigin? {
		board?.departures.first { $0.tripKey == key }.flatMap { departureOrigin($0.key) }
	}
	func departureIsCached(_ key: String) -> Bool { !connected || (combinedBoard?.origins[key]?.cached ?? boardIsCached) }
	func realStationIDs(_ ids: [String]) -> [String] { Array(Set(ids.flatMap { combinedStations[$0]?.stationIDs ?? [$0] })).sorted() }
	var theme: AppTheme { AppTheme.all.first { $0.id == themeID } ?? AppTheme.all[0] }
	var preference: StationPreference { stationPreferences[stationID] ?? StationPreference(view: combinedStations[stationID] == nil ? .track : .direction) }
	var favoriteStations: [Station] { favorites.compactMap { id in visibleStations.first { $0.id == id } } }
	var isDownloading: Bool { downloadTask != nil }
	var baseURL: URL { URL(string: endpoint) ?? TransitAPI.productionBaseURL }

	/// Opening a station board from a transfer keeps the current tab, so its navigation
	/// stack can return to that transfer and train.
	func selectStation(_ id: String, switchTab: Bool = true) {
		favoriteStartupAttempted = true
		guard id != stationID else { if switchTab { selectedTab = 0 }; return }
		stationID = id
		boardGeneration += 1
		memberBoards = [:]
		combinedBoard = nil
		if switchTab { selectedTab = 0 }
		board = nil
		boardSavedAt = nil
		boardIsCached = true
		boardError = nil
		recordRecent(id)
		persist()
		Task { await loadCachedBoard(id) }
		planOffline()
	}

	func toggleFavorite(_ id: String) {
		if favorites.contains(id) { favorites.removeAll { $0 == id } } else { favorites.append(id) }
		persist()
		planOffline()
	}
	func toggleFavoriteCar(_ id: String) {
		guard TrainFavorites.validCarID(id) else { return }
		if trainFavorites.cars.contains(id) { trainFavorites.cars.removeAll { $0 == id } } else { trainFavorites.cars.append(id) }
		persist()
	}
	func toggleFavoriteConsist(_ ids: [String]) {
		guard (1...20).contains(ids.count), Set(ids).count == ids.count, ids.allSatisfy(TrainFavorites.validCarID) else { return }
		if trainFavorites.containsConsist(ids) { trainFavorites.consists.removeAll { TrainFavorites.consistKey($0) == TrainFavorites.consistKey(ids) } }
		else { trainFavorites.consists.append(ids.sorted()) }
		persist()
	}
	func setDistanceUnit(_ value: DistanceUnit) { units.distance = value; persist() }
	func setTimeFormat(_ value: TimeFormat) { units.time = value; persist() }
	func setTrainMatch(_ value: TrainFavorites.Match) { trainFavorites.match = value; persist() }
	func setStationSelection(_ value: StationSelection) {
		stationSelection = value
		// A settings change must not let an older startup location request navigate.
		favoriteStartupAttempted = true
		persistWidgetPreferences()
	}
	func setWidgetStationSelection(_ value: WidgetStationSelection) { widgetPreferences.stationSelection = value; persistWidgetPreferences() }

	func setDirection(_ direction: String) {
		var value = preference
		value.direction = direction
		stationPreferences[stationID] = value
		persist()
	}

	func toggleRoute(_ route: String) {
		var value = preference
		if value.routes.contains(route) { value.routes.removeAll { $0 == route } } else { value.routes.append(route) }
		stationPreferences[stationID] = value
		persist()
	}

	func setBoardView(_ view: BoardSortOrder) {
		var value = preference
		value.view = view
		stationPreferences[stationID] = value
		persist()
	}

	func resetFilters() { stationPreferences[stationID] = StationPreference(view: preference.view); persist() }
	func clearRoutes() { var value = preference; value.routes = []; stationPreferences[stationID] = value; persist() }

	/// Transfer filters always name their transfer station explicitly; they never
	/// follow the selected board station.
	func transferFilter(for stationID: String) -> TransferStationPreference { transferSettings.transferFilter(for: stationID) }
	/// Separate mode copies the board filters into a missing entry on first use.
	func ensureTransferFilter(for stationID: String) {
		var settings = transferSettings
		guard settings.seedTransferFilter(for: stationID) else { return }
		transferPreferences = settings.transfers
		persist()
	}
	func setTransferDirection(_ direction: String, for stationID: String) { updateTransferFilter(for: stationID) { $0.direction = direction } }
	func toggleTransferRoute(_ route: String, for stationID: String) { updateTransferFilter(for: stationID) { TransferFilters.toggle(route, in: &$0) } }
	func clearTransferRoutes(for stationID: String) { updateTransferFilter(for: stationID) { $0.routes = [] } }
	func resetTransferFilters(for stationID: String) { updateTransferFilter(for: stationID) { $0 = TransferStationPreference() } }
	func setSeparateTransferFilters(_ value: Bool) { transferPreferences.separateFilters = value; persist() }
	func setShowTrackProvenance(_ value: Bool) { departureRows.showTrackProvenance = value; persist() }
	func setCombinePosition(_ value: Bool) { departureRows.combinePosition = value; persist() }
	func setShowConsist(_ value: Bool) { departureRows.showConsist = value; persist() }
	func setShowHeadway(_ value: Bool) { departureRows.showHeadway = value; persist() }
	private var transferSettings: PortableSettings {
		var value = PortableSettings(); value.stations = stationPreferences; value.transfers = transferPreferences; return value
	}
	private func updateTransferFilter(for stationID: String, _ change: (inout TransferStationPreference) -> Void) {
		var settings = transferSettings
		settings.updateTransferFilter(for: stationID, change)
		stationPreferences = settings.stations; transferPreferences = settings.transfers
		persist()
	}
	func setTheme(_ id: String) { themeID = id; persist() }
	func setWidgetDisplay(_ value: WidgetDisplayOptions) { widgetPreferences.display = value; persistWidgetPreferences() }
	func setWidgetLockScreen(_ value: LockScreenWidgetOptions) { widgetPreferences.lockScreen = value; persistWidgetPreferences() }
	func setWidgetMatchApp(_ value: Bool) {
		widgetPreferences.matchAppFilters = value
		persistWidgetPreferences()
	}
	func setWidgetView(_ view: BoardSortOrder, stationID: String) {
		var value = widgetPreferences.stations[stationID] ?? StationPreference(view: .direction)
		value.view = view
		widgetPreferences.stations[stationID] = value
		persistWidgetPreferences()
	}
	func toggleWidgetRoute(_ route: String, stationID: String) {
		let value = widgetPreferences.stations[stationID] ?? StationPreference(view: .direction)
		setWidgetRoute(route, enabled: !value.routes.contains(route), stationID: stationID)
	}
	func setWidgetRoute(_ route: String, enabled: Bool, stationID: String) {
		var value = widgetPreferences.stations[stationID] ?? StationPreference(view: .direction)
		guard value.routes.contains(route) != enabled else { return }
		if enabled { value.routes.append(route) } else { value.routes.removeAll { $0 == route } }
		widgetPreferences.stations[stationID] = value
		persistWidgetPreferences()
	}
	func clearWidgetRoutes(stationID: String) {
		var value = widgetPreferences.stations[stationID] ?? StationPreference(view: .direction)
		value.routes = []
		widgetPreferences.stations[stationID] = value
		persistWidgetPreferences()
	}
	private func persistWidgetPreferences() {
		persist()
		syncWidgets(reload: true)
	}
	func openWidgetURL(_ url: URL) {
		if let key = WidgetLink.tripKey(from: url) {
			// A ride link opens its trip without changing the selected station.
			favoriteStartupAttempted = true
			selectedTab = 0
			openTripKey = key
			return
		}
		guard let id = WidgetLink.stationID(from: url), combinedStations[id] != nil || stations.contains(where: { $0.id == id }) || (!id.hasPrefix("combined:") && favorites.contains(id)) else { return }
		selectStation(id)
	}

	func setEndpoint(_ value: String) throws {
		let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
		guard let url = URL(string: cleaned), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
			  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
			throw AppError.message("Enter a complete HTTP or HTTPS API URL, including its /api/v1/ path.")
		}
		endpoint = url.absoluteString.hasSuffix("/") ? url.absoluteString : url.absoluteString + "/"
		boardGeneration += 1
		catalogGeneration += 1
		memberBoards = [:]
		combinedBoard = nil
		api = TransitAPI(baseURL: URL(string: endpoint)!)
		apiBeforeOutage = nil
		if outageSimulated { beginSimulatedOutage() }
		boardIsCached = true
		cancelDownload()
		availablePack = nil
		fleetPackFacets = FleetFacets()
		lastCatalogAttempt = 0
		persist()
		// Cached content belongs to one endpoint; restore this endpoint's ride and boards.
		board = nil; boardSavedAt = nil; activeRide = nil; activeRideTrip = nil; savedTrips = []; surroundingTrips = [:]; liveTrips = [:]
		planOffline()
		Task {
			await restoreOffline()
			planOffline()
			await refreshCatalog(); await refreshBoard()
		}
	}

	func suspend(background: Bool) {
		active = false
		activeGeneration += 1
		// Prefetch is foreground-only; the active ride stays saved for the next visit.
		Task {
			await prefetcher?.setForeground(false)
			if background { try? await transitStore?.flushAccessTimes() }
		}
		if background {
			// A new foreground visit should start at the nearest favorite again.
			// Inactive transitions (including the location prompt) are still the same visit.
			favoriteStartupAttempted = false
			closestFavoriteTask?.cancel()
			closestFavoriteTask = nil
			locationGeneration += 1
			locationTask?.cancel()
			locationTask = nil
			locator.cancel()
		}
	}

	func runWhileActive() async {
		activeGeneration += 1
		let generation = activeGeneration
		active = true
		defer { if activeGeneration == generation { active = false } }
		if !networkStarted {
			networkStarted = true
			network.pathUpdateHandler = { [weak self] path in
				let connected = path.status == .satisfied
				let snapshot = NetworkPathSnapshot(path)
				Task { @MainActor [weak self] in
					guard let self else { return }
					self.networkConnected = connected
					self.networkPath = snapshot
					await self.connectionChanged()
				}
			}
			network.start(queue: DispatchQueue(label: "nyc.juliet.subways.network"))
		}
		offlineManifest = await offlineStore?.manifest()
		await restoreTask?.value
		await expireOfflineEntries()
		await prefetcher?.setConnected(connected)
		await prefetcher?.setForeground(true)
		planOffline()
		await withTaskGroup(of: Void.self) { group in
			group.addTask { await self.clockLoop() }
			group.addTask { await self.loadInitialCatalog() }
			group.addTask { await self.widgetLocationLoop() }
		}
	}

	private func clockLoop() async {
		while !Task.isCancelled {
			now = fixedNow ?? Date().timeIntervalSince1970
			do { try await Task.sleep(for: .seconds(1)) } catch { return }
		}
	}
	private func loadInitialCatalog() async {
		async let catalog: Void = refreshCatalog()
		// Cached favorites can be selected without waiting for the network.
		await openClosestFavoriteOnce()
		await catalog
	}
	private func widgetLocationLoop() async {
		while !Task.isCancelled {
			await refreshWidgetLocation()
			do { try await Task.sleep(for: .seconds(30)) } catch { return }
		}
	}
	func refreshWidgetLocation() async {
		// Keep the widget's closest favorite current while the app is in use,
		// without moving a manually selected board or prompting in the background.
		let selection = widgetPreferences.stationSelection.followApp ? stationSelection : widgetPreferences.stationSelection.selection
		guard active, !Task.isCancelled, !locationDisabled, selection.mode != .favorite || !favorites.isEmpty,
			locator.isAuthorized || locationRequest != nil else { return }
		_ = try? await currentLocation()
	}

	func refreshCatalog() async {
		let attempt = Date().timeIntervalSinceReferenceDate
		guard attempt - lastCatalogAttempt > 5 else { return }
		lastCatalogAttempt = attempt
		catalogGeneration += 1
		let generation = catalogGeneration
		let requestedEndpoint = endpoint
		do {
			let value = try await api.stations()
			try Task.checkCancellation()
			guard generation == catalogGeneration, requestedEndpoint == endpoint else { return }
			stations = value
			rebuildCombinedBoard()
			Self.write(value, at: directory.appendingPathComponent("stations.json"))
			syncWidgets(reload: true)
			catalogError = nil
			// Favorites without a saved catalog become resolvable after this refresh.
			if active { await openClosestFavoriteOnce() }
		} catch {
			if !Task.isCancelled, generation == catalogGeneration, requestedEndpoint == endpoint { catalogError = "Station catalog unavailable. Saved stations remain available; reconnect to load every station." }
		}
	}

	/// Fetches the selected board now, ahead of automatic work. It joins a matching
	/// fetch already queued or in flight, and returns at once without a connection.
	func refreshBoard() async {
		if combinedStations[stationID] != nil {
			let id = stationID
			await loadCachedBoard(id)
			guard let prefetcher else { return }
			let requestedEndpoint = endpoint
			let members = selectedMemberIDs.filter { member in stations.contains { $0.id == member && $0.departureMode != "external" } }
			await withTaskGroup(of: Void.self) { group in
				for member in members {
					group.addTask { _ = await prefetcher.request(OfflineFetchRequest(endpoint: requestedEndpoint, target: .board(stationID: member), priority: .explicit)) }
				}
			}
			if id == stationID, requestedEndpoint == endpoint { rebuildCombinedBoard() }
			return
		}
		guard station?.departureMode != "external" || board?.njt?.configured == true else { return }
		let id = stationID
		let outcome = await prefetcher?.request(OfflineFetchRequest(endpoint: endpoint, target: .board(stationID: id), priority: .explicit)) ?? .paused
		if outcome == .paused, id == stationID { await showSavedBoard(id, failed: false) }
	}

	/// Fetches a trip now, for opening details or pulling to refresh. Periodic
	/// refreshes of open trips come from the prefetcher's shared cadence.
	@discardableResult
	func refreshTrip(_ key: String) async -> OfflineFetchOutcome {
		await prefetcher?.request(OfflineFetchRequest(endpoint: endpoint, target: .trip(key: key), priority: .explicit)) ?? .paused
	}

	/// Train details register for their whole lifetime, including while the connection
	/// is lost or another view is pushed over them, so their fetched details stay in
	/// memory for saving and the trip refreshes on the selected cadence.
	func openTrip(_ key: String) {
		openTrips[key, default: 0] += 1
		if openTrips[key] == 1 { planOffline() }
	}
	func closeTrip(_ key: String) {
		guard let count = openTrips[key] else { return }
		if count > 1 { openTrips[key] = count - 1; return }
		openTrips[key] = nil
		liveTrips[key] = nil
		planOffline()
	}

	// MARK: - Offline transit cache

	func isTripSaved(_ key: String) -> Bool { savedTrips.contains { $0.tripKey == key } }

	static func isProduction(_ endpoint: String) -> Bool {
		OfflineEndpoint.key(endpoint) == OfflineEndpoint.key(TransitAPI.productionBaseURL.absoluteString)
	}

	/// Applies retention when the app returns, before persisted entries are served.
	/// An expired automatic board on screen is dropped; saved trips and the ride are protected.
	private func expireOfflineEntries() async {
		guard let transitStore else { return }
		let requestedEndpoint = endpoint
		_ = try? await transitStore.evict()
		let id = stationID
		if combinedStations[id] != nil {
			for member in selectedMemberIDs {
				let saved = await transitStore.board(stationID: member, endpoint: requestedEndpoint)
				guard requestedEndpoint == endpoint, id == stationID else { return }
				if memberBoards[member]?.cached == true, memberBoards[member]?.savedAt != nil, saved == nil { memberBoards[member] = nil }
			}
			rebuildCombinedBoard()
			await reloadOfflineStatus()
			return
		}
		let stillSaved = await transitStore.board(stationID: id, endpoint: requestedEndpoint) != nil
		guard requestedEndpoint == endpoint, id == stationID else { return }
		if boardIsCached, boardSavedAt != nil, !stillSaved { board = nil; boardSavedAt = nil }
		await reloadOfflineStatus()
	}

	/// The age offline estimates are based on: the oldest prediction on the board,
	/// never an alerts or car-assignment feed that updates more often.
	static func predictionSourceTimestamp(_ board: Board) -> TimeInterval? {
		if let oldest = board.departures.map(\.timestamp).filter({ $0 > 0 }).min() { return oldest }
		return board.sources.filter { !OfflinePlanner.ancillaryBoardSources.contains($0.id) }.compactMap(\.timestamp).filter { $0 > 0 }.min()
	}

	/// Restores this endpoint's cached board, active ride and saved trips. Legacy
	/// board files are imported once and never deleted.
	func restoreOffline() async {
		guard let transitStore else { return }
		let requestedEndpoint = endpoint
		await transitStore.setPreferences(offlinePreferences)
		// Legacy board files carry no endpoint; importing them elsewhere would mix servers.
		if Self.isProduction(requestedEndpoint) { await transitStore.importLegacyBoards(from: directory, endpoint: requestedEndpoint) }
		// Retention applies before anything persisted is shown, including offline relaunches.
		_ = try? await transitStore.evict()
		guard requestedEndpoint == endpoint else { return }
		if board == nil { await loadCachedBoard(stationID) }
		let ride = await transitStore.activeRide(endpoint: requestedEndpoint)
		let rideTrip: CachedTrip? = if let ride { await transitStore.trip(key: ride.tripKey, endpoint: requestedEndpoint) } else { nil }
		guard requestedEndpoint == endpoint else { return }
		activeRide = ride
		activeRideTrip = rideTrip
		publishRide()
		await reloadOfflineStatus()
		for id in realStationIDs(favorites + [stationID]) {
			let cached = await transitStore.board(stationID: id, endpoint: requestedEndpoint)
			guard requestedEndpoint == endpoint else { return }
			if let cached { _ = try? widgetStore?.saveBoard(cached.board, endpoint: requestedEndpoint) }
		}
	}

	/// Shows a station's saved board until a live one arrives. Never replaces live data.
	func loadCachedBoard(_ id: String) async {
		let requestedEndpoint = endpoint
		if let definition = combinedStations[id] {
			let generation = boardGeneration
			for member in definition.stationIDs {
				let cached = await transitStore?.board(stationID: member, endpoint: requestedEndpoint)
				guard id == stationID, generation == boardGeneration, requestedEndpoint == endpoint, combinedStations[id] == definition else { return }
				if memberBoards[member]?.board == nil, let cached {
					memberBoards[member] = MemberBoardSnapshot(station: cached.board.station, board: cached.board, cached: true, savedAt: cached.savedAt, error: nil)
				}
			}
			rebuildCombinedBoard()
			return
		}
		guard let cached = await transitStore?.board(stationID: id, endpoint: requestedEndpoint),
			id == stationID, requestedEndpoint == endpoint, board == nil || boardIsCached && board?.station.id != id else { return }
		board = cached.board
		boardSavedAt = cached.savedAt
		boardIsCached = true
	}

	/// Opens System status in the Settings tab; Back returns to Settings.
	func openSystemStatus() {
		selectedTab = 2
		settingsPath = [.systemStatus]
	}

	/// Keeps the board on screen as offline estimates when it cannot be refreshed.
	private func showSavedBoard(_ id: String, failed: Bool) async {
		if combinedStations[id] != nil {
			guard id == stationID else { return }
			for member in selectedMemberIDs {
				if var saved = memberBoards[member] { saved.cached = true; memberBoards[member] = saved }
			}
			await loadCachedBoard(id)
			rebuildCombinedBoard()
			return
		}
		boardIsCached = true
		if board == nil { await loadCachedBoard(id) }
		guard id == stationID else { return }
		// A saved board is labeled by its offline estimate card, so only a missing one is an error.
		boardError = board != nil ? nil : connected ? "Could not reach the train feed. Pull to retry or choose a saved station." : noConnectionMessage()
	}

	/// Starts with "No connection" and says what the phone is doing about it.
	private func noConnectionMessage() -> String {
		"No connection · \(deviceNetworkStatus.activitySummary). No saved board for this station; choose a saved station or reconnect."
	}

	func reloadOfflineStatus() async {
		guard let transitStore else { return }
		let requestedEndpoint = endpoint
		// Only the first check shows its steps; later ones refresh numbers already on screen.
		// Checks can overlap, so only the latest one moves or clears the bar.
		let token = UUID()
		let showSteps = offlineUsage == nil
		if showSteps { storageCheckToken = token; storageCheck = .step(0, of: 3, "Reading saved trains") }
		let saved = await transitStore.savedTrips(endpoint: requestedEndpoint)
		if showSteps, storageCheckToken == token { storageCheck = .step(1, of: 3, "Reading save errors") }
		let failures = await transitStore.failures()
		if showSteps, storageCheckToken == token { storageCheck = .step(2, of: 3, "Measuring offline storage") }
		let usage = await transitStore.usage()
		if showSteps, storageCheckToken == token { storageCheck = nil; storageCheckToken = nil }
		guard requestedEndpoint == endpoint else { return }
		savedTrips = saved
		offlineFailures = failures
		offlineUsage = usage
	}

	/// Measures storage off the main actor, then reads memory, power, and the latest feed latency.
	func refreshSystemStatus() async {
		let directory = directory
		let widgetDirectory = widgetStore?.directory
		let knownBundleBytes = appBundleBytes
		let storage = await Task.detached(priority: .utility) {
			let legacyBoards = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
				.filter { $0.lastPathComponent.hasPrefix("board-") && $0.pathExtension == "json" }
			let volume = StorageMeasure.volume(containing: directory)
			return AppStorageBreakdown(
				appBundleBytes: knownBundleBytes ?? StorageMeasure.bytes(at: Bundle.main.bundleURL),
				settingsBytes: StorageMeasure.bytes(at: ["settings.json", "preferences.json", "widgets.json"].map { directory.appendingPathComponent($0) }),
				transitCacheBytes: StorageMeasure.bytes(at: [directory.appendingPathComponent("OfflineTransit", isDirectory: true)] + legacyBoards),
				catalogBytes: StorageMeasure.bytes(at: directory.appendingPathComponent("stations.json")),
				widgetCacheBytes: widgetDirectory.map(StorageMeasure.bytes(at:)) ?? 0,
				urlCacheBytes: Int64(URLCache.shared.currentDiskUsage),
				fleetBytes: StorageMeasure.bytes(at: directory.appendingPathComponent("FleetDownload", isDirectory: true)),
				deviceFreeBytes: volume.free, deviceTotalBytes: volume.total)
		}.value
		appBundleBytes = storage.appBundleBytes
		let process = ProcessInfo.processInfo
		let memory = AppMemoryStatus(appFootprintBytes: ProcessMemory.footprintBytes() ?? 0, devicePhysicalMemoryBytes: process.physicalMemory, urlCacheMemoryBytes: Int64(URLCache.shared.currentMemoryUsage))
		systemStatus = SystemStatusSnapshot(storage: storage, memory: memory, thermal: ThermalLevel(process.thermalState), isLowPowerMode: process.isLowPowerModeEnabled, roundTripMilliseconds: await api.lastRoundTripMilliseconds, measuredAt: Date().timeIntervalSince1970)
	}

	func setOfflinePreferences(_ value: OfflinePreferences) {
		guard value.isValid else { return }
		offlinePreferences = value
		persist()
		let saved = offlinePreferences
		Task {
			await transitStore?.setPreferences(saved)
			_ = try? await transitStore?.evict()
			await reloadOfflineStatus()
		}
		if !offlinePreferences.preloadOtherStationTrips { surroundingTrips = [:] }
		planOffline()
		syncWidgets(reload: true)
	}

	func cachedTrip(_ key: String) async -> CachedTrip? { await transitStore?.trip(key: key, endpoint: endpoint) }

	/// "Save trip offline": kept until removed. Pass any detail still in memory, even
	/// after the connection drops; the store keeps whichever source is newer. Without
	/// one, the board's onward stops are saved as a labeled partial trip.
	/// `inferFromBoard: false` uses only the given origin: train details pass the context
	/// they captured, so a board selected later never supplies one.
	func saveTripOffline(_ key: String, detail: TripDetail?, origin: DepartureOrigin? = nil, inferFromBoard: Bool = true) async {
		guard let transitStore else { offlineActionError = "Offline storage is unavailable on this device."; return }
		let requestedEndpoint = endpoint
		let boardStation = inferFromBoard ? board?.station : nil
		do {
			if let detail { try await transitStore.saveTrip(detail, endpoint: requestedEndpoint, departure: origin?.departure ?? (inferFromBoard ? boardDeparture(key) : nil), manuallySaved: true) }
			else if await transitStore.trip(key: key, endpoint: requestedEndpoint) == nil {
				guard let departure = origin?.departure ?? (inferFromBoard ? boardDeparture(key) : nil) else { throw AppError.message("No train details are available to save yet. Reconnect and try again.") }
				try await transitStore.savePartialTrip(departure, endpoint: requestedEndpoint, manuallySaved: true, station: origin?.station ?? boardStation)
			}
			try await transitStore.setManuallySaved(true, tripKey: key, endpoint: requestedEndpoint)
			offlineActionError = nil
		} catch { offlineActionError = "Could not save this train offline. " + error.localizedDescription }
		await reloadOfflineStatus()
	}

	/// Explicit removal from the saved list. The snapshot may then expire automatically.
	func removeSavedTrip(_ key: String) async {
		do { try await transitStore?.setManuallySaved(false, tripKey: key, endpoint: endpoint); offlineActionError = nil }
		catch { offlineActionError = "Could not remove this saved train. " + error.localizedDescription }
		await reloadOfflineStatus()
	}

	/// "I'm on this train". One active ride; it stays protected across relaunch until ended.
	func startRide(_ key: String, detail: TripDetail?, origin: DepartureOrigin? = nil, inferFromBoard: Bool = true) async {
		guard let transitStore else { offlineActionError = "Offline storage is unavailable on this device."; return }
		guard !OfflineIdentity.isPositionalTrip(key) else { offlineActionError = "PATH reports identify a station arrival, not one train, so rides can't follow them."; return }
		let requestedEndpoint = endpoint
		let departure = origin?.departure ?? (inferFromBoard ? boardDeparture(key) : nil)
		do {
			if let detail { try await transitStore.saveTrip(detail, endpoint: requestedEndpoint, departure: departure) }
			else if await transitStore.trip(key: key, endpoint: requestedEndpoint) == nil, let departure { try await transitStore.savePartialTrip(departure, endpoint: requestedEndpoint, station: origin?.station ?? (inferFromBoard ? board?.station : nil)) }
			let ride = ActiveRide(tripKey: key, boardingStationID: departure == nil ? nil : origin?.station.id ?? (inferFromBoard && combinedStations[stationID] == nil ? stationID : nil), startedAt: Date().timeIntervalSince1970)
			try await transitStore.setActiveRide(ride, endpoint: requestedEndpoint)
			let trip = await transitStore.trip(key: key, endpoint: requestedEndpoint)
			guard requestedEndpoint == endpoint else { return }
			activeRide = ride
			activeRideTrip = trip
			offlineActionError = nil
		} catch { offlineActionError = "Could not start this ride. " + error.localizedDescription }
		publishRide()
		planOffline()
		await reloadOfflineStatus()
	}

	func endRide() async {
		do {
			try await transitStore?.setActiveRide(nil, endpoint: endpoint)
			activeRide = nil
			activeRideTrip = nil
			offlineActionError = nil
		} catch { offlineActionError = "Could not end this ride. " + error.localizedDescription }
		publishRide()
		planOffline()
		await reloadOfflineStatus()
	}

	/// Clears automatic boards and trips for this endpoint. Saved trains and the
	/// active ride are kept.
	func removeAutomaticOfflineData() async {
		do { _ = try await transitStore?.removeAutomaticEntries(endpoint: endpoint); offlineActionError = nil }
		catch { offlineActionError = "Could not clear automatic downloads. " + error.localizedDescription }
		surroundingTrips = [:]
		await reloadOfflineStatus()
	}

	func dismissOfflineFailures() async {
		await transitStore?.clearFailures()
		offlineFailures = []
	}

	private func boardDeparture(_ key: String) -> Departure? {
		guard let departure = board?.departures.first(where: { $0.tripKey == key }) else { return nil }
		return combinedBoard?.origins[departure.key]?.departure ?? departure
	}

	@discardableResult
	private func storeBoard(_ value: Board, endpoint requestedEndpoint: String, viewed: String? = nil, distance: Double? = nil) async -> Bool {
		guard let transitStore else { return false }
		let saved = (try? await transitStore.saveBoard(value, endpoint: requestedEndpoint, viewedStationID: viewed, distanceMeters: distance)) != nil
		let failures = await transitStore.failures()
		let savedAt = saved ? await transitStore.board(stationID: value.station.id, endpoint: requestedEndpoint)?.savedAt : nil
		guard requestedEndpoint == endpoint else { return saved }
		offlineFailures = failures
		if viewed == nil, value.station.id == stationID {
			// The live board is now also the saved copy offline estimates come from.
			if saved { boardSavedAt = savedAt }
		}
		return saved
	}

	private func storeTrip(_ detail: TripDetail, key: String) async {
		guard let transitStore else { return }
		let requestedEndpoint = endpoint
		_ = try? await transitStore.saveTrip(detail, endpoint: requestedEndpoint, departure: boardDeparture(key))
		let failures = await transitStore.failures()
		guard requestedEndpoint == endpoint else { return }
		offlineFailures = failures
		guard activeRide?.tripKey == key else { return }
		let trip = await transitStore.trip(key: key, endpoint: requestedEndpoint)
		// The endpoint or ride may have changed while the store was read.
		guard requestedEndpoint == endpoint, activeRide?.tripKey == key else { return }
		activeRideTrip = trip
		publishRide()
	}

	/// The automatic fetch set. Only the active ride and the selected board refresh
	/// every 10 s; next-trip snapshots, favorites and boards near the viewed station
	/// (never GPS) use the 30 s background cadence so they cannot starve each other.
	func planOffline() {
		guard let prefetcher else { return }
		let requests = plannedRequests()
		let targets = requests.map(\.target)
		if targets != trackedFetches { trackedFetches = targets }
		Task { await prefetcher.track(requests) }
	}

	func plannedRequests() -> [OfflineFetchRequest] {
		var requests: [OfflineFetchRequest] = []
		var seen = Set<OfflineFetchTarget>()
		var snapshots = Set<String>()
		func add(_ target: OfflineFetchTarget, _ priority: OfflineFetchPriority) {
			if seen.insert(target).inserted { requests.append(OfflineFetchRequest(endpoint: endpoint, target: target, priority: priority)) }
		}
		if let ride = activeRide { add(.trip(key: ride.tripKey), .activeRide) }
		if combinedStations[stationID] != nil {
			for id in selectedMemberIDs where stations.contains(where: { $0.id == id && $0.departureMode != "external" }) { add(.board(stationID: id), .selected) }
		} else if station?.departureMode != "external" || board?.njt?.configured == true { add(.board(stationID: stationID), .selected) }
		for key in openTrips.keys.sorted() { add(.trip(key: key), .selected) }
		if let board, board.station.id == stationID {
			for key in OfflinePlanner.tripKeysToSnapshot(board, preferences: offlinePreferences) { add(.trip(key: key), .background); snapshots.insert(key) }
		}
		var others: [String] = []
		for id in realStationIDs(favorites) where stations.contains(where: { $0.id == id && $0.departureMode != "external" }) { others.append(id) }
		if let viewed = station {
			for (nearby, _) in OfflinePlanner.surroundingStations(of: viewed, catalog: stations, preferences: offlinePreferences) where nearby.departureMode != "external" { others.append(nearby.id) }
		}
		for id in others where id != stationID { add(.board(stationID: id), .background) }
		// Other stations means favorites at any distance and nearby stations, even with the radius off.
		if offlinePreferences.preloadOtherStationTrips {
			for id in others where id != stationID {
				for key in surroundingTrips[id] ?? [] { add(.trip(key: key), .background); snapshots.insert(key) }
			}
		}
		snapshotKeys = snapshots
		return requests
	}

	private func makePrefetcher() -> OfflinePrefetcher {
		OfflinePrefetcher { [weak self] request in await self?.performFetch(request) }
	}

	/// The prefetcher's only network path. It calls the private fetchers directly;
	/// calling the public refresh methods here would join this same request and wait forever.
	private func performFetch(_ request: OfflineFetchRequest) async {
		guard request.endpoint == endpoint else { return }
		fetchesInFlight += 1
		defer { fetchesInFlight -= 1 }
		switch request.target {
		case .board(let id): await performBoard(id)
		case .trip(let key): await performTrip(key)
		}
	}

	/// Only newer source data replaces a snapshot; the store keeps the previous
	/// source time for unchanged responses.
	private func performBoard(_ id: String) async {
		let requestedEndpoint = endpoint
		let generation = boardGeneration
		let client = api
		let target = OfflineFetchTarget.board(stationID: id)
		// Only a board the screen is still waiting for reports its download.
		let tracked = board == nil && id == stationID ? trackFetch(target) : nil
		defer { endFetch(target, token: tracked?.token) }
		do {
			let value = try await client.board(stationID: id, progress: tracked?.handler)
			try Task.checkCancellation()
			guard requestedEndpoint == endpoint else { return }
			if combinedStations[stationID] != nil, selectedMemberIDs.contains(id), generation == boardGeneration {
				_ = try? widgetStore?.saveBoard(value, endpoint: requestedEndpoint)
				let saved = await storeBoard(value, endpoint: requestedEndpoint)
				let savedAt = saved ? await transitStore?.board(stationID: id, endpoint: requestedEndpoint)?.savedAt : nil
				guard requestedEndpoint == endpoint, generation == boardGeneration, selectedMemberIDs.contains(id) else { return }
				memberBoards[id] = MemberBoardSnapshot(station: value.station, board: value, cached: !connected, savedAt: savedAt, error: nil)
				rebuildCombinedBoard()
				planOffline()
				return
			}
			if id == stationID, generation == boardGeneration {
				_ = try? widgetStore?.saveBoard(value, endpoint: requestedEndpoint)
				board = value
				boardIsCached = !connected
				boardError = nil
				now = fixedNow ?? Date().timeIntervalSince1970
				recordRecent(id)
				persist()
				await storeBoard(value, endpoint: requestedEndpoint)
				planOffline()
				return
			}
			let viewed = station
			let distance = viewed.map { Display.distanceMeters(lat1: $0.lat, lon1: $0.lon, lat2: value.station.lat, lon2: value.station.lon) }
			await storeBoard(value, endpoint: requestedEndpoint, viewed: viewed?.id, distance: distance)
			if realStationIDs(favorites).contains(id) {
				_ = try? widgetStore?.saveBoard(value, endpoint: requestedEndpoint)
				syncWidgets(reload: false)
			}
			if offlinePreferences.preloadOtherStationTrips {
				let keys = OfflinePlanner.tripKeysToSnapshot(value, preferences: offlinePreferences)
				if surroundingTrips[id] != keys { surroundingTrips[id] = keys; planOffline() }
			}
		} catch {
			if combinedStations[stationID] != nil, selectedMemberIDs.contains(id), requestedEndpoint == endpoint, generation == boardGeneration, !Task.isCancelled {
				let cached = await transitStore?.board(stationID: id, endpoint: requestedEndpoint)
				guard requestedEndpoint == endpoint, generation == boardGeneration, selectedMemberIDs.contains(id) else { return }
				if let member = stations.first(where: { $0.id == id }) {
					memberBoards[id] = MemberBoardSnapshot(station: member, board: cached?.board ?? memberBoards[id]?.board, cached: true, savedAt: cached?.savedAt ?? memberBoards[id]?.savedAt, error: "Feed unavailable")
				}
				rebuildCombinedBoard()
				return
			}
			guard id == stationID, requestedEndpoint == endpoint, generation == boardGeneration, !Task.isCancelled else { return }
			await showSavedBoard(id, failed: true)
		}
	}

	private func performTrip(_ key: String) async {
		let requestedEndpoint = endpoint
		let client = api
		let target = OfflineFetchTarget.trip(key: key)
		let tracked = openTrips[key] != nil && liveTrips[key]?.detail == nil ? trackFetch(target) : nil
		defer { endFetch(target, token: tracked?.token) }
		do {
			let value = try await client.trip(key: key, progress: tracked?.handler)
			try Task.checkCancellation()
			guard requestedEndpoint == endpoint else { return }
			let open = openTrips[key] != nil
			if open { liveTrips[key] = LiveTrip(detail: value) }
			if !OfflineIdentity.isPositionalTrip(key), snapshotKeys.contains(key) || activeRide?.tripKey == key || isTripSaved(key) || open && offlinePreferences.saveOpenedTrips {
				await storeTrip(value, key: key)
			}
		} catch {
			// A trip missing from the feed is not a cancellation; any snapshot stays as saved.
			guard requestedEndpoint == endpoint, openTrips[key] != nil, !Task.isCancelled else { return }
			liveTrips[key, default: LiveTrip()].failure = (error as? TransitAPIError) == .notFound ? .notFound : .unavailable(error.localizedDescription)
		}
	}

	/// Starts publishing one fetch's download to `fetchProgress`.
	private func trackFetch(_ target: OfflineFetchTarget) -> (token: UUID, handler: TransferProgressHandler) {
		let token = UUID()
		fetchTokens[target] = token
		return (token, { [weak self] progress in await self?.reportFetch(progress, target: target, token: token) })
	}
	private func reportFetch(_ progress: TransferProgress, target: OfflineFetchTarget, token: UUID) {
		guard fetchTokens[target] == token else { return }
		fetchProgress[target] = progress
	}
	private func endFetch(_ target: OfflineFetchTarget, token: UUID?) {
		guard let token, fetchTokens[target] == token else { return }
		fetchTokens[target] = nil
		fetchProgress[target] = nil
	}

	/// The bar shown before the selected station has any departures on screen.
	var boardLoad: LoadProgress {
		let subject = station.map { "departures for \($0.name)" } ?? "departures"
		if let progress = fetchProgress[.board(stationID: stationID)] { return progress.load(subject) }
		return LoadProgress(fraction: nil, detail: connected ? "Waiting to request \(subject)…" : "Waiting for a connection (\(deviceNetworkStatus.shortActivity)) to request \(subject)…")
	}
	/// The bar shown while an open train has no details yet.
	func tripLoad(_ key: String) -> LoadProgress {
		if let progress = fetchProgress[.trip(key: key)] { return progress.load("train details") }
		return LoadProgress(fraction: nil, detail: connected ? "Waiting to request train details…" : "Waiting for a connection (\(deviceNetworkStatus.shortActivity)) to request train details…")
	}

	/// The network path's details, then what the app is fetching or waiting to fetch.
	var networkActivity: String {
		deviceNetworkStatus.detailLine(waitingTargets: max(0, trackedFetches.count - fetchesInFlight), inFlightTargets: fetchesInFlight, endpointHost: baseURL.host())
	}
	/// Whether automatic refreshes run, and the boards and trains they keep current.
	var networkSyncSummary: String {
		let boards = trackedFetches.filter { if case .board = $0 { true } else { false } }.count
		return deviceNetworkStatus.syncLine(trackedBoards: boards, trackedTrips: trackedFetches.count - boards, inFlight: fetchesInFlight)
	}

	private func connectionChanged() async {
		let isConnected = networkConnected && !outageSimulated
		guard isConnected != connected else { updateDeviceNetworkStatus(); return }
		connected = isConnected
		// The recovery refresh below still reads as connecting.
		reconnectGeneration += 1
		let generation = reconnectGeneration
		reconnecting = isConnected && active
		updateDeviceNetworkStatus()
		// Reconnecting makes every tracked fetch due at once (recovery refresh).
		await prefetcher?.setConnected(isConnected)
		guard active else { return }
		if isConnected {
			async let catalog: Void = refreshCatalog()
			async let board: Void = refreshBoard()
			_ = await (catalog, board)
			guard generation == reconnectGeneration else { return }
			reconnecting = false
			updateDeviceNetworkStatus()
		} else {
			await showSavedBoard(stationID, failed: false)
		}
	}

	private func updateDeviceNetworkStatus() {
		let status = networkPath.map { path in
			path.status(radioTechnology: path.transports.contains(.cellular) ? radioTechnology() : nil, simulatedOutage: outageSimulated, reconnecting: reconnecting)
		} ?? DeviceNetworkStatus(state: outageSimulated ? .simulatedOutage : .connecting)
		guard status != deviceNetworkStatus else { return }
		deviceNetworkStatus = status
		// A "No connection" notice names what the phone is doing, so it follows the path.
		if !connected, board == nil, boardError?.hasPrefix("No connection") == true { boardError = noConnectionMessage() }
	}

	/// The data service's radio generation. Reading it needs no permission and is nil on the simulator.
	private func radioTechnology() -> String? {
		#if canImport(CoreTelephony) && os(iOS)
		if telephony == nil { telephony = CTTelephonyNetworkInfo() }
		guard let telephony, let technologies = telephony.serviceCurrentRadioAccessTechnology else { return nil }
		let technology = telephony.dataServiceIdentifier.flatMap { technologies[$0] } ?? technologies.keys.sorted().first.flatMap { technologies[$0] }
		return DeviceNetworkStatus.radioLabel(technology)
		#else
		return nil
		#endif
	}

	/// The widget follows the ride only when that preference is on; the snapshot is shared either way.
	private func publishRide() {
		try? widgetStore?.saveRide(activeRide, trip: activeRideTrip, endpoint: endpoint)
		if widgetReloadEnabled { WidgetCenter.shared.reloadTimelines(ofKind: WidgetSharedStore.kind) }
	}

	/// Simulates losing the network on the same endpoint: requests fail and the
	/// app reports no connection, so this endpoint's cache stays in use.
	func setSimulatedOutage(_ value: Bool) async {
		guard value != outageSimulated else { return }
		outageSimulated = value
		if value { beginSimulatedOutage() }
		else if let saved = apiBeforeOutage { api = saved; apiBeforeOutage = nil }
		await connectionChanged()
	}

	private func beginSimulatedOutage() {
		if apiBeforeOutage == nil { apiBeforeOutage = api }
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [SimulatedOutage.self]
		api = TransitAPI(baseURL: baseURL, session: URLSession(configuration: configuration))
	}

	func locateNearby() async {
		guard !locating else { return }
		nearbyLocation = nil
		guard !locationDisabled else { locationError = "Location is disabled. You can still search for any station."; return }
		locating = true
		locationError = nil
		defer { locating = false }
		do { nearbyLocation = try await currentLocation() }
		catch { locationError = error.localizedDescription }
	}

	private func currentLocation() async throws -> CLLocation {
		if locationTask == nil {
			locationGeneration += 1
			locationTask = Task { @MainActor in
				if let locationRequest { return try await locationRequest() }
				#if DEBUG
				if let testLocation { return testLocation }
				#endif
				return try await locator.locate()
			}
		}
		let generation = locationGeneration
		defer { if generation == locationGeneration { locationTask = nil } }
		let location = try await locationTask!.value
		guard generation == locationGeneration, !Task.isCancelled else { throw CancellationError() }
		guard Self.usableLocation(location) else { throw AppError.message("Could not get a current location. Search for a station or try again.") }
		widgetLocation = WidgetCoordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude, timestamp: location.timestamp.timeIntervalSince1970)
		syncWidgets(reload: true)
		return location
	}
	static func usableLocation(_ location: CLLocation, now: Date = .now) -> Bool {
		let coordinate = WidgetCoordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude, timestamp: location.timestamp.timeIntervalSince1970)
		return location.horizontalAccuracy.isFinite && location.horizontalAccuracy >= 0 && coordinate.isUsable(now: now.timeIntervalSince1970)
	}

	private func openClosestFavoriteOnce() async {
		// A rider passes a different closest favorite at nearly every stop; returning
		// to the app must not navigate away from their ride.
		guard activeRide == nil, active, !Task.isCancelled, !locationDisabled, !favoriteStartupAttempted, !stations.isEmpty,
			stationSelection.mode != .favorite || !favoriteStations.isEmpty else { return }
		let initialStation = stationID
		// A permission sheet briefly deactivates the scene. Reuse the same one-shot
		// request after activation, while canceled polling tasks never navigate.
		if closestFavoriteTask == nil {
			closestFavoriteTask = Task {
				do { return try await currentLocation() }
				catch {
					if !Task.isCancelled { locationError = error.localizedDescription }
					return nil
				}
			}
		}
		let location = await closestFavoriteTask?.value
		guard active, !Task.isCancelled, !favoriteStartupAttempted else { return }
		closestFavoriteTask = nil
		guard let location, initialStation == stationID, activeRide == nil else { return }
		let coordinate = WidgetCoordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude, timestamp: location.timestamp.timeIntervalSince1970)
		guard coordinate.isUsable(now: Date().timeIntervalSince1970) else { return }
		if let closest = stationSelection.select(stations: visibleStations, favorites: favorites, location: coordinate, previous: stationID) {
			selectStation(closest.id)
			await refreshBoard()
		}
	}

	func loadFleetPackFacets() async {
		let requestedEndpoint = endpoint
		guard connected else { return }
		fleetPackFacetsError = nil
		do {
			let page = try await api.fleet(query: ["view": "cars", "retired": "true"])
			guard requestedEndpoint == endpoint, !Task.isCancelled else { return }
			fleetPackFacets = page.facets
		} catch {
			if requestedEndpoint == endpoint, !Task.isCancelled { fleetPackFacetsError = "Car type and yard choices are unavailable. You can still prepare all cars or retry loading the choices." }
		}
	}

	func setFleetPackSelection(_ selection: FleetPackSelection) {
		guard downloadTask == nil else { return }
		fleetPackSelection = selection
		availablePack = nil
		downloadError = nil
	}

	func checkDownload() async {
		guard downloadTask == nil else { return }
		let generation = UUID(), url = baseURL, selection = fleetPackSelection
		downloadGeneration = generation
		downloadError = nil
		availablePack = nil
		isPreparingFleetPack = true
		fleetPackJob = nil
		downloadTask = Task { [weak self] in
			defer { self?.finishFleetDownload(generation: generation) }
			do {
				let pack = try await Self.prepareFleetPack(api: FleetPackAPI(baseURL: url), selection: selection) { [weak self] job in
					if self?.downloadGeneration == generation { self?.fleetPackJob = job }
				}
				guard let self, self.downloadGeneration == generation, self.baseURL == url else { return }
				self.availablePack = pack
			} catch {
				if !Task.isCancelled, self?.downloadGeneration == generation { self?.downloadError = error.localizedDescription }
			}
		}
		await downloadTask?.value
	}

	private static func prepareFleetPack(api: FleetPackAPI, selection: FleetPackSelection, update: (FleetPackJob) -> Void) async throws -> FleetPackManifest {
		var job = try await api.prepare(selection: selection)
		update(job)
		var restarted = false
		// The server may need to scan several million recent events on its first build.
		// Wait through its 20-minute worker limit so a slow, valid pack can finish.
		let deadline = Date().addingTimeInterval(21 * 60)
		while job.state == .preparing {
			try Task.checkCancellation()
			guard Date() < deadline else { throw AppError.message("This fleet pack is taking longer than expected. Try preparing it again. Your saved fleet is still available.") }
			try await Task.sleep(for: .seconds(1))
			do { job = try await api.status(jobID: job.jobId) }
			catch FleetPackAPIError.expired where !restarted {
				restarted = true
				job = try await api.prepare(selection: selection)
			}
			update(job)
		}
		try Task.checkCancellation()
		guard let pack = job.manifest,
			pack.selection.historyDays == selection.historyDays,
			Set(pack.selection.equipment) == Set(selection.equipment), Set(pack.selection.yards) == Set(selection.yards) else { throw FleetPackAPIError.invalidResponse }
		return pack
	}

	private func finishFleetDownload(generation: UUID) {
		guard downloadGeneration == generation else { return }
		fleetDownload = nil
		fleetPackJob = nil
		isPreparingFleetPack = false
		downloadGeneration = nil
		downloadTask = nil
	}

	func startDownload() {
		guard downloadTask == nil, let pack = availablePack, let store = offlineStore else { return }
		downloadError = nil
		fleetDownload = FleetDownloadProgress(stage: .downloading, completedBytes: 0, totalBytes: pack.archiveByteLength)
		let generation = UUID()
		downloadGeneration = generation
		let url = baseURL
		downloadTask = Task { [weak self] in
			defer { self?.finishFleetDownload(generation: generation) }
			do {
				try await store.download(pack: pack, apiBaseURL: url) { [weak self] progress in
					Task { @MainActor [weak self] in
						guard let self, self.downloadGeneration == generation, !self.isPreparingFleetPack else { return }
						// Updates hop here independently, so an older one can arrive late; the bar only moves forward.
						if progress.fraction >= self.fleetDownload?.fraction ?? 0 { self.fleetDownload = progress }
					}
				}
				let saved = await store.manifest()
				guard self?.downloadGeneration == generation else { return }
				self?.offlineManifest = saved
			} catch OfflineFleetError.expired {
				guard !Task.isCancelled, let self, self.downloadGeneration == generation, self.baseURL == url else { return }
				self.availablePack = nil
				self.isPreparingFleetPack = true
				self.fleetDownload = nil
				self.fleetPackJob = nil
				do {
					let fresh = try await Self.prepareFleetPack(api: FleetPackAPI(baseURL: url), selection: pack.selection) { [weak self] job in
						if self?.downloadGeneration == generation { self?.fleetPackJob = job }
					}
					guard self.downloadGeneration == generation, self.baseURL == url else { return }
					self.availablePack = fresh
					self.downloadError = "The previous archive expired. A fresh pack is ready; review its size and choose Download again."
				} catch {
					if !Task.isCancelled { self.downloadError = error.localizedDescription }
				}
			} catch {
				if !Task.isCancelled, self?.downloadGeneration == generation { self?.downloadError = error.localizedDescription }
			}
		}
	}

	func cancelDownload() { downloadTask?.cancel() }

	/// The bar while the server builds a pack: its own build progress once the job reports it.
	var fleetPackLoad: LoadProgress {
		guard let job = fleetPackJob else { return LoadProgress(fraction: nil, detail: "Sending your fleet selection to \(baseURL.host ?? "the server")…") }
		return job.progress?.load ?? LoadProgress(fraction: nil, detail: "The server is preparing your fleet pack…")
	}
	var fleetDownloadLoad: LoadProgress { (fleetDownload ?? FleetDownloadProgress(stage: .downloading, completedBytes: 0, totalBytes: 0)).load }
	func deleteDownload() async {
		guard downloadTask == nil else { return }
		do {
			try await offlineStore?.delete()
			offlineManifest = nil
			useSavedFleet = false
		} catch { downloadError = error.localizedDescription }
	}

	private func rebuildCombinedBoard() {
		guard let definition = combinedStations[stationID] else { return }
		let station = CombinedStationResolver.station(id: stationID, name: definition.name, stationIDs: definition.stationIDs, catalog: stations)
			?? Station(id: stationID, name: definition.name, borough: "", lat: 0, lon: 0)
		let members = definition.stationIDs.map { id -> MemberBoardSnapshot in
			if let value = memberBoards[id] { return value }
			let member = stations.first { $0.id == id }
			return MemberBoardSnapshot(station: member ?? Station(id: id, name: id, borough: "", lat: 0, lon: 0), board: nil, cached: true, savedAt: nil,
				error: member == nil ? "Station missing from catalog" : member?.departureMode == "external" ? "Use official departure tools" : connected ? "Loading departures…" : "No saved board")
		}
		let value = CombinedBoardSnapshot(station: station, members: members)
		combinedBoard = value
		board = value.board
		boardIsCached = !connected || !members.contains { $0.board != nil && !$0.cached }
		// Saved members are labeled by the offline estimate card, so only real problems are errors.
		let problems = value.warnings(includeSaved: false)
		boardError = problems.isEmpty ? nil : problems.joined(separator: "\n")
		let supported = members.filter { $0.station.departureMode != "external" }
		boardSavedAt = !supported.isEmpty && supported.allSatisfy { $0.savedAt != nil } ? supported.compactMap(\.savedAt).min() : nil
	}

	var allLineKeys: [String] {
		Array(Set((stations.flatMap(\.routes) + hiddenRoutes + (board?.departures.map(\.route) ?? [])).map(LineVisibility.key))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
	}
	func setLine(_ route: String, enabled: Bool) {
		let key = LineVisibility.key(route)
		setHiddenLines(enabled ? hiddenRoutes.filter { LineVisibility.key($0) != key } : Array(Set(hiddenRoutes + [key])))
	}
	func setHiddenLines(_ routes: [String]) {
		var settings = portableSettings
		settings.hiddenRoutes = Array(Set(routes.map(LineVisibility.key))).sorted()
		do {
			try acceptSettings(try settings.validated(), sync: settingsSync, notify: true)
			favoriteStartupAttempted = true
		} catch { settingsError = error.localizedDescription }
	}
	@discardableResult
	func saveCombinedStation(id: String?, name: String, stationIDs: [String]) throws -> String {
		let key = id ?? "combined:" + UUID().uuidString.lowercased()
		var settings = portableSettings
		settings.combinedStations[key] = CombinedStation(name: name.trimmingCharacters(in: .whitespacesAndNewlines), stationIDs: Array(Set(stationIDs)).sorted())
		if id == nil { settings.stations[key] = StationPreference(view: .direction) }
		try acceptSettings(try settings.validated(), lastStation: key, sync: settingsSync, notify: true)
		selectedTab = 0
		return key
	}
	func deleteCombinedStation(_ id: String) throws {
		guard combinedStations[id] != nil else { return }
		var settings = portableSettings
		settings.combinedStations[id] = nil
		settings.favorites.removeAll { $0 == id }
		settings.stations[id] = nil
		settings.widgets.stations[id] = nil
		try acceptSettings(try settings.validated(), sync: settingsSync, notify: true)
		recent.removeAll { $0 == id }
	}

	private func recordRecent(_ id: String) { recent.removeAll { $0 == id }; recent.insert(id, at: 0); recent = Array(recent.prefix(8)) }
	var portableSettings: PortableSettings {
		var value = PortableSettings(); value.favorites = favorites; value.theme = themeID
		value.combinedStations = combinedStations; value.hiddenRoutes = hiddenRoutes
		value.trainFavorites = trainFavorites; value.stationSelection = stationSelection; value.units = units
		value.stations = stationPreferences; value.widgets = widgetPreferences; value.offline = offlinePreferences; value.transfers = transferPreferences; value.departureRows = departureRows; return value
	}
	private var settingsStore: DeviceSettingsStore { DeviceSettingsStore(fileURL: directory.appendingPathComponent("settings.json")) }
	private func record(settings: PortableSettings, lastStation: String, sync: SettingsSyncState?) -> DeviceSettings {
		var record = DeviceSettings(settings: settings, lastStation: lastStation)
		record.recent = recent.filter { !$0.hasPrefix("combined:") || settings.combinedStations[$0] != nil }; record.endpoint = endpoint; record.sync = sync; return record
	}
	private func persist() {
		do {
			try settingsStore.save(record(settings: portableSettings, lastStation: stationID, sync: settingsSync))
			durableSettings = portableSettings
			settingsError = nil; settingsDidChange?(); syncWidgets(reload: false)
		} catch {
			if let saved = durableSettings {
				favorites = saved.favorites; themeID = saved.theme
				trainFavorites = saved.trainFavorites; stationSelection = saved.stationSelection; units = saved.units
				stationPreferences = saved.stations; widgetPreferences = saved.widgets; offlinePreferences = saved.offline
				combinedStations = saved.combinedStations; hiddenRoutes = saved.hiddenRoutes; transferPreferences = saved.transfers; departureRows = saved.departureRows
			}
			settingsError = "Settings could not be saved on this device. Your previous preferences are unchanged. " + error.localizedDescription
		}
	}
	func acceptSettings(_ settings: PortableSettings, lastStation: String? = nil, sync: SettingsSyncState?, notify: Bool = false, replacingUnreadable: Bool = false) throws {
		var selected = lastStation ?? stationID
		if selected.hasPrefix("combined:"), settings.combinedStations[selected] == nil {
			let visible = stations.compactMap { LineVisibility.station($0, hiddenRoutes: settings.hiddenRoutes) }
			selected = combinedStations[selected]?.stationIDs.first(where: { id in visible.contains { $0.id == id } }) ?? visible.first?.id ?? stations.first?.id ?? "602"
		}
		let definitionChanged = combinedStations[selected] != settings.combinedStations[selected]
		try settingsStore.save(record(settings: settings, lastStation: selected, sync: sync), replacingUnreadable: replacingUnreadable)
		combinedStations = settings.combinedStations; hiddenRoutes = settings.hiddenRoutes; transferPreferences = settings.transfers; departureRows = settings.departureRows
		favorites = settings.favorites; themeID = settings.theme; stationPreferences = settings.stations; widgetPreferences = settings.widgets; settingsSync = sync; settingsError = nil
		trainFavorites = settings.trainFavorites; stationSelection = settings.stationSelection; units = settings.units
		let offlineChanged = offlinePreferences != settings.offline
		offlinePreferences = settings.offline
		if lastStation != nil { favoriteStartupAttempted = true }
		durableSettings = settings
		if selected != stationID || definitionChanged {
			stationID = selected; favoriteStartupAttempted = true; boardGeneration += 1
			memberBoards = [:]; combinedBoard = nil
			board = nil; boardSavedAt = nil; boardIsCached = true; boardError = nil
			Task { await loadCachedBoard(selected) }
		}
		if offlineChanged {
			let saved = offlinePreferences
			Task { await transitStore?.setPreferences(saved); _ = try? await transitStore?.evict(); await reloadOfflineStatus() }
		}
		planOffline()
		if Self.isProduction(endpoint) {
			for id in realStationIDs(favorites + [stationID]) {
				if let board = Self.read(Board.self, at: Self.boardURL(directory: directory, id: id)) { _ = try? widgetStore?.saveBoard(board, endpoint: endpoint) }
			}
		}
		syncWidgets(reload: true)
		if notify { settingsDidChange?() }
	}
	func previewSettingsFile(_ url: URL) {
		guard url.isFileURL, url.pathExtension.lowercased() == "nerds" else { settingsError = "Choose a .nerds settings file."; return }
		let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
		do {
			let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
			let data = try handle.read(upToCount: NerdsSettingsFile.maxBytes + 1) ?? Data()
			pendingSettingsImport = try NerdsSettingsFile.decode(data); settingsError = nil; selectedTab = 2
		} catch { settingsError = (error as? SettingsError)?.localizedDescription ?? "This settings file could not be read. Choose a valid .nerds file."; selectedTab = 2 }
	}
	func importSettings(_ file: NerdsSettingsFile) throws {
		try acceptSettings(file.settings, lastStation: file.lastStation, sync: settingsSync, notify: true, replacingUnreadable: true)
		pendingSettingsImport = nil
	}
	private func syncWidgets(reload: Bool) {
		guard let widgetStore else { return }
		let state = WidgetSharedState(favorites: favorites, stations: stations, appFilters: stationPreferences, widgets: widgetPreferences, themeID: themeID, endpoint: endpoint, appLocation: widgetLocation, stationSelection: stationSelection, units: units, offline: offlinePreferences, combinedStations: combinedStations, hiddenRoutes: hiddenRoutes)
		let previous = try? widgetStore.load()
		try? widgetStore.save(state)
		let changed = previous?.favorites != state.favorites || previous?.appFilters != state.appFilters || previous?.themeID != state.themeID || previous?.endpoint != state.endpoint || previous?.stationSelection != state.stationSelection || previous?.widgets != state.widgets || previous?.units != state.units || previous?.offline != state.offline || previous?.combinedStations != state.combinedStations || previous?.hiddenRoutes != state.hiddenRoutes
		let time = Date().timeIntervalSince1970
		if reload || changed || time - lastWidgetReload >= 60 {
			lastWidgetReload = time
			if widgetReloadEnabled { WidgetCenter.shared.reloadTimelines(ofKind: WidgetSharedStore.kind) }
		}
	}
	private static func boardURL(directory: URL, id: String) -> URL {
		let safe = Data(id.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
		return directory.appendingPathComponent("board-\(safe).json")
	}
	private static func read<T: Decodable>(_ type: T.Type, at url: URL) -> T? { (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(type, from: $0) } }
	private static func write<T: Encodable>(_ value: T, at url: URL) { if let data = try? JSONEncoder().encode(value) { try? data.write(to: url, options: .atomic) } }
}

/// Live details for an open trip, and why the latest refresh failed.
struct LiveTrip: Equatable {
	enum Failure: Equatable { case notFound, unavailable(String) }
	var detail: TripDetail?
	var failure: Failure?
}

/// Fails every request immediately, as when the device has no connection.
final class SimulatedOutage: URLProtocol, @unchecked Sendable {
	override class func canInit(with request: URLRequest) -> Bool { true }
	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
	override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
	override func stopLoading() {}
}

enum AppError: LocalizedError {
	case message(String)
	var errorDescription: String? { if case .message(let text) = self { text } else { nil } }
}

@MainActor
private final class LocationProvider: NSObject, @preconcurrency CLLocationManagerDelegate {
	private let manager = CLLocationManager()
	private var continuation: CheckedContinuation<CLLocation, Error>?
	private var timeout: Task<Void, Never>?
	var isAuthorized: Bool {
		#if os(macOS)
		return manager.authorizationStatus == .authorizedAlways
		#else
		return manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways
		#endif
	}

	override init() {
		super.init()
		manager.delegate = self
		manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
	}

	func locate() async throws -> CLLocation {
		guard continuation == nil else { throw AppError.message("Already finding your location. You can also search for any station.") }
		return try await withCheckedThrowingContinuation { continuation in
			self.continuation = continuation
			timeout = Task { [weak self] in
				do { try await Task.sleep(for: .seconds(12)) } catch { return }
				self?.finish(.failure(AppError.message("Could not get your location. Search for a station or try again.")))
			}
			switch manager.authorizationStatus {
			case .notDetermined: manager.requestWhenInUseAuthorization()
			case .authorizedWhenInUse, .authorizedAlways: manager.requestLocation()
			default: finish(.failure(AppError.message("Location permission is off. You can still search for any station, or allow location in the Settings app.")))
			}
		}
	}

	func cancel() { finish(.failure(CancellationError())) }

	func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
		guard continuation != nil else { return }
		switch manager.authorizationStatus {
		case .authorizedWhenInUse, .authorizedAlways: manager.requestLocation()
		case .denied, .restricted: finish(.failure(AppError.message("Location permission is off. You can still search for any station.")))
		default: break
		}
	}
	func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
		guard continuation != nil else { return }
		if let location = locations.filter({ AppModel.usableLocation($0) }).max(by: { $0.timestamp < $1.timestamp }) { finish(.success(location)) }
		else { manager.startUpdatingLocation() }
	}
	func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
		finish(.failure(AppError.message("Could not get your location. Search for a station or try again.")))
	}
	private func finish(_ result: Result<CLLocation, Error>) {
		manager.stopUpdatingLocation()
		timeout?.cancel()
		timeout = nil
		let waiting = continuation
		continuation = nil
		waiting?.resume(with: result)
	}
}


/// The parts of an `NWPath` the device network status uses, copied off the monitor's queue.
private struct NetworkPathSnapshot: Sendable {
	var status: DeviceNetworkStatus.PathStatus
	var transports: [DeviceNetworkStatus.Transport]
	var reason: DeviceNetworkStatus.PathReason?
	var isExpensive: Bool
	var isConstrained: Bool
	var supportsIPv4: Bool
	var supportsIPv6: Bool
	var supportsDNS: Bool

	init(_ path: NWPath) {
		status = switch path.status {
		case .satisfied: .satisfied
		case .requiresConnection: .requiresConnection
		case .unsatisfied: .unsatisfied
		@unknown default: .unsatisfied
		}
		transports = path.availableInterfaces.map { interface in
			switch interface.type {
			case .wifi: .wifi
			case .cellular: .cellular
			case .wiredEthernet: .wiredEthernet
			case .loopback: .loopback
			case .other: .other
			@unknown default: .other
			}
		}
		reason = switch path.unsatisfiedReason {
		case .notAvailable: .notAvailable
		case .cellularDenied: .cellularDenied
		case .wifiDenied: .wifiDenied
		case .localNetworkDenied: .localNetworkDenied
		case .vpnInactive: .vpnInactive
		@unknown default: nil
		}
		isExpensive = path.isExpensive
		isConstrained = path.isConstrained
		supportsIPv4 = path.supportsIPv4
		supportsIPv6 = path.supportsIPv6
		supportsDNS = path.supportsDNS
	}

	func status(radioTechnology: String?, simulatedOutage: Bool, reconnecting: Bool) -> DeviceNetworkStatus {
		DeviceNetworkStatus(path: status, transports: transports, reason: reason, radioTechnology: radioTechnology, isExpensive: isExpensive, isConstrained: isConstrained, supportsIPv4: supportsIPv4, supportsIPv6: supportsIPv6, supportsDNS: supportsDNS, simulatedOutage: simulatedOutage, reconnecting: reconnecting)
	}
}
