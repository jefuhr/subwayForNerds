import Foundation
import Testing
import TransitCore

/// These are real endpoint responses exported from the recorded protobuf feeds.
/// npm run fixtures:native regenerates both shared and Swift fixture copies.
@Suite struct BackendFixtureTests {
	@Test func allEndpointContractsDecodeAndRoundTrip() throws {
		let stations: [Station] = try roundTrip("catalog")
		let board: Board = try roundTrip("board")
		let trip: TripDetail = try roundTrip("trip")
		let transfers: TransferResult = try roundTrip("transfers")
		let context: StationContext = try roundTrip("context")
		let fleet: FleetPage = try roundTrip("fleet-page")
		let detail: FleetDetail = try roundTrip("fleet-detail")
		let manifest: FleetOfflineManifest = try roundTrip("offline-manifest")
		#expect(stations.count > 400)
		#expect(!board.departures.isEmpty)
		#expect(trip.train.consist != nil)
		#expect(trip.source != nil)
		#expect(!transfers.connections.isEmpty)
		#expect(transfers.connections.allSatisfy { $0.gap != nil && $0.basis != nil })
		#expect(!context.entrances.isEmpty)
		#expect(fleet.total > 0)
		#expect(!detail.cars.isEmpty)
		#expect(manifest.id == manifest.sha256)
		#expect(manifest.counts.cars > 0)
	}

	@Test func edgeTripPreservesUnknownFalseZeroAndRepeatedStops() throws {
		let trip: TripDetail = try roundTrip("edge-trip")
		#expect(trip.train.assigned == false)
		#expect(trip.train.position?.timestamp == 0)
		#expect(trip.train.stops[0].arrival == 0)
		#expect(trip.train.stops[0].departure == nil)
		#expect(trip.train.stops[0].sequence == 0)
		#expect(trip.train.stops.filter { $0.id == "635N" }.map(\.sequence) == [0, 1, 3])
		#expect(trip.train.stops[1].scheduledTrack == "0")
		#expect(trip.train.stops[2].relationship == "SKIPPED")
		#expect(trip.train.stops.last?.stationId == nil)
		let request = try TransitAPI().requestURL(components: ["trips"], query: ["key": trip.train.key])
		#expect(URLComponents(url: request, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == trip.train.key)
	}

	@Test func edgeBoardKeepsUnknownAssignmentSeparateFromFalse() throws {
		let board: Board = try roundTrip("edge-board")
		#expect(board.departures.contains { $0.assigned == false })
		#expect(board.departures.contains { $0.assigned == nil })
		#expect(Set(board.departures.map(\.key)).count == board.departures.count)
		#expect(board.departures.contains { $0.scheduledTrack == "0" })
	}

	@Test func fixtureLabelsFollowTheTrainsTrunkAndRenderAsServed() throws {
		let board: Board = try roundTrip("board")
		let edge: Board = try roundTrip("edge-board")
		let transfers: TransferResult = try roundTrip("transfers")
		// Pattern is trunk plus local/express, never the platform's raw MTA line name.
		func patterns(_ rows: [Departure]) -> [String: Set<String>] {
			Dictionary(grouping: rows, by: \.route).mapValues { Set($0.map(\.pattern)) }
		}
		let boardPatterns = patterns(board.departures)
		#expect(boardPatterns["4"] == ["Lex local"])
		#expect(boardPatterns["6"] == ["Lex local"])
		#expect(boardPatterns["L"] == ["Canarsie"])
		for route in ["N", "Q", "R"] { #expect(boardPatterns[route] == ["Broadway"], "\(route)") }
		let transferPatterns = patterns(transfers.connections)
		#expect(transferPatterns["1"] == ["7 Av local"])
		#expect(transferPatterns["2"] == ["7 Av express"])
		#expect(transferPatterns["3"] == ["7 Av express"])
		#expect(transferPatterns["F"] == ["6 Av"])
		// The platform line is a short segment (or absent); no raw compound name reaches a row.
		let rows = board.departures + edge.departures + transfers.connections
		#expect(!rows.isEmpty)
		for row in rows {
			#expect(!row.pattern.contains(" - ") && !row.area.contains(" - "), "\(row.route) \(row.pattern) | \(row.area)")
			let label = Display.boardingLabel(row, showProvenance: false)
			#expect(label.components(separatedBy: "Track ").count == 2, Comment(rawValue: label))
		}
		let uptownF = try #require(transfers.connections.first { $0.route == "F" && $0.area.hasSuffix("Track B2") })
		#expect(Display.boardingLabel(uptownF, showProvenance: false) == "6 Av · Uptown · Track B2")
		let westSideL = try #require(board.departures.first { $0.route == "L" && $0.area.hasSuffix("Track 2") })
		#expect(Display.boardingLabel(westSideL, showProvenance: false) == "Canarsie · West Side · Track 2")
	}

	private func roundTrip<T: Codable & Equatable>(_ name: String) throws -> T {
		let file = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
		let decoded = try JSONDecoder().decode(T.self, from: Data(contentsOf: file))
		#expect(try JSONDecoder().decode(T.self, from: JSONEncoder().encode(decoded)) == decoded)
		return decoded
	}
}
