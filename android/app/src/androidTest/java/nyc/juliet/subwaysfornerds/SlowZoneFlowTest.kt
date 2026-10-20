package nyc.juliet.subwaysfornerds

import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.ComposeTimeoutException
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.hasScrollToIndexAction
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onFirst
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToIndex
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performSemanticsAction
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.uiautomator.UiDevice
import nyc.juliet.subwaysfornerds.core.SlowZoneDisplay
import nyc.juliet.subwaysfornerds.core.Settings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.runner.RunWith

/**
 * Estimated slow zones over recorded HTTP: the fixture server's synthetic Transit Lab rows put a 4
 * train inside 28 St → 23 St-Baruch College with a major slowdown further down its route. The board
 * tags that train while live, train details place each zone before the stop it ends at, and saved
 * copies shown offline drop the live-only parts.
 *
 * Needs SFN_API_BASE_URL and SFN_TEST_NOW (see scripts/test-android-e2e.sh); skipped otherwise.
 */
@RunWith(AndroidJUnit4::class)
class SlowZoneFlowTest {
	private val network = NativeNetworkAcceptanceRule()
	private val compose = createEmptyComposeRule()
	@get:Rule val rules: RuleChain = RuleChain.outerRule(network).around(compose)

	@Test
	fun liveBoardTagsTheTrainAndDetailsPlaceEachZoneBeforeItsEndStop() {
		val server = network.requireRecordedServer()
		val board = network.io { network.client().board(server.station) }
		val zoned = board.departures.filter { it.slowZone != null }
		assertTrue("The recorded board needs a train in a slow zone", zoned.isNotEmpty())
		val row = zoned.first()
		val zone = row.slowZone!!
		val train = network.io { network.client().trip(row.tripKey) }.train
		val zones = train.slowZones.orEmpty()
		assertEquals("The recorded train should have its current zone and one ahead", listOf("633S" to "634S", "419S" to "420S"), zones.map { it.from to it.to })
		network.evidence.note("zoned rows ${zoned.map { it.key }}; trip ${row.tripKey} zones ${zones.map { "${it.from}->${it.to}@${it.toIndex}${if (it.current == true) " current" else ""}" }}")

		network.persist(Settings(), server.station)
		network.installApp()
		var scenario = ActivityScenario.launch(MainActivity::class.java)
		try {
			// 1. The live board tags the train with its typical extra time and reads the zone aloud.
			await("the recorded board to load live") { exists("boardList") && !exists("boardOfflineEstimate") && taggedKeys("departure_").isNotEmpty() }
			assertTrue("Departure ${row.key} is not on the board", reveal(row.key))
			val tag = "slowZoneTag_${row.key}"
			await("the slow zone tag") { exists(tag) }
			assertEquals("In an estimated slow zone: 28 St → 23 St-Baruch College, typically 42s slower", description(tag))
			assertEquals(SlowZoneDisplay.accessibilityLabel(zone), description(tag))
			val shownTags = taggedKeys("slowZoneTag_")
			assertTrue("Only trains in a zone are tagged: $shownTags", (shownTags - zoned.map { it.key }.toSet()).isEmpty())
			saveRow("01-board-tag-row", "departure_${row.key}")
			network.screenshot("01-board-tag")

			// 2. Train details: one summary line, then each zone directly above its end stop.
			node("departure_${row.key}").performClick()
			await("live train details") { exists("trainDetails") && exists("slowZoneSummary") }
			assertEquals("2 estimated slow zones ahead · about +2m 56s typical", description("slowZoneSummary"))
			network.screenshot("02-detail-summary")
			val current = "slowZoneSegment_633S_634S"
			assertTrue(scrollIn("trainDetails", hasTestTag(current)))
			assertEquals("Estimated slow zone · now: 28 St → 23 St-Baruch College · +42s on a 1m 32s run · since Aug 10", description(current))
			assertDirectlyAbove(current, "stop_${train.stops[zones[0].toIndex].id}")
			showAtTop(hasText("Remaining stopping pattern"))
			network.screenshot("02-detail-current-zone")
			val ahead = "slowZoneSegment_419S_420S"
			assertTrue(scrollIn("trainDetails", hasTestTag(ahead)))
			assertEquals("Estimated major slowdown: Wall St → Bowling Green · +2m 14s on a 1m 28s run · since Aug 31", description(ahead))
			assertDirectlyAbove(ahead, "stop_${train.stops[zones[1].toIndex].id}")
			showAtTop(hasTestTag("stop_${train.stops[zones[1].toIndex - 1].id}"))
			network.screenshot("03-detail-zone-ahead")
			assertTrue("The attribution fine print is missing", scrollIn("trainDetails", hasText(SlowZoneDisplay.attribution, substring = true)))
			showAtTop(hasText(SlowZoneDisplay.attribution, substring = true))
			network.screenshot("04-detail-attribution")

			// 3. Saved offline: the board hides the live tag and details drop "now".
			assertTrue(scrollIn("trainDetails", hasTestTag("saveTripOffline")))
			node("saveTripOffline").performClick()
			await("the train to be saved offline") { exists("removeSavedTrip") }
			back()
			network.loseConnectivity()
			scrollBoardToTop()
			await("the board to be shown as saved and offline", 45_000) { exists("boardOfflineEstimate") }
			assertTrue("Departure ${row.key} should stay on the saved board", reveal(row.key))
			assertFalse("Cached boards must hide the live slow zone tag", exists(tag))
			assertTrue("No row on a cached board may show a slow zone tag: ${taggedKeys("slowZoneTag_")}", taggedKeys("slowZoneTag_").isEmpty())
			saveRow("05-offline-board-row", "departure_${row.key}")
			network.screenshot("05-offline-board")
			node("departure_${row.key}").performClick()
			await("offline train details") { exists("offlineEstimateLabel") && exists("slowZoneSummary") }
			assertEquals("2 estimated slow zones ahead · about +2m 56s typical", description("slowZoneSummary"))
			assertTrue(scrollIn("trainDetails", hasTestTag(current)))
			assertEquals("Estimated slow zone: 28 St → 23 St-Baruch College · +42s on a 1m 32s run · since Aug 10", description(current))
			network.screenshot("06-offline-detail-zone")
		} finally {
			scenario.close()
		}
	}

	// MARK: Layout

	/**
	 * The zone row is the row just above its end stop. Tagged bounds exclude each row's own padding, so
	 * only that padding and the divider (about 11dp) separate them; any row in between is at least 48dp.
	 */
	private fun assertDirectlyAbove(zoneTag: String, stopTag: String) {
		// Scrolling the zone and then its stop into view leaves both on screen, the stop at the bottom at most.
		assertTrue(scrollIn("trainDetails", hasTestTag(zoneTag)))
		assertTrue(scrollIn("trainDetails", hasTestTag(stopTag)))
		val zone = placedBounds(zoneTag)
		val stop = placedBounds(stopTag)
		val gap = stop.top - zone.bottom
		assertTrue("$zoneTag ($zone) should sit directly above $stopTag ($stop); gap $gap px", gap >= 0f && gap <= 16f * density())
	}

	/** Bounds of the one laid-out node with the tag; lists also compose rows ahead of the viewport without placing them. */
	private fun placedBounds(tag: String): Rect {
		val placed = compose.onAllNodesWithTag(tag, useUnmergedTree = true).fetchSemanticsNodes().filter { it.layoutInfo.isPlaced }
		assertEquals("Expected one placed node tagged $tag", 1, placed.size)
		return placed.single().boundsInRoot
	}

	private fun density(): Float = network.context.resources.displayMetrics.density

	/** Scrolls train details so the node starts at the top of the list, for screenshots that show what follows it. */
	private fun showAtTop(target: SemanticsMatcher) {
		assertTrue(scrollIn("trainDetails", target))
		val list = compose.onAllNodes(hasScrollToIndexAction() and hasTestTag("trainDetails")).onFirst()
		val node = compose.onAllNodes(target, useUnmergedTree = true).fetchSemanticsNodes().first { it.layoutInfo.isPlaced }
		// The action runs on the main thread, so the offset is measured before it.
		val offset = node.boundsInRoot.top - list.fetchSemanticsNode().boundsInRoot.top
		list.performSemanticsAction(SemanticsActions.ScrollBy) { it(0f, offset) }
		compose.waitForIdle()
	}

	/** A crop of one row beside the full-screen screenshots; window capture can time out on a loaded emulator. */
	private fun saveRow(name: String, tag: String) {
		runCatching { network.saveBitmap(name, node(tag).captureToImage().asAndroidBitmap()) }
			.onFailure { network.evidence.note("row capture $name unavailable: $it") }
	}

	// MARK: Navigation

	private fun node(tag: String): SemanticsNodeInteraction = compose.onAllNodesWithTag(tag).onFirst()

	private fun scrollBoardToTop() {
		await("the board list") { exists("boardList") }
		node("boardList").performScrollToIndex(0)
		compose.waitForIdle()
	}

	/** Scrolls the board until a departure row is composed; false when the board does not show it. */
	private fun reveal(key: String): Boolean {
		scrollBoardToTop()
		return try { node("boardList").performScrollToNode(hasTestTag("departure_$key")); true } catch (_: AssertionError) { false }
	}

	private fun scrollIn(screen: String, target: SemanticsMatcher): Boolean {
		val containers = compose.onAllNodes(hasScrollToIndexAction() and hasTestTag(screen))
		assertEquals("Expected one scrollable screen tagged $screen", 1, containers.fetchSemanticsNodes().size)
		return try {
			containers.onFirst().performScrollToNode(target)
			compose.waitForIdle()
			true
		} catch (error: AssertionError) {
			if (!error.message.orEmpty().startsWith("No node found that matches ${target.description} in scrollable container")) throw error
			false
		}
	}

	private fun back() {
		when {
			exists("navigateBack") -> node("navigateBack").performClick()
			exists("closeScreen") -> node("closeScreen").performClick()
			else -> UiDevice.getInstance(network.instrumentation).pressBack()
		}
		await("the board") { exists("boardList") }
	}

	// MARK: Semantics

	private fun exists(tag: String): Boolean = compose.onAllNodesWithTag(tag, useUnmergedTree = true).fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty()

	private fun description(tag: String): String? =
		compose.onAllNodesWithTag(tag, useUnmergedTree = true).fetchSemanticsNodes(atLeastOneRootRequired = false).firstOrNull()?.config?.getOrNull(SemanticsProperties.ContentDescription)?.joinToString()

	private fun texts(tag: String): List<String> = compose.onAllNodesWithTag(tag, useUnmergedTree = true).fetchSemanticsNodes(atLeastOneRootRequired = false).flatMap { allTexts(it) }

	private fun allTexts(node: SemanticsNode): List<String> = node.config.getOrNull(SemanticsProperties.Text).orEmpty().map { it.text } + node.children.flatMap { allTexts(it) }

	/** Keys of the composed nodes whose test tag starts with the prefix. */
	private fun taggedKeys(prefix: String): Set<String> = compose.onAllNodes(
		SemanticsMatcher("test tag starts with $prefix") { it.config.getOrNull(SemanticsProperties.TestTag)?.startsWith(prefix) == true },
		useUnmergedTree = true,
	).fetchSemanticsNodes(atLeastOneRootRequired = false).mapNotNull { it.config.getOrNull(SemanticsProperties.TestTag)?.removePrefix(prefix) }.toSet()

	private fun await(what: String, timeout: Long = 30_000, condition: () -> Boolean) {
		try { compose.waitUntil(timeout, condition) } catch (_: ComposeTimeoutException) { throw AssertionError("Timed out after ${timeout}ms waiting for $what") }
	}

	private fun awaitTexts(tag: String, what: String, timeout: Long = 30_000, condition: (List<String>) -> Boolean) {
		try { compose.waitUntil(timeout) { condition(texts(tag)) } } catch (_: ComposeTimeoutException) { throw AssertionError("Timed out after ${timeout}ms waiting for $what; $tag shows ${texts(tag)}") }
	}
}
