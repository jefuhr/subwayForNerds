import Foundation
import Testing
@testable import TransitCore

struct UnitsTests {
	@Test func radiusConversionsRoundTripWithoutChangingCanonicalFeet() {
		for unit in DistanceUnit.allCases {
			for feet in [1, 5280, 26400] {
				#expect(unit.radiusFeet(from: unit.radiusInput(feet: feet)) == feet)
			}
			for invalid in ["", "NaN", "Infinity", "-1", "0", "1e2", "1,000", "nope"] {
				#expect(unit.radiusFeet(from: invalid) == nil)
			}
			#expect(unit.radiusFeet(from: unit.radiusInput(feet: 26401)) == nil)
		}
		#expect(DistanceUnit.mi.radiusFeet(from: "1.5") == 7920)
		#expect(DistanceUnit.m.radiusFeet(from: "0.3048") == 1)
		#expect(DistanceUnit.ft.radiusFeet(from: "1.5") == 2)
		#expect(DistanceUnit.mi.radiusFeet(from: "5.0001") == nil)
	}
	@Test func nearbyDistanceLabelsRespectUnitsAndTinyDistances() {
		#expect(DistanceUnit.auto.distanceLabel(meters: 50) == "50 m")
		#expect(DistanceUnit.auto.distanceLabel(meters: 1609.344) == "1.6 km")
		#expect(DistanceUnit.mi.distanceLabel(meters: 1609.344) == "1 mi")
		#expect(DistanceUnit.ft.distanceLabel(meters: 1609.344) == "5280 ft")
		#expect(DistanceUnit.m.distanceLabel(meters: 1609.344) == "1609 m")
		#expect(DistanceUnit.km.distanceLabel(meters: 1609.344) == "1.61 km")
		#expect(DistanceUnit.mi.distanceLabel(meters: 0.3048) == "<0.01 mi")
		#expect(DistanceUnit.km.distanceLabel(meters: 0.3048) == "<0.01 km")
	}
	@Test func wallClocksUseNewYorkAndCountdownFallbackUsesChosenFormat() throws {
		let midnight = try #require(ISO8601DateFormatter().date(from: "2026-01-15T05:00:00Z")).timeIntervalSince1970
		#expect(Display.clockTime(midnight) == "12:00 AM")
		#expect(Display.clockTime(midnight, format: .twentyFourHour) == "00:00")
		#expect(Display.clockTime(midnight + 43200, format: .twentyFourHour) == "12:00")
		#expect(Display.clockTime(midnight + 43200, format: .twelveHour) == "12:00 PM")
		#expect(Display.clockTime(midnight + 46800, format: .twentyFourHour) == "13:00")
		#expect(Display.countdown(midnight, timestamp: midnight, now: midnight, cached: true, timeFormat: .twentyFourHour).value == "00:00")
		#expect(Display.countdown(midnight + 120, timestamp: midnight, now: midnight, timeFormat: .twentyFourHour) == Countdown(value: "2", unit: "min"))
		#expect(Display.clockTime(nil, format: .twentyFourHour) == "—")
		let summerMidnight = try #require(ISO8601DateFormatter().date(from: "2026-07-15T04:00:00Z")).timeIntervalSince1970
		#expect(Display.clockTime(summerMidnight, format: .twentyFourHour) == "00:00")
	}
	@Test func publishedOutageClocksChangeOnlyRecognizedWallClockText() {
		#expect(Display.publishedClockText("09/05/2026 08:00 PM", format: .twentyFourHour) == "09/05/2026 20:00")
		#expect(Display.publishedClockText("9/6/2026 12:01 AM", format: .twentyFourHour) == "9/6/2026 00:01")
		#expect(Display.publishedClockText("09/06/2026 12:00 PM", format: .twentyFourHour) == "09/06/2026 12:00")
		#expect(Display.publishedClockText("09/05/2026 08:00 PM", format: .twelveHour) == "09/05/2026 08:00 PM")
		for text in ["Until further notice", "2026-09-05T20:00:00Z", "09/05/2026", "09/05/2026 20:00", "09/05/2026 13:00 PM", "09/05/2026 08:99 PM", "work ends at 08:00 PM", ""] {
			#expect(Display.publishedClockText(text, format: .twentyFourHour) == text)
		}
	}
	@Test func oldFilesMigrateAndProvidedUnitsValidateStrictly() throws {
		for version in [1, 2] {
			var root = try JSONSerialization.jsonObject(with: NerdsSettingsFile(settings: PortableSettings(), lastStation: "602").data()) as! [String: Any]
			root["version"] = version
			var settings = root["settings"] as! [String: Any]
			settings.removeValue(forKey: "units"); root["settings"] = settings
			#expect(try JSONDecoder().decode(PortableSettings.self, from: JSONSerialization.data(withJSONObject: settings)).units == UnitPreferences())
			#expect(try NerdsSettingsFile.decode(JSONSerialization.data(withJSONObject: root)).settings.units == UnitPreferences())
			for invalid: Any in [["distance": "meters", "time": "24h"], ["distance": "m", "time": "24"], ["distance": "m"], ["distance": "m", "time": "24h", "extra": true], NSNull()] {
				settings["units"] = invalid; root["settings"] = settings
				#expect(throws: (any Error).self) { try NerdsSettingsFile.decode(JSONSerialization.data(withJSONObject: root)) }
			}
		}
	}
	@Test func unitsPersistRoundTripMergeAndReachWidgetSnapshot() throws {
		var local = PortableSettings(); local.units.distance = .km
		var remote = PortableSettings(); remote.units.time = .twentyFourHour
		let merged = try SettingsMerge.merge(base: PortableSettings(), local: local, remote: remote)
		#expect(merged.conflicts.isEmpty)
		#expect(merged.settings.units == UnitPreferences(distance: .km, time: .twentyFourHour))
		#expect(try NerdsSettingsFile.decode(NerdsSettingsFile(settings: merged.settings, lastStation: "602").data()).settings == merged.settings)
		let state = WidgetSharedState(units: merged.settings.units)
		#expect(try JSONDecoder().decode(WidgetSharedState.self, from: JSONEncoder().encode(state)).units == merged.settings.units)
		var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
		legacy.removeValue(forKey: "units")
		#expect(try JSONDecoder().decode(WidgetSharedState.self, from: JSONSerialization.data(withJSONObject: legacy)).units == UnitPreferences())
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: directory) }
		let store = DeviceSettingsStore(fileURL: directory.appendingPathComponent("settings.json"))
		try store.save(DeviceSettings(settings: merged.settings, lastStation: "602"))
		#expect(try store.load()?.settings.units == merged.settings.units)
	}
}
