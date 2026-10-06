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
		var replacement = file; replacement.settings.favorites = ["changed"]
		var failed = false
		do { try unavailable.importSettings(replacement) } catch { failed = true }
		try expect(failed && unavailable.portableSettings == file.settings, "A failed import write must retain the previous settings in memory")
		try FileManager.default.removeItem(at: settingsURL)
		try FileManager.default.moveItem(at: backupURL, to: settingsURL)
		print("PASS: .nerds preview, atomic import, widget sharing, relaunch and write-failure recovery")

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
