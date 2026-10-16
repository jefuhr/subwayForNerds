package nyc.juliet.subwaysfornerds.core

import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.Locale
import java.util.TimeZone

class SlowZonesTest {
	private fun fixture(name: String): String = javaClass.getResourceAsStream("/fixtures/$name")!!.bufferedReader().use { it.readText() }
	private fun board(name: String = "board.json") = TransitJson.decodeFromString(Board.serializer(), fixture(name))
	private fun trip(name: String) = TransitJson.decodeFromString(TripDetail.serializer(), fixture(name)).train
	private val baruch = SlowZone("633S", "634S", "28 St → 23 St-Baruch College", "slow", "2026-08-10", "2026-09-04", 41.6, 92.4, 20)

	@Test fun boardRowsCarryOnlyTheZoneTheirTrainIsInNow() {
		val rows = board().departures
		val zoned = rows.filter { it.slowZone != null }
		assertEquals(1, zoned.size)
		val row = zoned.single()
		assertEquals("gtfs|20260905|123100_4..S06X064||635S|1", row.key)
		assertEquals("4", row.route)
		assertEquals(baruch, row.slowZone)
		assertTrue(rows.size > 1)
	}

	@Test fun trainDetailsCarryEveryZoneAheadWithItsEndStopIndex() {
		val l = trip("trip.json")
		val ahead = l.slowZones!!.single()
		assertEquals(TrainSlowZone("L02N", "L01N", "6 Av → 8 Av", "slow", "2026-07-13", "2026-09-02", 18.3, 71.5, 38, toIndex = 2), ahead)
		assertNull(ahead.current)
		assertEquals("L01N", l.stops[ahead.toIndex].id)

		val four = trip("slow-zone-trip.json")
		val zones = four.slowZones!!
		assertEquals(listOf("633S" to "634S", "419S" to "420S"), zones.map { it.from to it.to })
		assertEquals(listOf(0, 9), zones.map { it.toIndex })
		assertEquals(listOf(true, null), zones.map { it.current })
		assertEquals(listOf("slow", "disruption"), zones.map { it.kind })
		assertEquals(baruch, zones[0].zone)
		assertEquals("Wall St → Bowling Green", zones[1].segment)
		assertEquals("2026-08-31", zones[1].since)
		assertEquals("2026-09-04", zones[1].through)
		assertEquals(134.4, zones[1].extraSeconds, 0.0)
		assertEquals(88.0, zones[1].baselineSeconds, 0.0)
		assertEquals(5, zones[1].slowDays)
		zones.forEach { assertEquals(it.to, four.stops[it.toIndex].id) }
	}

	@Test fun olderServersWithoutSlowZonesStillDecode() {
		assertTrue(board("edge-board.json").departures.isNotEmpty())
		assertTrue(board("edge-board.json").departures.all { it.slowZone == null })
		assertNull(trip("edge-trip.json").slowZones)
		val transfers = TransitJson.decodeFromString(TransferResult.serializer(), fixture("transfers.json"))
		assertTrue(transfers.connections.all { it.slowZone == null })
	}

	@Test fun unknownFutureKindsDecodeAndReadAsSlowZones() {
		val raw = TransitJson.encodeToJsonElement(SlowZone.serializer(), baruch).jsonObject
		val future = TransitJson.decodeFromJsonElement(SlowZone.serializer(), JsonObject(raw + ("kind" to JsonPrimitive("signal work")) + ("severity" to JsonPrimitive(3))))
		assertEquals("signal work", future.kind)
		assertEquals("slow zone", SlowZoneDisplay.label(future))
		assertEquals("major slowdown", SlowZoneDisplay.label(baruch.copy(kind = "disruption")))
		assertEquals("slow zone", SlowZoneDisplay.label(baruch))
	}

	@Test fun secondsRoundLikeTheWebClient() {
		assertEquals("42s", SlowZoneDisplay.seconds(41.6))
		assertEquals("1m 32s", SlowZoneDisplay.seconds(92.4))
		assertEquals("2m", SlowZoneDisplay.seconds(120.0))
		assertEquals("2m 56s", SlowZoneDisplay.seconds(176.0))
		assertEquals("2m 56s", SlowZoneDisplay.seconds(41.6 + 134.4))
		assertEquals("59s", SlowZoneDisplay.seconds(59.4))
		assertEquals("1m", SlowZoneDisplay.seconds(59.5))
		assertEquals("0s", SlowZoneDisplay.seconds(-3.0))
		assertEquals("0s", SlowZoneDisplay.seconds(Double.NaN))
	}

	@Test fun sinceIsACalendarDateInEveryTimeZone() {
		val zone = TimeZone.getDefault()
		val locale = Locale.getDefault()
		try {
			for (id in listOf("UTC", "America/New_York", "America/Los_Angeles", "Pacific/Pago_Pago", "Pacific/Kiritimati", "Asia/Tokyo")) {
				TimeZone.setDefault(TimeZone.getTimeZone(id))
				Locale.setDefault(Locale.FRANCE)
				assertEquals(id, "Aug 10", SlowZoneDisplay.date("2026-08-10"))
				assertEquals(id, "Sep 1", SlowZoneDisplay.date("2026-09-01"))
				assertEquals(id, "Jan 1", SlowZoneDisplay.date("2027-01-01"))
			}
		} finally {
			TimeZone.setDefault(zone)
			Locale.setDefault(locale)
		}
		assertEquals("soon", SlowZoneDisplay.date("soon"))
	}

	@Test fun wordingMatchesTheWebClient() {
		assertEquals("+42s", SlowZoneDisplay.tag(baruch))
		assertEquals("In an estimated slow zone: 28 St → 23 St-Baruch College, typically 42s slower", SlowZoneDisplay.accessibilityLabel(baruch))
		assertEquals("In an estimated major slowdown: 28 St → 23 St-Baruch College, typically 42s slower", SlowZoneDisplay.accessibilityLabel(baruch.copy(kind = "disruption")))
		val four = trip("slow-zone-trip.json").slowZones!!
		assertEquals("2 estimated slow zones ahead · about +2m 56s typical", SlowZoneDisplay.summary(four))
		assertEquals("1 estimated slow zone ahead · about +18s typical", SlowZoneDisplay.summary(trip("trip.json").slowZones!!))
		assertNull(SlowZoneDisplay.summary(emptyList()))
		assertNull(SlowZoneDisplay.summary(null))
		assertEquals("slow zone · now", SlowZoneDisplay.heading(four[0], live = true))
		assertEquals("slow zone", SlowZoneDisplay.heading(four[0], live = false))
		assertEquals("major slowdown", SlowZoneDisplay.heading(four[1], live = true))
		assertEquals("28 St → 23 St-Baruch College · +42s on a 1m 32s run · since Aug 10", SlowZoneDisplay.detail(four[0]))
		assertEquals("Wall St → Bowling Green · +2m 14s on a 1m 28s run · since Aug 31", SlowZoneDisplay.detail(four[1]))
		assertEquals("Estimated slow zone · now: 28 St → 23 St-Baruch College · +42s on a 1m 32s run · since Aug 10", SlowZoneDisplay.segmentAccessibilityLabel(four[0], live = true))
		assertEquals("Estimated major slowdown: Wall St → Bowling Green · +2m 14s on a 1m 28s run · since Aug 31", SlowZoneDisplay.segmentAccessibilityLabel(four[1], live = false))
		assertEquals(
			"Slow zones are estimated from weekday daytime run times by Transit Lab (transitlab.nyc, CC BY 4.0), built from MTA data. Not an official MTA speed restriction list; the slow section can be anywhere between the two stops.",
			SlowZoneDisplay.attribution,
		)
	}

	@Test fun segmentRowsGoBeforeTheirEndStopAndIgnoreIndexesOutsideTheSnapshot() {
		val four = trip("slow-zone-trip.json")
		assertEquals(mapOf(0 to listOf("633S"), 9 to listOf("419S")), SlowZoneDisplay.byStop(four).mapValues { (_, zones) -> zones.map { it.from } })
		val zones = four.slowZones!!
		val broken = four.copy(slowZones = zones + zones[1].copy(from = "X", toIndex = four.stops.size) + zones[1].copy(from = "Y", toIndex = -1))
		assertEquals(setOf(0, 9), SlowZoneDisplay.byStop(broken).keys)
		assertTrue(SlowZoneDisplay.byStop(trip("edge-trip.json")).isEmpty())
	}

	@Test fun departureAndTrainRoundTripsKeepSlowZonesAndLeaveThemAbsentOtherwise() {
		val source = board()
		val row = source.departures.single { it.slowZone != null }
		val encoded = TransitJson.encodeToJsonElement(Departure.serializer(), row).jsonObject
		assertEquals(JsonPrimitive("633S"), encoded["slowZone"]!!.jsonObject["from"])
		assertEquals(row, TransitJson.decodeFromJsonElement(Departure.serializer(), encoded))
		val plain = source.departures.first { it.slowZone == null }
		assertFalse(TransitJson.encodeToJsonElement(Departure.serializer(), plain).jsonObject.containsKey("slowZone"))
		// The board is what the offline cache writes and reads back.
		assertEquals(source, TransitJson.decodeFromString(Board.serializer(), TransitJson.encodeToString(Board.serializer(), source)))

		val detail = TransitJson.decodeFromString(TripDetail.serializer(), fixture("slow-zone-trip.json"))
		val zones = TransitJson.encodeToJsonElement(TripDetail.serializer(), detail).jsonObject["train"]!!.jsonObject["slowZones"]!!.jsonArray
		assertEquals(JsonPrimitive(true), zones[0].jsonObject["current"])
		assertFalse("A zone ahead stays without a current flag", zones[1].jsonObject.containsKey("current"))
		assertEquals(detail, TransitJson.decodeFromString(TripDetail.serializer(), TransitJson.encodeToString(TripDetail.serializer(), detail)))
		val older = trip("edge-trip.json")
		assertFalse(TransitJson.encodeToJsonElement(Train.serializer(), older).jsonObject.containsKey("slowZones"))
	}
}
