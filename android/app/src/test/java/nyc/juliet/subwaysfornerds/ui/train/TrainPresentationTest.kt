package nyc.juliet.subwaysfornerds.ui.train

import nyc.juliet.subwaysfornerds.core.StopPrediction
import nyc.juliet.subwaysfornerds.core.Train
import nyc.juliet.subwaysfornerds.core.TripDetail
import nyc.juliet.subwaysfornerds.data.CachedTrip
import nyc.juliet.subwaysfornerds.ui.TripFailure
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TrainPresentationTest {
	private val now = 1_800_000_000.0
	private fun detail(timestamp: Double, relationship: String? = null) = TripDetail(Train(
		key = "gtfs-ace|1", feed = "gtfs-ace", tripId = "1", route = "A", destination = "Far Rockaway", direction = "SOUTH", timestamp = timestamp,
		stops = listOf(StopPrediction("A27S", "42 St", arrival = now - 60), StopPrediction("A24S", "34 St", arrival = now + 120)),
		relationship = relationship,
	))
	private fun saved(timestamp: Double) = CachedTrip("gtfs-ace|1", detail = detail(timestamp), savedAt = timestamp + 2, accessedAt = now)

	@Test fun connectedLiveDataIsNeverAnOfflineEstimate() {
		val shown = TrainPresentation.of(detail(now - 10), null, saved(now - 600), true, false, connected = true, now = now)
		assertFalse(shown.cached)
		assertFalse(shown.showingSnapshot)
		assertNull(shown.error)
		assertNull(shown.nextStopIndex)
	}

	@Test fun offlineUsesWhicheverCopyHasTheNewerSource() {
		val newerMemory = TrainPresentation.of(detail(now - 30), null, saved(now - 600), true, false, connected = false, now = now)
		assertTrue(newerMemory.cached)
		assertFalse(newerMemory.showingSnapshot)
		assertEquals(now - 30, newerMemory.sourceTimestamp!!, 0.0)
		val newerSaved = TrainPresentation.of(detail(now - 900), null, saved(now - 300), true, false, connected = false, now = now)
		assertTrue(newerSaved.showingSnapshot)
		assertEquals(1, newerSaved.nextStopIndex)
		assertEquals("No connection. Showing offline estimates.", newerSaved.error)
	}

	@Test fun missingFromFeedIsNotCancellation() {
		val shown = TrainPresentation.of(detail(now - 30), TripFailure.NotFound, saved(now - 300), true, false, connected = true, now = now)
		assertEquals("No longer in the current feed. Showing the last report, which may be out of date.", shown.error)
		val none = TrainPresentation.of(null, TripFailure.NotFound, null, true, false, connected = true, now = now)
		assertEquals("This train is no longer in the current feed.", none.error)
	}

	@Test fun canceledTrainsGetNoEstimate() {
		val shown = TrainPresentation.of(null, null, CachedTrip("gtfs-ace|1", detail = detail(now - 100, "CANCELED"), savedAt = now, accessedAt = now), true, false, connected = false, now = now)
		assertEquals("canceled when saved", shown.noEstimate)
		assertNull(shown.nextStopIndex)
	}

	@Test fun pathSnapshotsNeverFetchAndSayWhenTheyAreGone() {
		val shown = TrainPresentation.of(detail(now), null, null, savedLoaded = true, snapshotOnly = true, connected = true, now = now)
		assertNull(shown.train)
		assertEquals("This saved arrival is no longer stored on this device.", shown.error)
	}
}
