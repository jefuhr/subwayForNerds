import CoreLocation
import Foundation
import TransitCore

// The startup model only needs theme identities; UI rendering is tested by XCTest.
struct AppTheme {
	let id: String
	static let all = [AppTheme(id: "subway")]
}

/// Serves boards and trips for one endpoint host and can fail like a lost connection.
final class FixtureAPI: URLProtocol, @unchecked Sendable {
	static let host = "fixture.test"
	private static let lock = NSLock()
	nonisolated(unsafe) private static var responses: [String: Data] = [:]
	nonisolated(unsafe) private static var counts: [String: Int] = [:]
	static func set(_ path: String, _ data: Data) { lock.withLock { responses[path] = data } }
	static func requests(_ path: String) -> Int { lock.withLock { counts[path, default: 0] } }
	static func reset() { lock.withLock { responses = [:]; counts = [:] } }
	override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
	override func startLoading() {
		guard let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
		let key = components.path + (components.queryItems?.first { $0.name == "key" }.map { "?key=" + ($0.value ?? "") } ?? "")
		let data = Self.lock.withLock { Self.counts[key, default: 0] += 1; return Self.responses[key] }
		let response = HTTPURLResponse(url: url, statusCode: data == nil ? 404 : 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
		client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
		client?.urlProtocol(self, didLoad: data ?? Data("{}".utf8))
		client?.urlProtocolDidFinishLoading(self)
	}
	override func stopLoading() {}
}

// A stalled catalog request must never block selection from saved favorites.
final class StalledAPI: URLProtocol, @unchecked Sendable {
	override class func canInit(with request: URLRequest) -> Bool { true }
	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
	override func startLoading() {}
	override func stopLoading() {}
}

@main
struct NativeStartupTests {
	enum Failure: Error { case expectation(String) }

	@MainActor static func main() async throws {
		// Line-buffered so PASS lines before a failing expectation still reach the log.
		setvbuf(stdout, nil, _IOLBF, 0)
		setenv("SFN_API_BASE_URL", "http://127.0.0.1:1/api/v1/", 1)
		setenv("SFN_DISABLE_LOCATION", "0", 1)
		setenv("SFN_TEST_LOCATION", "40.755290,-73.987495", 1)
		setenv("SFN_RESET_STATE", "0", 1)
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-startup-\(UUID())")
		defer { try? FileManager.default.removeItem(at: directory) }
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let stations = [
			Station(id: "far", name: "Far favorite", borough: "M", lat: 40.90, lon: -73.90),
			Station(id: "near", name: "Near favorite", borough: "M", lat: 40.755290, lon: -73.987495),
			Station(id: "other", name: "Not a favorite", borough: "M", lat: 40.75, lon: -73.98)
		]
		try JSONEncoder().encode(stations).write(to: directory.appendingPathComponent("stations.json"))
		try JSONSerialization.data(withJSONObject: [
			"stationID": "far", "favorites": ["far", "near"], "recent": [],
			"theme": "subway", "stations": [:]
		]).write(to: directory.appendingPathComponent("preferences.json"))

		let app = AppModel(stateDirectory: directory)
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [StalledAPI.self]
		let session = URLSession(configuration: configuration)
		defer { session.invalidateAndCancel() }
		app.api = TransitAPI(baseURL: app.baseURL, session: session)
		var foreground = Task { await app.runWhileActive() }
		try await waitForStation("near", in: app)
		print("PASS: cold launch selects the nearest of two saved favorites while the catalog request is stalled")
		try expect(app.favorites == ["far", "near"] && !app.widgetPreferences.matchAppFilters, "Adding widget defaults must preserve legacy favorites")
		app.setWidgetView(.family, stationID: "far")
		app.toggleWidgetRoute("Q", stationID: "far")
		app.setWidgetMatchApp(true)
		app.setWidgetMatchApp(false)
		var homeScreen = app.widgetPreferences.display
		homeScreen.refreshInterval = .tenMinutes
		app.setWidgetDisplay(homeScreen)
		var lockScreen = app.widgetPreferences.lockScreen
		lockScreen.display.trainsPerDirection = 0
		lockScreen.display.fields = [.track, .carType]
		lockScreen.directionOrder = .uptownLeft
		lockScreen.showService = false
		lockScreen.display.refreshInterval = .oneMinute
		app.setWidgetLockScreen(lockScreen)
		for matchApp in [true, false] {
			app.setWidgetMatchApp(matchApp)
			try expect(app.widgetPreferences.display == homeScreen && app.widgetPreferences.lockScreen == lockScreen, "Changing the filter source must preserve both widget refresh intervals and display choices")
		}
		let restoredWidgets = AppModel(stateDirectory: directory)
		try expect(restoredWidgets.widgetPreferences.stations["far"] == StationPreference(routes: ["Q"], view: .family), "Independent widget filters must survive toggles and relaunch")
		try expect(restoredWidgets.favorites == ["far", "near"], "Widget settings must not change favorites")
		try expect(restoredWidgets.widgetPreferences.lockScreen == lockScreen && restoredWidgets.widgetPreferences.display == homeScreen, "Lock Screen customization and both refresh intervals must persist independently of Home Screen display")
		let sharedWidgets = try restoredWidgets.widgetStore!.load()
		try expect(sharedWidgets.widgets == restoredWidgets.widgetPreferences && sharedWidgets.favorites.count == 2, "The extension must see the saved widget settings and favorites")
		print("PASS: legacy favorites, independent filters, Lock Screen display, and separate refresh intervals survive relaunch and shared snapshot persistence")
		await app.locateNearby()
		try expect(app.nearbyLocation?.coordinate.latitude == 40.755290, "Nearby search must obtain location")
		try expect(app.stations.count == 3, "Nearby search must retain all stations, including nonfavorites")
		print("PASS: nearby search obtains location and retains the full station catalog")

		app.selectStation("far")
		await stop(app, task: foreground, background: false)
		foreground = Task { await app.runWhileActive() }
		try await Task.sleep(for: .milliseconds(200))
		try expect(app.stationID == "far", "Temporary inactivity must preserve a manual choice")
		print("PASS: temporary inactivity preserves the manually selected station")

		await stop(app, task: foreground, background: true)
		foreground = Task { await app.runWhileActive() }
		try await waitForStation("near", in: app)
		print("PASS: returning from the background selects the closest favorite again")
		await stop(app, task: foreground, background: true)
		app.openWidgetURL(WidgetLink.board(stationID: "far"))
		foreground = Task { await app.runWhileActive() }
		try await Task.sleep(for: .milliseconds(200))
		try expect(app.stationID == "far", "A widget deep link must win over automatic closest-favorite startup")
		print("PASS: widget navigation opens its displayed station without closest-favorite redirection")
		await stop(app, task: foreground, background: true)

		app.favorites = []
		app.selectStation("far")
		app.suspend(background: true)
		foreground = Task { await app.runWhileActive() }
		try await Task.sleep(for: .milliseconds(200))
		try expect(app.stationID == "far", "Without favorites, retain the last station")
		print("PASS: no favorites retains the last station")
		await stop(app, task: foreground, background: true)

		app.toggleFavorite("far")
		app.toggleFavorite("near")
		setenv("SFN_DISABLE_LOCATION", "1", 1)
		let unavailable = AppModel(stateDirectory: directory)
		try expect(unavailable.favorites.count == 2, "The unavailable-location check needs saved favorites")
		let disabledForeground = Task { await unavailable.runWhileActive() }
		try await Task.sleep(for: .milliseconds(200))
		try expect(unavailable.stationID == "far", "Unavailable location must retain the last station")
		print("PASS: unavailable location retains the last station")
		await unavailable.locateNearby()
		try expect(unavailable.nearbyLocation == nil && unavailable.locationError != nil, "Unavailable nearby search must explain the failure and preserve searchable stations")
		try expect(unavailable.stations.count == 3, "Unavailable location must not remove the station catalog")
		print("PASS: unavailable nearby search preserves the catalog and explains the location failure")
		await stop(unavailable, task: disabledForeground, background: true)

		let fixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("test/fixtures/settings.nerds")
		let file = try NerdsSettingsFile.decode(Data(contentsOf: fixture))
		let before = unavailable.portableSettings
		unavailable.previewSettingsFile(fixture)
		try expect(unavailable.pendingSettingsImport != nil && unavailable.portableSettings == before, "Opening a .nerds file must preview without changing settings")
		try unavailable.importSettings(file)
		try expect(unavailable.portableSettings == file.settings && unavailable.stationID == "602", "Import must apply station, widget and app preferences together")
		let imported = AppModel(stateDirectory: directory)
		try expect(imported.portableSettings == file.settings, "Imported preferences must survive relaunch")
		let importedWidgetSettings = try imported.widgetStore!.load().widgets
		try expect(importedWidgetSettings == file.settings.widgets, "Import must update the shared widget snapshot")
		let settingsURL = directory.appendingPathComponent("settings.json")
		let backupURL = directory.appendingPathComponent("settings-backup.json")
		try FileManager.default.moveItem(at: settingsURL, to: backupURL)
		try FileManager.default.createDirectory(at: settingsURL, withIntermediateDirectories: false)
		let favoritesBeforeFailedSave = unavailable.favorites
		unavailable.toggleFavorite("unsaved-favorite")
		try expect(unavailable.favorites == favoritesBeforeFailedSave && unavailable.settingsError != nil, "A failed favorite save must roll back the star and report the error")
		var replacement = file; replacement.settings.favorites = ["changed"]
		var failed = false
		do { try unavailable.importSettings(replacement) } catch { failed = true }
		try expect(failed && unavailable.portableSettings == file.settings, "A failed import write must retain the previous settings in memory")
		try FileManager.default.removeItem(at: settingsURL)
		try FileManager.default.moveItem(at: backupURL, to: settingsURL)
		print("PASS: .nerds preview, atomic import, widget sharing, relaunch and write-failure recovery")
		try Data("{damaged".utf8).write(to: settingsURL, options: .atomic)
		let recovered = AppModel(stateDirectory: directory)
		try expect(recovered.favorites == file.settings.favorites, "Damaged settings must recover the latest favorites from the redundant snapshot")
		print("PASS: favorites recover from a damaged primary settings file")

		let brokenDirectory = directory.appendingPathComponent("unrecoverable")
		try FileManager.default.createDirectory(at: brokenDirectory, withIntermediateDirectories: true)
		let brokenURL = brokenDirectory.appendingPathComponent("settings.json")
		let damaged = Data("{do not overwrite".utf8)
		try damaged.write(to: brokenURL)
		let broken = AppModel(stateDirectory: brokenDirectory)
		broken.toggleFavorite("602")
		try expect(try Data(contentsOf: brokenURL) == damaged, "Routine preference saves must preserve unreadable originals")
		try broken.importSettings(file)
		try expect(AppModel(stateDirectory: brokenDirectory).favorites == file.settings.favorites, "An explicit validated import can repair unreadable settings")
		print("PASS: unreadable settings are preserved until an explicit import repairs them")
		let coldDirectory = directory.appendingPathComponent("cold-widget-link")
		var coldSettings = PortableSettings(); coldSettings.favorites = ["far", "near"]
		try DeviceSettingsStore(fileURL: coldDirectory.appendingPathComponent("settings.json")).save(DeviceSettings(settings: coldSettings, lastStation: "near"))
		setenv("SFN_DISABLE_LOCATION", "0", 1)
		let cold = AppModel(stateDirectory: coldDirectory)
		cold.openWidgetURL(WidgetLink.board(stationID: "unknown"))
		try expect(cold.stationID == "near", "Unknown widget links must remain rejected")
		cold.openWidgetURL(WidgetLink.board(stationID: "far"))
		try expect(cold.stationID == "far", "A saved favorite widget link must work before the catalog is available")
		cold.stations = stations
		let coldForeground = Task { await cold.runWhileActive() }
		try await Task.sleep(for: .milliseconds(250))
		try expect(cold.stationID == "far", "A later catalog load must not override a cold widget link")
		await stop(cold, task: coldForeground, background: true)
		print("PASS: a saved favorite widget deep link works without a cached catalog and wins over startup selection")
		try await locationRegressions(directory: directory.appendingPathComponent("location"), stations: stations)
		try await selectionRegressions(directory: directory.appendingPathComponent("selection"), stations: stations)
		try await combinedRegressions(directory: directory.appendingPathComponent("combined"))
		try await offlineRegressions(directory: directory.appendingPathComponent("offline"))
	}

	@MainActor static func combinedRegressions(directory: URL) async throws {
		// Failure modes: synthetic network requests, collapsed boarding opportunities,
		// lost physical ride origin, a failed member replacing the entire board, and
		// hidden aliases that cannot be enabled again after import.
		setenv("SFN_DISABLE_LOCATION", "1", 1)
		setenv("SFN_API_BASE_URL", "https://fixture.test/subwaysForNerds/api/v1/", 1)
		setenv("SFN_SIMULATE_OUTAGE", "0", 1)
		URLProtocol.registerClass(FixtureAPI.self)
		defer { URLProtocol.unregisterClass(FixtureAPI.self) }
		FixtureAPI.reset()
		let api = "/subwaysForNerds/api/v1/"
		let id = "combined:6d9542db-9ab7-422e-9548-fd66c1d4a384"
		let stations = [Station(id: "628", name: "Fulton St", borough: "M", routes: ["A"], lat: 40.71, lon: -74.01), Station(id: "624", name: "World Trade Center", borough: "M", routes: ["A"], lat: 40.71, lon: -74.01)]
		let now = Date().timeIntervalSince1970
		let boards = stations.enumerated().map { index, station in
			Board(station: station, generatedAt: now, sources: [SourceState(id: "ace", timestamp: now)], departures: [Departure(key: "same", tripKey: "same-trip", route: "A", destination: "Uptown", direction: "NORTH", stopId: station.id, partId: station.id, area: "", time: now + Double(index + 1) * 120, pattern: "Local", patternSource: "feed", location: "", feed: "ace", timestamp: now)])
		}
		FixtureAPI.set(api + "stations", try JSONEncoder().encode(stations))
		// The second member only has a saved board; its request deliberately fails.
		FixtureAPI.set(api + "stations/628/board", try JSONEncoder().encode(boards[0]))
		var settings = PortableSettings()
		settings.combinedStations[id] = CombinedStation(name: "Downtown", stationIDs: ["628", "624"])
		settings.stations["628"] = StationPreference(routes: ["C"], view: .service)
		settings.offline.nearbyRadiusFeet = 0
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		try JSONEncoder().encode(stations).write(to: directory.appendingPathComponent("stations.json"))
		try DeviceSettingsStore(fileURL: directory.appendingPathComponent("settings.json")).save(DeviceSettings(settings: settings, lastStation: id))
		let cache = OfflineTransitStore(directory: directory.appendingPathComponent("OfflineTransit", isDirectory: true))
		try await cache.saveBoard(boards[1], endpoint: "https://fixture.test/subwaysForNerds/api/v1/")
		let model = AppModel(stateDirectory: directory)
		let task = Task { await model.runWhileActive() }
		try await waitFor("combined partial board", timeout: 1000) { model.combinedBoard?.board.departures.count == 2 && model.combinedBoard?.members.contains { $0.station.id == "624" && $0.error != nil } == true }
		try expect(FixtureAPI.requests(api + "stations/" + id + "/board") == 0, "Combined IDs must never reach the server")
		try expect(model.preference.routes.isEmpty && model.preference.view == .direction, "Groups use independent defaults")
		let snapshot = try expectValue(model.combinedBoard, "Combined snapshot exists")
		try expect(snapshot.cachedDepartureKeys.count == 1 && !model.boardIsCached, "Partial cache is tracked per member")
		let key = try expectValue(snapshot.origins.first { $0.value.station.id == "624" }?.key, "Second boarding origin exists")
		let origin = try expectValue(model.departureOrigin(key), "Presentation key resolves its physical origin")
		await model.startRide("same-trip", detail: nil, origin: origin)
		try expect(model.activeRide?.boardingStationID == "624", "Ride boards the selected physical member")
		let backgroundMember = Station(id: "background", name: "Background member", borough: "M", routes: ["A"], lat: 41, lon: -74)
		model.stations.append(backgroundMember)
		FixtureAPI.set(api + "stations/background/board", try JSONEncoder().encode(Board(station: backgroundMember, generatedAt: now)))
		var expanded = model.portableSettings
		expanded.combinedStations[id]?.stationIDs.append(backgroundMember.id); expanded.favorites = [id]
		try model.acceptSettings(expanded, sync: nil)
		model.selectStation("628")
		try await waitFor("favorite group member shared cache", timeout: 1000) { model.widgetStore?.board(stationID: "background", endpoint: model.endpoint) != nil }
		model.selectStation(id)
		await model.loadCachedBoard(id)
		model.setHiddenLines(["A"])
		try expect(model.displayBoard?.departures.isEmpty == true && model.activeRide != nil, "Global hiding preserves the active ride")
		var aliases = model.portableSettings; aliases.hiddenRoutes = ["6X"]
		try model.acceptSettings(aliases, sync: nil)
		model.setLine("6", enabled: true)
		try expect(model.hiddenRoutes.isEmpty, "Enabling a parent removes imported express aliases")
		try model.deleteCombinedStation(id)
		try expect(stations.contains { $0.id == model.stationID } && model.activeRide?.boardingStationID == "624", "Deleting a selected group falls back without losing its ride")
		await stop(model, task: task, background: true)
		print("PASS: combined boards use real member requests, preserve separate cached boarding opportunities and ride origins, and recover after deletion or line changes")
	}

	@MainActor static func settle() async throws {
		for _ in 0..<20 { await Task.yield() }
		try await Task.sleep(for: .milliseconds(20))
	}

	@MainActor static func locationRegressions(directory: URL, stations: [Station]) async throws {
		setenv("SFN_DISABLE_LOCATION", "0", 1)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		try JSONEncoder().encode(stations).write(to: directory.appendingPathComponent("stations.json"))
		var settings = PortableSettings(); settings.favorites = ["far", "near"]
		try DeviceSettingsStore(fileURL: directory.appendingPathComponent("settings.json")).save(DeviceSettings(settings: settings, lastStation: "far"))
		let source = LocationSequence()
		let model = AppModel(stateDirectory: directory, locationRequest: { try await source.locate() })
		let foreground = Task { await model.runWhileActive() }
		for _ in 0..<100 where source.requests == 0 { try await Task.sleep(for: .milliseconds(10)) }
		let nearby = Task { await model.locateNearby() }
		try await waitForStation("near", in: model)
		await nearby.value
		try expect(source.requests == 1 && model.nearbyLocation != nil && model.locationError == nil, "Startup, nearby search, and widget refresh must share an in-flight location request")
		model.selectStation("near")
		source.location = CLLocation(latitude: 40.90, longitude: -73.90)
		await model.refreshWidgetLocation()
		let shared = try model.widgetStore!.load()
		try expect(shared.appLocation?.latitude == 40.90 && model.stationID == "near", "Moving must refresh widget coordinates without redirecting a manual board selection")
		await stop(model, task: foreground, background: true)
		let requests = source.requests
		await model.refreshWidgetLocation()
		try expect(source.requests == requests, "Background app must not poll for widget location")
		let invalid = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 40.9, longitude: -73.9), altitude: 0, horizontalAccuracy: -1, verticalAccuracy: -1, timestamp: .now)
		let stale = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 40.9, longitude: -73.9), altitude: 0, horizontalAccuracy: 20, verticalAccuracy: 20, timestamp: Date().addingTimeInterval(-3600))
		try expect(!AppModel.usableLocation(invalid) && !AppModel.usableLocation(stale), "Invalid or stale GPS fixes must not select the wrong favorite")
		source.location = stale
		await model.locateNearby()
		try expect(model.locationError != nil && model.nearbyLocation == nil && model.stationID == "near", "A stale location response must clear old nearby distances, report a failure, and preserve the selected board")
		let unchanged = try model.widgetStore!.load().appLocation
		try expect(unchanged == shared.appLocation, "A stale location response must not replace the widget's newer fix")
		print("PASS: concurrent location requests coalesce, foreground movement updates widgets without navigation, and stale GPS fixes are rejected")
	}

	@MainActor static func selectionRegressions(directory: URL, stations: [Station]) async throws {
		// Failure modes: empty favorites gating GPS, radius ignored, incomplete widget
		// catalogs, lost nonfavorite cache, late GPS navigation, and partial rollback.
		setenv("SFN_DISABLE_LOCATION", "0", 1)
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [StalledAPI.self]
		let session = URLSession(configuration: configuration)
		defer { session.invalidateAndCancel() }
		for mode in [StationSelection.Mode.closest, .nearbyFavorite] {
			let folder = directory.appendingPathComponent(mode.rawValue)
			try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
			try JSONEncoder().encode(stations).write(to: folder.appendingPathComponent("stations.json"))
			var settings = PortableSettings()
			settings.favorites = mode == .closest ? [] : ["far"]
			settings.stationSelection = StationSelection(mode: mode, radiusFeet: 1)
			try DeviceSettingsStore(fileURL: folder.appendingPathComponent("settings.json")).save(DeviceSettings(settings: settings, lastStation: "far"))
			// Legacy board files only migrate for production; this endpoint gets an endpoint-scoped cache.
			let cached = Board(station: stations[1], generatedAt: 123, departures: [])
			try await OfflineTransitStore(directory: folder.appendingPathComponent("OfflineTransit", isDirectory: true)).saveBoard(cached, endpoint: ProcessInfo.processInfo.environment["SFN_API_BASE_URL"]!)
			let source = LocationSequence()
			let model = AppModel(stateDirectory: folder, locationRequest: { try await source.locate() })
			model.api = TransitAPI(baseURL: model.baseURL, session: session)
			let foreground = Task { await model.runWhileActive() }
			try await waitForStation("near", in: model)
			// Legacy board files are imported into the offline store, which restores asynchronously.
			try await waitFor { model.board?.station.id == "near" }
			try expect(source.requests > 0 && model.boardIsCached && model.board?.station.id == "near", "Automatic selection must open the nonfavorite cached board")
			let shared = try model.widgetStore!.load()
			try expect(shared.stations == stations && shared.stationSelection == settings.stationSelection, "Widgets must receive the full catalog and app selection preferences")
			try expect(shared.selectedStation(location: nil, previous: "far")?.id == "near", "Widgets following the app must select a nonfavorite using the shared location")
			let requests = source.requests
			await model.refreshWidgetLocation()
			try expect(source.requests > requests, "Foreground widget location refresh must work without favorites in closest mode")
			await stop(model, task: foreground, background: true)
			let restored = AppModel(stateDirectory: folder)
			try await waitFor("widget board share") { restored.widgetStore!.board(stationID: "near", endpoint: restored.endpoint) != nil }
			try expect(restored.widgetStore!.board(stationID: "near", endpoint: restored.endpoint)?.generatedAt == 123, "Relaunch must share the selected nonfavorite board cache with widgets")
			var override = WidgetStationSelection()
			override.followApp = false
			override.selection = StationSelection(mode: .favorite, radiusFeet: 1)
			restored.setWidgetStationSelection(override)
			let independent = try restored.widgetStore!.load()
			try expect(independent.selectedStation(location: shared.appLocation, previous: "near")?.id == (mode == .closest ? nil : "far"), "Independent widget selection must override app closest selection")
			override.followApp = true
			restored.setWidgetStationSelection(override)
			let following = try restored.widgetStore!.load()
			try expect(following.selectedStation(location: shared.appLocation, previous: "far")?.id == "near" && following.widgets.stationSelection.selection == override.selection, "Following the app must preserve the stored independent override")
			restored.setDistanceUnit(.km)
			restored.setTimeFormat(.twentyFourHour)
			let units = UnitPreferences(distance: .km, time: .twentyFourHour)
			try expect(restored.units == units && AppModel(stateDirectory: folder).units == units, "Unit preferences must survive relaunch")
			try expect(try restored.widgetStore!.load().units == units, "Widget sharing must receive both unit preferences")
			let before = restored.portableSettings
			let widgetBefore = try restored.widgetStore!.load()
			let settingsURL = folder.appendingPathComponent("settings.json")
			let savedURL = folder.appendingPathComponent("settings.saved")
			try FileManager.default.moveItem(at: settingsURL, to: savedURL)
			try FileManager.default.createDirectory(at: settingsURL, withIntermediateDirectories: false)
			restored.setStationSelection(StationSelection(mode: .favorite, radiusFeet: 26400))
			try expect(restored.portableSettings == before && restored.settingsError != nil, "Failed station preference save must roll back")
			override.followApp = false
			restored.setWidgetStationSelection(override)
			try expect(restored.portableSettings == before && restored.settingsError != nil, "Failed widget override save must roll back")
			restored.toggleFavoriteCar("nyct:R160:001")
			try expect(restored.portableSettings == before && restored.settingsError != nil, "Failed car favorite save must roll back")
			restored.toggleFavoriteConsist(["nyct:R160:001", "nyct:R160:002"])
			try expect(restored.portableSettings == before && restored.settingsError != nil, "Failed consist favorite save must roll back")
			restored.setTrainMatch(.anyCar)
			try expect(restored.portableSettings == before && restored.settingsError != nil, "Failed matching preference save must roll back")
			restored.setDistanceUnit(.mi)
			restored.setTimeFormat(.twelveHour)
			try expect(restored.portableSettings == before && restored.settingsError != nil, "Failed unit preference saves must roll back")
			try expect(try restored.widgetStore!.load() == widgetBefore, "Failed preference writes must not publish partial widget settings")
			try FileManager.default.removeItem(at: settingsURL)
			try FileManager.default.moveItem(at: savedURL, to: settingsURL)
			try expect(AppModel(stateDirectory: folder).portableSettings == before, "Failed new preferences must remain rolled back after relaunch")
		}
		// Explicitly choosing the already displayed station must also beat pending GPS.
		let raceFolder = directory.appendingPathComponent("closest")
		let source = LocationSequence()
		let race = AppModel(stateDirectory: raceFolder, locationRequest: { try await source.locate() })
		race.api = TransitAPI(baseURL: race.baseURL, session: session)
		race.selectStation("far")
		race.suspend(background: true)
		let foreground = Task { await race.runWhileActive() }
		for _ in 0..<100 where source.requests == 0 { try await Task.sleep(for: .milliseconds(10)) }
		try expect(source.requests > 0, "Race regression must have an in-flight GPS request")
		race.selectStation("far")
		await race.refreshWidgetLocation()
		try await Task.sleep(for: .milliseconds(50))
		try expect(race.stationID == "far", "A manual choice of the current station must win over pending automatic GPS selection")
		await stop(race, task: foreground, background: true)
		print("PASS: closest without favorites, one-foot nearby fallback, widget overrides/full catalog/nonfavorite cache, pending GPS navigation, units relaunch/sharing, and new-preference write rollback")
	}

	@MainActor static func offlineRegressions(directory: URL) async throws {
		// Failure modes: snapshots not saved before an outage, cache lost when the
		// connection drops on the same endpoint, ride or saved trips lost on relaunch,
		// offline times shown as live, a recovered connection not refreshing, unchanged
		// responses renewing source age, nearby boards chosen by GPS instead of the viewed
		// station, ride links changing the selected station, and silent save failures.
		setenv("SFN_DISABLE_LOCATION", "1", 1)
		setenv("SFN_API_BASE_URL", "https://\(FixtureAPI.host)/subwaysForNerds/api/v1/", 1)
		setenv("SFN_SIMULATE_OUTAGE", "0", 1)
		URLProtocol.registerClass(FixtureAPI.self)
		defer { URLProtocol.unregisterClass(FixtureAPI.self); setenv("SFN_SIMULATE_OUTAGE", "0", 1) }
		FixtureAPI.reset()
		let api = "/subwaysForNerds/api/v1/"
		let viewed = Station(id: "viewed", name: "Viewed", borough: "M", routes: ["A"], lat: 40.7500, lon: -73.9900)
		let close = Station(id: "close", name: "Close", borough: "M", routes: ["A"], lat: 40.7530, lon: -73.9900) // ~1,090 ft
		let far = Station(id: "far", name: "Far", borough: "M", routes: ["A"], lat: 40.7700, lon: -73.9900) // ~7,300 ft
		let start = Date().timeIntervalSince1970
		func departure(_ key: String, _ direction: String, minutes: Double, source: TimeInterval) -> Departure {
			Departure(key: key + "@viewed", tripKey: key, route: "A", destination: direction == "NORTH" ? "Uptown" : "Downtown", direction: direction, stopId: "A1", partId: "A1", area: "Track 1", time: start + minutes * 60, pattern: "Local", patternSource: "feed", location: "At Earlier", feed: "ace", timestamp: source, onward: [OnwardStop(stationId: "close", stopId: "A2", name: "Close", time: start + minutes * 60 + 120)])
		}
		func board(_ station: Station, source: TimeInterval) -> Data {
			let departures = station.id == "viewed" ? [departure("t1", "NORTH", minutes: 5, source: source), departure("t2", "NORTH", minutes: 9, source: source), departure("t3", "NORTH", minutes: 14, source: source), departure("t4", "SOUTH", minutes: 7, source: source)] : []
			return try! JSONEncoder().encode(Board(station: station, generatedAt: start, sources: [SourceState(id: "ace", timestamp: source, fetchedAt: source)], departures: departures))
		}
		func trip(_ key: String, minutes: Double, source: TimeInterval) -> Data {
			let train = Train(key: key, feed: "ace", tripId: key, route: "A", destination: "Uptown", direction: "NORTH", trainId: "A 1200", assigned: true, timestamp: source, position: TrainPosition(stopId: "A0", name: "Earlier", timestamp: source),
				stops: [StopPrediction(id: "A1", name: "Viewed", stationId: "viewed", arrival: start + minutes * 60), StopPrediction(id: "A2", name: "Close", stationId: "close", arrival: start + minutes * 60 + 120), StopPrediction(id: "A3", name: "Far", stationId: "far", arrival: start + minutes * 60 + 600)],
				consist: Consist(cars: [ConsistCar(number: "1234", type: "R46")], updatedAt: source, fetchedAt: source))
			return try! JSONEncoder().encode(TripDetail(train: train, raw: .object(["source": .string("fixture")])))
		}
		let source = start - 20
		FixtureAPI.set(api + "stations", try JSONEncoder().encode([viewed, close, far]))
		for station in [viewed, close, far] { FixtureAPI.set(api + "stations/\(station.id)/board", board(station, source: source)) }
		for (key, minutes) in [("t1", 5.0), ("t2", 9.0), ("t3", 14.0), ("t4", 7.0)] { FixtureAPI.set(api + "trips?key=\(key)", trip(key, minutes: minutes, source: source)) }

		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		try JSONEncoder().encode([viewed, close, far]).write(to: directory.appendingPathComponent("stations.json"))
		try DeviceSettingsStore(fileURL: directory.appendingPathComponent("settings.json")).save(DeviceSettings(settings: PortableSettings(), lastStation: "viewed"))
		let model = AppModel(stateDirectory: directory)
		let endpoint = model.endpoint
		var foreground = Task { await model.runWhileActive() }
		try await waitFor("viewed board snapshots", timeout: 1000) { model.readiness.boardSaved && model.readiness.wanted.count == 3 && model.readiness.savedCount == 3 }
		try expect(model.readiness.wanted == ["t1", "t2", "t4"], "Two full trips per line and direction must be chosen, got \(model.readiness.wanted)")
		try await waitFor("nearby board", timeout: 1000) { FixtureAPI.requests(api + "stations/close/board") > 0 }
		let store = try expectValue(model.transitStore, "The offline store must open")
		for _ in 0..<100 { if await store.board(stationID: "close", endpoint: endpoint) != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
		try expect(await store.board(stationID: "close", endpoint: endpoint)?.viewedStationID == "viewed", "Boards near the viewed station must be cached with their viewed station")
		try expect(FixtureAPI.requests(api + "stations/far/board") == 0, "Stations beyond the radius of the viewed station must not be fetched")
		try expect(FixtureAPI.requests(api + "trips?key=t3") == 0, "Only the configured number of next trips per line and direction may be fetched automatically")
		print("PASS: the viewed board, its next trips per line and direction, and boards near the viewed station are saved while connected")

		await model.saveTripOffline("t3", detail: nil)
		try expect(model.savedTrips.first { $0.tripKey == "t3" }?.isComplete == false, "Saving an unloaded train must keep a labeled partial trip from the board")
		model.openTrip("t1")
		try expect(await model.refreshTrip("t1") == .completed, "An explicit trip refresh completes while connected")
		let t1 = try expectValue(model.liveTrips["t1"]?.detail, "Open train details keep the fetched trip in memory")
		await model.saveTripOffline("t1", detail: t1)
		model.closeTrip("t1")
		try expect(model.liveTrips["t1"] == nil, "Closing train details drops their in-memory copy")
		try expect(model.isTripSaved("t1") && model.savedTrips.first { $0.tripKey == "t1" }?.isComplete == true, "Saving a loaded train must keep its full details")
		await model.startRide("t2", detail: nil)
		try expect(model.activeRide?.tripKey == "t2" && model.activeRide?.boardingStationID == "viewed" && model.activeRideTrip?.isComplete == true && !model.isTripSaved("t2"), "I'm on this train must follow one ride without adding it to saved trains")
		print("PASS: Save trip offline keeps full or partial trips, separate from the one active ride")

		await model.setSimulatedOutage(true)
		try expect(!model.connected && model.endpoint == endpoint, "A simulated outage must keep the same endpoint")
		await model.refreshBoard()
		try expect(model.board?.station.id == "viewed" && model.boardIsCached && model.boardError?.contains("offline estimates") == true, "An outage must keep the viewed board as labeled offline estimates, got \(model.boardError ?? "nil")")
		try expect(model.boardSavedAt != nil, "A board saved while live must say it was saved, not 'not saved offline', after the connection drops")
		let clock = ContinuousClock()
		let started = clock.now
		try expect(await model.refreshTrip("t1") == .paused && clock.now - started < .seconds(1), "Explicit requests return promptly without a connection")
		let cachedDeparture = try expectValue(model.board?.departures.first { $0.tripKey == "t1" }, "The cached board must keep t1")
		let estimate = OfflineDisplay.countdown(departure: cachedDeparture, now: Date().timeIntervalSince1970, cached: true, preferences: model.offlinePreferences)
		try expect(estimate.unit == "min", "A fresh saved prediction counts down as an offline estimate, got \(estimate)")
		let outageRequests = FixtureAPI.requests(api + "stations/viewed/board")
		await stop(model, task: foreground, background: true)

		setenv("SFN_SIMULATE_OUTAGE", "1", 1)
		let relaunched = AppModel(stateDirectory: directory)
		try expect(relaunched.endpoint == endpoint && !relaunched.connected, "Relaunching during an outage keeps the endpoint and reports no connection")
		foreground = Task { await relaunched.runWhileActive() }
		try await waitFor("restored ride", timeout: 300) { relaunched.activeRide != nil && relaunched.board != nil && relaunched.savedTrips.count == 2 }
		try expect(relaunched.activeRide?.tripKey == "t2" && relaunched.activeRideTrip?.isComplete == true, "The active ride and its snapshot must survive relaunch")
		try expect(Set(relaunched.savedTrips.map(\.tripKey)) == ["t1", "t3"], "Saved trains must survive relaunch")
		try expect(relaunched.boardIsCached && relaunched.boardSavedAt != nil && relaunched.board?.station.id == "viewed", "The viewed board must restore from the offline store")
		let savedT4 = try expectValue(await relaunched.cachedTrip("t4"), "Automatic next-trip snapshots must survive relaunch")
		try expect(savedT4.isComplete && OfflineDisplay.estimateLabel(timestamp: savedT4.sourceTimestamp, now: Date().timeIntervalSince1970, preferences: relaunched.offlinePreferences).hasPrefix("Offline estimate"), "Saved trips must be labeled offline estimates with their source age")
		try await Task.sleep(for: .milliseconds(300))
		try expect(FixtureAPI.requests(api + "stations/viewed/board") == outageRequests, "No requests may reach the server during an outage")
		let rideURL = try expectValue(URL(string: "subwaynerds://ride?key=t2"), "ride link")
		relaunched.openWidgetURL(rideURL)
		try expect(relaunched.openTripKey == "t2" && relaunched.stationID == "viewed", "A ride link must open its trip without changing the selected station")
		print("PASS: an outage on the same endpoint keeps the board, ride, saved and automatic trips across relaunch with offline labels")

		let savedBefore = try expectValue(await store.board(stationID: "viewed", endpoint: endpoint)?.savedAt, "saved board time")
		await relaunched.setSimulatedOutage(false)
		try await waitFor("recovery refresh", timeout: 500) { relaunched.connected && !relaunched.boardIsCached }
		try expect(relaunched.boardError == nil && !relaunched.boardIsCached, "Reconnecting must replace offline estimates with live data")
		let reopened = OfflineTransitStore(directory: directory.appendingPathComponent("OfflineTransit", isDirectory: true))
		try expect(await reopened.board(stationID: "viewed", endpoint: endpoint)?.savedAt == savedBefore, "An unchanged response must not renew the saved source snapshot")
		FixtureAPI.set(api + "stations/viewed/board", board(viewed, source: source + 15))
		await relaunched.refreshBoard()
		try expect((await reopened.board(stationID: "viewed", endpoint: endpoint)?.sourceTimestamp ?? 0) >= source + 15, "Newer source data must replace the saved board")
		print("PASS: reconnecting refreshes immediately, unchanged responses keep their source age, and newer data replaces snapshots")

		await relaunched.removeSavedTrip("t3")
		try expect(!relaunched.isTripSaved("t3") && relaunched.isTripSaved("t1"), "Removing one saved train keeps the others")
		await relaunched.endRide()
		try expect(relaunched.activeRide == nil, "Ending the ride clears it")
		var preferences = relaunched.offlinePreferences
		preferences.estimateLimitMinutes = 7
		relaunched.setOfflinePreferences(preferences)
		try expect(relaunched.offlinePreferences.estimateLimitMinutes == 30, "Invalid offline preferences must be rejected")
		preferences.estimateLimitMinutes = 60; preferences.nearbyRadiusFeet = 0; preferences.departuresPerLineDirection = 3; preferences.tripDetailsPerLineDirection = 1
		relaunched.setOfflinePreferences(preferences)
		await stop(relaunched, task: foreground, background: true)
		setenv("SFN_SIMULATE_OUTAGE", "0", 1)
		let third = AppModel(stateDirectory: directory)
		try expect(third.offlinePreferences == preferences && third.portableSettings.offline == preferences, "Offline preferences must persist in portable settings")
		try await waitFor("third restore", timeout: 300) { third.savedTrips.count == 1 }
		try expect(third.activeRide == nil && third.isTripSaved("t1"), "An ended ride stays ended and remaining saved trains stay after relaunch")
		print("PASS: saved trains are removed only explicitly, rides end explicitly, and offline preferences validate and persist")

		await third.startRide("t1", detail: nil)
		await third.removeAutomaticOfflineData()
		try expect(await third.cachedTrip("t4") == nil && third.isTripSaved("t1") && third.activeRide?.tripKey == "t1" && third.activeRideTrip != nil && third.offlineActionError == nil, "Clearing automatic downloads keeps saved trains and the active ride")
		await third.endRide()
		print("PASS: clearing automatic downloads keeps saved trains and the active ride")

		let offlineDirectory = directory.appendingPathComponent("OfflineTransit", isDirectory: true)
		try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: offlineDirectory.path)
		defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: offlineDirectory.path) }
		for folder in (try? FileManager.default.contentsOfDirectory(at: offlineDirectory, includingPropertiesForKeys: nil)) ?? [] {
			try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
		}
		FixtureAPI.set(api + "stations/viewed/board", board(viewed, source: source + 40))
		third.api = TransitAPI(baseURL: third.baseURL)
		await third.refreshBoard()
		try await waitFor("visible save failure", timeout: 300) { !third.offlineFailures.isEmpty }
		try expect(third.board?.station.id == "viewed" && !third.boardIsCached, "A failed offline save must not hide the live board")
		for folder in (try? FileManager.default.contentsOfDirectory(at: offlineDirectory, includingPropertiesForKeys: nil)) ?? [] {
			try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
		}
		await third.dismissOfflineFailures()
		try expect(third.offlineFailures.isEmpty, "Save failures can be dismissed")
		print("PASS: failed offline saves are visible without hiding live data")
		try await offlineReviewRegressions(directory: directory.appendingPathComponent("review"), stations: [viewed, close, far], source: source)
	}

	@MainActor static func offlineReviewRegressions(directory: URL, stations: [Station], source: TimeInterval) async throws {
		// Failure modes from review: duplicate board requests on station change, a
		// foreground closest-favorite redirect closing a ride, fresh feeds hiding old
		// predictions in the source age, 10 s churn for snapshot trips, and newer
		// in-memory details discarded when saving after the connection drops.
		let api = "/subwaysForNerds/api/v1/"
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		try JSONEncoder().encode(stations).write(to: directory.appendingPathComponent("stations.json"))
		var settings = PortableSettings()
		settings.favorites = ["viewed", "far"]
		settings.offline.saveOpenedTrips = false
		try DeviceSettingsStore(fileURL: directory.appendingPathComponent("settings.json")).save(DeviceSettings(settings: settings, lastStation: "viewed"))
		setenv("SFN_DISABLE_LOCATION", "0", 1)
		let source0 = LocationSequence()
		source0.location = CLLocation(latitude: stations[2].lat, longitude: stations[2].lon)
		let model = AppModel(stateDirectory: directory, locationRequest: { try await source0.locate() })
		var foreground = Task { await model.runWhileActive() }
		// The first visit moves to the closest favorite; a manual choice then wins for the visit.
		try await waitForStation("far", in: model)
		model.selectStation("viewed")
		await model.refreshBoard() // BoardView's .task(id: stationID)
		try await waitFor("viewed board", timeout: 500) { model.board?.station.id == "viewed" && !model.boardIsCached }

		let planned = model.plannedRequests()
		try expect(planned.first { $0.target == .board(stationID: "viewed") }?.priority == .selected, "The selected board refreshes on the 10 s cadence")
		try expect(planned.filter { if case .trip = $0.target { return true } else { return false } }.allSatisfy { $0.priority == .background }, "Next-trip snapshots use the 30 s background cadence")
		model.openTrip("t4")
		model.openTrip("t4")
		try expect(model.plannedRequests().first { $0.target == .trip(key: "t4") }?.priority == .selected, "Open train details refresh on the shared selected cadence instead of their own poll")
		model.closeTrip("t4")
		try expect(model.plannedRequests().first { $0.target == .trip(key: "t4") }?.priority == .selected, "A second open view keeps the trip registered")
		model.closeTrip("t4")
		try expect(model.plannedRequests().first { $0.target == .trip(key: "t4") }?.priority == .background, "Closing the last view returns the trip to the background snapshot cadence")
		print("PASS: only the selected board, open train details and the active ride use the 10 s cadence")

		// A station never fetched before: its tracked fetch is due at once, and the
		// view's explicit refresh must join it rather than make a second request.
		let fresh = Station(id: "fresh", name: "Fresh", borough: "M", lat: 40.60, lon: -73.90)
		FixtureAPI.set(api + "stations/fresh/board", try JSONEncoder().encode(Board(station: fresh, generatedAt: source, sources: [SourceState(id: "ace", timestamp: source)])))
		model.selectStation("fresh")
		await model.refreshBoard()
		try await Task.sleep(for: .milliseconds(300))
		try expect(FixtureAPI.requests(api + "stations/fresh/board") == 1, "Selecting a station and refreshing it must make exactly one board request, got \(FixtureAPI.requests(api + "stations/fresh/board"))")
		try expect(model.board?.station.id == "fresh" && !model.boardIsCached && model.boardError == nil, "The joined request applies the fresh board")
		print("PASS: an explicit refresh joins the automatic fetch for the same board")

		model.selectStation("viewed")
		await model.refreshBoard()
		model.openTrip("t3")
		_ = await model.refreshTrip("t3")
		let memory = try expectValue(model.liveTrips["t3"]?.detail, "Open details keep the fetched trip")
		try expect(await model.cachedTrip("t3") == nil, "With save opened trips off, an opened trip is not stored automatically")
		await model.setSimulatedOutage(true)
		try expect(model.liveTrips["t3"]?.detail == memory, "Details in memory survive losing the connection")
		await model.saveTripOffline("t3", detail: model.liveTrips["t3"]?.detail)
		try expect(await model.cachedTrip("t3")?.isComplete == true, "Saving after the connection drops keeps the full details from memory, not a partial board trip")
		model.closeTrip("t3")
		await model.setSimulatedOutage(false)
		print("PASS: full details loaded before an outage are saved in full after it")

		await model.refreshBoard()
		await model.startRide("t2", detail: nil)
		try expect(model.activeRide?.tripKey == "t2", "Ride for redirect check")
		await stop(model, task: foreground, background: true)
		foreground = Task { await model.runWhileActive() }
		try await Task.sleep(for: .milliseconds(600))
		try expect(model.stationID == "viewed", "Returning to the app during a ride must not redirect to the closest favorite, got \(model.stationID)")
		await model.endRide()
		await stop(model, task: foreground, background: true)
		foreground = Task { await model.runWhileActive() }
		try await waitForStation("far", in: model)
		await stop(model, task: foreground, background: true)
		setenv("SFN_DISABLE_LOCATION", "1", 1)
		print("PASS: an active ride blocks foreground closest-favorite redirection; without one it still applies")

		let now = Date().timeIntervalSince1970
		let mixed = Board(station: stations[0], generatedAt: now, sources: [SourceState(id: "ace", timestamp: now - 2400), SourceState(id: "subway-alerts", timestamp: now - 60), SourceState(id: "helium", timestamp: now - 30)],
			departures: [Departure(key: "k", tripKey: "k", route: "A", destination: "Uptown", direction: "NORTH", stopId: "A1", partId: "A1", area: "", time: now + 600, pattern: "", patternSource: "feed", location: "", feed: "ace", timestamp: now - 2400)])
		let age = try expectValue(AppModel.predictionSourceTimestamp(mixed), "prediction source time")
		try expect(OfflineDisplay.estimateLabel(timestamp: age, now: now, preferences: OfflinePreferences()) == "Last known times · source 40m ago", "Alerts and car feeds must not make old predictions look fresh, got \(OfflineDisplay.estimateLabel(timestamp: age, now: now, preferences: OfflinePreferences()))")
		print("PASS: the offline source age is the oldest prediction, not the newest ancillary feed")

		// Preloading other stations' trips covers favorites at any distance, even with the radius off.
		let preloadDirectory = directory.appendingPathComponent("preload")
		try FileManager.default.createDirectory(at: preloadDirectory, withIntermediateDirectories: true)
		try JSONEncoder().encode(stations).write(to: preloadDirectory.appendingPathComponent("stations.json"))
		var preload = PortableSettings()
		preload.favorites = ["far"]
		preload.offline.nearbyRadiusFeet = 0
		preload.offline.preloadOtherStationTrips = true
		try DeviceSettingsStore(fileURL: preloadDirectory.appendingPathComponent("settings.json")).save(DeviceSettings(settings: preload, lastStation: "viewed"))
		let farTrip = Departure(key: "f1@far", tripKey: "f1", route: "A", destination: "Uptown", direction: "NORTH", stopId: "A3", partId: "A3", area: "", time: now + 900, pattern: "Local", patternSource: "feed", location: "", feed: "ace", timestamp: source)
		FixtureAPI.set(api + "stations/far/board", try JSONEncoder().encode(Board(station: stations[2], generatedAt: now, sources: [SourceState(id: "ace", timestamp: source)], departures: [farTrip])))
		FixtureAPI.set(api + "trips?key=f1", try JSONEncoder().encode(TripDetail(train: Train(key: "f1", feed: "ace", tripId: "f1", route: "A", destination: "Uptown", direction: "NORTH", timestamp: source, stops: [StopPrediction(id: "A3", name: "Far", stationId: "far", arrival: now + 900)]))))
		let preloader = AppModel(stateDirectory: preloadDirectory)
		let preloading = Task { await preloader.runWhileActive() }
		try await waitFor("distant favorite trip", timeout: 1000) { FixtureAPI.requests(api + "trips?key=f1") > 0 }
		for _ in 0..<100 { if await preloader.cachedTrip("f1")?.isComplete == true { break }; try await Task.sleep(for: .milliseconds(10)) }
		try expect(await preloader.cachedTrip("f1")?.isComplete == true, "A distant favorite's next trip must be saved when other-station trips are preloaded with the radius off")
		let pathKey = "path|unknown|arrival-0|"
		var positional = memory
		positional.train.key = pathKey
		positional.train.feed = "path"
		FixtureAPI.set(api + "trips?key=" + pathKey, try JSONEncoder().encode(positional))
		preloader.openTrip(pathKey)
		_ = await preloader.refreshTrip(pathKey)
		try expect(preloader.liveTrips[pathKey]?.detail == positional, "Opened PATH arrivals remain available as live details")
		try expect(await preloader.cachedTrip(pathKey) == nil, "Opening a positional PATH arrival must not automatically cache a reusable train identity")
		await preloader.setSimulatedOutage(true)
		await preloader.saveTripOffline(pathKey, detail: preloader.liveTrips[pathKey]?.detail)
		try expect(await preloader.cachedTrip(pathKey)?.detail == positional && preloader.isTripSaved(pathKey), "A manual PATH save after an outage keeps the report the user saw")
		preloader.closeTrip(pathKey)
		print("PASS: PATH arrivals are saved only explicitly, including full details retained after an outage")
		await stop(preloader, task: preloading, background: true)
		print("PASS: preloading other stations' trips includes distant favorites with the nearby radius off")
		try await retentionAndLegacyRegressions(directory: directory.appendingPathComponent("retention"), stations: stations)
	}

	@MainActor static func retentionAndLegacyRegressions(directory: URL, stations: [Station]) async throws {
		// Failure modes: an offline relaunch serving automatic entries past retention, and
		// legacy board files (which have no endpoint) imported into a non-production cache.
		let endpoint = ProcessInfo.processInfo.environment["SFN_API_BASE_URL"]!
		let old = Date().timeIntervalSince1970 - 7 * 3600
		let folder = directory.appendingPathComponent("expired")
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		try JSONEncoder().encode(stations).write(to: folder.appendingPathComponent("stations.json"))
		try DeviceSettingsStore(fileURL: folder.appendingPathComponent("settings.json")).save(DeviceSettings(settings: PortableSettings(), lastStation: "viewed"))
		let past = OfflineTransitStore(directory: folder.appendingPathComponent("OfflineTransit", isDirectory: true), clock: { old })
		let board = Board(station: stations[0], generatedAt: old, sources: [SourceState(id: "ace", timestamp: old)], departures: [Departure(key: "x@viewed", tripKey: "x", route: "A", destination: "Uptown", direction: "NORTH", stopId: "A1", partId: "A1", area: "", time: old + 600, pattern: "", patternSource: "feed", location: "", feed: "ace", timestamp: old)])
		try await past.saveBoard(board, endpoint: endpoint)
		try await past.saveTrip(TripDetail(train: Train(key: "x", feed: "ace", tripId: "x", route: "A", destination: "Uptown", direction: "NORTH", timestamp: old, stops: [StopPrediction(id: "A1", name: "Viewed", stationId: "viewed", arrival: old + 600)])), endpoint: endpoint, manuallySaved: true)
		setenv("SFN_SIMULATE_OUTAGE", "1", 1)
		defer { setenv("SFN_SIMULATE_OUTAGE", "0", 1) }
		let expired = AppModel(stateDirectory: folder)
		let foreground = Task { await expired.runWhileActive() }
		try await waitFor("saved trains restored") { expired.savedTrips.count == 1 }
		try await Task.sleep(for: .milliseconds(100))
		try expect(expired.board == nil, "An offline relaunch must not serve an automatic board past retention")
		try expect(expired.isTripSaved("x"), "Saved trains are never expired")
		await stop(expired, task: foreground, background: true)
		print("PASS: retention applies on an offline relaunch before saved boards are shown; saved trains stay")

		let legacy = directory.appendingPathComponent("legacy")
		try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
		try JSONEncoder().encode(stations).write(to: legacy.appendingPathComponent("stations.json"))
		try DeviceSettingsStore(fileURL: legacy.appendingPathComponent("settings.json")).save(DeviceSettings(settings: PortableSettings(), lastStation: "viewed"))
		let recent = Board(station: stations[0], generatedAt: Date().timeIntervalSince1970, sources: [SourceState(id: "ace", timestamp: Date().timeIntervalSince1970 - 60)])
		let legacyName = "board-" + Data("viewed".utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_") + ".json"
		let legacyData = try JSONEncoder().encode(recent)
		try legacyData.write(to: legacy.appendingPathComponent(legacyName))
		let elsewhere = AppModel(stateDirectory: legacy)
		try await Task.sleep(for: .milliseconds(300))
		try expect(elsewhere.board == nil && elsewhere.widgetStore!.board(stationID: "viewed", endpoint: elsewhere.endpoint) == nil, "Legacy boards must not be imported into a non-production endpoint")
		try elsewhere.acceptSettings(elsewhere.portableSettings, sync: nil)
		try expect(elsewhere.widgetStore!.board(stationID: "viewed", endpoint: elsewhere.endpoint) == nil, "Settings import must not republish legacy production boards under a development endpoint")
		setenv("SFN_API_BASE_URL", TransitAPI.productionBaseURL.absoluteString, 1)
		defer { setenv("SFN_API_BASE_URL", endpoint, 1) }
		// Restore only; no foreground run, so nothing reaches the production server.
		let production = AppModel(stateDirectory: legacy)
		try await waitFor("legacy production board") { production.board?.station.id == "viewed" }
		try expect(production.boardIsCached && (try? Data(contentsOf: legacy.appendingPathComponent(legacyName))) == legacyData, "Production imports legacy boards and leaves the original file untouched")
		print("PASS: legacy board files migrate only into the production cache and are never modified")
	}

	static func expectValue<T>(_ value: T?, _ message: String) throws -> T {
		guard let value else { throw Failure.expectation(message) }
		return value
	}

	@MainActor final class LocationSequence {
		var requests = 0
		var location = CLLocation(latitude: 40.755290, longitude: -73.987495)
		func locate() async throws -> CLLocation {
			requests += 1
			try await Task.sleep(for: .milliseconds(200))
			return location
		}
	}

	@MainActor static func waitForStation(_ id: String, in app: AppModel) async throws {
		for _ in 0..<200 {
			if app.stationID == id { return }
			try await Task.sleep(for: .milliseconds(10))
		}
		throw Failure.expectation("Expected \(id), got \(app.stationID)")
	}

	@MainActor static func waitFor(_ message: String = "condition", timeout: Int = 300, _ condition: @MainActor () -> Bool) async throws {
		for _ in 0..<timeout {
			if condition() { return }
			try await Task.sleep(for: .milliseconds(10))
		}
		throw Failure.expectation("Timed out waiting for \(message)")
	}

	@MainActor static func stop(_ app: AppModel, task: Task<Void, Never>, background: Bool) async {
		app.suspend(background: background)
		task.cancel()
		await task.value
	}

	static func expect(_ condition: Bool, _ message: String) throws {
		if !condition { throw Failure.expectation(message) }
	}
}
