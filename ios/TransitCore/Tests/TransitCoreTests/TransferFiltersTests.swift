import Foundation
import Testing
@testable import TransitCore

struct TransferFiltersTests {
	private func departure(_ key: String, route: String, direction: String = "NORTH", time: TimeInterval = 1300, timestamp: TimeInterval = 1000) -> Departure {
		Departure(key: key, tripKey: key, route: route, destination: "Test", direction: direction, stopId: "L02N", partId: "L02", area: "Platform", time: time, pattern: "Local", patternSource: "feed", location: "", feed: "gtfs", timestamp: timestamp)
	}
	private func settingsJSON(_ data: Data) throws -> [String: Any] { try JSONSerialization.jsonObject(with: data) as! [String: Any] }
	private func fileData(version: Int, transfers: Any?) throws -> Data {
		var root = try settingsJSON(NerdsSettingsFile(settings: PortableSettings(), lastStation: "602").data())
		var settings = root["settings"] as! [String: Any]
		settings["transfers"] = transfers
		if version < 4 { settings["combinedStations"] = nil; settings["hiddenRoutes"] = nil }
		if version < 3 { settings["offline"] = nil }
		root["settings"] = settings; root["version"] = version
		return try JSONSerialization.data(withJSONObject: root)
	}

	@Test func defaultsAreSharedAndEmpty() {
		let settings = PortableSettings()
		#expect(settings.transfers == TransferPreferences())
		#expect(settings.transfers.separateFilters == false)
		#expect(settings.transfers.stations.isEmpty)
	}

	@Test func sharedModeReadsAndWritesTheTargetStationBoardFiltersPreservingView() {
		var settings = PortableSettings()
		settings.stations["601"] = StationPreference(direction: "SOUTH", routes: ["L"], view: .family)
		settings.stations["602"] = StationPreference(direction: "NORTH", routes: ["4"], view: .track)
		#expect(settings.transferFilter(for: "601") == TransferStationPreference(direction: "SOUTH", routes: ["L"]))
		settings.updateTransferFilter(for: "601") { $0.direction = "NORTH"; $0.routes.append("1") }
		#expect(settings.stations["601"] == StationPreference(direction: "NORTH", routes: ["L", "1"], view: .family))
		// The unrelated selected station is never touched.
		#expect(settings.stations["602"] == StationPreference(direction: "NORTH", routes: ["4"], view: .track))
		#expect(settings.transfers.stations.isEmpty)
		settings.updateTransferFilter(for: "618") { $0.routes = ["L"] }
		#expect(settings.stations["618"] == StationPreference(direction: "ALL", routes: ["L"], view: .track))
	}

	@Test func separateModeSeedsFromBoardOnceThenEditsIndependently() {
		var settings = PortableSettings()
		settings.stations["601"] = StationPreference(direction: "SOUTH", routes: ["L"], view: .family)
		settings.transfers.separateFilters = true
		// Before first use the board filters apply.
		#expect(settings.transferFilter(for: "601") == TransferStationPreference(direction: "SOUTH", routes: ["L"]))
		#expect(settings.seedTransferFilter(for: "601") == true)
		#expect(settings.seedTransferFilter(for: "601") == false)
		#expect(settings.transfers.stations["601"] == TransferStationPreference(direction: "SOUTH", routes: ["L"]))
		settings.updateTransferFilter(for: "601") { $0.direction = "ALL"; $0.routes = ["1"] }
		#expect(settings.stations["601"] == StationPreference(direction: "SOUTH", routes: ["L"], view: .family))
		#expect(settings.transferFilter(for: "601") == TransferStationPreference(direction: "ALL", routes: ["1"]))
		// Later board edits do not change an already used transfer entry.
		settings.stations["601"]?.routes = ["F"]
		#expect(settings.transferFilter(for: "601") == TransferStationPreference(direction: "ALL", routes: ["1"]))
		// An edit before any explicit seed still starts from the board filters.
		settings.stations["618"] = StationPreference(direction: "NORTH", routes: [], view: .track)
		settings.updateTransferFilter(for: "618") { $0.routes = ["L"] }
		#expect(settings.transfers.stations["618"] == TransferStationPreference(direction: "NORTH", routes: ["L"]))
	}

	@Test func sharedModeNeverSeedsAndDisablingRetainsTheMap() {
		var settings = PortableSettings()
		#expect(settings.seedTransferFilter(for: "601") == false)
		#expect(settings.transfers.stations.isEmpty)
		settings.transfers.separateFilters = true
		settings.updateTransferFilter(for: "601") { $0.direction = "SOUTH" }
		settings.transfers.separateFilters = false
		#expect(settings.transfers.stations["601"]?.direction == "SOUTH")
		#expect(settings.transferFilter(for: "601").direction == "ALL")
		settings.transfers.separateFilters = true
		#expect(settings.transferFilter(for: "601").direction == "SOUTH")
	}

	@Test func choicesComeFromStationMetadataPlusConnectionsWithAliasesAndHiddenLines() {
		let choices = TransferFilters.choices(stationRoutes: ["L", "1", "GS", "F"], connections: [departure("a", route: "M"), departure("b", route: "FS"), departure("c", route: "L")], hiddenRoutes: ["F"])
		#expect(choices == ["1", "L", "M", "S"])
		// Stable regardless of which connections are currently reported.
		#expect(TransferFilters.choices(stationRoutes: ["L", "1"], connections: [], hiddenRoutes: []) == ["1", "L"])
	}

	@Test func connectionsHonorDirectionRoutesAliasesHiddenLinesAndLiveness() {
		let connections = [
			departure("n1", route: "1"), departure("s1", route: "1", direction: "SOUTH"),
			departure("shuttle", route: "GS"), departure("hidden", route: "F"),
			departure("past", route: "L", time: 900), departure("stale", route: "L", timestamp: 0)
		]
		let now: TimeInterval = 1000
		let all = TransferFilters.usable(connections, hiddenRoutes: ["F"], now: now)
		#expect(all.map(\.key) == ["n1", "s1", "shuttle"])
		#expect(TransferFilters.filter(all, by: TransferStationPreference(direction: "NORTH", routes: [])).map(\.key) == ["n1", "shuttle"])
		#expect(TransferFilters.filter(all, by: TransferStationPreference(direction: "ALL", routes: ["S"])).map(\.key) == ["shuttle"])
		// Stored legacy aliases still match their normalized route.
		#expect(TransferFilters.filter(all, by: TransferStationPreference(direction: "ALL", routes: ["GS"])).map(\.key) == ["shuttle"])
		// A stored selection of a hidden line is kept but matches nothing visible.
		#expect(TransferFilters.filter(all, by: TransferStationPreference(direction: "ALL", routes: ["F"])).isEmpty)
	}

	@Test func toggleMatchesBoardSemantics() {
		var value = TransferStationPreference()
		TransferFilters.toggle("L", in: &value)
		TransferFilters.toggle("1", in: &value)
		#expect(value.routes == ["L", "1"])
		TransferFilters.toggle("L", in: &value)
		#expect(value.routes == ["1"])
	}

	@Test func importedAliasesToggleAsTheirNormalizedChip() {
		var value = TransferStationPreference(direction: "ALL", routes: ["GS", "FS", "SI", "L"])
		#expect(TransferFilters.selectedChips(value) == ["L", "S", "SIR"])
		// Tapping the selected S chip removes every stored shuttle alias instead of appending S.
		TransferFilters.toggle("S", in: &value)
		#expect(value.routes == ["SI", "L"])
		TransferFilters.toggle("SIR", in: &value)
		#expect(value.routes == ["L"])
		TransferFilters.toggle("SIR", in: &value)
		#expect(value.routes == ["L", "SIR"])
		#expect(TransferFilters.selectedChips(value) == ["L", "SIR"])
	}

	@Test func canonicalV5FixtureDecodesAndReencodes() throws {
		let url = try #require(Bundle.module.url(forResource: "transfers", withExtension: "nerds", subdirectory: "Fixtures"))
		let file = try NerdsSettingsFile.decode(Data(contentsOf: url))
		#expect(file.version == 5)
		#expect(file.settings.transfers.separateFilters)
		#expect(file.settings.transfers.stations["602"] == TransferStationPreference(direction: "SOUTH", routes: ["5", "6"]))
		#expect(file.settings.transfers.stations["path-wtc"] == TransferStationPreference(direction: "TO_NJ", routes: []))
		let reencoded = try NerdsSettingsFile.decode(file.data())
		#expect(reencoded.version == 5)
		#expect(reencoded.settings == file.settings)
		#expect(try reencoded.settings.json() == file.settings.json())
	}

	@Test func exportsSortTransferRoutes() throws {
		var settings = PortableSettings()
		settings.transfers.stations["601"] = TransferStationPreference(direction: "ALL", routes: ["L", "1"])
		let root = try settingsJSON(NerdsSettingsFile(settings: settings, lastStation: "602").data())
		let transfers = (root["settings"] as! [String: Any])["transfers"] as! [String: Any]
		#expect(((transfers["stations"] as! [String: Any])["601"] as! [String: Any])["routes"] as? [String] == ["1", "L"])
	}

	@Test func v5RoundTripsTransfersAndExportsCurrentVersion() throws {
		var settings = PortableSettings()
		settings.transfers.separateFilters = true
		settings.transfers.stations["601"] = TransferStationPreference(direction: "SOUTH", routes: ["L", "1"])
		let data = try NerdsSettingsFile(settings: settings, lastStation: "602").data()
		let root = try settingsJSON(data)
		#expect(root["version"] as? Int == 5)
		let transfers = (root["settings"] as! [String: Any])["transfers"] as! [String: Any]
		#expect(transfers["separateFilters"] as? Bool == true)
		let routes = ((transfers["stations"] as! [String: Any])["601"] as! [String: Any])["routes"] as? [String]
		#expect(routes.map(Set.init) == ["1", "L"])
		let restored = try NerdsSettingsFile.decode(data)
		#expect(restored.settings.transfers.separateFilters)
		#expect(restored.settings.transfers.stations["601"]?.direction == "SOUTH")
		#expect(restored.settings == settings)
	}

	@Test func olderVersionsImportAsSharedAndCannotContainTransfers() throws {
		for version in 1...4 {
			let restored = try NerdsSettingsFile.decode(fileData(version: version, transfers: nil))
			#expect(restored.settings.transfers == TransferPreferences(), "v\(version)")
			#expect(throws: (any Error).self) { try NerdsSettingsFile.decode(fileData(version: version, transfers: ["separateFilters": false, "stations": [:]])) }
		}
		#expect(throws: (any Error).self) { try NerdsSettingsFile.decode(fileData(version: 5, transfers: nil)) }
		#expect(throws: (any Error).self) { try NerdsSettingsFile.decode(fileData(version: 6, transfers: ["separateFilters": false, "stations": [:]])) }
		_ = try NerdsSettingsFile.decode(fileData(version: 5, transfers: ["separateFilters": false, "stations": [:]]))
	}

	@Test func invalidTransferSettingsAreRejected() throws {
		let invalid: [Any] = [
			"shared",
			["separateFilters": false],
			["separateFilters": "yes", "stations": [:]],
			["separateFilters": false, "stations": [:], "extra": true],
			["separateFilters": false, "stations": ["601": ["direction": "SOUTH", "routes": [], "view": "track"]]],
			["separateFilters": false, "stations": ["601": ["direction": "UP", "routes": []]]],
			["separateFilters": false, "stations": ["601": ["direction": "ALL", "routes": ["L", "L"]]]],
			["separateFilters": false, "stations": ["601": ["direction": "ALL", "routes": (0...128).map { "R\($0)" }]]],
			["separateFilters": false, "stations": ["601": ["direction": "ALL"]]],
			["separateFilters": false, "stations": ["__proto__": ["direction": "ALL", "routes": []]]],
			["separateFilters": false, "stations": ["": ["direction": "ALL", "routes": []]]]
		]
		for value in invalid {
			#expect(throws: (any Error).self, "\(value)") { try NerdsSettingsFile.decode(fileData(version: 5, transfers: value)) }
		}
		var settings = PortableSettings()
		settings.transfers.stations["601"] = TransferStationPreference(direction: "UP", routes: [])
		#expect(throws: (any Error).self) { try settings.validated() }
	}

	@Test func normalizationSortsTransferRoutes() throws {
		var a = PortableSettings(); a.transfers.stations["601"] = TransferStationPreference(direction: "ALL", routes: ["L", "1"])
		var b = PortableSettings(); b.transfers.stations["601"] = TransferStationPreference(direction: "ALL", routes: ["1", "L"])
		#expect(a == b)
		guard case .object(let root) = try a.json(), case .object(let transfers) = root["transfers"], case .object(let stations) = transfers["stations"], case .object(let entry) = stations["601"] else { Issue.record("missing transfers"); return }
		#expect(entry["routes"] == .array([.string("1"), .string("L")]))
		#expect(Set(entry.keys) == ["direction", "routes"])
	}

	@Test func legacyDeviceAndAccountSettingsWithoutTransfersMigrate() throws {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: directory) }
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		var record = try settingsJSON(JSONEncoder().encode(DeviceSettings(settings: PortableSettings(), lastStation: "602")))
		var settings = record["settings"] as! [String: Any]
		settings["transfers"] = nil; record["settings"] = settings
		let store = DeviceSettingsStore(fileURL: directory.appendingPathComponent("settings.json"))
		try JSONSerialization.data(withJSONObject: record).write(to: store.fileURL)
		let loaded = try #require(try store.load())
		#expect(loaded.settings.transfers == TransferPreferences())
		// Account payloads are plain portable settings and migrate the same way.
		let account = try JSONDecoder().decode(PortableSettings.self, from: JSONSerialization.data(withJSONObject: settings))
		#expect(account.transfers == TransferPreferences())
		// Saving afterwards persists the migrated value.
		try store.save(loaded)
		let saved = try settingsJSON(Data(contentsOf: store.fileURL))
		#expect((saved["settings"] as! [String: Any])["transfers"] != nil)
	}

	@Test func mergeCombinesIndependentTransferEditsAndReportsConflicts() throws {
		var base = PortableSettings()
		base.transfers.stations["601"] = TransferStationPreference(direction: "ALL", routes: [])
		var local = base; local.transfers.separateFilters = true
		var remote = base; remote.transfers.stations["618"] = TransferStationPreference(direction: "SOUTH", routes: ["L"])
		let merged = try SettingsMerge.merge(base: base, local: local, remote: remote)
		#expect(merged.conflicts.isEmpty)
		#expect(merged.settings.transfers.separateFilters)
		#expect(merged.settings.transfers.stations["618"]?.routes == ["L"])
		local.transfers.stations["601"]?.direction = "NORTH"
		remote.transfers.stations["601"]?.direction = "SOUTH"
		let conflicted = try SettingsMerge.merge(base: base, local: local, remote: remote)
		#expect(conflicted.conflicts.map(\.path) == ["/transfers/stations/601/direction"])
		#expect(try SettingsMerge.merge(base: base, local: local, remote: remote, choices: ["/transfers/stations/601/direction": "remote"]).settings.transfers.stations["601"]?.direction == "SOUTH")
	}

	@Test func changesListTransferPathsForImportPreview() throws {
		var to = PortableSettings(); to.transfers.separateFilters = true
		to.transfers.stations["601"] = TransferStationPreference(direction: "SOUTH", routes: [])
		let paths = try SettingsMerge.changes(from: PortableSettings(), to: to).map(\.path)
		#expect(paths == ["transfers / separateFilters", "transfers / stations / 601"])
	}
}
