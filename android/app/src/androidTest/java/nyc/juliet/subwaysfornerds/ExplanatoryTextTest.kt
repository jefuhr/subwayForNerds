package nyc.juliet.subwaysfornerds

import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.hasScrollToNodeAction
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeUp
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.runner.RunWith

/**
 * The app-wide subtext cut: screens keep their data rows, ages, counts and notices, and drop the grey footers
 * and captions that only explain how something works. Each test scrolls a whole list, because footers are
 * separate lazy rows that exist only near the viewport.
 */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class ExplanatoryTextTest {
	private val compose = createAndroidComposeRule<MainActivity>()
	@get:Rule val rules: RuleChain = RuleChain.outerRule(FixtureRule()).around(compose).around(FailureArtifacts(compose))

	private val anyConnection = SemanticsMatcher("is a connection row") { it.config.getOrNull(SemanticsProperties.TestTag)?.startsWith("connection_") == true }

	@Test fun boardAndTrainDetailsKeepOnlyData() {
		compose.waitForDepartures()
		assertNoneWhileScrolling("boardList", BOARD_PROSE)
		compose.onRoot().saveScreenshot("board-without-footers")
		compose.scrollToDeparture(FIRST_NORTH_L).performClick()
		compose.waitUntilAtLeastOneExists(hasTestTag("boardingStation"), 10_000)
		assertNoneWhileScrolling("trainDetails", TRAIN_PROSE)
	}

	@Test fun connectionsKeepTheWindowAndDropTheDisclaimer() {
		compose.waitForDepartures()
		compose.scrollToDeparture(FIRST_NORTH_L).performClick()
		compose.waitUntilAtLeastOneExists(hasTestTag("boardingStation"), 10_000)
		compose.onNode(hasTestTag("trainDetails") and hasScrollToNodeAction()).performScrollToNode(hasTestTag("stop_L02N"))
		compose.onNodeWithTag("stop_L02N").performClick()
		compose.waitUntilAtLeastOneExists(anyConnection, 15_000)
		assertNoneWhileScrolling("transfersScreen", TRANSFER_PROSE)
		// "Next 30 minutes" is the window the rows cover, so it stays.
		compose.onNode(hasTestTag("transfersScreen") and hasScrollToNodeAction()).performScrollToNode(hasText("Next 30 minutes"))
		compose.onRoot().saveScreenshot("transfers-without-footers")
	}

	@Test fun linesAndFleetKeepOnlyData() {
		compose.waitUntilAtLeastOneExists(hasTestTag("boardScreen"), 10_000)
		compose.onNodeWithTag("tab_settings").performClick()
		compose.onNodeWithTag("settingsScreen").performScrollToNode(hasTestTag("lineVisibilitySettings"))
		compose.onNodeWithTag("lineVisibilitySettings").performClick()
		compose.waitUntilAtLeastOneExists(hasTestTag("linesScreen"), 5_000)
		assertNoneWhileScrolling("linesScreen", listOf("Applies to stations, departures, connections, alerts, and station widgets"))
		compose.onNodeWithTag("closeScreen").performClick()
		compose.onNodeWithTag("tab_fleet").performClick()
		compose.waitUntilAtLeastOneExists(hasTestTag("fleetBrowser"), 10_000)
		compose.waitUntilAtLeastOneExists(SemanticsMatcher("is a fleet row") { it.config.getOrNull(SemanticsProperties.TestTag)?.startsWith("fleet_") == true }, 15_000)
		assertNoneWhileScrolling("fleetBrowser", listOf("Missing from a feed does not mean inactive."))
		compose.onRoot().saveScreenshot("fleet-without-footers")
	}

	/** Swipes a list from its top to well past its end, checking that none of the phrases is ever composed. */
	private fun assertNoneWhileScrolling(listTag: String, phrases: List<String>) {
		val list = compose.onNode(hasTestTag(listTag) and hasScrollToNodeAction())
		repeat(14) {
			for (phrase in phrases) assertTrue("'$phrase' should be gone from $listTag", compose.onAllNodes(hasText(phrase, substring = true)).fetchSemanticsNodes().isEmpty())
			list.performTouchInput { swipeUp() }
			compose.waitForIdle()
		}
	}

	private companion object {
		val BOARD_PROSE = listOf("Times are predictions, not promises", "Track labels are feed-reported", "An empty board does not mean service is suspended", "Some lines are hidden in settings")
		val TRAIN_PROSE = listOf(
			"Compared with weekday daytime service", "Offline estimates count down the saved predictions", "Arrival / departure · Eastern", "Future track fields describe that stop",
			"Tap a car for its fleet history", "Reported order does not confirm the front of the train",
			"Static context only; live predictions take precedence.", "Car numbers and the train's current position are not shown offline.",
			"Estimated next stop · not observed",
		)
		val TRANSFER_PROSE = listOf("raw time gaps, no walking allowance", "Connections are not guaranteed", "Filters saved for transfers at this station only", "Filters shared with this station's board")
	}
}
