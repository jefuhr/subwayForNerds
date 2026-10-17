package nyc.juliet.subwaysfornerds

import android.graphics.Bitmap
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import java.util.regex.Pattern
import nyc.juliet.subwaysfornerds.core.TrackMapCamera
import nyc.juliet.subwaysfornerds.core.Settings
import nyc.juliet.subwaysfornerds.core.TrackMapSlowZoneDisplay
import nyc.juliet.subwaysfornerds.ui.map.TrackMapSlowZoneCountKey
import nyc.juliet.subwaysfornerds.ui.map.TrackMapViewportKey
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.runner.RunWith

/** Recorded HTTP acceptance on a coordinator-leased AVD; no production or fixture listener fallback. */
@RunWith(AndroidJUnit4::class)
class TrackMapSlowZoneFlowTest {
	private val network = NativeNetworkAcceptanceRule()
	private val compose = createEmptyComposeRule()
	@get:Rule val rules: RuleChain = RuleChain.outerRule(network).around(compose)

	@Test fun highlightsHaveAccessibleEstimatedDetailsAndFollowRoutesWithoutMovingMap() {
		val server = network.requireRecordedServer()
		network.persist(Settings(theme = "hacker"), server.station)
		network.installApp()
		val scenario = ActivityScenario.launch(MainActivity::class.java)
		try {
			compose.waitUntil(30_000) { exists("tab_map") }
			node("tab_map").performClick()
			compose.waitUntil(45_000) { exists("track-map-canvas") && exists("track-map-slow-zones") }
			compose.waitUntil(35_000) { count() > 0 }
			scenario.onActivity { activity ->
				val map = network.model(activity).trackMap
				val path = map.slowZones(map.clock()).first { it.paths.isNotEmpty() }.paths.first()
				map.camera = TrackMapCamera.centered(path[path.size / 2], TrackMapCamera.DETAIL_SCALE, checkNotNull(map.topology).page)
			}
			compose.waitForIdle()
			val visible = visibleBitmap("before filtering")
			assertSearchChromeVisible(visible)
			val highlightedPixels = amberPixels(canvasBitmap(visible))
			assertTrue("Expected visible amber pixels on reviewed rail", highlightedPixels > 10)
			val viewport = node("track-map-canvas").fetchSemanticsNode().config[TrackMapViewportKey]
			shot("slow-zone-map-amber-highlights")
			node("track-map-slow-zones").performClick()
			compose.waitUntil(5_000) { exists("track-map-slow-zone-list") }
			var firstID = ""
			var detail = ""
			scenario.onActivity { activity ->
				val map = network.model(activity).trackMap
				val zone = map.slowZones(map.clock()).first()
				firstID = zone.id
				detail = TrackMapSlowZoneDisplay.detail(zone)
			}
			node("track-map-slow-zone-list").performScrollToNode(hasTestTag("track-map-slow-zone-$firstID"))
			val spoken = node("track-map-slow-zone-$firstID").fetchSemanticsNode().config[SemanticsProperties.ContentDescription]
			assertTrue(spoken.toString(), spoken.contains(detail))
			assertTrue(detail.contains("Estimated") && detail.contains("typically +") && detail.contains("Transit Lab"))
			shot("slow-zone-map-accessible-details")
			node("track-map-slow-zone-close").performClick()
			scenario.onActivity { activity -> network.model(activity).trackMap.toggleRoute("__no_matching_route__") }
			compose.waitUntil(5_000) { count() == 0 }
			val filteredPixels = amberPixels(canvasBitmap(visibleBitmap("after filtering")))
			assertTrue("Filtering should remove visible amber overlay pixels: $highlightedPixels -> $filteredPixels", filteredPixels < highlightedPixels)
			assertEquals(viewport, node("track-map-canvas").fetchSemanticsNode().config[TrackMapViewportKey])
			scenario.onActivity { activity -> network.model(activity).trackMap.clearRoutes() }
			compose.waitUntil(5_000) { count() > 0 }
			assertEquals(viewport, node("track-map-canvas").fetchSemanticsNode().config[TrackMapViewportKey])
			assertTrue("Requests escaped fixture origin: ${network.gate.foreign}", network.gate.foreign.isEmpty())
		} finally {
			network.screenshot("slow-zone-map-final")
			scenario.close()
		}
	}

	private fun assertUnobstructed(name: String) {
		val obstruction = By.text(Pattern.compile(".*(isn't responding|is not responding|keeps stopping|has stopped).*", Pattern.CASE_INSENSITIVE))
		assertFalse("System ANR/crash dialog obscures acceptance screenshot $name", UiDevice.getInstance(network.instrumentation).hasObject(obstruction))
	}

	private fun shot(name: String) {
		assertUnobstructed(name)
		assertNotNull(network.screenshot(name))
	}

	private fun visibleBitmap(name: String): Bitmap {
		assertUnobstructed(name)
		network.instrumentation.waitForIdleSync()
		return checkNotNull(network.instrumentation.uiAutomation.takeScreenshot()) { "Visible screenshot unavailable: $name" }
	}

	/** In the seeded dark theme, the PDF must not paint over the native station-search field. */
	private fun assertSearchChromeVisible(bitmap: Bitmap) {
		val bounds = node("track-map-search").fetchSemanticsNode().boundsInWindow
		var dark = 0
		var total = 0
		for (y in bounds.top.toInt().coerceAtLeast(0) until bounds.bottom.toInt().coerceAtMost(bitmap.height) step 4) {
			for (x in bounds.left.toInt().coerceAtLeast(0) until bounds.right.toInt().coerceAtMost(bitmap.width) step 4) {
				if (android.graphics.Color.luminance(bitmap.getPixel(x, y)) < 0.5f) dark += 1
				total += 1
			}
		}
		assertTrue("Map artwork obscures native station-search controls: $dark/$total dark pixels at $bounds", total > 0 && dark > total * 0.7)
	}

	private fun canvasBitmap(bitmap: Bitmap): Bitmap {
		val bounds = node("track-map-canvas").fetchSemanticsNode().boundsInWindow
		val left = bounds.left.toInt().coerceIn(0, bitmap.width)
		val top = bounds.top.toInt().coerceIn(0, bitmap.height)
		val right = bounds.right.toInt().coerceIn(left, bitmap.width)
		val bottom = bounds.bottom.toInt().coerceIn(top, bitmap.height)
		check(right > left && bottom > top) { "Map canvas has no visible screen bounds: $bounds" }
		return Bitmap.createBitmap(bitmap, left, top, right - left, bottom - top)
	}

	private fun amberPixels(bitmap: Bitmap): Int {
		var count = 0
		for (y in 0 until bitmap.height) for (x in 0 until bitmap.width) {
			val color = bitmap.getPixel(x, y)
			if (android.graphics.Color.red(color) > 240 && android.graphics.Color.green(color) in 135..170 && android.graphics.Color.blue(color) < 30) count += 1
		}
		return count
	}

	private fun node(tag: String) = compose.onAllNodesWithTag(tag).onFirst()
	private fun exists(tag: String) = compose.onAllNodesWithTag(tag).fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty()
	private fun count(): Int = node("track-map-canvas").fetchSemanticsNode().config.getOrNull(TrackMapSlowZoneCountKey) ?: 0
}
