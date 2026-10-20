package nyc.juliet.subwaysfornerds

import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import nyc.juliet.subwaysfornerds.core.Departure
import nyc.juliet.subwaysfornerds.core.DepartureRowSettings
import nyc.juliet.subwaysfornerds.core.OfflineSettings
import nyc.juliet.subwaysfornerds.core.TrainFavorites
import nyc.juliet.subwaysfornerds.core.VehiclePosition
import nyc.juliet.subwaysfornerds.ui.board.DepartureRow
import nyc.juliet.subwaysfornerds.ui.theme.AppTheme
import nyc.juliet.subwaysfornerds.ui.theme.SubwaysTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

private fun tagPrefix(prefix: String) = SemanticsMatcher("test tag starts with $prefix") { it.config.getOrNull(SemanticsProperties.TestTag)?.startsWith(prefix) == true }

/**
 * Where the headway gap lands under the default settings. Only rows that combine position move it to the
 * countdown column; NJT and GPS vehicle-position rows keep today's gap on the right of the stops line.
 */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class DepartureRowGapPlacementTest {
	@get:Rule(order = 0) val compose = createComposeRule()
	@get:Rule(order = 1) val failures = FailureArtifacts(compose)
	private val now = 1_800_000_000.0

	private fun row(key: String, time: Double, feed: String, position: VehiclePosition? = null) = Departure(
		key = key, tripKey = "trip-$key", route = if (feed.startsWith("njt-")) "NJT-HBLR" else "L", destination = "Destination", direction = "NORTH",
		stopId = "stop", partId = "part", area = "Platform", time = time, arrival = time, pattern = "Local", patternSource = "reported",
		location = if (feed.startsWith("njt-")) "" else "At Bedford Av", stopsAway = 2, feed = feed, timestamp = now - 10,
		locationTimestamp = now - 25, scheduledTrack = "1", vehiclePosition = position,
	)

	private fun show(departure: Departure, previous: Departure, settings: DepartureRowSettings = DepartureRowSettings()) {
		compose.setContent {
			SubwaysTheme(AppTheme.forId("subway")) {
				DepartureRow(departure, now, false, previous, false, OfflineSettings(), "12h", TrainFavorites(), settings)
			}
		}
	}

	private fun gapTags() = compose.onAllNodes(tagPrefix("departureGap_"), useUnmergedTree = true).fetchSemanticsNodes().size
	private fun positionTags() = compose.onAllNodes(tagPrefix("departurePosition_"), useUnmergedTree = true).fetchSemanticsNodes().size
	private fun shows(text: String) = compose.onAllNodes(hasText(text, substring = true), useUnmergedTree = true).fetchSemanticsNodes().isNotEmpty()

	@Test fun njtRowsKeepTheGapOnTheStopsLine() {
		show(row("b", now + 600, "njt-hblr"), row("a", now + 300, "njt-hblr"))
		assertEquals("No countdown-column gap on an NJT row", 0, gapTags())
		assertEquals("NJT rows never get the combined line", 0, positionTags())
		assertEquals(true, shows("+5m after previous"))
		assertEquals(false, shows("+5m gap"))
	}

	@Test fun vehiclePositionRowsKeepTheGapOnTheStopsLine() {
		val gps = VehiclePosition("v", "njt", "v1", "L", lat = 40.7, lon = -74.0, stopName = "Bedford Av", timestamp = now - 10, fetchedAt = now - 5)
		show(row("b", now + 600, "gtfs-l", gps), row("a", now + 300, "gtfs-l"))
		assertEquals(0, gapTags())
		assertEquals(0, positionTags())
		assertEquals(true, shows("+5m after previous"))
		assertEquals(true, shows("2 stops away"))
	}

	@Test fun scheduleFeedRowsMoveTheGapToTheCountdownColumn() {
		show(row("b", now + 600, "gtfs-l"), row("a", now + 300, "gtfs-l"))
		assertEquals(1, gapTags())
		assertEquals(1, positionTags())
		assertEquals(true, shows("+5m gap"))
		assertEquals(false, shows("after previous"))
		compose.onAllNodes(hasContentDescription("5 minutes after previous train"), useUnmergedTree = true).assertCountEquals(1)
	}

	@Test fun splitModeKeepsTheGapOnTheStopsLineForEveryRow() {
		show(row("b", now + 600, "gtfs-l"), row("a", now + 300, "gtfs-l"), DepartureRowSettings(combinePosition = false))
		assertEquals(0, gapTags())
		assertEquals(0, positionTags())
		assertEquals(true, shows("+5m after previous"))
	}
}
