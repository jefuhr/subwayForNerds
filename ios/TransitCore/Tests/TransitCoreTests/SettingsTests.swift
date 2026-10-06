import Foundation
import Testing
@testable import TransitCore

struct SettingsTests {
	@Test func portableFixtureAndNativeOnlyValuesRoundTrip() throws {
		let url = Bundle.module.url(forResource: "settings", withExtension: "nerds", subdirectory: "Fixtures")!
		let file = try NerdsSettingsFile.decode(Data(contentsOf: url))
		#expect(file.settings.widgets.stations["future:station"]?.view == .corridor)
		#expect(try NerdsSettingsFile.decode(file.data()).settings == file.settings)
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
}
