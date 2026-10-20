package nyc.juliet.subwaysfornerds

import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsOff
import androidx.compose.ui.test.assertIsOn
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.test.ext.junit.runners.AndroidJUnit4
import nyc.juliet.subwaysfornerds.core.DepartureRowSettings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.runner.RunWith

/** The recorded first northbound L train's key, without the row's `departure_` tag prefix. */
private const val FIRST_NORTH_L_KEY = "gtfs-l|20260905|122300_L..N||L03N|0"
private const val FIRST_NORTH_L_POSITION = "At 14 St-Union Sq · 0 stops away · 33s ago"

private fun tagPrefix(prefix: String) = SemanticsMatcher("test tag starts with $prefix") { it.config.getOrNull(SemanticsProperties.TestTag)?.startsWith(prefix) == true }
private fun SemanticsNodeInteraction.text(): String = fetchSemanticsNode().config.getOrNull(SemanticsProperties.Text).orEmpty().joinToString(" ") { it.text }

@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class DepartureRowSettingsFlowTest {
	private val compose = createAndroidComposeRule<MainActivity>()
	@get:Rule val rules: RuleChain = RuleChain.outerRule(FixtureRule()).around(compose).around(FailureArtifacts(compose))

	private fun groupHeaders(): List<String> =
		compose.onAllNodes(tagPrefix("departureGroup_")).fetchSemanticsNodes().map { node -> node.config.getOrNull(SemanticsProperties.Text).orEmpty().joinToString(" ") { it.text } }
	private fun gapCount() = compose.onAllNodes(tagPrefix("departureGap_"), useUnmergedTree = true).fetchSemanticsNodes().size
	private fun position(): SemanticsNodeInteraction = compose.onNodeWithTag("departurePosition_$FIRST_NORTH_L_KEY", useUnmergedTree = true)

	/** Whether any text inside the first northbound L row contains [text]; the row's own semantics merge, so read the unmerged tree. */
	private fun rowHasText(text: String): Boolean =
		compose.onAllNodes(hasText(text, substring = true) and hasAnyAncestor(hasTestTag(FIRST_NORTH_L)), useUnmergedTree = true).fetchSemanticsNodes().isNotEmpty()

	private fun toggle(tag: String) {
		compose.onNodeWithTag("tab_settings").performClick()
		compose.onNodeWithTag("settingsScreen").performScrollToNode(hasTestTag(tag))
		compose.onNodeWithTag(tag).performClick()
		compose.onNodeWithTag("tab_board").performClick()
		compose.waitForDepartures()
	}

	@Test fun defaultRowsShowOneCombinedPositionLineAndNoProvenance() {
		compose.waitForDepartures()
		compose.scrollToDeparture(FIRST_NORTH_L).assertIsDisplayed()
		assertEquals(FIRST_NORTH_L_POSITION, position().text())
		// Today's second line, "0 stops away · 33s ago", is now part of the one combined line.
		assertTrue(groupHeaders().isNotEmpty())
		assertTrue("Group headers drop provenance by default: ${groupHeaders()}", groupHeaders().none { it.contains("reported") || it.contains("scheduled") })
		assertTrue("Headway moves to the countdown column", gapCount() > 0)
		compose.onRoot().saveScreenshot("departure-rows-default")
	}

	@Test fun settingsGroupHasFourDirectSwitchesWithTheContractDefaults() {
		compose.waitForDepartures()
		compose.onNodeWithTag("tab_settings").performClick()
		compose.onNodeWithTag("settingsScreen").performScrollToNode(hasTestTag("departureRowsTrackSource"))
		compose.onNodeWithTag("departureRowsTrackSource").assertIsOff()
		compose.onNodeWithTag("departureRowsCombinePosition").assertIsOn()
		compose.onNodeWithTag("departureRowsCarNumbers").assertIsOn()
		compose.onNodeWithTag("departureRowsGap").assertIsOn()
		compose.onNodeWithTag("departureRowsGap").assertIsDisplayed()
		compose.onRoot().saveScreenshot("departure-rows-settings")
	}

	@Test fun switchesChangeTheRowsAndPersistToSettings() {
		compose.waitForDepartures()
		compose.scrollToDeparture(FIRST_NORTH_L)
		assertTrue(rowHasText("R211A"))

		toggle("departureRowsTrackSource")
		assertTrue("Provenance on: ${groupHeaders()}", groupHeaders().any { it.contains("reported") || it.contains("scheduled") })
		compose.onRoot().saveScreenshot("departure-rows-provenance")

		toggle("departureRowsCarNumbers")
		compose.scrollToDeparture(FIRST_NORTH_L)
		assertFalse("Car numbers hidden", rowHasText("R211A"))
		compose.onRoot().saveScreenshot("departure-rows-no-car-numbers")

		toggle("departureRowsGap")
		assertEquals("Headway hidden everywhere", 0, gapCount())
		toggle("departureRowsGap")
		assertTrue(gapCount() > 0)

		// Split mode restores today's two lines, with the gap back on the stops line.
		toggle("departureRowsCombinePosition")
		compose.scrollToDeparture(FIRST_NORTH_L)
		assertTrue("Split mode has no combined line", compose.onAllNodes(tagPrefix("departurePosition_"), useUnmergedTree = true).fetchSemanticsNodes().isEmpty())
		assertEquals(0, gapCount())
		assertTrue(rowHasText("0 stops away · 33s ago"))
		assertTrue(rowHasText("At 14 St-Union Sq"))
		assertFalse(rowHasText("At 14 St-Union Sq · 0 stops away"))
		compose.onRoot().saveScreenshot("departure-rows-split")

		compose.waitUntil(5_000) {
			kotlinx.coroutines.runBlocking { nyc.juliet.subwaysfornerds.data.AndroidSettingsStore(compose.activity).load().departureRows } == DepartureRowSettings(true, false, false, true)
		}
	}
}
