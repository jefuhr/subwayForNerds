import Foundation
@testable import TransitCore

/// A settable clock shared with actors under test.
final class TestClock: @unchecked Sendable {
	private let lock = NSLock()
	private var value: TimeInterval
	init(_ value: TimeInterval) { self.value = value }
	var now: TimeInterval {
		get { lock.withLock { value } }
		set { lock.withLock { value = newValue } }
	}
	func advance(_ seconds: TimeInterval) { now += seconds }
	var function: @Sendable () -> TimeInterval { { self.now } }
}

enum OfflineFixtures {
	static let endpoint = "https://juliet.nyc/subwaysForNerds/api/v1/"
	static let start: TimeInterval = 1_790_000_000

	static func station(_ id: String, lat: Double = 40.75, lon: Double = -73.99) -> Station {
		Station(id: id, name: "Station \(id)", borough: "M", routes: ["1"], lat: lat, lon: lon)
	}

	static func departure(_ tripKey: String, route: String = "1", direction: String = "NORTH", feed: String = "gtfs", time: TimeInterval? = start + 600, timestamp: TimeInterval = start, relationship: String? = nil, onward: [OnwardStop] = []) -> Departure {
		Departure(key: tripKey + "@stop", tripKey: tripKey, route: route, destination: "Uptown", direction: direction, stopId: "101N", partId: "101", area: "Uptown platform", time: time, pattern: "local", patternSource: "schedule", location: "Station 101", feed: feed, timestamp: timestamp, relationship: relationship, onward: onward)
	}

	static func board(_ id: String = "101", sources: [SourceState] = [SourceState(id: "gtfs", timestamp: start)], departures: [Departure]) -> Board {
		Board(station: station(id), generatedAt: start + 5, sources: sources, departures: departures)
	}

	static func detail(_ key: String, timestamp: TimeInterval = start, stops: [StopPrediction]? = nil, raw: JSONValue? = .object(["entity": .string("raw")])) -> TripDetail {
		let predictions = stops ?? [
			StopPrediction(id: "101N", name: "Station 101", stationId: "101", arrival: timestamp + 60),
			StopPrediction(id: "102N", name: "Station 102", stationId: "102", arrival: timestamp + 180),
		]
		return TripDetail(train: Train(key: key, feed: "gtfs", tripId: key, route: "1", destination: "Uptown", direction: "NORTH", timestamp: timestamp, stops: predictions), raw: raw, source: TripSource(state: SourceState(id: "gtfs", timestamp: timestamp)))
	}

	static func temporaryDirectory() -> URL {
		FileManager.default.temporaryDirectory.appendingPathComponent("offline-tests-" + UUID().uuidString, isDirectory: true)
	}
}
