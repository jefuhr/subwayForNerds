import Foundation
import Testing
import TransitCore

/// Slow zones are additive: the recorded fixtures carry synthetic zones from the fixture
/// service, and older payloads such as the edge fixtures decode without them.
@Suite struct SlowZoneTests {
	private let twentyThird = SlowZone(from: "633S", to: "634S", segment: "28 St → 23 St-Baruch College", kind: "slow",
		since: "2026-08-10", through: "2026-09-04", extraSeconds: 41.6, baselineSeconds: 92.4, slowDays: 20)

	@Test func boardRowsCarryOnlyTheCurrentZone() throws {
		let board: Board = try roundTrip("board")
		let zoned = board.departures.filter { $0.slowZone != nil }
		#expect(!zoned.isEmpty)
		#expect(zoned.allSatisfy { $0.route == "4" && $0.tripKey == "gtfs|20260905|123100_4..S06X064|" })
		#expect(zoned.allSatisfy { $0.slowZone == twentyThird })
		#expect(board.departures.contains { $0.slowZone == nil })
		#expect(SlowZoneDisplay.boardTag(twentyThird) == "+42s")
		#expect(SlowZoneDisplay.accessibilityLabel(twentyThird) == "In an estimated slow zone: 28 St → 23 St-Baruch College, typically 42s slower")
	}

	@Test func tripCarriesOneZoneAheadThatIsNotCurrent() throws {
		let train = try (roundTrip("trip") as TripDetail).train
		let zones = try #require(train.slowZones)
		#expect(zones.count == 1)
		let zone = try #require(zones.first)
		#expect(zone.zone == SlowZone(from: "L02N", to: "L01N", segment: "6 Av → 8 Av", kind: "slow", since: "2026-07-13", through: "2026-09-02", extraSeconds: 18.3, baselineSeconds: 71.5, slowDays: 38))
		#expect(zone.toIndex == 2)
		#expect(zone.current == nil)
		// toIndex addresses the segment's end stop.
		#expect(train.stops[zone.toIndex].id == zone.to)
		#expect(train.stops[zone.toIndex - 1].id == zone.from)
		#expect(SlowZoneDisplay.title(zone, cached: false) == "slow zone")
		#expect(SlowZoneDisplay.detail(zone) == "6 Av → 8 Av · +18s on a 1m 12s run · since Jul 13")
		#expect(SlowZoneDisplay.summary(zones) == "1 estimated slow zone ahead · about +18s typical")
	}

	@Test func slowZoneTripListsTheCurrentZoneFirstAndADisruptionAhead() throws {
		let train = try (roundTrip("slow-zone-trip") as TripDetail).train
		let zones = try #require(train.slowZones)
		#expect(zones.count == 2)
		#expect(zones[0].zone == twentyThird)
		#expect(zones[0].toIndex == 0 && zones[0].current == true)
		#expect(train.stops[0].id == "634S")
		#expect(zones[1].kind == "disruption" && zones[1].toIndex == 9 && zones[1].current == nil)
		#expect(train.stops[9].id == zones[1].to && train.stops[8].id == zones[1].from)
		#expect(zones.filter { $0.current == true }.count == 1)

		#expect(SlowZoneDisplay.summary(zones) == "2 estimated slow zones ahead · about +2m 56s typical")
		#expect(SlowZoneDisplay.title(zones[0], cached: false) == "slow zone · now")
		// A cached trip shown offline never claims the train is in the zone now.
		#expect(SlowZoneDisplay.title(zones[0], cached: true) == "slow zone")
		#expect(SlowZoneDisplay.detail(zones[0]) == "28 St → 23 St-Baruch College · +42s on a 1m 32s run · since Aug 10")
		#expect(SlowZoneDisplay.title(zones[1], cached: false) == "major slowdown")
		#expect(SlowZoneDisplay.detail(zones[1]) == "Wall St → Bowling Green · +2m 14s on a 1m 28s run · since Aug 31")
		#expect(SlowZoneDisplay.zones(zones, before: 0).map(\.to) == ["634S"])
		#expect(SlowZoneDisplay.zones(zones, before: 9).map(\.to) == ["420S"])
		#expect((1...8).allSatisfy { SlowZoneDisplay.zones(zones, before: $0).isEmpty })
	}

	@Test func edgeFixturesDecodeWithoutSlowZones() throws {
		let trip: TripDetail = try roundTrip("edge-trip")
		#expect(trip.train.slowZones == nil)
		let board: Board = try roundTrip("edge-board")
		#expect(!board.departures.isEmpty)
		#expect(board.departures.allSatisfy { $0.slowZone == nil })
		#expect(SlowZoneDisplay.summary(trip.train.slowZones ?? []) == nil)
	}

	@Test func unknownFutureKindsDecodeAndDisplayAsSlowZones() throws {
		let data = Data(#"{"from":"A01S","to":"A02S","segment":"One → Two","kind":"signal-work","since":"2026-01-02","through":"2026-01-09","extraSeconds":12,"baselineSeconds":60,"slowDays":4,"toIndex":3,"future":{"nested":true}}"#.utf8)
		let zone = try JSONDecoder().decode(TrainSlowZone.self, from: data)
		#expect(zone.kind == "signal-work" && zone.toIndex == 3 && zone.current == nil)
		#expect(SlowZoneDisplay.label(zone.zone) == "slow zone")
		#expect(SlowZoneDisplay.detail(zone) == "One → Two · +12s on a 1m run · since Jan 2")
		#expect(try JSONDecoder().decode(TrainSlowZone.self, from: JSONEncoder().encode(zone)) == zone)
		// A board row's zone has no index or current flag.
		#expect(try JSONDecoder().decode(SlowZone.self, from: data).segment == "One → Two")
	}

	@Test func secondsRoundAndDropEmptySeconds() {
		#expect(SlowZoneDisplay.seconds(41.6) == "42s")
		#expect(SlowZoneDisplay.seconds(92.4) == "1m 32s")
		#expect(SlowZoneDisplay.seconds(120) == "2m")
		#expect(SlowZoneDisplay.seconds(176) == "2m 56s")
		#expect(SlowZoneDisplay.seconds(59.5) == "1m")
		#expect(SlowZoneDisplay.seconds(0.4) == "0s")
		#expect(SlowZoneDisplay.seconds(-3) == "0s")
		#expect(SlowZoneDisplay.seconds(.infinity) == "0s")
		#expect(SlowZoneDisplay.seconds(.nan) == "0s")
	}

	@Test func datesAreCalendarDatesInEveryTimeZone() {
		let original = NSTimeZone.default
		defer { NSTimeZone.default = original }
		for identifier in ["Pacific/Kiritimati", "Pacific/Pago_Pago", "America/New_York", "UTC", "Asia/Tokyo"] {
			NSTimeZone.default = TimeZone(identifier: identifier)!
			#expect(SlowZoneDisplay.date("2026-08-10") == "Aug 10", "\(identifier)")
			#expect(SlowZoneDisplay.date("2026-01-01") == "Jan 1", "\(identifier)")
			#expect(SlowZoneDisplay.date("2026-12-31") == "Dec 31", "\(identifier)")
		}
		// Anything that is not a calendar date is shown as received.
		#expect(SlowZoneDisplay.date("2026-13-01") == "2026-13-01")
		#expect(SlowZoneDisplay.date("soon") == "soon")
	}

	private func roundTrip<T: Codable & Equatable>(_ name: String) throws -> T {
		let file = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
		let decoded = try JSONDecoder().decode(T.self, from: Data(contentsOf: file))
		#expect(try JSONDecoder().decode(T.self, from: JSONEncoder().encode(decoded)) == decoded)
		return decoded
	}
}
