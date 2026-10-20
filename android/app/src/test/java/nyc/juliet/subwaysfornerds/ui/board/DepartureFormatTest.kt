package nyc.juliet.subwaysfornerds.ui.board

import nyc.juliet.subwaysfornerds.core.Consist
import nyc.juliet.subwaysfornerds.core.ConsistCar
import nyc.juliet.subwaysfornerds.core.Departure
import nyc.juliet.subwaysfornerds.core.DepartureRowSettings
import nyc.juliet.subwaysfornerds.core.VehiclePosition
import nyc.juliet.subwaysfornerds.core.OfflineSettings
import nyc.juliet.subwaysfornerds.core.SlowZone
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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

	@Test fun combinedPositionJoinsLocationStopsAndAge() {
		val value = row("a", now + 60).copy(location = "At Newkirk Plaza", stopsAway = 1, locationTimestamp = now - 25)
		assertEquals("At Newkirk Plaza · 1 stop away · 25s ago", DepartureFormat.combinedPosition(value, now, cached = false))
		assertEquals("At Newkirk Plaza · 3 stops away · 25s ago", DepartureFormat.combinedPosition(value.copy(stopsAway = 3), now, cached = false))
		assertEquals("At Newkirk Plaza · 0 stops away · 25s ago", DepartureFormat.combinedPosition(value.copy(stopsAway = 0), now, cached = false))
	}

	@Test fun combinedPositionOmitsMissingPartsWithoutDanglingSeparators() {
		val value = row("a", now + 60).copy(location = "At Newkirk Plaza", stopsAway = 2, locationTimestamp = now - 25)
		assertEquals("2 stops away · 25s ago", DepartureFormat.combinedPosition(value.copy(location = ""), now, cached = false))
		assertEquals("At Newkirk Plaza · 25s ago", DepartureFormat.combinedPosition(value.copy(stopsAway = null), now, cached = false))
		assertEquals("At Newkirk Plaza · 2 stops away", DepartureFormat.combinedPosition(value.copy(locationTimestamp = null), now, cached = false))
		assertEquals("At Newkirk Plaza", DepartureFormat.combinedPosition(value.copy(stopsAway = null, locationTimestamp = null), now, cached = false))
		assertEquals("2 stops away", DepartureFormat.combinedPosition(value.copy(location = "", locationTimestamp = null), now, cached = false))
		// Today's fallback text still stands in when nothing at all is known about the position.
		assertEquals("Stop-relative position", DepartureFormat.combinedPosition(value.copy(location = "", stopsAway = null, locationTimestamp = null), now, cached = false))
		assertEquals("Stop-relative position · 25s ago", DepartureFormat.combinedPosition(value.copy(location = "", stopsAway = null), now, cached = false))
		assertEquals("Stop-relative position", DepartureFormat.positionDetail(value.copy(stopsAway = null, locationTimestamp = null), now))
	}

	@Test fun combinedPositionKeepsTheLastReportPrefixForHistoricalPositions() {
		val old = row("a", now + 60).copy(location = "At Newkirk Plaza", stopsAway = 1, locationTimestamp = now - 200)
		assertEquals("Last report: At Newkirk Plaza · 1 stop away · 3m ago", DepartureFormat.combinedPosition(old, now, cached = false))
		assertEquals("Last report: At Newkirk Plaza · 1 stop away · 3m ago", DepartureFormat.combinedPosition(old.copy(locationTimestamp = now - 200), now, cached = true))
		assertEquals("Last report: At Newkirk Plaza · 1 stop away · 25s ago", DepartureFormat.combinedPosition(old.copy(locationTimestamp = now - 25), now, cached = true))
	}

	@Test fun onlyScheduleFeedRowsCombineAndGpsRowsKeepTheirRendering() {
		val on = DepartureRowSettings(combinePosition = true)
		val off = DepartureRowSettings(combinePosition = false)
		val subway = row("a", now)
		assertTrue(DepartureFormat.combinesPosition(subway, on))
		assertFalse(DepartureFormat.combinesPosition(subway, off))
		assertFalse(DepartureFormat.combinesPosition(subway.copy(feed = "njt-hblr"), on))
		val gps = VehiclePosition("v", "njt", "v1", "NJT-HBLR", lat = 40.7, lon = -74.0, stopName = "Newport", timestamp = now - 10, fetchedAt = now - 5)
		assertFalse(DepartureFormat.combinesPosition(subway.copy(vehiclePosition = gps), on))
	}

	@Test fun headwayIsAThirdCountdownLineWhenCombinedAndHiddenWhenOff() {
		val first = row("a", now + 120)
		val second = row("b", now + 480)
		val settings = DepartureRowSettings()
		assertEquals(6, DepartureFormat.headway(second, first, now, cached = false, settings))
		assertNull(DepartureFormat.headway(second, first, now, cached = false, settings.copy(showHeadway = false)))
		assertNull(DepartureFormat.headway(second, first, now, cached = true, settings))
		assertNull(DepartureFormat.headway(second, null, now, cached = false, settings))
		assertNull(DepartureFormat.headway(row("c", now + 120), first, now, cached = false, settings))
		assertEquals("+6m gap", DepartureFormat.gapLabel(6))
		assertEquals("6 minutes after previous train", DepartureFormat.gapDescription(6))
		assertEquals("1 minute after previous train", DepartureFormat.gapDescription(1))
		assertEquals("+6m after previous", DepartureFormat.splitGapLabel(6))
	}

	@Test fun consistLineHidesWhenCarNumbersAreOff() {
		val consist = Consist(listOf(ConsistCar("4148", "R211A"), ConsistCar("4149", "R211A")), now - 30, now - 5)
		val value = row("a", now).copy(consist = consist)
		assertEquals("R211A · 4148–4149", DepartureFormat.consistLine(value, now, cached = false, DepartureRowSettings()))
		assertNull(DepartureFormat.consistLine(value, now, cached = false, DepartureRowSettings(showConsist = false)))
	}

	@Test fun platformLineFollowsTheProvenanceSetting() {
		val value = row("a", now).copy(area = "Broadway - Brighton", actualTrack = "A4", scheduledTrack = "A5")
		assertEquals("Broadway - Brighton · Track A4", DepartureFormat.platformLine(value, DepartureRowSettings()))
		assertEquals("Broadway - Brighton · Track A4 · reported", DepartureFormat.platformLine(value, DepartureRowSettings(showTrackProvenance = true)))
		assertEquals("Broadway - Brighton · Track A5 · scheduled", DepartureFormat.platformLine(value.copy(actualTrack = null), DepartureRowSettings(showTrackProvenance = true)))
		assertEquals("Broadway - Brighton · Track unknown", DepartureFormat.platformLine(value.copy(actualTrack = null, scheduledTrack = null), DepartureRowSettings()))
	}
}
