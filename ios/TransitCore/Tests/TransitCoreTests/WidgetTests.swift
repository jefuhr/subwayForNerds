import Foundation
import Testing
@testable import TransitCore

struct WidgetTests {
	@Test func settingsModesKeepIndependentFiltersAndBothDirections() {
		var settings = WidgetPreferences()
		settings.stations["a"] = StationPreference(routes: ["Q"], view: .family)
		let app = ["a": StationPreference(direction: "SOUTH", routes: ["B"], view: .track)]
		#expect(settings.preference(for: "a", app: app) == StationPreference(routes: ["Q"], view: .family))
		settings.matchAppFilters = true
		#expect(settings.preference(for: "a", app: app) == StationPreference(routes: ["B"], view: .track))
		#expect(settings.preference(for: "b", app: app) == StationPreference())
		settings.matchAppFilters = false
		#expect(settings.preference(for: "a", app: app).routes == ["Q"])
		#expect(settings.preference(for: "b", app: app) == StationPreference(view: .direction))
	}

	@Test func nearestFavoriteNeverSelectsANonfavoriteAndFallbackSurvivesRemoval() {
		let stations = [station("a", lat: 40), station("b", lat: 41), station("other", lat: 40.01)]
		let state = WidgetSharedState(favorites: ["a", "b"], stations: stations)
		#expect(state.selectedStation(location: WidgetCoordinate(latitude: 40.99, longitude: -74), previous: "a")?.id == "b")
		#expect(state.selectedStation(location: nil, previous: "b")?.id == "b")
		#expect(state.selectedStation(location: nil, previous: "removed")?.id == "a")
		#expect(WidgetSharedState().selectedStation(location: nil, previous: nil) == nil)
	}

	@Test func projectionBalancesDirectionsFiltersBeforeLimitingAndExcludesCanceled() {
		var canceled = departure("canceled", direction: "NORTH", time: 1010)
		canceled.relationship = "CANCELED"
		let board = Board(station: station("a"), generatedAt: 1000, departures: [
			departure("later", direction: "NORTH", time: 1200, route: "B"),
			departure("next", direction: "NORTH", time: 1100),
			departure("south", direction: "SOUTH", time: 1150),
			departure("past", direction: "SOUTH", time: 900), canceled
		])
		for order in BoardSortOrder.allCases {
			let groups = widgetDepartures(board, preference: StationPreference(routes: ["Q"], view: order), limit: 1, now: 1000)
			#expect(groups.flatMap(\.departures).map(\.key).sorted() == ["next", "south"])
		}
	}

	@Test func savedPredictionsKeepTheirOriginalClockTimesAndRegionalDirections() {
		let board = Board(station: station("a"), generatedAt: 1000, departures: [departure("ny", direction: "TO_NY", time: 1100)])
		let groups = widgetDepartures(board, preference: StationPreference(), limit: 1, now: 2000, cached: true)
		#expect(groups.first?.direction == "TO_NY")
		#expect(Display.countdown(groups[0].departures[0].time, timestamp: 1000, now: 2000, cached: true).unit == "last estimate")
	}

	@Test func sharedStorePersistsSettingsAndRejectsOlderBoardWrites() throws {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: directory) }
		let store = WidgetSharedStore(directory: directory)
		var state = WidgetSharedState(favorites: ["a"], stations: [station("a")])
		state.widgets.stations["a"] = StationPreference(routes: ["Q"], view: .corridor)
		try store.save(state)
		#expect(try store.load() == state)
		try store.saveBoard(Board(station: station("a"), generatedAt: 2000))
		try store.saveBoard(Board(station: station("a"), generatedAt: 1000))
		#expect(store.board(stationID: "a")?.generatedAt == 2000)
		#expect(store.board(stationID: "a", endpoint: "http://localhost/api/") == nil)
		try store.saveSelection(stationID: "a", location: WidgetCoordinate(latitude: 40, longitude: -74, timestamp: 2000))
		try store.saveSelection(stationID: "b", location: WidgetCoordinate(latitude: 41, longitude: -74, timestamp: 1000))
		#expect(store.selection()?.stationID == "a")
	}

	@Test func absentSettingsDecodeWithDefaultsAndDeepLinksRejectUnrelatedURLs() throws {
		#expect(try JSONDecoder().decode(WidgetPreferences.self, from: Data("{}".utf8)) == WidgetPreferences())
		let url = WidgetLink.board(stationID: "a / ?")
		#expect(WidgetLink.stationID(from: url) == "a / ?")
		#expect(WidgetLink.stationID(from: URL(string: "https://example.com/board?station=a")!) == nil)
	}

	@Test func displayOptionsMigratePersistAndRespectCarReportAge() throws {
		let legacy = try JSONDecoder().decode(WidgetPreferences.self, from: Data("{\"matchAppFilters\":true,\"stations\":{}}".utf8))
		#expect(legacy.display == WidgetDisplayOptions())
		var settings = legacy
		settings.display.fields = [.carType, .carCount]
		settings.display.trainsPerDirection = 3
		settings.display.compact = false
		settings.display.timeStyle = .clock
		#expect(try JSONDecoder().decode(WidgetPreferences.self, from: JSONEncoder().encode(settings)) == settings)
		var row = departure("cars", direction: "NORTH", time: 1100)
		row.consist = Consist(cars: [ConsistCar(number: "1", type: "R211A"), ConsistCar(number: "2", type: "R211A")], updatedAt: 1000, fetchedAt: 1000)
		#expect(widgetTrainDetails(row, options: settings.display, now: 1000) == "R211A · 2 cars")
		#expect(widgetTrainDetails(row, options: settings.display, now: 1091).contains("last reported"))
		#expect(widgetTrainDetails(row, options: settings.display, now: 1301).isEmpty)
		#expect(widgetTrainDetails(row, options: settings.display, now: 1000, cached: true).isEmpty)
	}

	@Test func timelineAdvancesRoundedMinutesAndStopsLiveEstimatesAtSourceExpiry() {
		let board = Board(station: station("a"), generatedAt: 1000, departures: [departure("next", direction: "NORTH", time: 1060)])
		#expect(widgetTimelineDates(board, now: 1000) == [1001, 1061, 1091])
		#expect(widgetTimelineDates(board, now: 1100).isEmpty)
	}

	@Test func lockScreenSettingsMigrateWithoutChangingHomeScreenDisplay() throws {
		var home = WidgetDisplayOptions()
		home.fields = [.destination, .carCount]
		home.trainsPerDirection = 5
		home.timeStyle = .clock
		let legacy = try JSONSerialization.data(withJSONObject: ["display": JSONSerialization.jsonObject(with: JSONEncoder().encode(home))])
		var settings = try JSONDecoder().decode(WidgetPreferences.self, from: legacy)
		#expect(settings.display == home)
		#expect(settings.lockScreen.display.fields == [.carCount])
		#expect(settings.lockScreen.display.timeStyle == .clock)
		#expect(settings.lockScreen.display.trainsPerDirection == 2)
		#expect(settings.lockScreen.directionOrder == .downtownLeft)
		#expect(settings.lockScreen.showService)
		settings.lockScreen.display.trainsPerDirection = 0
		settings.lockScreen.display.fields = [.track, .carType]
		settings.lockScreen.directionOrder = .uptownLeft
		settings.lockScreen.showService = false
		#expect(settings.display == home)
		#expect(try JSONDecoder().decode(WidgetPreferences.self, from: JSONEncoder().encode(settings)) == settings)
		let previousLock = try JSONSerialization.data(withJSONObject: ["display": JSONSerialization.jsonObject(with: JSONEncoder().encode(settings.lockScreen.display)), "directionOrder": "uptownLeft"])
		let migratedLock = try JSONDecoder().decode(LockScreenWidgetOptions.self, from: previousLock)
		#expect(migratedLock.showService && migratedLock.directionOrder == .uptownLeft)
		#expect(migratedLock.display == settings.lockScreen.display)
	}

	@Test func lockScreenDirectionsAndCountsKeepBothSidesAndBoundMaximumDensity() {
		var options = LockScreenWidgetOptions()
		#expect(options.orderedDirections() == ["SOUTH", "NORTH"])
		#expect(options.orderedDirections(regional: true) == ["TO_NJ", "TO_NY"])
		#expect(options.candidateCounts == [2, 1])
		options.display.trainsPerDirection = 0
		#expect(options.candidateCounts == [6, 5, 4, 3, 2, 1])
		options.directionOrder = .uptownLeft
		#expect(options.orderedDirections() == ["NORTH", "SOUTH"])
		#expect(options.orderedDirections(regional: true) == ["TO_NY", "TO_NJ"])
		options.display.trainsPerDirection = -100
		#expect(options.candidateCounts == [1])
		options.display.trainsPerDirection = 100
		#expect(options.candidateCounts.first == 6)
	}

	@Test func widgetServiceDetailsCanBeHiddenAndIdentifyInferredPatterns() {
		var row = departure("service", direction: "NORTH", time: 1100)
		row.pattern = "Brighton local"
		var display = WidgetDisplayOptions()
		display.fields = [.service]
		#expect(widgetTrainDetails(row, options: display, now: 1000) == "Brighton local")
		row.patternSource = "inferred"
		#expect(widgetTrainDetails(row, options: display, now: 1000) == "Brighton local · est.")
		display.fields = []
		#expect(widgetTrainDetails(row, options: display, now: 1000).isEmpty)
	}

	private func station(_ id: String, lat: Double = 40) -> Station {
		Station(id: id, name: id, borough: "M", routes: ["Q", "B"], lat: lat, lon: -74)
	}
	private func departure(_ key: String, direction: String, time: TimeInterval, route: String = "Q") -> Departure {
		Departure(key: key, tripKey: key, route: route, destination: "Test", direction: direction, stopId: "a", partId: "a", area: "Test", time: time, pattern: "Local", patternSource: "reported", location: "", feed: "test", timestamp: 1000)
	}
}
