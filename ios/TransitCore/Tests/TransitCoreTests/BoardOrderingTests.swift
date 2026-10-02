import Foundation
import Testing
@testable import TransitCore

struct BoardOrderingTests {
	@Test
	func boardingLabelKeepsExistingTrackOnceAndIncludesItsProvenance() {
		var row = departure("reported", track: "2")
		row.area = "4th Av · Manhattan · Track 2"
		row.scheduledTrack = "1"
		#expect(Display.boardingLabel(row) == "4th Av · Manhattan · Track 2 · reported")
		row.actualTrack = nil
		row.scheduledTrack = "2"
		#expect(Display.boardingLabel(row) == "4th Av · Manhattan · Track 2 · scheduled")
	}

	@Test
	func boardingLabelAddsMissingTrackAndMatchesOnlyTheExactSuffix() {
		var row = departure("reported", track: "2")
		row.area = "4th Av · Manhattan"
		#expect(Display.boardingLabel(row) == "4th Av · Manhattan · Track 2 · reported")
		row.area = "4th Av · Manhattan · Track 20"
		#expect(Display.boardingLabel(row) == "4th Av · Manhattan · Track 20 · Track 2 · reported")
		row.area = "Track 2"
		#expect(Display.boardingLabel(row) == "Track 2 · reported")
	}

	@Test
	func boardingLabelHandlesUnknownTracksEmptyFieldsAndMissingArea() {
		var row = departure("unknown")
		row.area = "4th Av · Manhattan"
		#expect(Display.boardingLabel(row) == "4th Av · Manhattan · Track unknown")
		row.actualTrack = " "; row.scheduledTrack = "3"
		#expect(Display.boardingLabel(row) == "4th Av · Manhattan · Track 3 · scheduled")
		row.area = "  "; row.actualTrack = " 2 "; row.scheduledTrack = ""
		#expect(Display.boardingLabel(row) == "R31 · Track 2 · reported")
		row.actualTrack = ""; row.scheduledTrack = " "
		#expect(Display.boardingLabel(row) == "R31 · Track unknown")
	}

	@Test
	func allViewsKeepEveryDepartureAndSeparateCorridorsFromFamilies() throws {
		let board = sampleBoard()
		for order in BoardSortOrder.allCases {
			let groups = groupDepartures(board, order: order, now: 1000)
			#expect(groups.flatMap(\.departures).map(\.key).sorted() == board.departures.map(\.key).sorted())
			#expect(Set(groups.map(\.id)).count == groups.count)
		}
		#expect(groupDepartures(board, now: 1000).count == 4)
		let directions = groupDepartures(board, order: .direction, now: 1000)
		#expect(directions.map(\.direction) == ["NORTH", "SOUTH"])
		#expect(directions[0].departures.map(\.key) == ["n", "d", "b", "q"])
		let families = groupDepartures(board, order: .family, now: 1000)
		let broadway = try #require(families.first { $0.label == "B / D / F / M" })
		#expect(broadway.departures.map(\.route) == ["D", "B"])
		let corridors = groupDepartures(board, order: .corridor, now: 1000)
		let fourth = try #require(corridors.first { $0.label == "4th Av" && $0.direction == "NORTH" })
		#expect(fourth.departures.map(\.route) == ["N", "D"])
		let services = groupDepartures(board, order: .service, now: 1000)
		#expect(services.filter { $0.service == "N" }.map(\.direction) == ["NORTH", "SOUTH"])
		#expect(board.departures.map(\.key) == ["d", "n", "b", "q", "s"])
	}

	@Test
	func allViewsSortTimeBeforeMissingEstimatesWithStableKeyTies() {
		var board = sampleBoard()
		board.departures = [departure("z", time: nil), departure("b", time: 1100), departure("a", time: 1100), departure("c", time: 1200)]
		for order in BoardSortOrder.allCases {
			let groups = groupDepartures(board, order: order, now: 1000)
			#expect(groups.count == 1)
			#expect(groups[0].departures.map(\.key) == ["a", "b", "c", "z"])
		}
	}

	@Test
	func shuttlesStaySeparateAndExpressVariantsShareFamilies() {
		var board = sampleBoard()
		board.departures = ["GS", "FS", "H"].map { departure($0, route: $0) }
		#expect(groupDepartures(board, order: .service, now: 1000).count == 3)
		#expect(groupDepartures(board, order: .family, now: 1000).count == 3)
		board.departures = ["F", "FX", "6", "6X", "7", "7X"].map { departure($0, route: $0) }
		let groups = groupDepartures(board, order: .family, now: 1000)
		#expect(groups.count == 3)
		#expect(groups.first { $0.label == "B / D / F / M" }?.departures.map(\.route) == ["F", "FX"])
		#expect(groups.first { $0.label == "4 / 5 / 6" }?.departures.map(\.route) == ["6", "6X"])
		#expect(groups.first { $0.label == "7" }?.departures.map(\.route) == ["7", "7X"])
	}

	@Test
	func regionalAndUnknownDirectionsRemainVisibleAndNaturallyOrdered() {
		var board = sampleBoard()
		board.departures = [departure("unknown", direction: "OTHER"), departure("nj", direction: "TO_NJ"), departure("ny", direction: "TO_NY"), departure("south", direction: "SOUTH"), departure("north", direction: "NORTH")]
		#expect(groupDepartures(board, order: .direction, now: 1000).map(\.direction) == ["NORTH", "SOUTH", "TO_NY", "TO_NJ", "UNKNOWN"])
		board.departures = [departure("ten", route: "10"), departure("two", route: "2")]
		#expect(groupDepartures(board, order: .service, now: 1000).map(\.service) == ["2", "10"])
	}

	@Test
	func trackFallbackAndSameNamedCorridorsRemainDistinct() {
		var board = sampleBoard()
		var scheduled = departure("scheduled", part: "R31")
		scheduled.scheduledTrack = "2"
		var reported = scheduled; reported.key = "reported"; reported.actualTrack = "2"
		var changed = scheduled; changed.key = "changed"; changed.actualTrack = "3"
		board.departures = [scheduled, reported, changed]
		#expect(groupDepartures(board, now: 1000).count == 2)
		#expect(groupDepartures(board, order: .direction, now: 1000).count == 1)
		board.station.parts[1].line = board.station.parts[0].line
		board.departures = [departure("one", part: "R31"), departure("two", part: "D24")]
		let groups = groupDepartures(board, order: .corridor, now: 1000)
		#expect(groups.count == 2)
		#expect(groups.map(\.label) == ["4th Av", "4th Av"])
	}

	@Test
	func filteringCachedDataAndCancellationWorkInEveryView() {
		var board = sampleBoard()
		var canceled = departure("canceled", route: "4"); canceled.relationship = "CANCELED"
		board.departures = [departure("old", route: "4", time: 900), canceled, departure("south", route: "4", direction: "SOUTH"), departure("other", route: "L")]
		for order in BoardSortOrder.allCases {
			let live = groupDepartures(board, direction: "NORTH", routes: ["4"], order: order, now: 1000)
			#expect(live.flatMap(\.departures).map(\.key) == ["canceled"])
			#expect(live.flatMap(\.departures).first?.relationship == "CANCELED")
			let cached = groupDepartures(board, direction: "NORTH", routes: ["4"], order: order, now: 1000, cached: true)
			#expect(cached.flatMap(\.departures).map(\.key) == ["old", "canceled"])
		}
	}

	@Test
	func oldAndUnknownPreferencesRetainFiltersAndUseTrack() throws {
		for json in [#"{"direction":"SOUTH","routes":["4"]}"#, #"{"direction":"SOUTH","routes":["4"],"view":"future"}"#] {
			let preference = try JSONDecoder().decode(StationPreference.self, from: Data(json.utf8))
			#expect(preference == StationPreference(direction: "SOUTH", routes: ["4"], view: .track))
		}
		#expect(try JSONDecoder().decode(StationPreference.self, from: Data("{}".utf8)) == StationPreference())
	}

	@Test
	func perStationViewPersistsThroughFileRelaunch() async throws {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: directory) }
		let file = directory.appendingPathComponent("preferences.json")
		let value = TransitPreferences(lastStation: "617", favorites: ["617"], stations: ["617": StationPreference(direction: "NORTH", routes: ["N"], view: .service), "602": StationPreference(view: .corridor)])
		try await TransitPreferencesStore(fileURL: file).save(value)
		#expect(await TransitPreferencesStore(fileURL: file).load() == value)
	}

	private func sampleBoard() -> Board {
		let parts = [StationPart(id: "R31", stationId: "R31", name: "Atlantic Av", line: "4th Av", lat: 0, lon: 0, ada: "1", north: "Manhattan", south: "Brooklyn"), StationPart(id: "D24", stationId: "D24", name: "Atlantic Av", line: "Brighton", lat: 0, lon: 0, ada: "1", north: "Manhattan", south: "Brooklyn")]
		let station = Station(id: "617", name: "Atlantic Av–Barclays Ctr", borough: "Bk", lat: 0, lon: 0, parts: parts)
		return Board(station: station, generatedAt: 1000, departures: [departure("d", route: "D", part: "R31", time: 1200, track: "1"), departure("n", route: "N", part: "R31", time: 1100, track: "3"), departure("b", route: "B", part: "D24", time: 1300), departure("q", route: "Q", part: "D24", time: nil), departure("s", route: "N", part: "R31", direction: "SOUTH", time: 1100, track: "2")])
	}

	private func departure(_ key: String, route: String = "N", part: String = "R31", direction: String = "NORTH", time: TimeInterval? = 1100, track: String? = nil) -> Departure {
		Departure(key: key, tripKey: key, route: route, destination: "Test destination", direction: direction, stopId: part + "N", partId: part, area: part + " · " + direction, time: time, actualTrack: track, pattern: "Local", patternSource: "inferred", location: "At station", feed: "gtfs", timestamp: 1000)
	}
}
