package nyc.juliet.subwaysfornerds

import android.content.pm.ActivityInfo
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsOff
import androidx.compose.ui.test.assertIsOn
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.hasScrollToNodeAction
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.lifecycle.ViewModelProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.UiDevice
import kotlinx.coroutines.runBlocking
import nyc.juliet.subwaysfornerds.core.NerdsCodec
import nyc.juliet.subwaysfornerds.core.Settings
import nyc.juliet.subwaysfornerds.core.StationSettings
import nyc.juliet.subwaysfornerds.core.TransferFilter
import nyc.juliet.subwaysfornerds.data.AndroidSettingsStore
import nyc.juliet.subwaysfornerds.ui.AppViewModel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.runner.RunWith

private const val TRANSFER_STATION = "601"
private const val TRANSFER_STOP = "stop_L02N"
private const val NORTH_L_CONNECTION = "connection_gtfs-l|20260905|122800_L..N||L02N|4"
private const val SOUTH_F_CONNECTION = "connection_gtfs-bdfm|20260905|122550_F..S|20:25:30|D19S|5"

/** Connections filtered by the transfer station, and its board opened without losing the way back. */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class TransferFlowTest {
	private val compose = createAndroidComposeRule<MainActivity>()
	@get:Rule val rules: RuleChain = RuleChain.outerRule(FixtureRule()).around(compose).around(FailureArtifacts(compose))

	private val device get() = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation())
	private val anyConnection = SemanticsMatcher("is a connection row") { it.config.getOrNull(SemanticsProperties.TestTag)?.startsWith("connection_") == true }
	private fun saved(): Settings = runBlocking { AndroidSettingsStore(InstrumentationRegistry.getInstrumentation().targetContext).load() }
	private fun waitForSaved(message: String, condition: (Settings) -> Boolean) {
		val deadline = System.currentTimeMillis() + 10_000
		while (!condition(saved())) { if (System.currentTimeMillis() > deadline) throw AssertionError("Timed out waiting for $message"); Thread.sleep(50) }
	}
	private fun transfersNode(tag: String) = compose.onNode(hasTestTag("transfersScreen") and hasScrollToNodeAction()).run { performScrollToNode(hasTestTag(tag)); compose.onNodeWithTag(tag) }
	private fun transfersHas(tag: String) = runCatching { compose.onNode(hasTestTag("transfersScreen") and hasScrollToNodeAction()).performScrollToNode(hasTestTag(tag)) }.isSuccess

	private fun openConnections() {
		compose.waitForDepartures()
		compose.scrollToDeparture(FIRST_NORTH_L).performClick()
		compose.waitUntilAtLeastOneExists(hasTestTag("boardingStation"), 10_000)
		compose.onNode(hasTestTag("trainDetails") and hasScrollToNodeAction()).performScrollToNode(hasTestTag(TRANSFER_STOP))
		compose.onNodeWithTag(TRANSFER_STOP).performClick()
		compose.waitUntilAtLeastOneExists(anyConnection, 15_000)
	}

	@Test fun transferFiltersUseTheTransferStationAndResetWhenTheyExcludeEveryRow() {
		openConnections()
		assertTrue(transfersHas(NORTH_L_CONNECTION))
		transfersNode("transfer_direction_SOUTH").performClick()
		transfersNode("transfer_direction_SOUTH").assertIsSelected()
		compose.waitForIdle()
		assertFalse("A northbound connection must not survive the southbound filter", transfersHas(NORTH_L_CONNECTION))
		assertTrue(transfersHas(SOUTH_F_CONNECTION))
		compose.onRoot().saveScreenshot("transfers-southbound")
		// Shared mode writes the transfer station's board filters, never the selected board's.
		waitForSaved("the transfer station filter") { it.stations[TRANSFER_STATION]?.direction == "SOUTH" }
		assertEquals(null, saved().stations[FIXTURE_STATION])

		// M is a line at the station with nothing reported: the empty state says the filters did it.
		transfersNode("transfer_routeFilter_M").performClick()
		compose.waitUntilAtLeastOneExists(hasTestTag("transfersFiltered"), 5_000)
		compose.onRoot().saveScreenshot("transfers-filtered-empty")
		transfersNode("resetTransferFilters").performClick()
		compose.waitUntilAtLeastOneExists(anyConnection, 5_000)
		assertTrue(transfersHas(NORTH_L_CONNECTION))
		waitForSaved("the reset") { it.stations[TRANSFER_STATION] == StationSettings() }
	}

	@Test fun separateFiltersCopyTheBoardOnceAndEditIndependently() {
		var viewModel: AppViewModel? = null
		compose.activityRule.scenario.onActivity { viewModel = ViewModelProvider(it)[AppViewModel::class.java] }
		compose.onNodeWithTag("tab_settings").performClick()
		compose.onNode(hasTestTag("settingsScreen") and hasScrollToNodeAction()).performScrollToNode(hasTestTag("separateTransferFilters"))
		compose.onNodeWithTag("separateTransferFilters").assertIsOff().performClick()
		compose.onNodeWithTag("separateTransferFilters").assertIsOn()
		compose.onRoot().saveScreenshot("settings-separate-transfer-filters")
		waitForSaved("separate mode") { it.transfers.separateFilters }
		compose.onNodeWithTag("tab_board").performClick()
		openConnections()
		// Shown once in separate mode, the station's board filters are copied and saved.
		waitForSaved("the seeded entry") { it.transfers.stations[TRANSFER_STATION] == TransferFilter() }
		transfersNode("transfer_routeFilter_F").performClick()
		waitForSaved("the separate edit") { it.transfers.stations[TRANSFER_STATION] == TransferFilter(routes = listOf("F")) }
		assertEquals(null, saved().stations[TRANSFER_STATION])
		assertTrue(transfersHas(SOUTH_F_CONNECTION))
		assertFalse(transfersHas(NORTH_L_CONNECTION))
		compose.onRoot().saveScreenshot("transfers-separate-f")
		assertTrue(viewModel!!.model.settings.transfers.separateFilters)
	}

	@Test fun openingTheStationBoardReturnsToTheTransferAndTrainWithNativeBack() {
		openConnections()
		transfersNode("openTransferStationBoard").performClick()
		compose.waitUntilAtLeastOneExists(hasTestTag("boardScreen"), 5_000)
		compose.waitUntilAtLeastOneExists(hasTestTag("selectedStation") and hasText("6 Av / 14 St", substring = true), 5_000)
		compose.onNodeWithTag("navigateBack").assertIsDisplayed()
		compose.onRoot().saveScreenshot("transfer-station-board")

		device.pressBack()
		compose.waitUntilAtLeastOneExists(hasTestTag("transfersScreen"), 5_000)
		compose.waitUntilAtLeastOneExists(anyConnection, 15_000)
		compose.onRoot().saveScreenshot("transfer-after-back")

		device.pressBack()
		compose.waitUntilAtLeastOneExists(hasTestTag("boardingStation"), 10_000)
		// The train keeps boarding where it was opened, although the board moved to the transfer station.
		compose.onNodeWithTag("boardingStation").assertIsDisplayed()
		compose.onNode(hasTestTag("boardingStation") and hasText("Boarding at 14 St-Union Sq")).assertExists()

		device.pressBack()
		compose.waitUntilAtLeastOneExists(hasTestTag("selectedStation") and hasText("6 Av / 14 St", substring = true), 5_000)
		val settings = saved()
		assertEquals(NerdsCodec.validate(settings), settings)
	}

	@Test fun theWayBackSurvivesRotationIntoTwoPanes() {
		openConnections()
		transfersNode("openTransferStationBoard").performClick()
		compose.waitUntilAtLeastOneExists(hasTestTag("selectedStation") and hasText("6 Av / 14 St", substring = true), 5_000)
		compose.activityRule.scenario.onActivity { it.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE }
		compose.waitForIdle()
		compose.onRoot().saveScreenshot("transfer-station-board-landscape")
		device.pressBack()
		compose.waitUntilAtLeastOneExists(hasTestTag("transfersScreen"), 10_000)
		compose.activityRule.scenario.onActivity { it.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT }
		compose.waitForIdle()
		compose.waitUntilAtLeastOneExists(hasTestTag("transfersScreen"), 10_000)
		compose.onRoot().saveScreenshot("transfer-after-rotation")
		device.pressBack()
		compose.waitUntilAtLeastOneExists(hasTestTag("boardingStation") and hasText("Boarding at 14 St-Union Sq"), 10_000)
		compose.activityRule.scenario.onActivity { it.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED }
	}
}
