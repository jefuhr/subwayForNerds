import Foundation
import Testing
@testable import TransitCore

struct CombinedBoardsTests {
	private let id = "combined:6d9542db-9ab7-422e-9548-fd66c1d4a384"
	private func station(_ id: String, routes: [String] = ["A"]) -> Station { Station(id: id, name: id, borough: "M", routes: routes, lat: 40.7, lon: -74) }
	private func row(_ key: String = "same", time: Double = 1100) -> Departure {
		Departure(key: key, tripKey: "one-train", route: "A", destination: "Uptown", direction: "NORTH", stopId: "A38N", partId: "A38", area: "Platform", time: time, pattern: "Local", patternSource: "feed", location: "", feed: "ace", timestamp: 1000)
	}
	@Test func boardingOpportunitiesRetainPhysicalOriginAndDuplicateRowsAreRemoved() throws {
		let a = station("628"), b = station("624")
		let combined = try #require(CombinedStationResolver.station(id: id, name: "Downtown", stationIDs: [a.id, b.id], catalog: [a,b]))
		let snapshot = CombinedBoardSnapshot(station: combined, members: [
			MemberBoardSnapshot(station: a, board: Board(station: a, generatedAt: 1000, departures: [row(), row()]), cached: false),
			MemberBoardSnapshot(station: b, board: Board(station: b, generatedAt: 1000, departures: [row(time: 1200)]), cached: false)
		])
		#expect(snapshot.board.departures.count == 2)
		#expect(Set(snapshot.board.departures.map(\.key)).count == 2)
		#expect(Set(snapshot.origins.values.map { $0.station.id }) == ["628", "624"])
		#expect(snapshot.board.departures.allSatisfy { $0.tripKey == "one-train" })
	}
	@Test func mixedCachedAndLiveRowsUseIndependentFreshness() {
		let a = station("628"), b = station("624")
		let combined = station(id)
		let snapshot = CombinedBoardSnapshot(station: combined, members: [
			MemberBoardSnapshot(station: a, board: Board(station: a, generatedAt: 1000, departures: [row(time: 950)]), cached: false),
			MemberBoardSnapshot(station: b, board: Board(station: b, generatedAt: 1000, departures: [row(time: 950)]), cached: true, savedAt: 1000, error: "Offline")
		])
		let rows = groupDepartures(snapshot.board, now: 1000, cachedDepartureKeys: snapshot.cachedDepartureKeys).flatMap(\.departures)
		#expect(rows.count == 1)
		#expect(snapshot.origins[rows[0].key]?.station.id == "624")
		#expect(!snapshot.warnings.isEmpty)
	}
	@Test func savedMemberWarningCanBeOmittedWithoutHidingRealProblems() {
		let saved = station("saved"), missing = station("missing"), stale = station("stale"), unknown = station("unknown"), live = station("live")
		let snapshot = CombinedBoardSnapshot(station: station(id), members: [
			MemberBoardSnapshot(station: saved, board: Board(station: saved, generatedAt: 1000, departures: [row("a")]), cached: true, savedAt: 1000),
			MemberBoardSnapshot(station: missing, board: nil, cached: true),
			// A saved board that could not refresh is still just a saved board.
			MemberBoardSnapshot(station: stale, board: Board(station: stale, generatedAt: 1000, departures: [row("b")]), cached: true, savedAt: 1000, error: "Feed unavailable"),
			MemberBoardSnapshot(station: unknown, board: nil, cached: true, error: "Station missing from catalog"),
			MemberBoardSnapshot(station: live, board: Board(station: live, generatedAt: 1000, departures: [row("c")]), cached: false)
		])
		// Widgets keep saying which members are saved; the app's board labels those itself.
		#expect(snapshot.warnings == snapshot.warnings(includeSaved: true))
		#expect(snapshot.warnings == ["saved: Saved departures · offline estimates", "missing: Departures unavailable", "stale: Feed unavailable", "unknown: Station missing from catalog"])
		#expect(snapshot.warnings(includeSaved: false) == ["missing: Departures unavailable", "unknown: Station missing from catalog"])
	}
	@Test func mixedWidgetPrioritizesUpcomingTrainOverPassedCachedEstimate() {
		let a = station("628"), b = station("624")
		let snapshot = CombinedBoardSnapshot(station: station(id), members: [
			MemberBoardSnapshot(station: a, board: Board(station: a, generatedAt: 1000, departures: [row("future", time: 1100)]), cached: false),
			MemberBoardSnapshot(station: b, board: Board(station: b, generatedAt: 1000, departures: [row("passed", time: 950)]), cached: true)
		])
		let rows = widgetDepartures(snapshot.board, preference: StationPreference(), limit: 1, now: 1000, cachedDepartureKeys: snapshot.cachedDepartureKeys).flatMap(\.departures)
		#expect(rows.count == 1)
		#expect(snapshot.origins[rows[0].key]?.station.id == "628")
	}

	@Test func globalLinesCoverAliasesAndAlertScopeWithoutChangingInput() {
		#expect(!LineVisibility.isEnabled("6X", hiddenRoutes: ["6"]))
		#expect(!LineVisibility.isEnabled("FX", hiddenRoutes: ["F"]))
		#expect(!LineVisibility.isEnabled("GS", hiddenRoutes: ["S"]))
		#expect(!LineVisibility.isEnabled("SI", hiddenRoutes: ["SIR"]))
		#expect(LineVisibility.station(station("x"), hiddenRoutes: ["A"]) == nil)
		let alerts = [ServiceAlert(id: "general", title: "General", description: ""), ServiceAlert(id: "hidden", title: "A", description: "", routes: ["A"]), ServiceAlert(id: "mixed", title: "A/C", description: "", routes: ["A", "C"])]
		#expect(LineVisibility.alerts(alerts, hiddenRoutes: ["A"]).map(\.id) == ["general", "mixed"])
		#expect(alerts[2].routes == ["A", "C"])
	}
	@Test func regionalMemberCannotTurnEntireCombinedBoardIntoExternalDirectory() {
		let combined = station(id, routes: ["A", "NJT-NLR"])
		#expect(!Board(station: combined, generatedAt: 1000).usesExternalDepartures)
	}
	@Test func portableV4AndMembershipMerge() throws {
		var settings = PortableSettings()
		settings.combinedStations[id] = CombinedStation(name: "Downtown", stationIDs: ["628", "624"])
		settings.hiddenRoutes = ["A"]
		let file = try NerdsSettingsFile.decode(NerdsSettingsFile(settings: settings, lastStation: id).data())
		#expect(file.version == 5)
		#expect(file.settings == settings)
		var remote = PortableSettings(); remote.hiddenRoutes = ["C"]
		let merged = try SettingsMerge.merge(base: PortableSettings(), local: settings, remote: remote)
		#expect(merged.settings.hiddenRoutes == ["A", "C"])
	}
	@Test func sharedV4FixtureRoundTrips() throws {
		let url = try #require(Bundle.module.url(forResource: "combined-stations", withExtension: "nerds", subdirectory: "Fixtures"))
		let file = try NerdsSettingsFile.decode(Data(contentsOf: url))
		#expect(file.lastStation == id)
		#expect(file.settings.combinedStations[id]?.stationIDs.count == 4)
		#expect(file.settings.hiddenRoutes == ["A", "NJT-NLR"])
		#expect(try NerdsSettingsFile.decode(file.data()).settings == file.settings)
	}
	@Test func widgetsHonorGlobalExclusionsWithIndependentFiltersAndResolveGroups() throws {
		let a = station("628"), b = station("624", routes: ["C"])
		var state = WidgetSharedState(favorites: [id], stations: [a,b], combinedStations: [id: CombinedStation(name: "Downtown", stationIDs: [a.id,b.id])], hiddenRoutes: ["A"])
		let selected = try #require(state.selectedStation(location: nil, previous: nil, now: 1000))
		#expect(selected.id == id)
		#expect(selected.routes == ["C"])
		let board = Board(station: a, generatedAt: 1000, departures: [row()])
		#expect(widgetDepartures(board, preference: StationPreference(routes: ["A"]), limit: 4, now: 1000, hiddenRoutes: ["A"]).isEmpty)
		state.hiddenRoutes = ["A", "C"]
		#expect(state.selectedStation(location: nil, previous: id, now: 1000) == nil)
		let restored = try JSONDecoder().decode(WidgetSharedState.self, from: JSONEncoder().encode(state))
		#expect(restored == state)
	}
}
