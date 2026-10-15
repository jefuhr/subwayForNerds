package nyc.juliet.subwaysfornerds

import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Widget and shared links arrive from outside the app. Each one goes through `am start` and the real
 * manifest filters, so the strict parser and its percent decoding run on the device's API level.
 */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class ExternalLinkTest {
	@get:Rule(order = 0) val activities = LaunchedActivities()
	@get:Rule(order = 1) val compose = createEmptyComposeRule()
	@get:Rule(order = 2) val failures = FailureArtifacts(compose)
	private val rideLink = "subwaynerds://ride?key=gtfs-l%7C20260905%7C122300_L..N%7C"

	@Before fun setUp() {
		FixtureEnvironment.install()
		activities.launch()
		compose.waitForDepartures()
	}

	@Test fun aStationLinkOpensThatStation() {
		sendViewIntentFromShell("subwaynerds://board?station=610")
		compose.waitUntilAtLeastOneExists(hasText("Grand Central-42 St"), 10_000)
		compose.onRoot().saveScreenshot("link-station-grand-central")
	}

	@Test fun aRideLinkOpensTheTrainWithoutChangingStation() {
		sendViewIntentFromShell(rideLink)
		compose.waitUntilAtLeastOneExists(hasTestTag("saveTripOffline"), 10_000)
		compose.onRoot().saveScreenshot("link-ride-train-details")
		compose.onNodeWithTag("navigateBack").performClick()
		compose.waitUntilAtLeastOneExists(hasText("14 St-Union Sq"), 5_000)
	}

	@Test fun ambiguousLinksAreIgnored() {
		// Two stations in one link: neither is opened.
		sendViewIntentFromShell("subwaynerds://board?station=610&station=611")
		// A later valid link is handled, so the ambiguous one was already processed and dropped.
		sendViewIntentFromShell(rideLink)
		compose.waitUntilAtLeastOneExists(hasTestTag("saveTripOffline"), 10_000)
		compose.onNodeWithTag("navigateBack").performClick()
		compose.waitUntilAtLeastOneExists(hasText("14 St-Union Sq"), 5_000)
		compose.onRoot().saveScreenshot("link-ambiguous-ignored")
	}
}
