package nyc.juliet.subwaysfornerds.ui

import nyc.juliet.subwaysfornerds.core.DepartureRowSettings
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Test

/** The four direct switches in settings write only their own key and persist. */
class DepartureRowSettingsModelTest {
	private val harness = ModelHarness()
	private lateinit var model: AppModel

	@After fun tearDown() = harness.close()

	private fun waitForSaved(message: String, condition: (DepartureRowSettings) -> Boolean) {
		val deadline = System.currentTimeMillis() + 30_000
		while (!condition(kotlinx.coroutines.runBlocking { harness.storage.store.load() }.departureRows)) {
			if (System.currentTimeMillis() > deadline) org.junit.Assert.fail("Timed out waiting for $message")
			Thread.sleep(20)
		}
	}

	@Test fun switchesChangeOneKeyEachAndPersist() {
		model = harness.create()
		assertEquals(DepartureRowSettings(), model.departureRows)
		harness.onModel { model.setShowTrackProvenance(true) }
		assertEquals(DepartureRowSettings(showTrackProvenance = true), model.departureRows)
		harness.onModel { model.setCombinePosition(false) }
		harness.onModel { model.setShowConsist(false) }
		harness.onModel { model.setShowHeadway(false) }
		assertEquals(DepartureRowSettings(showTrackProvenance = true, combinePosition = false, showConsist = false, showHeadway = false), model.departureRows)
		waitForSaved("all four switches to save") { it == DepartureRowSettings(true, false, false, false) }
		harness.onModel { model.setShowTrackProvenance(false); model.setCombinePosition(true) }
		assertEquals(DepartureRowSettings(false, true, false, false), model.departureRows)
	}
}
