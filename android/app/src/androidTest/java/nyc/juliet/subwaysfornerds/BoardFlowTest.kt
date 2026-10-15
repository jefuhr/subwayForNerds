package nyc.juliet.subwaysfornerds

import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isEnabled
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performTextInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import nyc.juliet.subwaysfornerds.core.Settings
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.rules.TestRule
import org.junit.runner.Description
import org.junit.runner.RunWith
import org.junit.runners.model.Statement

/** Installs fixture dependencies before the activity rule launches MainActivity. */
class FixtureRule(private val settings: () -> Settings? = { null }, private val online: Boolean = true) : TestRule {
	override fun apply(base: Statement, description: Description): Statement = object : Statement() {
		override fun evaluate() { FixtureEnvironment.install(settings(), online = online); base.evaluate() }
	}
}

@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class BoardFlowTest {
	private val fixtures = FixtureRule()
	private val compose = createAndroidComposeRule<MainActivity>()
	@get:Rule val rules: RuleChain = RuleChain.outerRule(fixtures).around(compose).around(FailureArtifacts(compose))

	@Test fun recordedBoardShowsLiveGroupedDepartures() {
		compose.waitForDepartures()
		compose.onNodeWithText("14 St-Union Sq").assertIsDisplayed()
		compose.onNodeWithTag("boardFreshness").assertIsDisplayed()
		compose.onNodeWithTag("offlineReadiness").assertExists()
		compose.onRoot().saveScreenshot("board-live")
		compose.scrollToDeparture(FIRST_NORTH_L).assertIsDisplayed()
		compose.onRoot().saveScreenshot("board-live-l-train")
	}

	@Test fun directionAndViewChipsFilterTheBoard() {
		compose.waitForDepartures()
		assertTrue(compose.boardListHas(FIRST_NORTH_L))
		compose.boardNode("direction_SOUTH").performClick()
		compose.boardNode("direction_SOUTH").assertIsSelected()
		compose.waitForIdle()
		assertFalse("A northbound train must not survive the southbound filter", compose.boardListHas(FIRST_NORTH_L))
		compose.boardNode("boardView_direction").performClick()
		compose.boardNode("boardView_direction").assertIsSelected()
		compose.onRoot().saveScreenshot("board-southbound-direction-view")
		compose.boardNode("direction_ALL").performClick()
		compose.waitForIdle()
		assertTrue(compose.boardListHas(FIRST_NORTH_L))
	}

	@Test fun stationSearchStartsEmptyAndChoosesAStation() {
		compose.waitForDepartures()
		compose.onNodeWithTag("findStation").performClick()
		compose.onNodeWithTag("stationPicker").assertIsDisplayed()
		compose.onNodeWithText("Quick switch").assertExists()
		compose.onNodeWithTag("stationSearchField").performTextInput("Times Sq")
		compose.waitUntilAtLeastOneExists(hasTestTag("nearbyStationSummary"), 5_000)
		compose.onRoot().saveScreenshot("station-search")
		compose.onNodeWithTag("closeScreen").performClick()
		compose.onNodeWithTag("boardScreen").assertIsDisplayed()
	}

	@Test fun trainDetailsSaveOfflineAndFollowARide() {
		compose.waitForDepartures()
		compose.scrollToDeparture(FIRST_NORTH_L).performClick()
		compose.waitUntilAtLeastOneExists(hasTestTag("saveTripOffline"), 10_000)
		// The destination appears in the header and again as the last stop.
		assertTrue(compose.onAllNodesWithText("8 Av").fetchSemanticsNodes().isNotEmpty())
		compose.onRoot().saveScreenshot("train-details-live")
		compose.onNodeWithTag("saveTripOffline").performClick()
		compose.waitUntilAtLeastOneExists(hasTestTag("removeSavedTrip"), 10_000)
		// Saved state publishes before the final snapshot read finishes; the ride action stays
		// disabled until that save task finishes. Wait for actionable readiness, not only its label.
		compose.waitUntilAtLeastOneExists(hasTestTag("startRide") and isEnabled(), 10_000)
		compose.onNodeWithTag("startRide").assertIsEnabled()
		compose.onNodeWithTag("startRide").performClick()
		compose.waitUntilAtLeastOneExists(hasTestTag("endRide"), 10_000)
		compose.onNodeWithTag("navigateBack").performClick()
		compose.waitUntilAtLeastOneExists(hasTestTag("activeRideBanner"), 10_000)
		compose.onNodeWithTag("savedTrips").assertExists()
		compose.onRoot().saveScreenshot("board-with-ride")
	}

	@Test fun favoritesBecomeSwipeableStationPages() {
		compose.waitForDepartures()
		compose.onNodeWithTag("toggleFavorite").performClick()
		compose.onNodeWithTag("findStation").performClick()
		compose.onNodeWithTag("stationSearchField").performTextInput("Grand Central")
		compose.waitUntilAtLeastOneExists(hasContentDescription("Favorite Grand Central-42 St"), 5_000)
		compose.onNode(hasContentDescription("Favorite Grand Central-42 St")).performClick()
		compose.onNodeWithTag("closeScreen").performClick()
		compose.waitUntilAtLeastOneExists(hasTestTag("stationPager"), 5_000)
		compose.onNodeWithTag("nextStation").performClick()
		// The recorded fixture has no board for the second station, so the app says so honestly.
		compose.waitUntilAtLeastOneExists(hasTestTag("boardError"), 10_000)
		compose.onRoot().saveScreenshot("station-pager-unavailable-board")
		assertTrue(FixtureEnvironment.transit.requests.any { it.startsWith("board:") && it != "board:$FIXTURE_STATION" })
	}
}
