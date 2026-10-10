import Foundation
import Testing
@testable import TransitCore

struct WidgetRefreshTests {
	@Test func newestUsableLocationWinsAcrossAppAndWidgetRefreshes() {
		let app = WidgetCoordinate(latitude: 41, longitude: -74, timestamp: 990)
		let extensionFix = WidgetCoordinate(latitude: 40, longitude: -74, timestamp: 980)
		let otherWidget = WidgetCoordinate(latitude: 42, longitude: -74, timestamp: 995)
		#expect(WidgetCoordinate.newestUsable(in: [extensionFix, app, nil], now: 1000) == app)
		#expect(WidgetCoordinate.newestUsable(in: [nil, app, otherWidget], now: 1000) == otherWidget)
		#expect(WidgetCoordinate.newestUsable(in: [nil, app, otherWidget], now: 1300) == nil)
		let stations = [Station(id: "a", name: "A", borough: "M", routes: ["Q"], lat: 40, lon: -74),
			Station(id: "b", name: "B", borough: "M", routes: ["Q"], lat: 41, lon: -74)]
		var state = WidgetSharedState(favorites: ["a", "b"], stations: stations, appLocation: app)
		#expect(state.selectedStation(location: extensionFix, previous: "a", now: 1000)?.id == "b")
		#expect(state.selectedStation(location: nil, previous: "a", now: 1300)?.id == "a")
		state.favorites = ["a"]
		#expect(state.selectedStation(location: nil, previous: "b", now: 1000)?.id == "a")
	}

	@Test func locationFreshnessHasFiniteBoundsAndRejectsFutureFixes() {
		#expect(WidgetCoordinate(latitude: 40, longitude: -74, timestamp: 700.001).isUsable(now: 1000))
		#expect(WidgetCoordinate(latitude: 40, longitude: -74, timestamp: 1000).isUsable(now: 1000))
		for timestamp in [700, 1000.001, .nan, .infinity, -.infinity] {
			#expect(!WidgetCoordinate(latitude: 40, longitude: -74, timestamp: timestamp).isUsable(now: 1000))
		}
		#expect(!WidgetCoordinate(latitude: 91, longitude: -74, timestamp: 1000).isUsable(now: 1000))
		#expect(!WidgetCoordinate(latitude: 40, longitude: 181, timestamp: 1000).isUsable(now: 1000))
		#expect(!WidgetCoordinate(latitude: 40, longitude: -74, timestamp: 1000).isUsable(now: .nan))
	}

	@Test func legacyDisplaysKeepTheirSettingsAndFiveMinuteRefresh() throws {
		let legacy = Data("""
		{"display":{"fields":["carType"],"compact":false,"trainsPerDirection":4,"timeStyle":"clock"},
		"lockScreen":{"display":{"fields":[],"compact":true,"trainsPerDirection":0,"timeStyle":"minutes"},"directionOrder":"uptownLeft","showService":false}}
		""".utf8)
		let settings = try JSONDecoder().decode(WidgetPreferences.self, from: legacy)
		#expect(settings.display.refreshInterval == .fiveMinutes)
		#expect(settings.lockScreen.display.refreshInterval == .fiveMinutes)
		#expect(settings.display.fields == [.carType] && !settings.display.compact)
		#expect(settings.display.trainsPerDirection == 4 && settings.display.timeStyle == .clock)
		#expect(settings.lockScreen.display.fields.isEmpty && settings.lockScreen.display.trainsPerDirection == 0)
		#expect(settings.lockScreen.directionOrder == .uptownLeft && !settings.lockScreen.showService)
		#expect(try JSONDecoder().decode(WidgetDisplayOptions.self, from: Data("{}".utf8)) == WidgetDisplayOptions())
	}

	@Test func refreshIntervalsPersistIndependentlyAndResetOnlyTheirDisplay() throws {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: directory) }
		let store = WidgetSharedStore(directory: directory)
		var state = WidgetSharedState(favorites: ["44"])
		state.widgets.display.refreshInterval = .tenMinutes
		state.widgets.lockScreen.display.refreshInterval = .oneMinute
		state.widgets.stations["44"] = StationPreference(routes: ["Q"], view: .service)
		state.widgets.matchAppFilters = true
		try store.save(state)
		var restored = try store.load()
		#expect(restored == state)
		#expect(restored.widgets.display.refreshInterval.seconds == 600)
		#expect(restored.widgets.lockScreen.display.refreshInterval.seconds == 60)
		restored.widgets.display = WidgetDisplayOptions()
		#expect(restored.widgets.lockScreen == state.widgets.lockScreen)
		#expect(restored.widgets.display.refreshInterval == .fiveMinutes)
		restored.widgets.lockScreen = LockScreenWidgetOptions()
		#expect(restored.widgets.lockScreen.display.refreshInterval == .fiveMinutes)
		#expect(restored.widgets.stations == state.widgets.stations && restored.widgets.matchAppFilters)
	}

	@Test func refreshChoicesRoundTripAndUnsupportedChoicesKeepOtherSettings() throws {
		#expect(WidgetRefreshInterval.allCases.map(\.seconds) == [60, 120, 300, 600, 900, 1800, 3600])
		for interval in WidgetRefreshInterval.allCases {
			var display = WidgetDisplayOptions()
			display.refreshInterval = interval
			#expect(try JSONDecoder().decode(WidgetDisplayOptions.self, from: JSONEncoder().encode(display)) == display)
		}
		let unsupported = try JSONDecoder().decode(WidgetDisplayOptions.self, from: Data("{\"refreshInterval\":7,\"fields\":[\"track\"],\"timeStyle\":\"clock\"}".utf8))
		#expect(unsupported.refreshInterval == .fiveMinutes)
		#expect(unsupported.fields == [.track] && unsupported.timeStyle == .clock)
	}
}
