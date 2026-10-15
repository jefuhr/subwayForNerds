package nyc.juliet.subwaysfornerds.data

import java.nio.file.Files
import kotlinx.coroutines.test.runTest
import nyc.juliet.subwaysfornerds.core.*
import org.junit.Assert.*
import org.junit.Test

class AndroidTransitCacheTest {
	private val station = Station(id = "station", name = "Saved station", borough = "Bk", lat = 40.7, lon = -74.0)
	private fun departure(key: String = "trip", feed: String = "a", timestamp: Double = 100.0) = Departure(
		key = key, tripKey = key, route = "A", direction = "NORTH", destination = "Uptown", stopId = "stop", partId = "part", area = "area",
		feed = feed, timestamp = timestamp, time = 1000.0,
		pattern = "Local", patternSource = "reported", location = "At station",
	)
	private fun trip(key: String = "trip", timestamp: Double = 100.0) = TripDetail(Train(key = key, feed = "a", tripId = key, route = "A", destination = "Uptown", direction = "NORTH", timestamp = timestamp))

	@Test fun relaunchKeepsManualAndActiveTripsDuringExpirationAndAutomaticClear() = runTest {
		val root = Files.createTempDirectory("sfn-cache").toFile()
		try {
			var now = 100.0
			val store = AndroidTransitCache(root, "https://example.test/api/", clock = { now })
			store.saveTrip(trip("saved"), manual = true)
			store.saveTrip(trip("ride"))
			store.setActiveRide("ride")
			store.saveTrip(trip("automatic"))
			store.saveBoard(Board(station = station, generatedAt = 9999.0, departures = listOf(departure())))
			now += 86400
			val reopened = AndroidTransitCache(root, "https://example.test/api/", clock = { now })
			reopened.prune()
			reopened.clearAutomatic()
			assertEquals("saved", reopened.savedTrips().single().train.key)
			assertEquals("ride", reopened.activeRide()!!.train.key)
			assertNull(reopened.loadTrip("automatic"))
			assertNull(reopened.loadBoard(station.id))
			reopened.removeTrip("ride")
			assertNotNull(reopened.activeRide())
		} finally { root.deleteRecursively() }
	}

	@Test fun sourceMergeRetainsFailedAndOlderGroupsAndNeverUsesFetchTime() = runTest {
		val root = Files.createTempDirectory("sfn-merge").toFile()
		try {
			var now = 200.0
			val store = AndroidTransitCache(root, "https://example.test/", clock = { now })
			store.saveBoard(Board(station, generatedAt = 200.0,
				sources = listOf(SourceState(id = "a", timestamp = 100.0), SourceState(id = "b", timestamp = 100.0)),
				departures = listOf(departure("a", "a"), departure("b", "b"))))
			now = 300.0
			store.saveBoard(Board(station, generatedAt = 300.0,
				sources = listOf(SourceState(id = "a", timestamp = 90.0), SourceState(id = "b", timestamp = 150.0)),
				departures = listOf(departure("older", "a", 90.0), departure("newer", "b", 150.0))))
			assertEquals(setOf("a", "newer"), store.loadBoard(station.id)!!.departures.map { it.key }.toSet())
			store.saveBoard(Board(station, generatedAt = 9000.0,
				sources = listOf(SourceState(id = "b", timestamp = 9000.0, error = "unavailable")), departures = emptyList()))
			assertEquals(150.0, store.loadBoard(station.id)!!.departures.maxOf { it.timestamp }, 0.0)
			assertEquals(300.0, store.boardSnapshot(station.id)!!.savedAt, 0.0)
		} finally { root.deleteRecursively() }
	}

	@Test fun positionalPATHIsFrozenWhenSavedAndCannotBecomeActiveRide() = runTest {
		val root = Files.createTempDirectory("sfn-path").toFile()
		try {
			val store = AndroidTransitCache(root, "https://example.test/")
			store.saveTrip(trip("path|station|0", 200.0))
			store.saveTrip(trip("path|station|0", 100.0), manual = true)
			store.saveTrip(trip("path|station|0", 300.0))
			assertEquals(100.0, store.loadTrip("path|station|0")!!.train.timestamp, 0.0)
			try { store.setActiveRide("path|station|0"); fail("Positional trip became active") } catch (_: IllegalArgumentException) { }
		} finally { root.deleteRecursively() }
	}

	@Test fun quotasKeepBothDirectionsAndHiddenRoutesInStoredData() {
		val rows = (1..8).flatMap { index -> listOf(departure("n$index"), departure("s$index").copy(direction = "SOUTH")) }
		val retained = OfflinePlanner.retainedBoard(Board(station, 100.0, departures = rows), OfflineSettings(departuresPerLineDirection = 2))
		assertEquals(listOf("n1", "s1", "n2", "s2"), retained.departures.map { it.key })
		assertTrue(OfflinePlanner.tripKeysToSnapshot(Board(station, 100.0, departures = listOf(departure("path|0"))), OfflineSettings()).isEmpty())
	}

	@Test fun missingIndexIsRebuiltFromDurableProtectionRecords() = runTest {
		val root = Files.createTempDirectory("sfn-index").toFile()
		try {
			val store = AndroidTransitCache(root, "https://example.test/")
			store.saveTrip(trip("saved"), true)
			root.walkTopDown().first { it.name == "index.json" }.delete()
			assertEquals("saved", store.savedTrips().single().train.key)
			store.clearAutomatic()
			assertEquals(1, store.usage().savedTripCount)
		} finally { root.deleteRecursively() }
	}

	@Test fun protectedBytesCanExceedLimitWithoutSilentEviction() = runTest {
		val root = Files.createTempDirectory("sfn-pressure").toFile()
		try {
			val store = AndroidTransitCache(root, "https://example.test/")
			store.setPreferences(OfflineSettings(storageLimitMiB = 25))
			store.saveTrip(trip("automatic"))
			val large = trip("saved").copy(raw = kotlinx.serialization.json.JsonPrimitive("x".repeat(26 * 1_048_576)))
			store.saveTrip(large, manual = true)
			val usage = store.usage()
			assertTrue(usage.overLimit)
			assertEquals(usage.totalBytes, usage.protectedBytes)
			assertNull(store.loadTrip("automatic"))
			assertEquals("saved", AndroidTransitCache(root, "https://example.test/").savedTrips().single().train.key)
		} finally { root.deleteRecursively() }
	}

	@Test fun partialTripNamesBoardingStationAndNeverReplacesCompleteTrip() = runTest {
		val root = Files.createTempDirectory("sfn-partial").toFile()
		try {
			val store = AndroidTransitCache(root, "https://example.test/")
			store.saveDeparture(departure().copy(location = "Reported train position"), station, manual = true)
			val partial = store.tripSnapshot("trip")!!
			assertFalse(partial.isComplete)
			assertEquals("Saved station", partial.stops.first().name)
			assertNull(partial.train!!.position)
			store.saveTrip(trip(timestamp = 100.0))
			store.saveDeparture(departure(timestamp = 300.0), station)
			assertTrue(store.tripSnapshot("trip")!!.isComplete)
		} finally { root.deleteRecursively() }
	}

	@Test fun nearbyPlanUsesViewedStationAndKeepsFavoriteAndActivePriority() {
		val near = station.copy(id = "near", lat = station.lat + 0.001)
		val distant = station.copy(id = "far", lat = station.lat + 1.0)
		val settings = Settings(favorites = listOf("far"), offline = OfflineSettings(nearbyRadiusFeet = 1000))
		val plan = OfflinePlanner.requests("fixture", station, listOf(station, near, distant), settings, activeRide = ActiveRideRecord("ride", startedAt = 1.0))
		assertEquals(OfflineFetchPriority.SELECTED, plan.first { it.target == OfflineFetchTarget.Board(station.id) }.priority)
		assertTrue(plan.any { it.target == OfflineFetchTarget.Board("near") })
		assertTrue(plan.any { it.target == OfflineFetchTarget.Board("far") })
		assertEquals(OfflineFetchPriority.ACTIVE_RIDE, plan.first { it.target == OfflineFetchTarget.Trip("ride") }.priority)
		assertEquals(listOf("near"), OfflinePlanner.surroundingStations(station, listOf(station, near, distant), settings.offline).map { it.station.id })
	}

	@Test fun alertAndGPSUpdatesDoNotRenewPredictionSaveTime() = runTest {
		val root = Files.createTempDirectory("sfn-independent-clocks").toFile()
		try {
			var now = 200.0
			val store = AndroidTransitCache(root, "https://example.test/", clock = { now })
			val initial = Board(station, 200.0, listOf(SourceState("a", 100.0), SourceState("subway-alerts", 100.0)), listOf(departure()))
			store.saveBoard(initial)
			now = 300.0
			store.saveBoard(initial.copy(generatedAt = 300.0, sources = listOf(SourceState("a", 100.0), SourceState("subway-alerts", 300.0))))
			assertEquals(200.0, store.boardSnapshot(station.id)!!.savedAt, 0.0)
			assertEquals(100.0, store.loadBoard(station.id)!!.departures.single().timestamp, 0.0)
		} finally { root.deleteRecursively() }
	}

	@Test fun failedSourceMetadataCannotPoisonDepartureOnlyFallback() {
		val stored = Board(station, 100.0, departures = listOf(departure("saved", timestamp = 100.0)))
		val failed = Board(station, 9000.0, sources = listOf(SourceState("a", 9000.0, error = "unavailable")))
		val retained = OfflinePlanner.mergeBoard(failed, stored).board
		assertEquals(100.0, retained.sources.single().timestamp!!, 0.0)
		val recovered = OfflinePlanner.mergeBoard(Board(station, 150.0, sources = listOf(SourceState("a", 150.0)), departures = listOf(departure("recovered", timestamp = 150.0))), retained)
		assertEquals("recovered", recovered.board.departures.single().key)
	}
}
