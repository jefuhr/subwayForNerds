import CoreLocation
import Foundation
import TransitCore

// The startup model only needs theme identities; UI rendering is tested by XCTest.
struct AppTheme {
	let id: String
	static let all = [AppTheme(id: "subway")]
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

	@MainActor static func stop(_ app: AppModel, task: Task<Void, Never>, background: Bool) async {
		app.suspend(background: background)
		task.cancel()
		await task.value
	}

	static func expect(_ condition: Bool, _ message: String) throws {
		if !condition { throw Failure.expectation(message) }
	}
}
