import Foundation
import Testing
@testable import TransitCore

struct DepartureRowSettingsTests {
	private func root(_ settings: PortableSettings = PortableSettings()) throws -> [String: Any] {
		try JSONSerialization.jsonObject(with: NerdsSettingsFile(settings: settings, lastStation: "602").data()) as! [String: Any]
	}
	private func decode(_ root: [String: Any]) throws -> NerdsSettingsFile {
		try NerdsSettingsFile.decode(JSONSerialization.data(withJSONObject: root))
	}
	/// Rewrites a current export into the shape an older client wrote.
	private func file(version: Int, departureRows: Any?) throws -> [String: Any] {
		var file = try root(), settings = file["settings"] as! [String: Any]
		settings["departureRows"] = departureRows
		if version < 5 { settings["transfers"] = nil }
		if version < 4 { settings["combinedStations"] = nil; settings["hiddenRoutes"] = nil }
		if version < 3 { settings["offline"] = nil }
		file["settings"] = settings; file["version"] = version
		return file
	}
	private func withRows(_ key: String, _ value: Any) throws -> [String: Any] {
		var file = try root(), settings = file["settings"] as! [String: Any], rows = settings["departureRows"] as! [String: Any]
		rows[key] = value; settings["departureRows"] = rows; file["settings"] = settings
		return file
	}
	private let valid: [String: Any] = ["showTrackProvenance": false, "combinePosition": true, "showConsist": true, "showHeadway": true]

	@Test func defaultsMatchTheContract() throws {
		let rows = DepartureRowSettings()
		#expect(rows == DepartureRowSettings(showTrackProvenance: false, combinePosition: true, showConsist: true, showHeadway: true))
		#expect(PortableSettings().departureRows == rows)
		let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(rows)) as! [String: Bool]
		#expect(json == ["showTrackProvenance": false, "combinePosition": true, "showConsist": true, "showHeadway": true])
		let exported = try root()["settings"] as! [String: Any]
		#expect(exported["departureRows"] as? [String: Bool] == json)
	}

	@Test func exportsWriteVersionSix() throws {
		#expect(NerdsSettingsFile.currentVersion == 6)
		#expect(try root()["version"] as? Int == 6)
	}

	@Test func v5FilesImportWithDefaultsAndCannotContainDepartureRows() throws {
		for version in 1...5 {
			let restored = try decode(file(version: version, departureRows: nil))
			#expect(restored.version == version)
			#expect(restored.settings.departureRows == DepartureRowSettings(), "v\(version)")
			#expect(throws: (any Error).self, "v\(version) with departureRows") { try decode(file(version: version, departureRows: valid)) }
		}
		// Re-exporting a migrated file upgrades it to the current version with defaults.
		let reexported = try NerdsSettingsFile.decode(decode(file(version: 5, departureRows: nil)).data())
		#expect(reexported.version == 6)
		#expect(reexported.settings.departureRows == DepartureRowSettings())
	}

	@Test func v6RequiresDepartureRows() throws {
		#expect(throws: (any Error).self) { try decode(file(version: 6, departureRows: nil)) }
		_ = try decode(file(version: 6, departureRows: valid))
		var future = try root(); future["version"] = 7
		#expect(throws: (any Error).self) { try decode(future) }
	}

	@Test func canonicalV6FixtureDecodesAndRoundTrips() throws {
		let url = try #require(Bundle.module.url(forResource: "departure-rows", withExtension: "nerds", subdirectory: "Fixtures"))
		let file = try NerdsSettingsFile.decode(Data(contentsOf: url))
		#expect(file.version == 6)
		#expect(file.settings.departureRows == DepartureRowSettings(showTrackProvenance: true, combinePosition: false, showConsist: false, showHeadway: true))
		#expect(file.settings.transfers.separateFilters)
		let reencoded = try NerdsSettingsFile.decode(file.data())
		#expect(reencoded.version == 6)
		#expect(reencoded.settings == file.settings)
		#expect(try reencoded.settings.json() == file.settings.json())
	}

	@Test func invalidShapesAreRejected() throws {
		let invalid: [Any] = [
			"rows", 1, NSNull(), [Any](),
			[String: Any](),
			["showTrackProvenance": false, "combinePosition": true, "showConsist": true],
			["showTrackProvenance": false, "combinePosition": true, "showConsist": true, "showHeadway": true, "extra": true],
			["showTrackProvenance": 0, "combinePosition": true, "showConsist": true, "showHeadway": true],
			["showTrackProvenance": false, "combinePosition": "true", "showConsist": true, "showHeadway": true],
			["showTrackProvenance": false, "combinePosition": true, "showConsist": NSNull(), "showHeadway": true],
			["showTrackProvenance": false, "combinePosition": true, "showConsist": true, "showHeadway": 1],
		]
		for rows in invalid {
			var file = try root(), settings = file["settings"] as! [String: Any]
			settings["departureRows"] = rows; file["settings"] = settings
			#expect(throws: (any Error).self, "\(rows)") { try decode(file) }
		}
		for key in valid.keys {
			for value in [1, 0, "true", NSNull()] as [Any] {
				#expect(throws: (any Error).self, "\(key)=\(value)") { try decode(withRows(key, value)) }
			}
			var file = try root(), settings = file["settings"] as! [String: Any], rows = settings["departureRows"] as! [String: Any]
			rows.removeValue(forKey: key); settings["departureRows"] = rows; file["settings"] = settings
			#expect(throws: (any Error).self, "missing \(key)") { try decode(file) }
			#expect(try decode(withRows(key, !(valid[key] as! Bool))).settings.departureRows.value(for: key) == !(valid[key] as! Bool))
		}
	}

	@Test func deviceSettingsWithoutDepartureRowsDecodeAsDefaults() throws {
		var raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(PortableSettings())) as! [String: Any]
		raw.removeValue(forKey: "departureRows")
		#expect(try JSONDecoder().decode(PortableSettings.self, from: JSONSerialization.data(withJSONObject: raw)).departureRows == DepartureRowSettings())
	}

	@Test func mergeIsPerKeyAndBooleansNeverConflict() throws {
		let base = PortableSettings()
		var local = base; local.departureRows.combinePosition = false; local.departureRows.showConsist = false
		var remote = base; remote.departureRows.showTrackProvenance = true; remote.departureRows.showConsist = false
		// Independent keys merge; a key changed identically on both sides agrees.
		let merged = try SettingsMerge.merge(base: base, local: local, remote: remote)
		#expect(merged.conflicts.isEmpty)
		#expect(merged.settings.departureRows == DepartureRowSettings(showTrackProvenance: true, combinePosition: false, showConsist: false, showHeadway: true))
		// A key edited on only one side takes that side, whichever side it is.
		var remoteOnly = base; remoteOnly.departureRows.showHeadway = false
		#expect(try SettingsMerge.merge(base: base, local: base, remote: remoteOnly).settings.departureRows.showHeadway == false)
		#expect(try SettingsMerge.merge(base: base, local: remoteOnly, remote: base).settings.departureRows.showHeadway == false)
		// Booleans have two values, so three distinct values (a conflict) cannot occur at a key.
		#expect(try SettingsMerge.merge(base: base, local: local, remote: remote).conflicts.map(\.path) == [])
	}

	@Test func legacyBaselineMigratesToDefaultsBeforeMerging() throws {
		// A sync baseline saved before v6 has no departureRows key.
		var raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(PortableSettings())) as! [String: Any]
		raw.removeValue(forKey: "departureRows")
		let legacy = try JSONDecoder().decode(PortableSettings.self, from: JSONSerialization.data(withJSONObject: raw))
		#expect(legacy.departureRows == DepartureRowSettings())
		var local = legacy; local.departureRows.showConsist = false
		var remote = legacy; remote.departureRows.showTrackProvenance = true
		let merged = try SettingsMerge.merge(base: legacy, local: local, remote: remote)
		#expect(merged.conflicts.isEmpty)
		#expect(merged.settings.departureRows == DepartureRowSettings(showTrackProvenance: true, combinePosition: true, showConsist: false, showHeadway: true))
	}

	@Test func changePreviewNamesTheChangedKey() throws {
		var after = PortableSettings(); after.departureRows.combinePosition = false
		let changes = try SettingsMerge.changes(from: PortableSettings(), to: after)
		#expect(changes.map(\.path) == ["departureRows / combinePosition"])
		#expect(changes.first?.local == .bool(true) && changes.first?.remote == .bool(false))
	}
}

private extension DepartureRowSettings {
	func value(for key: String) -> Bool? {
		switch key {
		case "showTrackProvenance": showTrackProvenance
		case "combinePosition": combinePosition
		case "showConsist": showConsist
		case "showHeadway": showHeadway
		default: nil
		}
	}
}
