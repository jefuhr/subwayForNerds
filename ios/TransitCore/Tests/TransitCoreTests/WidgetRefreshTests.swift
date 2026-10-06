import Foundation
import Testing
@testable import TransitCore

struct WidgetRefreshTests {
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
