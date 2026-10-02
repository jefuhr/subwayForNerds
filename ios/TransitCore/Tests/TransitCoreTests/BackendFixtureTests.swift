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

	private func roundTrip<T: Codable & Equatable>(_ name: String) throws -> T {
		let file = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
		let decoded = try JSONDecoder().decode(T.self, from: Data(contentsOf: file))
		#expect(try JSONDecoder().decode(T.self, from: JSONEncoder().encode(decoded)) == decoded)
		return decoded
	}
}
