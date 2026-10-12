import Foundation
import Testing
@testable import TransitCore

struct OfflineSettingsTests {
	private func root(_ settings: PortableSettings = PortableSettings()) throws -> [String: Any] {
		try JSONSerialization.jsonObject(with: NerdsSettingsFile(settings: settings, lastStation: "602").data()) as! [String: Any]
	}
	private func decode(_ root: [String: Any]) throws -> NerdsSettingsFile {
		try NerdsSettingsFile.decode(JSONSerialization.data(withJSONObject: root))
	}
	private func withOffline(_ key: String, _ value: Any) throws -> [String: Any] {
		var file = try root(), settings = file["settings"] as! [String: Any], offline = settings["offline"] as! [String: Any]
		offline[key] = value; settings["offline"] = offline; file["settings"] = settings
		return file
	}

	@Test func defaultsMatchTheFrozenContract() throws {
		let value = OfflinePreferences()
		#expect(value == OfflinePreferences(departuresPerLineDirection: 5, tripDetailsPerLineDirection: 2, saveOpenedTrips: true, nearbyRadiusFeet: 2640, preloadOtherStationTrips: false, estimateLimitMinutes: 30, retentionHours: 6, storageLimitMiB: 50, widgetsFollowActiveRide: false))
		let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
		#expect(Set(json.keys) == OfflinePreferences.keys)
		#expect(value.estimateLimit == 1800 && value.retention == 21_600 && value.storageLimitBytes == 52_428_800)
	}

	@Test func v3ExportsOfflineAndOlderFilesMigrateToDefaults() throws {
		var settings = PortableSettings()
		settings.offline = OfflinePreferences(departuresPerLineDirection: 20, nearbyRadiusFeet: 0, estimateLimitMinutes: 120, widgetsFollowActiveRide: true)
		let file = NerdsSettingsFile(settings: settings, lastStation: "602")
		#expect(file.version == 4)
		let restored = try NerdsSettingsFile.decode(file.data())
		#expect(restored.settings.offline == settings.offline)
		#expect(restored.settings == settings)
		for name in ["settings", "favorites"] {
			let legacy = try NerdsSettingsFile.decode(Data(contentsOf: Bundle.module.url(forResource: name, withExtension: "nerds", subdirectory: "Fixtures")!))
			#expect(legacy.version < 3)
			#expect(legacy.settings.offline == OfflinePreferences())
		}
		// Device settings and sync baselines written before v3 decode with defaults.
		var raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(PortableSettings())) as! [String: Any]
		raw.removeValue(forKey: "offline")
		#expect(try JSONDecoder().decode(PortableSettings.self, from: JSONSerialization.data(withJSONObject: raw)).offline == OfflinePreferences())
	}

	@Test func sharedV3FixtureMatchesWeb() throws {
		let file = try NerdsSettingsFile.decode(Data(contentsOf: Bundle.module.url(forResource: "offline", withExtension: "nerds", subdirectory: "Fixtures")!))
		#expect(file.version == 3)
		#expect(file.settings.offline == OfflinePreferences(departuresPerLineDirection: 20, tripDetailsPerLineDirection: 0, saveOpenedTrips: false, nearbyRadiusFeet: 0, preloadOtherStationTrips: true, estimateLimitMinutes: 120, retentionHours: 24, storageLimitMiB: 250, widgetsFollowActiveRide: true))
		#expect(try NerdsSettingsFile.decode(file.data()).settings == file.settings)
	}

	@Test func everyFieldValidatesStrictlyAtItsBoundaries() throws {
		let accepted: [String: [Any]] = [
			"departuresPerLineDirection": [1, 20], "tripDetailsPerLineDirection": [0, 20], "saveOpenedTrips": [true, false], "nearbyRadiusFeet": [0, 26400],
			"preloadOtherStationTrips": [true, false], "estimateLimitMinutes": [5, 15, 30, 60, 120], "retentionHours": [1, 6, 12, 24], "storageLimitMiB": [25, 50, 100, 250], "widgetsFollowActiveRide": [true, false],
		]
		let rejected: [String: [Any]] = [
			"departuresPerLineDirection": [0, 21, 1.5, "5", NSNull()], "tripDetailsPerLineDirection": [-1, 21, 0.5, false], "saveOpenedTrips": [1, "true", NSNull()], "nearbyRadiusFeet": [-1, 26401, 2640.5, "2640"],
			"preloadOtherStationTrips": [0, "false"], "estimateLimitMinutes": [0, 10, 31, 30.5, "30"], "retentionHours": [0, 2, 48, "6"], "storageLimitMiB": [0, 10, 500, "50"], "widgetsFollowActiveRide": ["yes", NSNull()],
		]
		for (key, values) in accepted { for value in values { #expect((try? decode(withOffline(key, value))) != nil, "\(key)=\(value)") } }
		for (key, values) in rejected { for value in values { #expect(throws: (any Error).self, "\(key)=\(value)") { try decode(withOffline(key, value)) } } }
		var file = try root(), settings = file["settings"] as! [String: Any], offline = settings["offline"] as! [String: Any]
		offline.removeValue(forKey: "retentionHours"); settings["offline"] = offline; file["settings"] = settings
		#expect(throws: (any Error).self) { try decode(file) }
		#expect(throws: (any Error).self) { try decode(withOffline("extra", 1)) }
		var invalid = PortableSettings(); invalid.offline.storageLimitMiB = 75
		#expect(throws: (any Error).self) { try invalid.validated() }
	}

	@Test func tripDetailsValidateIndependentlyAndClampWhereUsed() throws {
		let independent = try decode(withOffline("departuresPerLineDirection", 1)).settings.offline
		#expect(independent.tripDetailsPerLineDirection == 2)
		#expect(independent.effectiveTripDetailsPerLineDirection == 1)
		var settings = PortableSettings(); settings.offline.departuresPerLineDirection = 3; settings.offline.tripDetailsPerLineDirection = 20
		#expect(try settings.validated().offline.effectiveTripDetailsPerLineDirection == 3)
	}

	@Test func versionsGateTheOfflineKey() throws {
		var file = try root(), settings = file["settings"] as! [String: Any]
		settings.removeValue(forKey: "offline"); file["settings"] = settings
		#expect(throws: (any Error).self) { try decode(file) }
		settings.removeValue(forKey: "combinedStations"); settings.removeValue(forKey: "hiddenRoutes")
		for version in [1, 2] {
			var older = try root(); older["version"] = version
			#expect(throws: (any Error).self) { try decode(older) }
			older["settings"] = settings
			#expect(try decode(older).settings.offline == OfflinePreferences())
		}
		var future = try root(); future["version"] = 5
		#expect(throws: (any Error).self) { try decode(future) }
	}

	@Test func offlineMergesFieldByFieldWithExplicitConflicts() throws {
		let base = PortableSettings()
		var local = base, remote = base
		local.offline.retentionHours = 24; remote.offline.storageLimitMiB = 250
		local.offline.estimateLimitMinutes = 5; remote.offline.estimateLimitMinutes = 120
		let merged = try SettingsMerge.merge(base: base, local: local, remote: remote)
		#expect(merged.settings.offline.retentionHours == 24)
		#expect(merged.settings.offline.storageLimitMiB == 250)
		#expect(merged.conflicts.map(\.path) == ["/offline/estimateLimitMinutes"])
		#expect(try SettingsMerge.merge(base: base, local: local, remote: remote, choices: ["/offline/estimateLimitMinutes": "remote"]).settings.offline.estimateLimitMinutes == 120)
	}
}
