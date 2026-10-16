package nyc.juliet.subwaysfornerds.ui.board

import nyc.juliet.subwaysfornerds.core.Consist
import nyc.juliet.subwaysfornerds.core.ConsistCar
import nyc.juliet.subwaysfornerds.core.Departure
import nyc.juliet.subwaysfornerds.core.OfflineSettings
import nyc.juliet.subwaysfornerds.core.SlowZone
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DepartureFormatTest {
	private val now = 1_800_000_000.0
	private fun row(key: String, time: Double?, track: String? = "1", timestamp: Double = now - 10) = Departure(
		key = key, tripKey = "trip-$key", route = "A", destination = "Inwood", direction = "NORTH", stopId = "A27N", partId = "A27",
		area = "Uptown", time = time, pattern = "Express", patternSource = "reported", location = "approaching 42 St", feed = "gtfs-ace",
		timestamp = timestamp, scheduledTrack = track,
	)

	@Test fun slowZoneTagsShowOnLiveAndLastReportRowsButNeverOnCachedBoards() {
		val zone = SlowZone("633S", "634S", "28 St → 23 St-Baruch College", "slow", "2026-08-10", "2026-09-04", 41.6, 92.4, 20)
		val zoned = row("a", now + 60).copy(slowZone = zone)
		assertEquals(zone, DepartureFormat.slowZone(zoned, cached = false))
		val oldPosition = zoned.copy(locationTimestamp = now - 200)
		assertTrue(DepartureFormat.historical(oldPosition, now, cached = false))
		assertEquals(zone, DepartureFormat.slowZone(oldPosition, cached = false))
		assertNull(DepartureFormat.slowZone(zoned, cached = true))
		assertNull(DepartureFormat.slowZone(row("b", now + 60), cached = false))
	}

	@Test fun cachedUnassignedTrainsNeverCountDown() {
		val value = DepartureFormat.countdown(row("a", now + 300).copy(assigned = false), now, cached = true, OfflineSettings(), "12h")
		assertEquals("not assigned", value.unit)
	}

	@Test fun liveRowsCountMinutesAndCachedRowsSayEstimatePassed() {
		assertEquals("5", DepartureFormat.countdown(row("a", now + 330), now, cached = false, OfflineSettings(), "12h").value)
		assertEquals("estimate passed", DepartureFormat.countdown(row("a", now - 60), now, cached = true, OfflineSettings(), "12h").unit)
	}

	@Test fun headwaysComeOnlyFromLiveRowsOnTheSameTrack() {
		val first = row("a", now + 120)
		val second = row("b", now + 480)
		assertEquals(6, DepartureFormat.gap(second, first, now, cached = false))
		assertNull(DepartureFormat.gap(second, first, now, cached = true))
		assertNull(DepartureFormat.gap(second, first.copy(timestamp = now - 400), now, cached = false))
		val rows = listOf(first, row("c", now + 200, track = "2"), second)
		assertEquals(first, DepartureFormat.previous(rows, 2))
	}

	@Test fun stopsAwayAndReportAge() {
		val value = row("a", now + 60).copy(stopsAway = 1, locationTimestamp = now - 75)
		assertEquals("1 stop away · 1m ago", DepartureFormat.positionDetail(value, now))
		assertEquals("Stop-relative position", DepartureFormat.positionDetail(row("b", now), now))
	}

	@Test fun consistsShowOnlyWhenCurrentAndLive() {
		val consist = Consist(listOf(ConsistCar("4148", "R211A"), ConsistCar("4149", "R211A")), now - 30, now - 5)
		assertEquals("R211A · 4148–4149", DepartureFormat.consistLine(row("a", now).copy(consist = consist), now, cached = false))
		assertNull(DepartureFormat.consistLine(row("a", now).copy(consist = consist), now, cached = true))
		assertEquals("R211A · 4148–4149 · last reported", DepartureFormat.consistLine(row("a", now).copy(consist = consist.copy(updatedAt = now - 120)), now, cached = false))
	}
}
