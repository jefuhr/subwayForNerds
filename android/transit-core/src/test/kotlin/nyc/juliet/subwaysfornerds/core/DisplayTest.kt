package nyc.juliet.subwaysfornerds.core

import org.junit.Assert.*
import org.junit.Test

class DisplayTest {
	private val now = 1_800_000_000.0
	private fun station(id: String) = Station(id, id, "M", listOf("A"), 40.7, -74.0)
	private fun row(key: String, part: String = "one", time: Double? = now + 60) = Departure(key, "trip", "A", "Uptown", "NORTH", "stop", part, "platform", time, time, pattern = "Local", patternSource = "inferred", location = "", feed = "gtfs-ace", timestamp = now)
	@Test fun predictionAndGpsClocksStayIndependent() {
		assertEquals(Freshness.LIVE, TransitDisplay.freshness(now - 60, now, 60.0))
		assertEquals(Freshness.STALE, TransitDisplay.freshness(now - 61, now, 60.0))
		val position = VehiclePosition("gps", "njt-bus-g2", "1", "NJT-HBLR", lat = 40.7, lon = -74.0, timestamp = now - 61, fetchedAt = now)
		assertTrue(TransitDisplay.vehiclePosition(position, now)!!.lastKnown)
		assertNull(TransitDisplay.vehiclePosition(position.copy(timestamp = now - 301), now))
		assertNull(TransitDisplay.vehiclePosition(position.copy(timestamp = now + 61), now))
		assertEquals("last estimate", TransitDisplay.countdown(now + 60, now - 61, now, staleAfter = 60.0).unit)
	}
	@Test fun combinedBoardsKeepBothBoardingOpportunitiesAndConservativeSourceAge() {
		val a = station("one"); val b = station("two")
		val combined = CombinedBoards.station("combined:test", "Both", listOf("one", "two"), listOf(a, b))!!
		val first = Board(a, now, listOf(SourceState("feed", now - 10, now, null)), listOf(row("same")))
		val second = Board(b, now, listOf(SourceState("feed", null, now, "down")), listOf(row("same")))
		val merged = CombinedBoards.merge(combined, listOf(MemberBoardSnapshot(a, first), MemberBoardSnapshot(b, second, cached = true)))
		assertEquals(2, merged.board.departures.size); assertEquals(2, merged.origins.size)
		assertEquals(setOf("one", "two"), merged.origins.values.map { it.station.id }.toSet())
		assertNull(merged.board.sources.single().timestamp); assertEquals(1, merged.cachedDepartureKeys.size)
	}
	@Test fun favoritesCannotHighlightHistoricalOrWrongProviderConsists() {
		val consist = Consist(listOf(ConsistCar("001", "R160A")), now, now)
		val favorites = TrainFavorites(cars = listOf("nyct:R160:001"))
		assertNotNull(favorites.match(consist, "gtfs-ace", now)); assertNull(favorites.match(consist, "path", now))
		assertNull(favorites.match(consist, "gtfs-si", now)); assertNull(favorites.match(consist, "gtfs-ace", now, cached = true))
		assertNull(favorites.match(consist.copy(updatedAt = now - 301), "gtfs-ace", now))
	}
	@Test fun sourceTimesAreNotGeneratedTimesAndPositionalPathKeysStayRestricted() {
		assertNull(OfflineIdentity.boardSourceTimestamp(Board(station("one"), now)))
		assertTrue(OfflineIdentity.isPositionalTrip("path|station|position"))
		assertFalse(OfflineIdentity.isPositionalTrip("gtfs-ace|trip"))
		assertEquals("estimate passed", OfflineDisplay.prediction(now - 1, now - 100, now, OfflineSettings()).unit)
		assertEquals("last estimate", OfflineDisplay.prediction(now + 60, now - 1801, now, OfflineSettings()).unit)
	}
	@Test fun stationSelectionPrefersCombinedAtEqualDistanceAndRadiusIsExclusive() {
		val one = station("one"); val both = one.copy(id = "combined:test")
		val location = StationLocation(40.7, -74.0, now)
		assertEquals(both, StationSelection("closest").select(listOf(one, both), emptyList(), location, now = now))
		assertFalse(StationSelection().includesFavorite(5280 * 0.3048))
		assertFalse(location.isUsable(now + 300))
	}
}
