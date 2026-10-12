import Foundation
import Testing
@testable import TransitCore

struct NjtTests {
	private let station = Station(id: "njt-19001", name: "34th Street", borough: "NJ", routes: ["NJT-HBLR"], lat: 40.67, lon: -74.11, departureMode: "external")
	private func source(_ id: String = "njt-bus-g2", time: Double = 1000, error: String? = nil) -> SourceState {
		SourceState(id: id, timestamp: time, fetchedAt: 1100, error: error, staleAfter: 60)
	}
	private func position(time: Double = 1000) -> VehiclePosition {
		VehiclePosition(id: "njt-bus-g2:10", provider: "njt-bus-g2", vehicleId: "10", route: "NJT-HBLR", tripId: "trip", lat: 40.67, lon: -74.11, timestamp: time, fetchedAt: 1100)
	}
	private func departure(time: Double = 1000) -> Departure {
		Departure(key: "njt-trip:19001", tripKey: "njt-trip", route: "NJT-HBLR", destination: "Hoboken", direction: "NORTH", stopId: "19001", partId: "njt-19001", area: "34th Street", time: 1200, pattern: "Light rail", patternSource: "inferred", location: "", feed: "njt-bus-g2", timestamp: time, staleAfter: 60)
	}
	private func board(rows: [Departure] = [], positions: [VehiclePosition] = []) -> Board {
		Board(station: station, generatedAt: 1100, sources: [source(time: rows.map(\.timestamp).max() ?? 1000)], departures: rows, njt: NjtState(configured: true, predictions: source(time: rows.map(\.timestamp).max() ?? 1000), positions: source("njt-bus-g2-positions")), vehiclePositions: positions)
	}

	@Test func legacyBoardsAndTrainsDecodeWithoutNewFields() throws {
		let json = #"{"station":{"id":"njt-19001","name":"34th Street","borough":"NJ","routes":["NJT-HBLR"],"lat":40.67,"lon":-74.11,"parts":[],"departureMode":"external"},"generatedAt":1000,"sources":[],"departures":[],"alerts":[]}"#
		let legacy = try JSONDecoder().decode(Board.self, from: Data(json.utf8))
		#expect(legacy.njt == nil && legacy.vehiclePositions == nil && legacy.usesExternalDepartures)
		let train = try JSONDecoder().decode(Train.self, from: Data(#"{"key":"mta","feed":"mta","tripId":"trip","route":"Q","destination":"96 St","direction":"NORTH","timestamp":1000,"stops":[],"alerts":[]}"#.utf8))
		#expect(train.staleAfter == nil && train.vehiclePosition == nil)
		#expect(Display.freshness(train, now: 1090) == .live)
		#expect(Display.freshness(train, now: 1091) == .stale)
	}

	@Test func exactNewJSONContractDecodesAndRoundTrips() throws {
		let positionJSON = #"{"id":"njt-bus-g2:10","provider":"njt-bus-g2","vehicleId":"10","route":"NJT-HBLR","tripId":"trip","serviceDate":"20261012","startTime":"09:00:00","lat":40.67,"lon":-74.11,"stopId":"19001","stopName":"34th Street","status":"STOPPED_AT","timestamp":1000,"fetchedAt":1100}"#
		let decoded = try JSONDecoder().decode(VehiclePosition.self, from: Data(positionJSON.utf8))
		#expect(decoded.timestamp == 1000 && decoded.stopName == "34th Street" && decoded.startTime == "09:00:00")
		let state = try JSONDecoder().decode(NjtState.self, from: Data(#"{"configured":true,"predictions":{"id":"njt-bus-g2","timestamp":1000,"fetchedAt":1100,"error":null,"staleAfter":60},"positions":{"id":"njt-bus-g2-positions","timestamp":999,"fetchedAt":1100,"error":null,"staleAfter":60},"cacheError":null}"#.utf8))
		var row = departure(); row.vehiclePosition = decoded
		var value = board(rows: [row], positions: [decoded]); value.njt = state
		#expect(try JSONDecoder().decode(Board.self, from: JSONEncoder().encode(value)) == value)
		let train = Train(key: "njt-trip", feed: "njt-bus-g2", tripId: "trip", route: "NJT-HBLR", destination: "Hoboken", direction: "NORTH", timestamp: 1000, staleAfter: 60, vehiclePosition: decoded)
		#expect(try JSONDecoder().decode(Train.self, from: JSONEncoder().encode(train)) == train)
	}

	@Test func configuredEmptyBoardIsCapableButNeverLiveArrivals() {
		var value = board()
		#expect(!value.usesExternalDepartures)
		#expect(!Display.hasLivePredictions(value, now: 1000))
		#expect(Display.njtPredictionMessage(value, now: 1000)?.contains("No arrival predictions") == true)
		#expect(Display.njtPredictionMessage(value, now: 1061)?.contains("unavailable") == true)
		value.njt?.configured = false
		value.station.departureMode = nil
		#expect(value.usesExternalDepartures)
		value.njt = nil
		#expect(value.usesExternalDepartures)
	}

	@Test func NJTPredictionsExpireAtSixtySecondsAndGPSAtFiveMinutes() {
		let row = departure()
		#expect(Display.freshness(row, now: 1060) == .live)
		#expect(Display.freshness(row, now: 1061) == .stale)
		#expect(Display.freshness(source(), now: 1061) == .stale)
		#expect(OfflineDisplay.countdown(departure: row, now: 1060, cached: false, preferences: OfflinePreferences()).unit == "min")
		#expect(OfflineDisplay.countdown(departure: row, now: 1061, cached: false, preferences: OfflinePreferences()).unit == "last estimate")
		#expect(Display.currentVehiclePositions([position()], now: 1300).count == 1)
		#expect(Display.currentVehiclePositions([position()], now: 1301).isEmpty)
		#expect(Display.vehiclePositionLabel(position(), now: 1061).contains("Last known"))
		#expect(Display.vehiclePositionLabel(position(), now: 1000).contains("40.67000, -74.11000"))
	}

	@Test func arrivalAndPositionFreshnessAreIndependentAndNoDataNeverCounts() {
		var row = departure(time: 1100); row.vehiclePosition = position(time: 1000)
		let value = board(rows: [row], positions: [position()])
		#expect(Display.hasLivePredictions(value, now: 1100))
		#expect(OfflineDisplay.countdown(departure: row, now: 1100, cached: false, preferences: OfflinePreferences()).unit == "min")
		var options = WidgetDisplayOptions(); options.fields = [.location]
		#expect(widgetTrainDetails(row, options: options, now: 1100).contains("Last known"))
		#expect(widgetTrainDetails(row, options: options, now: 1301).isEmpty)
		row.relationship = "NO_DATA"
		#expect(!Display.boardable(row))
		#expect(!Display.hasLivePredictions(board(rows: [row]), now: 1100))
		#expect(OfflineDisplay.countdown(departure: row, now: 1100, cached: false, preferences: OfflinePreferences()).unit == "no estimate")
		#expect(widgetDepartures(board(rows: [row]), preference: StationPreference(), limit: 2, now: 1100).isEmpty)
	}

	@Test func freshSourceWithoutAnActualEstimateOrWithAnErrorIsNotLive() {
		var row = departure(); row.time = nil
		#expect(!Display.hasLivePredictions(board(rows: [row]), now: 1000))
		var failed = board(rows: [departure()]); failed.njt?.predictions.error = "Unavailable"
		#expect(!Display.hasLivePredictions(failed, now: 1000))
		#expect(!Display.hasLivePredictions(board(rows: [departure()]), now: 1000, cached: true))
		var named = position(); named.stopName = "Actual reported stop"
		#expect(Display.vehiclePositionLabel(named, now: 1000).contains("Actual reported stop"))
		#expect(!Display.vehiclePositionLabel(named, now: 1000).contains("GPS"))
	}

	@Test func invalidGPSNeverAppearsAsCurrent() {
		var invalid = position(); invalid.lat = .nan
		#expect(Display.currentVehiclePositions([invalid], now: 1000).isEmpty)
		invalid = position(time: 1001)
		#expect(Display.currentVehiclePositions([invalid], now: 1000).isEmpty)
	}

	@Test func localWidgetTimelinesAgeNJTAtSixtySeconds() {
		let value = board(rows: [departure()], positions: [position()])
		#expect(widgetTimelineDates(value, now: 1000).contains(1061))
		#expect(!widgetTimelineDates(value, now: 1000).contains(1091))
		#expect(widgetOfflineTimelineDates(value, now: 1000, maximumAgeMinutes: 15).contains(1061))
		#expect(widgetOfflineTimelineDates(value, now: 1000, maximumAgeMinutes: 15).contains(1301))
	}

	@Test func emptyAndLinkedGPSWidgetsStillReceiveAgeTransitions() {
		#expect(widgetOfflineTimelineDates(board(), now: 1000, maximumAgeMinutes: 15).contains(1061))
		var row = departure(); row.vehiclePosition = position()
		#expect(widgetOfflineTimelineDates(board(rows: [row]), now: 1000, maximumAgeMinutes: 15).contains(1301))
	}

	@Test func positionsWithoutPredictionsPersistThroughBothCachesAndIndependentMerge() async throws {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: directory) }
		let widget = WidgetSharedStore(directory: directory.appendingPathComponent("widgets"))
		let original = board(positions: [position(time: 900)])
		try widget.saveBoard(original)
		var update = board(positions: [position(time: 1000)])
		update.njt?.predictions.error = "Predictions unavailable"
		update.njt?.positions.timestamp = 1000
		let merged = try widget.saveBoard(update)
		#expect(merged.njt?.configured == true)
		#expect(widget.board(stationID: station.id)?.vehiclePositions?.first?.timestamp == 1000)
		#expect(Display.currentVehiclePositions(merged.vehiclePositions ?? [], now: 1301).isEmpty)
		#expect(widget.board(stationID: station.id)?.vehiclePositions?.count == 1)
		let store = OfflineTransitStore(directory: directory.appendingPathComponent("app"))
		try await store.saveBoard(original, endpoint: "https://example.com/api/")
		try await store.saveBoard(update, endpoint: "https://example.com/api/")
		#expect(await store.board(stationID: station.id, endpoint: "https://example.com/api/")?.board.vehiclePositions?.count == 1)
	}

	@Test func transferOriginFreshnessDecodesWithoutBreakingLegacyJSON() throws {
		let legacy = try JSONDecoder().decode(TransferResult.self, from: Data(#"{"originTimestamp":1000,"arrival":1200,"basis":"arrival","connections":[],"sources":[]}"#.utf8))
		#expect(legacy.originStaleAfter == nil)
		let njt = try JSONDecoder().decode(TransferResult.self, from: Data(#"{"originTimestamp":1000,"originStaleAfter":60,"arrival":1200,"basis":"arrival","connections":[],"sources":[]}"#.utf8))
		#expect(Display.freshness(njt.originTimestamp, now: 1061, staleAfter: njt.originStaleAfter) == .stale)
	}

	@Test func partialSavedTripsKeepTheirNJTProvenance() {
		var row = departure(); row.vehiclePosition = position()
		let trip = CachedTrip(tripKey: row.tripKey, endpoint: "https://example.com/api/", departure: row, savedAt: 1000, accessedAt: 1000)
		#expect(trip.train?.staleAfter == 60 && trip.train?.vehiclePosition == row.vehiclePosition)
	}
}
