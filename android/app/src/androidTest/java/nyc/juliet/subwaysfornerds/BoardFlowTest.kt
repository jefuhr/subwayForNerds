package nyc.juliet.subwaysfornerds

import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertContentDescriptionEquals
import androidx.compose.ui.test.assertHasClickAction
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isEnabled
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performTextInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import nyc.juliet.subwaysfornerds.core.Settings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.ExternalResource
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
		compose.onRoot().saveScreenshot("board-live")
		compose.scrollToDeparture(FIRST_NORTH_L).assertIsDisplayed()
		compose.onRoot().saveScreenshot("board-live-l-train")
	}

	@Test fun headerKeepsTheNameInfoAlertsAndStarOnly() {
		compose.waitForDepartures()
		val alertCount = FixtureEnvironment.recordedBoard().alerts.size
		assertTrue("The recorded board needs alerts to prove the count badge", alertCount > 0)
		compose.onNodeWithTag("selectedStation").assertIsDisplayed()
		compose.onNodeWithTag("stationInfo").assertIsDisplayed().assertHasClickAction().assertContentDescriptionEquals("Station info").assertTouchTarget()
		compose.onNodeWithTag("stationAlerts").assertIsDisplayed().assertHasClickAction().assertContentDescriptionEquals("Alerts, $alertCount").assertTouchTarget()
		// The badge is visual only; the button's label already speaks the number.
		compose.onNodeWithTag("stationAlertsCount", useUnmergedTree = true).assertExists()
		compose.onNodeWithTag("toggleFavorite").assertIsDisplayed().assertTouchTarget()
		// Left to right: the station name, then info, alerts and the star.
		val name = compose.onNodeWithTag("selectedStation").fetchSemanticsNode().boundsInRoot
		val info = compose.onNodeWithTag("stationInfo").fetchSemanticsNode().boundsInRoot
		val alerts = compose.onNodeWithTag("stationAlerts").fetchSemanticsNode().boundsInRoot
		val star = compose.onNodeWithTag("toggleFavorite").fetchSemanticsNode().boundsInRoot
		assertTrue("Order should be name, info, alerts, star: $name $info $alerts $star", name.right <= info.left + 1f && info.right <= alerts.left + 1f && alerts.right <= star.left + 1f)
		assertTrue("The icon buttons sit on the name's row: $name $info", kotlin.math.abs(name.center.y - info.center.y) < 24f)
		// The metadata line, freshness label, readiness icon and chips are gone.
		for (tag in listOf("boardFreshness", "offlineReadiness", "savedTrips")) assertTrue("$tag should be gone", compose.onAllNodesWithTag(tag, useUnmergedTree = true).fetchSemanticsNodes().isEmpty())
		assertTrue("No favorite station chips", compose.onAllNodes(tagPrefix("favoriteStation_"), useUnmergedTree = true).fetchSemanticsNodes().isEmpty())
		for (text in listOf("Live feed", "Partial live data", "Saved board", "Station 602", "Saved trains")) {
			assertTrue("'$text' should not be on the board header", compose.onAllNodes(hasText(text, substring = true)).fetchSemanticsNodes().isEmpty())
		}
		assertTrue("The Station info and Alerts chips are icons now", compose.onAllNodes(hasText("Station info") or hasText("Alerts ($alertCount)")).fetchSemanticsNodes().isEmpty())
		compose.onRoot().saveScreenshot("board-header-icons")
		compose.onNodeWithTag("stationAlerts").performClick()
		compose.waitUntilAtLeastOneExists(hasTestTag("alertsScreen"), 5_000)
		compose.onNodeWithTag("closeScreen").performClick()
		compose.onNodeWithTag("stationInfo").performClick()
		compose.waitUntilAtLeastOneExists(hasTestTag("stationContext"), 5_000)
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
		startRideFromTheBoard()
		// Saved trains live in Settings now, not on the board header.
		compose.onNodeWithTag("savedTrips").assertDoesNotExist()
		compose.onRoot().saveScreenshot("board-with-ride")
	}

	@Test fun theRideBannerOpensDetailsAndItsXEndsTheRideAfterConfirming() {
		startRideFromTheBoard()
		assertTrue("The Ride details and End ride chips are gone", compose.onAllNodes(hasText("Ride details") or hasText("End ride")).fetchSemanticsNodes().isEmpty())
		compose.onNodeWithTag("openRide").assertHasClickAction().assert(SemanticsMatcher.expectValue(SemanticsProperties.Role, Role.Button))
		compose.onNodeWithTag("endRideFromBanner").assertHasClickAction().assertContentDescriptionEquals("End ride").assertTouchTarget()
		assertTrue("The ride banner no longer says the next stop is unobserved", allTexts(compose.onNodeWithTag("activeRideBanner").fetchSemanticsNode()).none { it.contains("next stop not observed") })
		compose.onRoot().saveScreenshot("board-ride-banner")

		// Anywhere else on the banner opens the ride's details.
		compose.onNodeWithTag("openRide").performClick()
		compose.waitUntilAtLeastOneExists(hasTestTag("endRide"), 10_000)
		compose.onNodeWithTag("navigateBack").performClick()
		compose.waitUntilAtLeastOneExists(hasTestTag("activeRideBanner"), 10_000)

		// The X asks first and must not also open the details.
		compose.onNodeWithTag("endRideFromBanner").performClick()
		compose.waitUntilAtLeastOneExists(hasText("End this ride?"), 5_000)
		assertTrue("The X must not trigger the banner tap", compose.onAllNodesWithTag("trainDetails").fetchSemanticsNodes().isEmpty())
		compose.onRoot().saveScreenshot("board-end-ride-confirmation")
		compose.onNodeWithText("Cancel").performClick()
		compose.onNodeWithTag("activeRideBanner").assertExists()

		compose.onNodeWithTag("endRideFromBanner").performClick()
		compose.onNodeWithTag("confirmEndRide").performClick()
		compose.waitUntil(10_000) { compose.onAllNodesWithTag("activeRideBanner").fetchSemanticsNodes().isEmpty() }
	}

	/** Saves the first northbound L train offline, rides it and returns to the board with its banner. */
	private fun startRideFromTheBoard() {
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
		// Other favorites are reached from the station picker or by swiping, not from chips in the header.
		assertTrue(compose.onAllNodes(tagPrefix("favoriteStation_"), useUnmergedTree = true).fetchSemanticsNodes().isEmpty())
		compose.onNodeWithTag("nextStation").performClick()
		// The recorded fixture has no board for the second station, so the app says so honestly.
		compose.waitUntilAtLeastOneExists(hasTestTag("boardError"), 10_000)
		compose.onRoot().saveScreenshot("station-pager-unavailable-board")
		assertTrue(FixtureEnvironment.transit.requests.any { it.startsWith("board:") && it != "board:$FIXTURE_STATION" })
	}
}

/** Puts the recorded board in the offline store before the activity starts, as an earlier visit would have. */
class SavedBoardRule : ExternalResource() {
	override fun before() {
		val context = InstrumentationRegistry.getInstrumentation().targetContext
		runBlocking { FixtureEnvironment.cache(context).saveBoardMerged(FixtureEnvironment.recordedBoard()) }
	}
}

@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class SavedBoardTest {
	private val compose = createAndroidComposeRule<MainActivity>()
	@get:Rule val rules: RuleChain = RuleChain.outerRule(FixtureRule(online = false)).around(SavedBoardRule()).around(compose).around(FailureArtifacts(compose))

	@Test fun aSavedBoardShowsOnlyTheOfflineEstimateCardAndItOpensSystemStatus() {
		compose.waitForDepartures()
		compose.waitUntilAtLeastOneExists(hasTestTag("boardOfflineEstimate"), 15_000)
		compose.waitForIdle()
		// The estimate line and the network headline stay; the grey detail and every notice go.
		compose.onNodeWithTag("boardOfflineEstimate", useUnmergedTree = true).assertIsDisplayed()
		compose.onNodeWithTag("deviceNetworkStatus", useUnmergedTree = true).assertIsDisplayed()
		val network = allTexts(compose.onNodeWithTag("deviceNetworkStatus", useUnmergedTree = true).fetchSemanticsNode())
		assertEquals("Only the bold network headline remains in the card: $network", 1, network.size)
		assertTrue("deviceNetworkDetail should not be on the board", compose.onAllNodesWithTag("deviceNetworkDetail", useUnmergedTree = true).fetchSemanticsNodes().isEmpty())
		assertTrue("A saved board has no board error", compose.onAllNodesWithTag("boardError", useUnmergedTree = true).fetchSemanticsNodes().isEmpty())
		for (text in listOf("Showing a saved board", "Some feeds are stale", "Board saved ", "Countdowns use this device's clock")) {
			assertTrue("'$text' should not be shown on a saved board", compose.onAllNodes(hasText(text, substring = true)).fetchSemanticsNodes().isEmpty())
		}
		// The old header freshness label is gone; the card is the only place that says the board is saved.
		assertTrue(compose.onAllNodesWithTag("boardFreshness", useUnmergedTree = true).fetchSemanticsNodes().isEmpty())
		compose.onRoot().saveScreenshot("board-saved-offline")

		compose.onNodeWithTag("boardOfflineCard").assertHasClickAction().assert(SemanticsMatcher.expectValue(SemanticsProperties.Role, Role.Button))
		compose.onNodeWithTag("boardOfflineCard").performClick()
		compose.waitUntilAtLeastOneExists(hasTestTag("systemStatusScreen"), 10_000)
		compose.onNodeWithTag("tab_settings").assertIsSelected()
		compose.onRoot().saveScreenshot("board-offline-card-system-status")
		// Back returns to Settings, not the board.
		compose.onNodeWithTag("navigateBack").performClick()
		compose.waitUntilAtLeastOneExists(hasTestTag("settingsScreen"), 5_000)
		compose.onNodeWithTag("tab_settings").assertIsSelected()
	}
}

private fun tagPrefix(prefix: String) = SemanticsMatcher("test tag starts with $prefix") { it.config.getOrNull(SemanticsProperties.TestTag)?.startsWith(prefix) == true }

private fun allTexts(node: SemanticsNode): List<String> = node.config.getOrNull(SemanticsProperties.Text).orEmpty().map { it.text } + node.children.flatMap { allTexts(it) }

/** Icon-only buttons need a 48dp touch target. Compose lays the control out at 40dp and extends its touch bounds to the minimum. */
private fun SemanticsNodeInteraction.assertTouchTarget(): SemanticsNodeInteraction {
	val density = InstrumentationRegistry.getInstrumentation().targetContext.resources.displayMetrics.density
	val bounds = fetchSemanticsNode().touchBoundsInRoot
	assertTrue("Touch target is ${bounds.width / density} x ${bounds.height / density} dp, expected at least 48 x 48", bounds.width >= 47.5f * density && bounds.height >= 47.5f * density)
	return this
}
