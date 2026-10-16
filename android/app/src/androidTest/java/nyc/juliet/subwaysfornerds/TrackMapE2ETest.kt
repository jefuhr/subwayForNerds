package nyc.juliet.subwaysfornerds

import android.content.pm.ActivityInfo
import android.os.SystemClock
import android.graphics.pdf.PdfDocument
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.hasScrollToIndexAction
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onFirst
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.doubleClick
import androidx.compose.ui.test.swipe
import androidx.compose.ui.test.click
import androidx.lifecycle.Lifecycle
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.uiautomator.UiDevice
import nyc.juliet.subwaysfornerds.core.Settings
import nyc.juliet.subwaysfornerds.core.TrackMapCamera
import nyc.juliet.subwaysfornerds.core.TrackMapPage
import nyc.juliet.subwaysfornerds.core.TrackMapViewportSummary
import nyc.juliet.subwaysfornerds.ui.map.TrackMapViewportKey
import nyc.juliet.subwaysfornerds.ui.map.TrackMapCanvas
import nyc.juliet.subwaysfornerds.ui.map.TrackMapModel
import nyc.juliet.subwaysfornerds.ui.map.TrackMapRenderer
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.rules.TestName
import org.junit.runner.RunWith
import java.io.File
import kotlin.math.abs
import kotlin.math.hypot

/**
 * Production native map and recorded HTTP on the explicitly leased dedicated AVD only.
 * The existing network rule owns app isolation, allowlisting and evidence. The test-only
 * fixture control changes snapshot availability, never device networking or other endpoints.
 * Exact 90/300-second semantics belong to the core suites; these tests exercise rider workflows.
 * Screenshots require visual review for artwork/rail alignment and do not prove full-network,
 * live-production, TalkBack or physical-device acceptance.
 */
@RunWith(AndroidJUnit4::class)
class TrackMapE2ETest {
	private val network = NativeNetworkAcceptanceRule()
	private val caseName = TestName()
	private val compose = createEmptyComposeRule()
	@get:Rule val rules: RuleChain = RuleChain.outerRule(network).around(caseName).around(compose)

	@Test
	fun stationSearchGesturesFitAndViewportSurviveTabsRotationAndStationBoard() = withMap { scenario ->
		node("track-map-fit").performClick()
		val fitted = viewport()
		assertEquals(3672, fitted.centerX)
		assertTrue(abs(fitted.centerY - 5770) <= 1)
		search("Union Sq")
		await("the recorded Union Sq search result") { exists("track-map-result-602") }
		node("track-map-result-602").performClick()
		await("search focus") { viewport() != fitted }
		val focused = viewport()
		node(CANVAS).performTouchInput { doubleClick(center) }
		await("double-tap zoom") { viewport().zoomPercent > focused.zoomPercent }
		val zoomed = viewport()
		node(CANVAS).performTouchInput { swipe(center, center + Offset(70f, 45f), 500) }
		await("pan") { viewport() != zoomed }
		val panned = viewport()
		shot("01-search-zoom-pan")
		node("tab_board").performClick()
		node("tab_map").performClick()
		await("map return") { exists(CANVAS) }
		assertViewport(panned, viewport(), "tab return")

		scenario.onActivity { it.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE }
		await("landscape") { network.context.resources.configuration.orientation == android.content.res.Configuration.ORIENTATION_LANDSCAPE }
		await("landscape canvas") { exists(CANVAS) }
		assertViewport(panned, viewport(), "landscape")
		shot("02-landscape")
		scenario.onActivity { it.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT }
		await("portrait") { network.context.resources.configuration.orientation == android.content.res.Configuration.ORIENTATION_PORTRAIT }
		await("portrait canvas") { exists(CANVAS) }
		assertViewport(panned, viewport(), "portrait")

		search("Union Sq")
		await("station result") { exists("track-map-result-602") }
		compose.onAllNodes(SemanticsMatcher("Union Sq departures") {
			it.config.getOrNull(SemanticsProperties.ContentDescription)?.any { label -> label.contains("Union Sq") && label.endsWith("departures") } == true
		}).onFirst().performClick()
		await("station board") { exists("stationBoardScreen") || exists("boardList") }
		shot("03-station-board")
		back()
		await("map after station board") { exists(CANVAS) }
		assertViewport(panned, viewport(), "station board return")
		node("track-map-fit").performClick()
		assertEquals(fitted, viewport())
		shot("04-fit-full-original-pdf")
	}

	@Test
	fun routeFilterAccessibleCertaintyAndRecordedTrainDetailReturn() = withMap { _ ->
		val snapshot = recordedSnapshot()
		val trains = trains(snapshot)
		assertTrue("The recorded detail trip is missing", trains.any { it.getString("key") == TRIP })
		search("Union Sq")
		await("station result") { exists("track-map-result-602") }
		node("track-map-result-602").performClick()
		val before = viewport()
		selectL()
		node("track-map-trains").performClick()
		reveal("track-map-train-$TRIP")
		val row = node("track-map-train-$TRIP").fetchSemanticsNode()
		val label = row.config.getOrNull(SemanticsProperties.ContentDescription).orEmpty().joinToString(" ")
		assertTrue("Track certainty must be spoken: $label", label.contains("track", ignoreCase = true))
		assertTrue("Position certainty must be spoken: $label", label.contains("position", ignoreCase = true) || label.contains("estimated", ignoreCase = true) || label.contains("reported", ignoreCase = true))
		val byKey = trains.associate { it.getString("key") to it.getString("route") }
		compose.onAllNodes(prefix("track-map-train-") and hasClickAction()).fetchSemanticsNodes().forEach {
			val key = it.config[SemanticsProperties.TestTag].removePrefix("track-map-train-")
			assertEquals("Route filter leaked $key", "L", byKey[key])
		}
		shot("05-filtered-accessible-list")
		node("track-map-train-$TRIP").performClick()
		await("recorded train details") { exists("trainDetails") }
		shot("06-recorded-train-details")
		back()
		await("map after train details") { exists(CANVAS) }
		assertViewport(before, viewport(), "train detail return")
	}

	@Test
	fun unplacedRecordedTrainHasIndividualAccessibleRowAndReason() = withMap { _ ->
		val unplaced = trains(recordedSnapshot()).firstOrNull { it.getString("placement") == "unplaced" && it.getString("route") == "L" }
			?: throw AssertionError("The frozen acceptance feed needs an unplaced train")
		selectL()
		node("track-map-trains").performClick()
		val tag = "track-map-train-${unplaced.getString("key")}"
		reveal(tag)
		val label = node(tag).fetchSemanticsNode().config.getOrNull(SemanticsProperties.ContentDescription).orEmpty().joinToString(" ")
		assertTrue("Unplaced train must be labeled not on the map: $label", label.contains("not on", true))
		assertTrue("Fixture must explain why the train is unplaced", unplaced.optString("reason").isNotBlank())
		assertTrue("Unplaced train must expose its recorded reason: $label", label.contains(unplaced.getString("reason")))
		shot("07-unplaced-accessible-reason")
	}

	@Test
	fun reportedTrackDoesNotImplyCertainPosition() = withMap { _ ->
		val uncertain = trains(recordedSnapshot()).firstOrNull { it.getString("route") == "L" && it.getString("placement") == "near-stop" && it.getString("trackBasis") == "reported" }
			?: throw AssertionError("The frozen feed needs a reported-track, near-stop L train")
		selectL()
		node("track-map-trains").performClick()
		val tag = "track-map-train-${uncertain.getString("key")}"
		reveal(tag)
		val label = node(tag).fetchSemanticsNode().config.getOrNull(SemanticsProperties.ContentDescription).orEmpty().joinToString(" ")
		assertTrue("Track report missing: $label", label.contains("reported", true))
		assertTrue("Near-stop uncertainty missing: $label", label.contains("unknown", true) || label.contains("near", true))
		shot("07-reported-track-uncertain-position")
	}

	@Test
	fun sameNamedStationsRemainDistinctSearchChoices() = withMap { _ ->
		search("23 St")
		await("distinct same-name stations") { compose.onAllNodes(prefix("track-map-result-")).fetchSemanticsNodes().size >= 2 }
		val choices = compose.onAllNodes(prefix("track-map-result-")).fetchSemanticsNodes()
		assertEquals("Search must group a station's map anchors into one result", choices.size, choices.map { it.config[SemanticsProperties.TestTag] }.toSet().size)
		shot("07-same-name-station-choices")
	}

	@Test
	fun largeTextAndReducedMotionKeepDarkMapControlsReachable() = withMap { scenario ->
		val font = network.shell("settings get system font_scale").trim()
		val motion = network.shell("settings get global animator_duration_scale").trim()
		try {
			network.shell("settings put system font_scale 2.0")
			network.shell("settings put global animator_duration_scale 0")
			scenario.moveToState(Lifecycle.State.CREATED)
			scenario.moveToState(Lifecycle.State.RESUMED)
			await("200 percent app text") { network.context.resources.configuration.fontScale >= 1.99f }
			await("large text map canvas") { exists(CANVAS) }
			assertEquals("Reduced-motion system setting did not apply", "0", network.shell("settings get global animator_duration_scale").trim())
			node("track-map-fit").performClick()
			node("track-map-trains").performClick()
			assertTrue("Large text lost accessible train list", exists("track-map-train-list"))
			shot("07-large-text-reduced-motion-dark-controls")
		} finally {
			if (font == "null") network.shell("settings delete system font_scale") else network.shell("settings put system font_scale $font")
			if (motion == "null") network.shell("settings delete global animator_duration_scale") else network.shell("settings put global animator_duration_scale $motion")
		}
	}

	@Test
	fun pollingStopsHiddenAndBackgroundAndHTTPFailureRetainsBaseMapAndRecovers() = withMap { scenario ->
		val before = viewport()
		node("tab_settings").performClick()
		SystemClock.sleep(2_000)
		val hidden = requests()
		SystemClock.sleep(POLL_WINDOW)
		assertEquals("Map polled in another tab", hidden, requests())
		node("tab_map").performClick()
		awaitRequestAfter(hidden)
		assertViewport(before, viewport(), "poll response")
		scenario.moveToState(Lifecycle.State.CREATED)
		SystemClock.sleep(2_000)
		val background = requests()
		SystemClock.sleep(POLL_WINDOW)
		assertEquals("Map polled while backgrounded", background, requests())
		scenario.moveToState(Lifecycle.State.RESUMED)
		awaitRequestAfter(background)
		control(unavailable = true)
		val afterFailure = requests()
		awaitRequestAfter(afterFailure)
		await("HTTP failure notice") { texts("track-map-status").any { it.contains("failed", true) } }
		assertTrue("Installed PDF disappeared after snapshot HTTP failure", exists(CANVAS))
		assertViewport(before, viewport(), "HTTP failure")
		shot("08-http-failure-base-map-retained")
		var held = emptyList<Pair<String, Pair<Double, Double>>>()
		scenario.onActivity { activity ->
			val map = network.model(activity).trackMap
			held = map.markers(map.clock(), false).map { it.train.key to (it.display.point.x to it.display.point.y) }
			assertTrue("Outage must immediately fade all held markers", map.markers(map.clock(), false).all { it.evidence.freshness.name != "LIVE" })
		}
		assertFalse("Recorded placed trains are needed to check freeze", held.isEmpty())
		SystemClock.sleep(3_000)
		scenario.onActivity { activity ->
			val map = network.model(activity).trackMap
			assertEquals("Failed HTTP must freeze positions", held, map.markers(map.clock(), false).map { it.train.key to (it.display.point.x to it.display.point.y) })
		}
		control(unavailable = false)
		val recovery = requests()
		awaitRequestAfter(recovery)
		await("HTTP recovery notice cleared") { texts("track-map-status").none { it.contains("failed", true) || it.contains("Reconnecting", true) } }
		shot("09-http-recovered")
	}

	@Test
	fun overlappingRecordedMarkersOfferChooser() = withMap { scenario ->
		node("track-map-fit").performClick()
		var tap: Offset? = null
		var keys = emptyList<String>()
		scenario.onActivity { activity ->
			val map = network.model(activity).trackMap
			val size = checkNotNull(map.viewSize)
			val view = checkNotNull(map.camera).viewport(size.first, size.second)
			val points = map.markers(map.clock(), false).map { it.train.key to view.toScreen(it.display.point) }
			val pair = points.indices.firstNotNullOfOrNull { i ->
				points.drop(i + 1).firstOrNull { (_, p) -> hypot(points[i].second.x - p.x, points[i].second.y - p.y) < 12 && p.x > 30 && p.x < size.first - 30 && p.y > 30 && p.y < size.second * 0.7 }?.let { points[i] to it }
			}
			assertNotNull("Frozen feed must contain two overlapping plotted markers", pair)
			pair?.let {
				keys = listOf(it.first.first, it.second.first)
				tap = Offset(((it.first.second.x + it.second.second.x) / 2).toFloat(), ((it.first.second.y + it.second.second.y) / 2).toFloat())
			}
		}
		node(CANVAS).performTouchInput { click(checkNotNull(tap)) }
		await("overlap chooser") { exists("track-map-chooser") }
		for (key in keys) assertTrue("Overlap chooser omitted recorded train $key", exists("track-map-choice-$key"))
		shot("10-overlap-chooser")
	}

	@Test
	fun installedBaseMapSearchAndFitSurviveSimulatedConnectivityLoss() = withMap { _ ->
		val passed = network.gate.passed.size
		network.loseConnectivity()
		await("offline map status") { texts("track-map-status").any { it.contains("Offline", true) } }
		assertTrue("Installed PDF disappeared offline", exists(CANVAS))
		node("track-map-fit").performClick()
		val fitted = viewport()
		search("Union Sq")
		await("offline local station search") { exists("track-map-result-602") }
		node("track-map-result-602").performClick()
		await("offline station focus") { viewport() != fitted }
		assertEquals("No HTTP request may succeed after connectivity loss", passed, network.gate.passed.size)
		shot("11-offline-installed-pdf-and-local-search")
	}

	/**
	 * Isolated gesture regression, not artwork acceptance. The same real canvas/page survives a
	 * recomposition after its parent receives a newer sample. A second tap must invoke the new
	 * callback with that sample, rather than the closure the pointer coroutine first captured.
	 */
	@Test
	fun stableCanvasUsesLatestTapCallbackAndRenderSampleAfterRecomposition() {
		network.installApp()
		val pdf = File(network.context.cacheDir, "track-map-pointer-regression.pdf")
		val document = PdfDocument()
		try {
			val page = document.startPage(PdfDocument.PageInfo.Builder(200, 200, 1).create())
			page.canvas.drawColor(android.graphics.Color.WHITE)
			document.finishPage(page)
			pdf.outputStream().use(document::writeTo)
		} finally { document.close() }
		val page = TrackMapPage(200.0, 200.0)
		val renderer = network.io { TrackMapRenderer.open(pdf, page, Runtime.getRuntime().maxMemory()) }
		val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
		val revision = mutableIntStateOf(1)
		val sample = mutableDoubleStateOf(1788656380.0)
		val delivered = mutableListOf<Pair<Int, Double>>()
		val map = TrackMapModel(scope, { _, _ -> throw AssertionError("An isolated canvas must not poll") }, { sample.doubleValue })
		map.camera = TrackMapCamera(100.0, 100.0, 1.0)
		val scenario = ActivityScenario.launch(MainActivity::class.java)
		try {
			scenario.onActivity { activity ->
				activity.setContent {
					val renderedRevision = revision.intValue
					val renderedSample = sample.doubleValue
					TrackMapCanvas(map, renderer, page, time = { renderedSample }, reducedMotion = false,
						description = "Gesture regression revision $renderedRevision at $renderedSample",
						onTap = { _, _ -> delivered += renderedRevision to renderedSample }, onFit = {}, modifier = Modifier.fillMaxSize())
				}
			}
			await("isolated production canvas") { exists(CANVAS) }
			node(CANVAS).performTouchInput { click(center) }
			compose.runOnIdle {
				assertEquals(listOf(1 to 1788656380.0), delivered)
				revision.intValue = 2
				sample.doubleValue = 1788656400.0
			}
			await("new render sample exposed") {
				node(CANVAS).fetchSemanticsNode().config.getOrNull(SemanticsProperties.ContentDescription)?.any { it.contains("revision 2 at ${1788656400.0}") } == true
			}
			node(CANVAS).performTouchInput { click(center) }
			compose.runOnIdle { assertEquals("Tap used an obsolete callback/time after a new render", listOf(1 to 1788656380.0, 2 to 1788656400.0), delivered) }
			shot("12-stable-canvas-latest-tap-callback")
		} finally {
			network.screenshot("${caseName.methodName}-final-gesture-regression")
			scenario.close()
			renderer.close()
			scope.cancel()
			pdf.delete()
		}
	}

	private fun withMap(block: (ActivityScenario<MainActivity>) -> Unit) {
		val server = network.requireRecordedServer()
		assertEquals("Map outage acceptance uses the in-process gate, not device radio settings", NativeNetworkAcceptanceRule.ConnectivityMode.IN_PROCESS, network.connectivity)
		assertEquals("This suite owns only fixture port 8194", 8194, java.net.URI(server.endpoint).port)
		assertEquals("Recorded September clock changed", 1788656380.0, server.now, 0.0)
		control(unavailable = false, reset = true)
		network.persist(Settings(theme = "hacker"), server.station)
		network.installApp()
		val scenario = ActivityScenario.launch(MainActivity::class.java)
		try {
			await("native Map tab") { exists("tab_map") }
			node("tab_map").performClick()
			await("native PDF canvas", 45_000) { exists(CANVAS) }
			assertTrue("Source credit must remain visible", compose.onAllNodes(hasText("vanshnookenraggen", substring = true)).fetchSemanticsNodes().isNotEmpty())
			await("recorded map response", 35_000) { network.gate.passed.any { it.contains("/track-map/") && it.endsWith("-> 200") } }
			shot("00-dark-native-map")
			block(scenario)
			assertTrue("Requests escaped the fixture origin: ${network.gate.foreign}", network.gate.foreign.isEmpty())
		} finally {
			network.screenshot("${caseName.methodName}-final")
			scenario.close()
			network.restoreConnectivity()
			control(unavailable = false)
		}
	}

	private fun node(tag: String): SemanticsNodeInteraction = compose.onAllNodesWithTag(tag).onFirst()
	private fun exists(tag: String): Boolean = compose.onAllNodesWithTag(tag).fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty()
	private fun prefix(value: String) = SemanticsMatcher("tag starts with $value") { it.config.getOrNull(SemanticsProperties.TestTag)?.startsWith(value) == true }
	private fun texts(tag: String): List<String> = compose.onAllNodesWithTag(tag, useUnmergedTree = true).fetchSemanticsNodes(atLeastOneRootRequired = false).flatMap { it.config.getOrNull(SemanticsProperties.Text).orEmpty().map { text -> text.text } }
	private fun search(query: String) { node("track-map-search").performTextReplacement(query) }
	private fun selectL() {
		val lineL = SemanticsMatcher("L route filter") {
			it.config.getOrNull(SemanticsProperties.ContentDescription)?.any { label -> label == "Line L" || label == "Line L, shown" } == true
		}
		await("L route filter") { compose.onAllNodes(lineL).fetchSemanticsNodes().isNotEmpty() }
		compose.onAllNodes(lineL).onFirst().performClick()
	}
	private fun back() {
		when {
			exists("navigateBack") -> node("navigateBack").performClick()
			exists("closeScreen") -> node("closeScreen").performClick()
			else -> UiDevice.getInstance(network.instrumentation).pressBack()
		}
	}
	private fun reveal(tag: String) {
		val lists = compose.onAllNodes(hasScrollToIndexAction() and hasTestTag("track-map-train-list"))
		assertEquals("Expected one native train list", 1, lists.fetchSemanticsNodes().size)
		lists.onFirst().performScrollToNode(hasTestTag(tag))
		assertTrue("Missing individually accessible train $tag", exists(tag))
	}
	private fun viewport(): TrackMapViewportSummary = node(CANVAS).fetchSemanticsNode().config[TrackMapViewportKey]
	private fun assertViewport(expected: TrackMapViewportSummary, actual: TrackMapViewportSummary, step: String) {
		assertTrue("$step moved center x: $expected -> $actual", abs(expected.centerX - actual.centerX) <= 2)
		assertTrue("$step moved center y: $expected -> $actual", abs(expected.centerY - actual.centerY) <= 2)
		assertEquals("$step changed zoom", expected.zoomPercent, actual.zoomPercent)
	}
	private fun await(what: String, timeout: Long = 30_000, condition: () -> Boolean) {
		try { compose.waitUntil(timeout, condition) } catch (error: androidx.compose.ui.test.ComposeTimeoutException) { throw AssertionError("Timed out waiting for $what; status=${texts("track-map-status")}", error) }
	}
	private fun shot(name: String) { assertNotNull("Screenshot unavailable: $name", network.screenshot("${caseName.methodName}-$name")) }

	private fun fixtureJSON(path: String, body: JSONObject? = null): JSONObject {
		val base = checkNotNull(network.recorded).endpoint
		val url = java.net.URI(base).resolve(path).toString()
		val request = Request.Builder().url(url).apply {
			if (body != null) put(body.toString().toRequestBody("application/json".toMediaType()))
		}.build()
		return network.http.newCall(request).execute().use { response ->
			assertEquals("Fixture $path", 200, response.code)
			JSONObject(checkNotNull(response.body).string())
		}
	}
	private fun control(unavailable: Boolean, reset: Boolean = false): JSONObject = fixtureJSON("/__test/track-map", JSONObject().put("unavailable", unavailable).put("resetRequests", reset))
	private fun requests(): Int = fixtureJSON("/__test/track-map").getInt("requests")
	private fun awaitRequestAfter(previous: Int) { network.waitFor(35_000, "map request after $previous") { requests() > previous } }
	private fun recordedSnapshot(): JSONObject = fixtureJSON("track-map/nyc-2.6.8-v1/snapshot").also {
		val path = File(network.artifactDirectory(), "${caseName.methodName}-recorded-snapshot.json")
		path.writeText(it.toString(2))
		network.evidence.note("recorded snapshot $path; coverage=${it.getJSONObject("coverage")}; routes=${trains(it).map { row -> row.getString("route") }.toSet()}")
	}
	private fun trains(snapshot: JSONObject): List<JSONObject> = snapshot.getJSONArray("trains").let { rows -> (0 until rows.length()).map { rows.getJSONObject(it) } }

	private companion object {
		const val CANVAS = "track-map-canvas"
		const val TRIP = "gtfs-l|20260905|122300_L..N|"
		const val POLL_WINDOW = 18_000L
	}
}
