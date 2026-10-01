import Foundation
import Testing
@testable import TransitCore

struct RegionalTests {
	@Test func optionalRegionalFieldsPreserveExistingNYCStations() throws {
		let nyc = Data(#"{"id":"602","name":"Fulton St","borough":"M","routes":["A","C"],"lat":40.71,"lon":-74.0,"parts":[]}"#.utf8)
		let station = try JSONDecoder().decode(Station.self, from: nyc)
		#expect(station.municipality == nil)
		#expect(station.departureMode == nil)
		#expect(Display.stationMatches(station, query: "Fulton Manhattan"))
		#expect(Display.displayRoute("GS") == "S")
	}

	@Test func externalNJTStationsRoundTripAndSearchMunicipality() throws {
		let json = Data(#"{"id":"njt-19001","name":"34th Street","borough":"NJ","municipality":"Bayonne","departureMode":"external","routes":["NJT-HBLR"],"lat":40.67,"lon":-74.11,"parts":[{"id":"njt-19001","stationId":"19001","name":"34th Street","line":"Hudson–Bergen Light Rail","routes":["NJT-HBLR"],"lat":40.67,"lon":-74.11,"ada":"","adaNotes":"","north":"Northbound","south":"Southbound"}]}"#.utf8)
		let station = try JSONDecoder().decode(Station.self, from: json)
		#expect(station.municipality == "Bayonne")
		#expect(station.departureMode == "external")
		#expect(try JSONDecoder().decode(Station.self, from: JSONEncoder().encode(station)) == station)
		#expect(Display.stationMatches(station, query: "Bayonne light rail"))
		#expect(Display.stationMatches(station, query: "New Jersey 19001"))
		#expect(Display.stationMatches(station, query: "Hudson-Bergen"))
		#expect(!Display.stationMatches(station, query: "Hoboken"))
		#expect(TransitLinks.njtDepartures.absoluteString == "https://www.njtransit.com/dv-to")
	}

	@Test func pathDirectionsAndRawRouteFiltersStayDistinct() {
		let station = Station(id: "path-jsq", name: "Journal Square", borough: "NJ", routes: ["PATH-NWK-WTC", "PATH-JSQ-33-HOB"], lat: 40.73, lon: -74.06)
		let ny = departure(key: "ny", route: "PATH-NWK-WTC", direction: "TO_NY")
		let nj = departure(key: "nj", route: "PATH-JSQ-33-HOB", direction: "TO_NJ")
		let board = Board(station: station, generatedAt: 1000, departures: [ny, nj])
		#expect(groupDepartures(board, direction: "TO_NY", now: 1000).flatMap(\.departures).map(\.key) == ["ny"])
		#expect(groupDepartures(board, direction: "TO_NJ", now: 1000).flatMap(\.departures).map(\.key) == ["nj"])
		#expect(groupDepartures(board, routes: ["PATH-JSQ-33-HOB"], now: 1000).flatMap(\.departures).map(\.key) == ["nj"])
		#expect(Display.displayRoute("PATH-JSQ-33-HOB") == "PATH-JSQ-33-HOB")
		#expect(Display.routeLabel("PATH-JSQ-33-HOB") == "JSQ–33 via HOB")
		#expect(Display.regionalRoute("PATH-JSQ-33-HOB")?.colors == [0x4D92FB, 0xFF9900])
		#expect(Display.directionLabel("TO_NY") == "To New York")
		#expect(Display.directionLabel("TO_NJ") == "To New Jersey")
		#expect(Display.directionLabel("NORTH") == "Northbound")
		#expect(Display.stationMatches(station, query: "PATH JSQ 33"))
	}

	private func departure(key: String, route: String, direction: String) -> Departure {
		Departure(key: key, tripKey: key, route: route, destination: "Terminal", direction: direction,
			stopId: "path-jsq", partId: "path-jsq", area: "PATH", time: 1060, pattern: "PATH", patternSource: "static",
			location: "At Journal Square", feed: "path", timestamp: 1000)
	}
}
