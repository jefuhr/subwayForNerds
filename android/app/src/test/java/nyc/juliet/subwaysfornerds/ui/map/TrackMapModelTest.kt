package nyc.juliet.subwaysfornerds.ui.map

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import nyc.juliet.subwaysfornerds.core.SourceState
import nyc.juliet.subwaysfornerds.core.Station
import nyc.juliet.subwaysfornerds.core.TrackMapCamera
import nyc.juliet.subwaysfornerds.core.TrackMapContract
import nyc.juliet.subwaysfornerds.core.TrackMapEdge
import nyc.juliet.subwaysfornerds.core.TrackMapFreshness
import nyc.juliet.subwaysfornerds.core.TrackMapMotion
import nyc.juliet.subwaysfornerds.core.TrackMapNode
import nyc.juliet.subwaysfornerds.core.TrackMapPage
import nyc.juliet.subwaysfornerds.core.TrackMapPlacement
import nyc.juliet.subwaysfornerds.core.TrackMapPoint
import nyc.juliet.subwaysfornerds.core.TrackMapPositionBasis
import nyc.juliet.subwaysfornerds.core.TrackMapSnapshot
import nyc.juliet.subwaysfornerds.core.TrackMapSnapshotCoverage
import nyc.juliet.subwaysfornerds.core.TrackMapStation
import nyc.juliet.subwaysfornerds.core.TrackMapTopology
import nyc.juliet.subwaysfornerds.core.TrackMapTopologyCoverage
import nyc.juliet.subwaysfornerds.core.TrackMapTrackBasis
import nyc.juliet.subwaysfornerds.core.TrackMapTrain
import nyc.juliet.subwaysfornerds.core.TransitException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.io.IOException
import kotlin.coroutines.Continuation
import kotlin.coroutines.resume
import kotlin.coroutines.suspendCoroutine

@OptIn(ExperimentalCoroutinesApi::class)
class TrackMapModelTest {
	private val now = 1_788_656_340.0
	private val a = TrackMapPoint(100.0, 100.0)
	private val c = TrackMapPoint(200.0, 300.0)
	private val topology = TrackMapTopology(
		1, TrackMapContract.MAP_VERSION, TrackMapContract.PDF_SHA256, TrackMapPage(7344.0, 11540.6), "Credit", "https://example.invalid/map.pdf",
		listOf(TrackMapStation("station:L03", "602", "L03", "14 St-Union Sq", a, listOf("L03N")), TrackMapStation("station:L08", "120", "L08", "Bedford Av", c, listOf("L08N"))),
		listOf(TrackMapNode("n:a", a), TrackMapNode("n:c", c)),
		listOf(TrackMapEdge("e1", "n:a", "n:c", listOf(a, c), false, true)), emptyList(),
		TrackMapTopologyCoverage(emptyList(), emptyList(), listOf("PARTIAL")),
	)
	private fun train(key: String = "gtfs-l|20260905|1|", route: String = "L", observedAt: Double = now - 10) = TrackMapTrain(
		key, "gtfs-l", route, "8 Av", "N", trackBasis = TrackMapTrackBasis.REPORTED, positionBasis = TrackMapPositionBasis.ESTIMATED,
		placement = TrackMapPlacement.TRACK, point = a, motion = TrackMapMotion(listOf("e1"), listOf(a, c), 0.0, 0.5, now, now + 60),
		observedAt = observedAt, feedTimestamp = observedAt, staleAt = observedAt + 90, expiresAt = observedAt + 300, freshness = TrackMapFreshness.LIVE,
	)
	private fun snapshot(trains: List<TrackMapTrain> = listOf(train()), mapVersion: String = TrackMapContract.MAP_VERSION, pdf: String = TrackMapContract.PDF_SHA256) =
		TrackMapSnapshot(1, mapVersion, pdf, now, listOf(SourceState("gtfs-l", now - 10, now - 5, null)), trains, TrackMapSnapshotCoverage(trains.size, 0, 0))

	private inner class Harness(val scope: TestScope, val mapTopology: TrackMapTopology = topology) {
		var clock = now
		val calls = mutableListOf<Long>()
		var next: suspend () -> TrackMapSnapshot = { snapshot() }
		val model = TrackMapModel(scope.backgroundScope, { version, _ -> assertEquals(TrackMapContract.MAP_VERSION, version); calls += scope.testScheduler.currentTime; next() }, { clock })
		fun ready() { model.loadAssets(object : TrackMapAssetSource { override suspend fun load() = TrackMapResources(mapTopology, File("unused.pdf")) }); scope.runCurrent() }
		fun show() { model.setForeground(true); model.setVisible(true); scope.runCurrent() }
	}

	@Test fun pollsEvery15SecondsOnlyWhileTheMapIsVisibleAndTheAppIsForeground() = runTest {
		val h = Harness(this)
		h.ready()
		h.model.setForeground(true); runCurrent()
		assertTrue("hidden map must not poll", h.calls.isEmpty())
		h.model.setVisible(true); runCurrent()
		assertEquals(1, h.calls.size)
		advanceTimeBy(14_999); runCurrent(); assertEquals(1, h.calls.size)
		advanceTimeBy(1); runCurrent(); assertEquals(2, h.calls.size)
		h.model.setVisible(false); advanceTimeBy(120_000); runCurrent()
		assertEquals(2, h.calls.size)
		h.model.setVisible(true); runCurrent(); assertEquals(3, h.calls.size)
		h.model.setForeground(false); advanceTimeBy(120_000); runCurrent()
		assertEquals(3, h.calls.size)
		// Repeated visibility signals never start a second loop.
		h.model.setForeground(true); h.model.setVisible(true); h.model.setVisible(true); runCurrent()
		advanceTimeBy(15_000); runCurrent()
		assertEquals(5, h.calls.size)
	}

	@Test fun leavingTheMapCancelsTheRequestInFlight() = runTest {
		val h = Harness(this)
		val gate = CompletableDeferred<TrackMapSnapshot>()
		var cancelled = false
		h.next = { try { gate.await() } catch (e: CancellationException) { cancelled = true; throw e } }
		h.ready(); h.show()
		assertEquals(1, h.calls.size)
		h.model.setVisible(false); runCurrent()
		assertTrue(cancelled)
		gate.complete(snapshot()); runCurrent()
		assertNull("a cancelled response is never applied", h.model.snapshot)
	}

	@Test fun unavailableAssetsShowALocalStateAndNeverPoll() = runTest {
		val h = Harness(this)
		h.model.loadAssets(object : TrackMapAssetSource { override suspend fun load(): TrackMapResources = throw TrackMapUnavailableException("Track map artwork is not installed in this build.") })
		runCurrent(); h.show(); advanceTimeBy(60_000); runCurrent()
		val state = h.model.assets
		assertTrue(state is TrackMapAssetState.Unavailable)
		assertEquals("Track map artwork is not installed in this build.", (state as TrackMapAssetState.Unavailable).detail)
		assertTrue(h.calls.isEmpty())
		assertEquals("Track map unavailable", h.model.status(now))
	}

	@Test fun mismatchedSnapshotsAreRejectedBeforePlotting() = runTest {
		val h = Harness(this)
		h.ready(); h.show()
		assertNotNull(h.model.snapshot)
		h.next = { snapshot(mapVersion = "nyc-2.6.9-v1") }
		advanceTimeBy(15_000); runCurrent()
		assertNull("the previous map's trains are not kept on a mismatched map", h.model.snapshot)
		assertTrue(h.model.markers(now, reducedMotion = false).isEmpty())
		assertTrue(h.model.status(now).startsWith("Map data mismatch"))
		h.next = { snapshot(pdf = "0".repeat(64)) }
		advanceTimeBy(15_000); runCurrent()
		assertNull(h.model.snapshot)
	}

	@Test fun pollingNeverResetsTheViewport() = runTest {
		val h = Harness(this)
		h.ready(); h.show()
		h.model.focusInitial(listOf("602"), 1000.0, 1000.0)
		assertEquals(a.x, h.model.camera!!.centerX, 0.0)
		val moved = TrackMapCamera(3000.0, 4000.0, 2.5)
		h.model.camera = moved
		advanceTimeBy(45_000); runCurrent()
		assertEquals(4, h.calls.size)
		assertEquals(moved, h.model.camera)
		// The initial focus happens once per model, even when the map is shown again.
		h.model.focusInitial(listOf("120"), 1000.0, 1000.0)
		assertEquals(moved, h.model.camera)
	}

	@Test fun initialFocusFitsTheMapWhenTheSelectedStationIsNotMapped() = runTest {
		val h = Harness(this)
		h.ready()
		h.model.focusInitial(listOf("999"), 1000.0, 1000.0)
		assertEquals(TrackMapCamera.fit(topology.page, 1000.0, 1000.0, TrackMapModel.FIT_PADDING), h.model.camera)
	}

	@Test fun failedRefreshKeepsTheLastSnapshotAgingByItsOriginalEvidence() = runTest {
		val h = Harness(this)
		h.ready(); h.show()
		h.next = { throw IOException("offline") }
		h.clock = now + 85
		advanceTimeBy(15_000); runCurrent()
		assertNotNull(h.model.snapshot)
		val row = h.model.rows(h.clock).single()
		assertEquals(TrackMapFreshness.STALE, row.evidence.freshness)
		assertTrue(h.model.status(h.clock).contains("showing last positions"))
		h.clock = now + 300
		assertTrue("expired evidence is not drawn", h.model.markers(h.clock, reducedMotion = false).isEmpty())
	}

	@Test fun offlineStopsMotionAndSkipsRequestsUntilReconnected() = runTest {
		val h = Harness(this)
		h.ready(); h.show()
		h.clock = now + 12
		h.model.setConnected(false)
		h.clock = now + 30
		advanceTimeBy(30_000); runCurrent()
		assertEquals(1, h.calls.size)
		val marker = h.model.markers(h.clock, reducedMotion = false).single()
		assertFalse(marker.display.animating)
		// Frozen at the drop: 12 s of a 60 s window to progress 0.5 is progress 0.1 along a → c.
		assertEquals(110.0, marker.display.point.x, 1e-6); assertEquals(120.0, marker.display.point.y, 1e-6)
		h.model.setConnected(true); runCurrent()
		assertEquals("reconnecting refreshes at once", 2, h.calls.size)
	}

	@Test fun routeFiltersAndSearchNarrowWhatIsShown() = runTest {
		val h = Harness(this)
		h.next = { snapshot(listOf(train("k1", "L"), train("k2", "Q"))) }
		h.ready(); h.show()
		assertEquals(listOf("L", "Q"), h.model.routes)
		h.model.toggleRoute("Q")
		assertEquals(listOf("k2"), h.model.markers(now, false).map { it.train.key })
		h.model.toggleRoute("Q")
		assertEquals(2, h.model.markers(now, false).size)
		assertEquals(listOf("Bedford Av"), h.model.search("bedf").map { it.title })
		assertTrue(h.model.search("").isEmpty())
	}

	@Test fun endpointChangeDropsTheOtherServersTrains() = runTest {
		val h = Harness(this)
		h.ready(); h.show()
		assertNotNull(h.model.snapshot)
		h.next = { throw TransitException.NotFound() }
		h.model.endpointChanged(); runCurrent()
		assertNull(h.model.snapshot)
		assertEquals(2, h.calls.size)
	}

	@Test fun trainsHeldAtAPlatformFaceAlongTheRailThatArrivesThere() = runTest {
		val h = Harness(this)
		val held = train().copy(point = c, motion = null, status = "STOPPED_AT", positionBasis = TrackMapPositionBasis.REPORTED)
		val near = train("k2").copy(point = c, motion = null, placement = TrackMapPlacement.NEAR_STOP)
		h.next = { snapshot(listOf(held, near)) }
		h.ready(); h.show()
		val markers = h.model.markers(now, reducedMotion = false).associateBy { it.train.key }
		assertEquals(kotlin.math.atan2(200.0, 100.0), markers.getValue(held.key).display.heading!!, 1e-9)
		assertNotNull(markers.getValue(held.key).display.path)
		assertNull("a train only near a stop has no known rail", markers.getValue("k2").display.heading)
	}

	@Test fun aFailedRefreshFreezesMotionAtTheFirstFailureAndCountsNoTrainAsLive() = runTest {
		val h = Harness(this)
		h.ready(); h.show()
		assertTrue(h.model.status(now).startsWith("1 live"))
		h.next = { throw IOException("HTTP 503") }
		h.clock = now + 12
		advanceTimeBy(15_000); runCurrent()
		// A second failure never moves the freeze forward.
		h.clock = now + 27
		advanceTimeBy(15_000); runCurrent()
		h.clock = now + 30
		val marker = h.model.markers(h.clock, reducedMotion = false).single()
		assertFalse(marker.display.animating)
		assertEquals(TrackMapFreshness.STALE, marker.evidence.freshness)
		assertEquals(110.0, marker.display.point.x, 1e-6); assertEquals(120.0, marker.display.point.y, 1e-6)
		assertTrue(h.model.status(h.clock), h.model.status(h.clock).startsWith("0 live · 1 stale"))
	}

	@Test fun goingOfflineFadesEveryTrainAtOnceAndReconnectingStaysFrozenUntilAValidatedSnapshot() = runTest {
		val h = Harness(this)
		h.ready(); h.show()
		h.clock = now + 12
		h.model.setConnected(false)
		// Evidence is only 22 s old, but nothing is live without a connection.
		assertEquals(TrackMapFreshness.STALE, h.model.rows(h.clock).single().evidence.freshness)
		assertTrue(h.model.status(h.clock).startsWith("0 live · 1 stale"))
		var resume: Continuation<TrackMapSnapshot>? = null
		h.next = { suspendCoroutine { resume = it } }
		h.clock = now + 30
		h.model.setConnected(true); runCurrent()
		assertEquals("reconnecting refreshes at once", 2, h.calls.size)
		val waiting = h.model.markers(h.clock, reducedMotion = false).single()
		assertFalse("a connection alone is not fresh data", waiting.display.animating)
		assertEquals(110.0, waiting.display.point.x, 1e-6); assertEquals(120.0, waiting.display.point.y, 1e-6)
		assertTrue(h.model.status(h.clock).startsWith("0 live"))
		// A failed reply after reconnecting keeps the original freeze.
		resume!!.resumeWith(Result.failure(IOException("timeout"))); runCurrent()
		assertEquals(110.0, h.model.markers(h.clock, reducedMotion = false).single().display.point.x, 1e-6)
		// A mismatched reply is not a validated success either.
		h.next = { snapshot(mapVersion = "nyc-2.6.9-v1") }
		advanceTimeBy(15_000); runCurrent()
		assertTrue(h.model.markers(h.clock, reducedMotion = false).isEmpty())
		h.next = { snapshot() }
		advanceTimeBy(15_000); runCurrent()
		val live = h.model.markers(h.clock, reducedMotion = false).single()
		assertEquals(TrackMapFreshness.LIVE, live.evidence.freshness)
		assertTrue(live.display.animating)
		assertTrue(h.model.status(h.clock).startsWith("1 live"))
	}

	@Test fun aLateResponseThatIgnoredCancellationIsNeverApplied() = runTest {
		for (leave in listOf<(TrackMapModel) -> Unit>({ it.setVisible(false) }, { it.setForeground(false) }, { it.setConnected(false) })) {
			val h = Harness(this)
			var resume: Continuation<TrackMapSnapshot>? = null
			// suspendCoroutine ignores cancellation, like a client that does not cooperate.
			h.next = { suspendCoroutine { resume = it } }
			h.ready(); h.show()
			leave(h.model); runCurrent()
			resume!!.resume(snapshot()); runCurrent()
			assertNull("a response from a cancelled request is never applied", h.model.snapshot)
			assertNull(h.model.progress)
		}
	}

	@Test fun sameNameStationsInDifferentComplexesStayApartWithTheirLinesAndBorough() = runTest {
		val b = TrackMapPoint(150.0, 150.0)
		val mapped = topology.copy(stations = listOf(
			TrackMapStation("station:L01", "618", "L01", "8 Av", a, listOf("L01N")),
			TrackMapStation("station:A31", "618", "A31", "14 St", b, listOf("A31N")),
			TrackMapStation("station:N02", "71", "N02", "8 Av", c, listOf("N02N")),
		))
		val h = Harness(this, mapped)
		h.ready()
		val catalog = listOf(
			Station("618", "14 St/8 Av", "M", listOf("L", "E", "A", "C"), 40.74, -74.0),
			Station("71", "8 Av", "Bk", listOf("N"), 40.63, -74.01),
		)
		val results = h.model.search("8 av", catalog)
		assertEquals(listOf("618", "71"), results.map { it.stationId })
		assertEquals(listOf("14 St/8 Av", "8 Av"), results.map { it.title })
		assertEquals(listOf("A C E L · Manhattan", "N · Brooklyn"), results.map { it.subtitle })
		// The matching part is what the map focuses.
		assertEquals("station:L01", results[0].station.id)
		// Without the catalog, the complex's other mapped names still tell them apart.
		val bare = h.model.search("8 av")
		assertEquals(listOf("8 Av", "8 Av"), bare.map { it.title })
		assertEquals(listOf("Also 14 St", ""), bare.map { it.subtitle })
		for (result in results + bare) for (opaque in listOf("618", "71", "station:", "L01", "A31", "N02")) {
			assertFalse("$opaque is visible in ${result.title} ${result.subtitle}", (result.title + " " + result.subtitle).contains(opaque))
		}
	}
}
