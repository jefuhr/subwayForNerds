import Foundation
import Testing
@testable import TransitCore

struct SettingsTests {
	@Test func portableFixtureAndNativeOnlyValuesRoundTrip() throws {
		let url = Bundle.module.url(forResource: "settings", withExtension: "nerds", subdirectory: "Fixtures")!
		let file = try NerdsSettingsFile.decode(Data(contentsOf: url))
		#expect(file.settings.widgets.stations["future:station"]?.view == .corridor)
		#expect(file.settings.widgets.lockScreen.directionOrder == .uptownLeft)
		#expect(file.settings.widgets.lockScreen.display.trainsPerDirection == 5)
		#expect(try NerdsSettingsFile.decode(file.data()).settings == file.settings)
	}
	@Test func refreshIntervalsSurvivePortableRoundTrips() throws {
		var settings = PortableSettings()
		settings.widgets.display.refreshInterval = .oneMinute
		settings.widgets.lockScreen.display.refreshInterval = .thirtyMinutes
		let file = NerdsSettingsFile(settings: settings, lastStation: "602")
		let restored = try NerdsSettingsFile.decode(file.data())
		#expect(restored.settings.widgets.display.refreshInterval == .oneMinute)
		#expect(restored.settings.widgets.lockScreen.display.refreshInterval == .thirtyMinutes)
		var root = try JSONSerialization.jsonObject(with: file.data()) as! [String: Any]
		var rawSettings = root["settings"] as! [String: Any]
		var widgets = rawSettings["widgets"] as! [String: Any]
		var display = widgets["display"] as! [String: Any]
		display["refreshInterval"] = 3; widgets["display"] = display
		rawSettings["widgets"] = widgets; root["settings"] = rawSettings
		#expect(throws: (any Error).self) { try NerdsSettingsFile.decode(JSONSerialization.data(withJSONObject: root)) }
	}
	@Test func olderFilesMigrateLockScreenSettings() throws {
		let file = NerdsSettingsFile(settings: PortableSettings(), lastStation: "602")
		var root = try JSONSerialization.jsonObject(with: file.data()) as! [String: Any]
		var settings = root["settings"] as! [String: Any]
		var widgets = settings["widgets"] as! [String: Any]
		widgets.removeValue(forKey: "lockScreen"); settings["widgets"] = widgets; root["settings"] = settings
		let restored = try NerdsSettingsFile.decode(JSONSerialization.data(withJSONObject: root))
		#expect(restored.settings.widgets.lockScreen.display.fields == [.stationName, .carType])
		#expect(restored.settings.widgets.lockScreen.display.timeStyle == .countdown)
		#expect(restored.settings.widgets.lockScreen.display.trainsPerDirection == 2)
	}
	@Test func invalidFilesNeverReachPersistence() throws {
		for data in [Data("{}".utf8), Data("null".utf8), Data(repeating: 32, count: 1_048_577)] {
			#expect(throws: (any Error).self) { try NerdsSettingsFile.decode(data) }
		}
		var file = NerdsSettingsFile(settings: PortableSettings(), lastStation: "602")
		file.version = 2
		#expect(throws: (any Error).self) { try NerdsSettingsFile.decode(JSONEncoder().encode(file)) }
	}
	@Test func mergeCombinesIndependentChangesAndRequiresConflictingChoices() throws {
		var base = PortableSettings(); base.favorites = ["602", "617"]
		var local = base; local.favorites = ["617", "611"]; local.theme = "night"
		var remote = base; remote.favorites.append("607"); remote.theme = "hacker"
		let merged = try SettingsMerge.merge(base: base, local: local, remote: remote)
		#expect(merged.settings.favorites == ["617", "607", "611"])
		#expect(merged.conflicts.map(\.path) == ["/theme"])
		#expect(try SettingsMerge.merge(base: base, local: local, remote: remote, choices: ["/theme": "remote"]).settings.theme == "hacker")
	}
	@Test func atomicSettingsPreservePreviousFileOnValidationFailure() throws {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: directory) }
		let store = DeviceSettingsStore(fileURL: directory.appendingPathComponent("settings.json"))
		let record = DeviceSettings(settings: PortableSettings(), lastStation: "602")
		try store.save(record)
		var bad = record; bad.settings.widgets.display.trainsPerDirection = 99
		#expect(throws: (any Error).self) { try store.save(bad) }
		#expect(try store.load()?.settings == record.settings)
	}
	@Test func damagedPrimaryRecoversLatestFavoritesFromBackup() throws {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: directory) }
		let store = DeviceSettingsStore(fileURL: directory.appendingPathComponent("settings.json"))
		var settings = PortableSettings(); settings.favorites = ["602", "611"]
		try store.save(DeviceSettings(settings: settings, lastStation: "611"))
		settings.favorites = ["611"]
		try store.save(DeviceSettings(settings: settings, lastStation: "611"))
		try Data("{damaged".utf8).write(to: store.fileURL, options: .atomic)
		#expect(try store.load()?.settings.favorites == ["611"])
	}
	@Test func unreadableSettingsAreNotOverwrittenByRoutineSaves() throws {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: directory) }
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let store = DeviceSettingsStore(fileURL: directory.appendingPathComponent("settings.json"))
		let damaged = Data("{damaged but recoverable".utf8)
		try damaged.write(to: store.fileURL)
		#expect(throws: (any Error).self) { try store.save(DeviceSettings(settings: PortableSettings(), lastStation: "602")) }
		#expect(try Data(contentsOf: store.fileURL) == damaged)
	}
}
