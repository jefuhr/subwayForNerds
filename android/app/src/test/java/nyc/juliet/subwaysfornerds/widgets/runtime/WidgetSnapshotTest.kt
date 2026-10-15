package nyc.juliet.subwaysfornerds.widgets.runtime

import nyc.juliet.subwaysfornerds.core.*
import org.junit.Assert.*
import org.junit.Test

class WidgetSnapshotTest {
	private val station = Station("station", "Station", "M", listOf("A"), 40.7, -74.0)
	private fun row(key: String, direction: String = "NORTH", timestamp: Double = 100.0) = Departure(key, key, "A", "Uptown", direction, "stop", "part", "Area", 1000.0, pattern = "Local", patternSource = "reported", location = "", feed = "gtfs-a", timestamp = timestamp)

	@Test fun snapshotKeepsSourceTimeDespiteNewFetchTimeAndBothDirections() {
		val board = Board(station, 9999.0, listOf(SourceState("gtfs-a", 100.0, 9999.0)), (1..30).map { row("n$it") } + row("south", "SOUTH"))
		val snapshot = WidgetSnapshotFactory.board(board, Settings(), now = 200.0, cached = true)
		assertEquals(100.0, snapshot.sourceTime!!, 0.0)
		assertEquals(1, snapshot.south.size)
		assertEquals(14, snapshot.north.size)
		assertTrue(snapshot.estimated)
		assertTrue(snapshot.estimateUsable)
	}

	@Test fun periodicMinimumDoesNotRewritePortableChoices() {
		val settings = Settings(widgets = WidgetSettings(display = WidgetDisplay(refreshInterval = 1)))
		assertEquals(15L, WidgetSnapshotFactory.preferredRefreshMinutes(settings))
		assertEquals(1, settings.widgets.display.refreshInterval)
		assertEquals(60L, WidgetSnapshotFactory.preferredRefreshMinutes(settings.copy(widgets = settings.widgets.copy(display = settings.widgets.display.copy(refreshInterval = 60)))))
	}

	@Test fun zeroInstalledWidgetsCancelOnlyOwnedRefreshWorkAndNeverAllowRefresh() {
		val settings = Settings(widgets = WidgetSettings(display = WidgetDisplay(refreshInterval = 1)))
		val absent = WidgetSnapshotFactory.schedulePlan(settings, installedWidgetCount = 0, deviceUnlocked = true)
		assertTrue(absent.cancelOwnWork)
		assertFalse(absent.refreshAllowed)
		assertNull(absent.periodicIntervalMinutes)
		val installed = WidgetSnapshotFactory.schedulePlan(settings, installedWidgetCount = 2, deviceUnlocked = true)
		assertFalse(installed.cancelOwnWork)
		assertTrue(installed.refreshAllowed)
		assertEquals(15L, installed.periodicIntervalMinutes)
		assertEquals(1, settings.widgets.display.refreshInterval)
	}

	@Test fun installedWidgetsKeepLongPortableCadenceAndLockedDeviceDefersCredentialStorageWork() {
		val settings = Settings(widgets = WidgetSettings(display = WidgetDisplay(refreshInterval = 60)))
		assertEquals(60L, WidgetSnapshotFactory.schedulePlan(settings, installedWidgetCount = 1, deviceUnlocked = true).periodicIntervalMinutes)
		val locked = WidgetSnapshotFactory.schedulePlan(settings, installedWidgetCount = 1, deviceUnlocked = false)
		assertFalse(locked.cancelOwnWork)
		assertFalse(locked.refreshAllowed)
		assertNull(locked.periodicIntervalMinutes)
	}

	@Test fun futureSourcesAndExpiredPredictionsNeverBecomeLive() {
		val future = WidgetSnapshotFactory.board(Board(station, 10000.0, departures = listOf(row("future", timestamp = 1000.0))), Settings(), now = 200.0, cached = false)
		assertTrue(future.north.single().cached)
		assertFalse(future.estimateUsable)
		val expired = WidgetSnapshotFactory.board(Board(station, 10000.0, departures = listOf(row("expired"))), Settings(), now = 10000.0, cached = false)
		assertFalse(expired.estimateUsable)
		assertTrue(expired.north.single().historicalDetail.contains("passed", ignoreCase = true))
	}

	@Test fun GPSOnlyBoardUsesPredictionClockAndKeepsHonestNoArrivals() {
		val board = Board(station.copy(routes = listOf("NJT-HBLR")), 9999.0,
			sources = listOf(SourceState("njt-hblr", timestamp = 100.0), SourceState("njt-hblr-gps", timestamp = 200.0)),
			njt = NjtState(true, SourceState("njt-hblr", timestamp = 100.0), SourceState("njt-hblr-gps", timestamp = 200.0)))
		val snapshot = WidgetSnapshotFactory.board(board, Settings(), now = 200.0, cached = false)
		assertEquals(100.0, snapshot.sourceTime!!, 0.0)
		assertTrue(snapshot.north.isEmpty() && snapshot.south.isEmpty())
		assertTrue(snapshot.message!!.contains("unavailable"))
	}

	@Test fun combinedGPSOnlyMetadataNeverSuppliesAnArrivalClock() {
		val board = Board(station.copy(id = "combined:test"), 9999.0, sources = listOf(SourceState("njt-bus-g2-positions", timestamp = 200.0)))
		val snapshot = WidgetSnapshotFactory.board(board, Settings(), now = 200.0, cached = false)
		assertNull(snapshot.sourceTime)
		assertFalse(snapshot.estimateUsable)
		assertTrue(snapshot.north.isEmpty() && snapshot.south.isEmpty())
	}

	@Test fun filtersApplyWithoutDroppingOtherDirectionAndCombinedOriginsSurvive() {
		val station2 = station.copy(id = "two", name = "Other station")
		val combined = CombinedBoards.merge(station.copy(id = "combined:test"), listOf(
			MemberBoardSnapshot(station, Board(station, 100.0, departures = listOf(row("same")))),
			MemberBoardSnapshot(station2, Board(station2, 100.0, departures = listOf(row("same")))),
		))
		val snapshot = WidgetSnapshotFactory.board(combined.board, Settings(), 110.0, false, combined = combined)
		assertEquals(2, snapshot.north.size)
		assertEquals(setOf("Station", "Other station"), snapshot.north.map { it.originLabel }.toSet())
	}
}
