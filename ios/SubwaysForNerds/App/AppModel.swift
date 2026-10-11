import CoreLocation
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

@MainActor @Observable
final class AppModel {
	var stations: [Station] = []
	var stationID: String
	var favorites: [String]
	var trainFavorites: TrainFavorites
	var stationSelection: StationSelection
	var themeID: String
	var stationPreferences: [String: StationPreference]
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
	var nearbyLocation: CLLocation?
	var locationError: String?
	var locating = false
	var connected = true
	var offlineManifest: FleetOfflineManifest?
	var availableManifest: FleetOfflineManifest?
	var downloadProgress: Double?
	var downloadError: String?
	var useSavedFleet = false
	var endpoint: String
	var api: TransitAPI
	let offlineStore: OfflineFleetStore?
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
	@ObservationIgnored private var downloadTask: Task<Void, Never>?
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
		recent = portable?.recent ?? saved.recent
		themeID = portable?.settings.theme ?? (AppTheme.all.contains(where: { $0.id == saved.theme }) ? saved.theme : "subway")
		stationPreferences = portable?.settings.stations ?? saved.stations
		widgetPreferences = portable?.settings.widgets ?? Self.read(WidgetPreferences.self, at: directory.appendingPathComponent("widgets.json")) ?? WidgetPreferences()
		settingsSync = portable?.sync
		#if DEBUG
		let base = environment["SFN_API_BASE_URL"].flatMap(URL.init(string:)) ?? (portable?.endpoint ?? saved.endpoint).flatMap(URL.init(string:)) ?? TransitAPI.productionBaseURL
		#else
		let base = TransitAPI.productionBaseURL
		#endif
		endpoint = base.absoluteString
		api = TransitAPI(baseURL: base)
		offlineStore = try? OfflineFleetStore(directory: directory.appendingPathComponent("FleetDownload", isDirectory: true))
		stations = Self.read([Station].self, at: directory.appendingPathComponent("stations.json")) ?? []
		board = Self.read(Board.self, at: Self.boardURL(directory: directory, id: stationID))
		widgetLocation = (try? widgetStore?.load())?.appLocation
		for id in Set(favorites + [stationID]) {
			if let board = Self.read(Board.self, at: Self.boardURL(directory: directory, id: id)) { try? widgetStore?.saveBoard(board, endpoint: endpoint) }
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
	}

	var station: Station? { board?.station ?? stations.first { $0.id == stationID } }
	var theme: AppTheme { AppTheme.all.first { $0.id == themeID } ?? AppTheme.all[0] }
	var preference: StationPreference { stationPreferences[stationID] ?? StationPreference() }
	var favoriteStations: [Station] { favorites.compactMap { id in stations.first { $0.id == id } } }
	var isDownloading: Bool { downloadTask != nil }
	var baseURL: URL { URL(string: endpoint) ?? TransitAPI.productionBaseURL }

	func selectStation(_ id: String) {
		favoriteStartupAttempted = true
		guard id != stationID else { selectedTab = 0; return }
		stationID = id
		selectedTab = 0
		board = Self.read(Board.self, at: Self.boardURL(directory: directory, id: id))
		boardIsCached = true
		boardError = nil
		recordRecent(id)
		persist()
	}

	func toggleFavorite(_ id: String) {
		if favorites.contains(id) { favorites.removeAll { $0 == id } } else { favorites.append(id) }
		persist()
		pruneBoards()
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
		guard let id = WidgetLink.stationID(from: url), favorites.contains(id) || stations.contains(where: { $0.id == id }) else { return }
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
		api = TransitAPI(baseURL: URL(string: endpoint)!)
		boardIsCached = true
		availableManifest = nil
		lastCatalogAttempt = 0
		persist()
		Task { await refreshCatalog(); await refreshBoard() }
	}

	func suspend(background: Bool) {
		active = false
		activeGeneration += 1
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
				Task { @MainActor [weak self] in
					guard let self else { return }
					self.connected = connected
					guard self.active else { return }
					if connected {
						async let catalog: Void = self.refreshCatalog()
						async let board: Void = self.refreshBoard()
						_ = await (catalog, board)
					} else {
						self.boardIsCached = true
						self.boardError = "No connection. Saved reports are historical; reconnect for current predictions."
					}
				}
			}
			network.start(queue: DispatchQueue(label: "nyc.juliet.subways.network"))
		}
		offlineManifest = await offlineStore?.manifest()
		await withTaskGroup(of: Void.self) { group in
			group.addTask { await self.clockLoop() }
			group.addTask { await self.loadInitialCatalog() }
			group.addTask { await self.boardLoop() }
			group.addTask { await self.favoritesLoop() }
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
	private func boardLoop() async {
		while !Task.isCancelled {
			await refreshBoard()
			do { try await Task.sleep(for: .seconds(10)) } catch { return }
		}
	}
	private func favoritesLoop() async {
		while !Task.isCancelled {
			await refreshFavorites()
			do { try await Task.sleep(for: .seconds(30)) } catch { return }
		}
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
			Self.write(value, at: directory.appendingPathComponent("stations.json"))
			syncWidgets(reload: true)
			catalogError = nil
			// Favorites without a saved catalog become resolvable after this refresh.
			if active { await openClosestFavoriteOnce() }
		} catch {
			if !Task.isCancelled, generation == catalogGeneration, requestedEndpoint == endpoint { catalogError = "Station catalog unavailable. Saved stations remain available; reconnect to load every station." }
		}
	}

	func refreshBoard() async {
		guard station?.departureMode != "external" else { return }
		let id = stationID
		boardGeneration += 1
		let generation = boardGeneration
		let requestedEndpoint = endpoint
		do {
			let value = try await api.board(stationID: id)
			try Task.checkCancellation()
			guard generation == boardGeneration, requestedEndpoint == endpoint, id == stationID else { return }
			Self.write(value, at: Self.boardURL(directory: directory, id: id))
			try? widgetStore?.saveBoard(value, endpoint: requestedEndpoint)
			board = value
			boardIsCached = !connected
			boardError = nil
			now = fixedNow ?? Date().timeIntervalSince1970
			recordRecent(id)
			persist()
			pruneBoards()
		} catch {
			guard id == stationID, !Task.isCancelled, generation == boardGeneration, requestedEndpoint == endpoint else { return }
			boardIsCached = true
			boardError = board == nil ? "Could not reach the train feed. Pull to retry or choose a saved station." : "Showing a saved board. Reconnect for current predictions."
		}
	}

	private func refreshFavorites() async {
		let requestedEndpoint = endpoint
		let client = api
		for id in favorites where id != stationID && stations.first(where: { $0.id == id })?.departureMode != "external" {
			guard !Task.isCancelled else { return }
			if let value = try? await client.board(stationID: id), requestedEndpoint == endpoint, favorites.contains(id), !Task.isCancelled {
				Self.write(value, at: Self.boardURL(directory: directory, id: id))
				try? widgetStore?.saveBoard(value, endpoint: requestedEndpoint)
				syncWidgets(reload: false)
			}
		}
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
		guard active, !Task.isCancelled, !locationDisabled, !favoriteStartupAttempted, !stations.isEmpty,
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
		guard let location, initialStation == stationID else { return }
		let coordinate = WidgetCoordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude, timestamp: location.timestamp.timeIntervalSince1970)
		guard coordinate.isUsable(now: Date().timeIntervalSince1970) else { return }
		if let closest = stationSelection.select(stations: stations, favorites: favorites, location: coordinate, previous: stationID) {
			selectStation(closest.id)
			await refreshBoard()
		}
	}

	func checkDownload() async {
		let requestedEndpoint = endpoint
		downloadError = nil
		do {
			let manifest = try await api.offlineManifest()
			guard requestedEndpoint == endpoint, !Task.isCancelled else { return }
			availableManifest = manifest
		} catch { if requestedEndpoint == endpoint, !Task.isCancelled { downloadError = "The fleet download is temporarily unavailable. Your saved copy is still usable." } }
	}

	func startDownload() {
		guard downloadTask == nil, let manifest = availableManifest, let store = offlineStore else { return }
		downloadError = nil
		downloadProgress = 0
		let generation = UUID()
		downloadGeneration = generation
		let url = baseURL
		downloadTask = Task { [weak self] in
			do {
				try await store.download(manifest: manifest, apiBaseURL: url) { [weak self] fraction in
					Task { @MainActor [weak self] in
						guard let self, self.downloadGeneration == generation else { return }
						self.downloadProgress = max(self.downloadProgress ?? 0, fraction)
					}
				}
				self?.offlineManifest = await store.manifest()
			} catch {
				if !Task.isCancelled { self?.downloadError = error.localizedDescription }
			}
			self?.downloadProgress = nil
			self?.downloadGeneration = nil
			self?.downloadTask = nil
		}
	}

	func cancelDownload() { downloadTask?.cancel() }
	func deleteDownload() async {
		guard downloadTask == nil else { return }
		do {
			try await offlineStore?.delete()
			offlineManifest = nil
			useSavedFleet = false
		} catch { downloadError = error.localizedDescription }
	}

	private func recordRecent(_ id: String) { recent.removeAll { $0 == id }; recent.insert(id, at: 0); recent = Array(recent.prefix(8)) }
	var portableSettings: PortableSettings {
		var value = PortableSettings(); value.favorites = favorites; value.theme = themeID
		value.trainFavorites = trainFavorites; value.stationSelection = stationSelection
		value.stations = stationPreferences; value.widgets = widgetPreferences; return value
	}
	private var settingsStore: DeviceSettingsStore { DeviceSettingsStore(fileURL: directory.appendingPathComponent("settings.json")) }
	private func record(settings: PortableSettings, lastStation: String, sync: SettingsSyncState?) -> DeviceSettings {
		var record = DeviceSettings(settings: settings, lastStation: lastStation)
		record.recent = recent; record.endpoint = endpoint; record.sync = sync; return record
	}
	private func persist() {
		do {
			try settingsStore.save(record(settings: portableSettings, lastStation: stationID, sync: settingsSync))
			durableSettings = portableSettings
			settingsError = nil; settingsDidChange?(); syncWidgets(reload: false)
		} catch {
			if let saved = durableSettings {
				favorites = saved.favorites; themeID = saved.theme
				trainFavorites = saved.trainFavorites; stationSelection = saved.stationSelection
				stationPreferences = saved.stations; widgetPreferences = saved.widgets
			}
			settingsError = "Settings could not be saved on this device. Your previous preferences are unchanged. " + error.localizedDescription
		}
	}
	func acceptSettings(_ settings: PortableSettings, lastStation: String? = nil, sync: SettingsSyncState?, notify: Bool = false, replacingUnreadable: Bool = false) throws {
		let selected = lastStation ?? stationID
		try settingsStore.save(record(settings: settings, lastStation: selected, sync: sync), replacingUnreadable: replacingUnreadable)
		favorites = settings.favorites; themeID = settings.theme; stationPreferences = settings.stations; widgetPreferences = settings.widgets; settingsSync = sync; settingsError = nil
		trainFavorites = settings.trainFavorites; stationSelection = settings.stationSelection
		if lastStation != nil { favoriteStartupAttempted = true }
		durableSettings = settings
		if selected != stationID {
			stationID = selected; favoriteStartupAttempted = true; boardGeneration += 1
			board = Self.read(Board.self, at: Self.boardURL(directory: directory, id: selected)); boardIsCached = true; boardError = nil
		}
		for id in Set(favorites + [stationID]) {
			if let board = Self.read(Board.self, at: Self.boardURL(directory: directory, id: id)) { try? widgetStore?.saveBoard(board, endpoint: endpoint) }
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
		let state = WidgetSharedState(favorites: favorites, stations: stations, appFilters: stationPreferences, widgets: widgetPreferences, themeID: themeID, endpoint: endpoint, appLocation: widgetLocation, stationSelection: stationSelection)
		let previous = try? widgetStore.load()
		try? widgetStore.save(state)
		let changed = previous?.favorites != state.favorites || previous?.appFilters != state.appFilters || previous?.themeID != state.themeID || previous?.endpoint != state.endpoint || previous?.stationSelection != state.stationSelection || previous?.widgets != state.widgets
		let time = Date().timeIntervalSince1970
		if reload || changed || time - lastWidgetReload >= 60 {
			lastWidgetReload = time
			if widgetReloadEnabled { WidgetCenter.shared.reloadTimelines(ofKind: WidgetSharedStore.kind) }
		}
	}
	private func pruneBoards() {
		let keep = Set((favorites + recent + [stationID]).map { Self.boardURL(directory: directory, id: $0).lastPathComponent })
		for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] where url.lastPathComponent.hasPrefix("board-") && !keep.contains(url.lastPathComponent) { try? FileManager.default.removeItem(at: url) }
	}
	private static func boardURL(directory: URL, id: String) -> URL {
		let safe = Data(id.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
		return directory.appendingPathComponent("board-\(safe).json")
	}
	private static func read<T: Decodable>(_ type: T.Type, at url: URL) -> T? { (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(type, from: $0) } }
	private static func write<T: Encodable>(_ value: T, at url: URL) { if let data = try? JSONEncoder().encode(value) { try? data.write(to: url, options: .atomic) } }
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
