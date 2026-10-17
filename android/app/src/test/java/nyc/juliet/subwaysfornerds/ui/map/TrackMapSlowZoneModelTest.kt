package nyc.juliet.subwaysfornerds.ui.map

import java.io.File
import java.io.IOException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import nyc.juliet.subwaysfornerds.core.*
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class TrackMapSlowZoneModelTest {
	private val now = 1_788_656_340.0
	private val a = TrackMapPoint(100.0, 100.0)
	private val b = TrackMapPoint(200.0, 300.0)
	private val topology = TrackMapTopology(1, TrackMapContract.MAP_VERSION, TrackMapContract.PDF_SHA256, TrackMapContract.PAGE, "Credit", "https://example.invalid", emptyList(), emptyList(), emptyList(), emptyList(), TrackMapTopologyCoverage(emptyList(), emptyList(), emptyList()))
	private val zone = TrackMapSlowZone("slow-L", listOf("L"), listOf(listOf(a, b)), "L01S", "L02S", "8 Av → 6 Av", "slow", "2026-09-01", "2026-09-05", 42.0, 90.0, 3)
	private val snapshot = TrackMapSnapshot(1, TrackMapContract.MAP_VERSION, TrackMapContract.PDF_SHA256, now, emptyList(), emptyList(), TrackMapSnapshotCoverage(0, 0, 0), TrackMapSlowZones("2026-09-05", now + 30, listOf(zone), 1))

	@Test fun zonesAppearWithoutTrainsSurviveFailureAndExpireIndependentlyOfPolls() = runTest {
		var clock = now
		var fail = false
		val model = TrackMapModel(backgroundScope, { _, _ -> if (fail) throw IOException("HTTP 503") else snapshot }, { clock })
		model.loadAssets(object : TrackMapAssetSource { override suspend fun load() = TrackMapResources(topology, File("unused.pdf")) })
		runCurrent(); model.setForeground(true); model.setVisible(true); runCurrent()
		assertTrue(model.markers(clock, false).isEmpty())
		assertEquals(listOf("L"), model.routes)
		assertEquals(listOf(zone), model.slowZones(clock))
		model.toggleRoute("Q"); assertTrue(model.slowZones(clock).isEmpty())
		model.clearRoutes()
		val camera = TrackMapCamera(3000.0, 4000.0, 2.5)
		model.camera = camera
		fail = true; clock = now + 10
		advanceTimeBy(15_000); runCurrent()
		assertNotNull(model.refreshError)
		assertEquals(listOf(zone), model.slowZones(clock))
		assertTrue(model.slowZoneStatus(clock).contains("cached", true))
		model.setConnected(false); model.setForeground(false)
		clock = now + 29.999; assertEquals(1, model.slowZones(clock).size)
		clock = now + 30; assertTrue(model.slowZones(clock).isEmpty())
		assertTrue(model.slowZoneStatus(clock).contains("expired", true))
		assertEquals(camera, model.camera)
	}

	@Test fun wrongMapIdentityAndEndpointChangeAlsoRemoveSlowZones() = runTest {
		var value = snapshot
		val model = TrackMapModel(backgroundScope, { _, _ -> value }, { now })
		model.loadAssets(object : TrackMapAssetSource { override suspend fun load() = TrackMapResources(topology, File("unused.pdf")) })
		runCurrent(); model.setForeground(true); model.setVisible(true); runCurrent()
		assertEquals(1, model.slowZones(now).size)
		value = snapshot.copy(pdfSha256 = "0".repeat(64))
		advanceTimeBy(15_000); runCurrent()
		assertTrue(model.slowZones(now).isEmpty())
		value = snapshot
		advanceTimeBy(15_000); runCurrent(); assertEquals(1, model.slowZones(now).size)
		model.setVisible(false); model.endpointChanged()
		assertTrue(model.slowZones(now).isEmpty())
	}
}
