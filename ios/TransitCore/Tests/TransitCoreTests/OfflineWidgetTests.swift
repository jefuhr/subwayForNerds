import Foundation
import Testing
@testable import TransitCore

struct OfflineWidgetTests {
	@Test func offlineTimelineIncludesPassedPredictionAndSourceExpiry() {
		let board = Board(station: Station(id: "602", name: "Union Sq", borough: "M", routes: ["Q"], lat: 40, lon: -74), generatedAt: 1500,
			departures: [Departure(key: "one", tripKey: "trip", route: "Q", destination: "Uptown", direction: "NORTH", stopId: "R20N", partId: "R20", area: "Broadway", time: 1600, pattern: "", patternSource: "static", location: "", feed: "gtfs", timestamp: 1000)])
		let dates = widgetOfflineTimelineDates(board, now: 1500, maximumAgeMinutes: 30)
		#expect(dates.contains(1601))
		#expect(dates.contains(2801))
		#expect(dates == dates.sorted())
		#expect(dates.allSatisfy { $0 > 1500 })
		// A later HTTP fetch cannot extend the source's estimate window.
		#expect(!dates.contains(3301))
	}

	@Test func offlineTimelineDoesNotScheduleOldMissingOrFutureReports() {
		let station = Station(id: "602", name: "Union Sq", borough: "M", routes: ["Q"], lat: 40, lon: -74)
		for source in [0.0, 100.0, 2001.0, Double.nan] {
			let row = Departure(key: "one", tripKey: "trip", route: "Q", destination: "Uptown", direction: "NORTH", stopId: "R20N", partId: "R20", area: "Broadway", time: 2200, pattern: "", patternSource: "static", location: "", feed: "gtfs", timestamp: source)
			#expect(widgetOfflineTimelineDates(Board(station: station, generatedAt: 2000, departures: [row]), now: 2000, maximumAgeMinutes: 30).isEmpty)
		}
	}

	@Test func widgetMinutesNeverOverstateTheRemainingTimelineInterval() {
		let value = widgetIntervalCountdown(Countdown(value: "5", unit: "min"), time: 1330, now: 1000, displayUntil: 1060)
		#expect(value == Countdown(value: "4", unit: "min"))
		#expect(widgetIntervalCountdown(Countdown(value: "4:00", unit: "last estimate"), time: 1330, now: 1000, displayUntil: 1060).unit == "last estimate")
	}

	@Test func crowdedTimelinePreservesCriticalTransitionsWithinBudget() {
		let station = Station(id: "602", name: "Union Sq", borough: "M", lat: 40, lon: -74)
		let rows = (0..<100).map { index in
			Departure(key: "\(index)", tripKey: "\(index)", route: "Q", destination: "Uptown", direction: "NORTH", stopId: "R20N", partId: "R20", area: "", time: 1100 + Double(index) * 30, pattern: "", patternSource: "static", location: "", feed: "gtfs", timestamp: 990)
		}
		let dates = widgetOfflineTimelineDates(Board(station: station, generatedAt: 1000, departures: rows), now: 1000, maximumAgeMinutes: 120)
		#expect(dates.count <= 240)
		for row in rows.prefix(28) { #expect(dates.contains(row.time! + 1)) }
		#expect(dates.last == 8191)
	}

	@Test func rideDeepLinkPreservesOpaqueTripIdentity() {
		let key = "gtfs|20261011|a/b+c?d#e|08:00:00"
		let url = WidgetLink.ride(tripKey: key)
		#expect(WidgetLink.tripKey(from: url) == key)
		#expect(WidgetLink.stationID(from: url) == nil)
		#expect(WidgetLink.tripKey(from: URL(string: "https://example.com/ride?key=x")!) == nil)
		#expect(WidgetLink.tripKey(from: URL(string: "subwaynerds://ride?key=")!) == nil)
	}

	@Test func lateWidgetUpdateCannotReviveAnEndedRide() throws {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: directory) }
		let app = WidgetSharedStore(directory: directory)
		let widget = WidgetSharedStore(directory: directory)
		let ride = ActiveRide(tripKey: "trip", boardingStationID: "602", startedAt: 1000)
		let snapshot = cachedTrip(timestamp: 1000)
		try app.saveRide(ride, trip: snapshot, endpoint: snapshot.endpoint)
		#expect(widget.ride(endpoint: snapshot.endpoint)?.ride == ride)
		try app.saveRide(nil, trip: nil, endpoint: snapshot.endpoint)
		#expect(try widget.updateRideTrip(cachedTrip(timestamp: 1100), for: ride, endpoint: snapshot.endpoint) == false)
		#expect(widget.ride(endpoint: snapshot.endpoint) == nil)
	}

	@Test func savedWidgetPrioritizesFuturePredictionsOverPassedRows() {
		let station = Station(id: "602", name: "Union Sq", borough: "M", routes: ["Q"], lat: 40, lon: -74)
		let rows = [900.0, 1300.0].map { time in
			Departure(key: String(time), tripKey: String(time), route: "Q", destination: "Uptown", direction: "NORTH", stopId: "R20N", partId: "R20", area: "Broadway", time: time, pattern: "", patternSource: "static", location: "", feed: "gtfs", timestamp: 800)
		}
		let board = Board(station: station, generatedAt: 850, departures: rows)
		let visible = widgetDepartures(board, preference: StationPreference(), limit: 1, now: 1000, cached: true).flatMap(\.departures)
		#expect(visible.map(\.time) == [1300])
	}

	@Test func rideSnapshotProtectsNewerSourceAndProductionAlias() throws {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: directory) }
		let store = WidgetSharedStore(directory: directory)
		let ride = ActiveRide(tripKey: "trip", startedAt: 1000)
		let snapshot = cachedTrip(timestamp: 1200)
		try store.saveRide(ride, trip: snapshot, endpoint: "https://juliet.nyc/subwaysForNerds/api/v1/")
		let newEndpoint = "https://subwaysfornerds.juliet.nyc/api/v1/"
		#expect(store.ride(endpoint: newEndpoint)?.trip.sourceTimestamp == 1200)
		#expect(try store.updateRideTrip(cachedTrip(timestamp: 1100), for: ride, endpoint: newEndpoint) == false)
		#expect(store.ride(endpoint: newEndpoint)?.trip.sourceTimestamp == 1200)
		#expect(store.ride(endpoint: "http://localhost:8092/api/v1/") == nil)
	}

	@Test func completeRideIsNeverReplacedByPartialProjection() throws {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: directory) }
		let store = WidgetSharedStore(directory: directory)
		let ride = ActiveRide(tripKey: "trip", startedAt: 1000)
		var complete = cachedTrip(timestamp: 1200)
		complete.detail = TripDetail(train: complete.train!)
		try store.saveRide(ride, trip: complete, endpoint: complete.endpoint)
		try store.saveRide(ride, trip: cachedTrip(timestamp: 1200), endpoint: complete.endpoint)
		#expect(store.ride(endpoint: complete.endpoint)?.trip.isComplete == true)
		#expect(try store.updateRideTrip(cachedTrip(timestamp: 1300), for: ride, endpoint: complete.endpoint) == false)
		#expect(store.ride(endpoint: complete.endpoint)?.trip.isComplete == true)
	}

	@Test func widgetBoardUsesPredictionSourceInsteadOfFetchTime() throws {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: directory) }
		let store = WidgetSharedStore(directory: directory)
		let station = Station(id: "602", name: "Union Sq", borough: "M", lat: 40, lon: -74)
		let endpoint = "https://subwaysfornerds.juliet.nyc/api/v1/"
		let good = Board(station: station, generatedAt: 1000, sources: [SourceState(id: "gtfs", timestamp: 1000)], departures: [cachedTrip(timestamp: 1000).departure!])
		try store.saveBoard(good, endpoint: endpoint)
		var older = good; older.generatedAt = 2000
		older.departures[0].timestamp = 900; older.departures[0].time = 9000
		older.sources = [SourceState(id: "gtfs", timestamp: 900, fetchedAt: 2000)]
		try store.saveBoard(older, endpoint: endpoint)
		#expect(store.board(stationID: station.id, endpoint: endpoint)?.departures == good.departures)
		#expect(store.board(stationID: station.id, endpoint: endpoint)?.generatedAt == 1000)
	}

	@Test func liveWidgetKeepsFullBoardWhileOfflineCopyHonorsLimit() throws {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: directory) }
		let store = WidgetSharedStore(directory: directory)
		var state = WidgetSharedState()
		state.offline.departuresPerLineDirection = 1
		try store.save(state)
		let station = Station(id: "602", name: "Union Sq", borough: "M", lat: 40, lon: -74)
		let rows = (0..<10).map { index in
			var row = cachedTrip(timestamp: 1000).departure!
			row.key = "row-\(index)"; row.tripKey = "trip-\(index)"; row.time = 1300 + Double(index) * 60
			return row
		}
		let fetched = Board(station: station, generatedAt: 1000, sources: [SourceState(id: "gtfs", timestamp: 1000)], departures: rows)
		for _ in 0..<2 {
			let displayed = try store.saveBoard(fetched)
			#expect(widgetDepartures(displayed, preference: StationPreference(), limit: 9, now: 1000).flatMap(\.departures).count == 9)
			#expect(store.board(stationID: station.id)?.departures.count == 1)
		}
	}

	private func cachedTrip(timestamp: TimeInterval) -> CachedTrip {
		let row = Departure(key: "row", tripKey: "trip", route: "Q", destination: "Uptown", direction: "NORTH", stopId: "R20N", partId: "R20", area: "Broadway", time: 2000, pattern: "", patternSource: "static", location: "", feed: "gtfs", timestamp: timestamp)
		return CachedTrip(tripKey: "trip", endpoint: "https://subwaysfornerds.juliet.nyc/api/v1/", departure: row, savedAt: timestamp, accessedAt: timestamp)
	}
}
