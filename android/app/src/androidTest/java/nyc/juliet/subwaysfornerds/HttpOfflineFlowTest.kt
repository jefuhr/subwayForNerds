package nyc.juliet.subwaysfornerds

import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.ComposeTimeoutException
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasScrollToIndexAction
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isRoot
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onFirst
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToIndex
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.printToLog
import androidx.compose.ui.test.swipeUp
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.uiautomator.UiDevice
import nyc.juliet.subwaysfornerds.core.Board
import nyc.juliet.subwaysfornerds.core.Departure
import nyc.juliet.subwaysfornerds.core.Display
import nyc.juliet.subwaysfornerds.core.OfflineIdentity
import nyc.juliet.subwaysfornerds.core.Settings
import nyc.juliet.subwaysfornerds.core.TripDetail
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.runner.RunWith

/**
 * Recorded-HTTP acceptance for the full native client. The production TransitClient and
 * ClientTransitService fetch the coordinator's recorded fixture server at its recorded clock,
 * and the production settings store and offline cache keep what the rider chose. After
 * connectivity loss, activity recreation and a fresh reopen, the app may show only that
 * persisted data, labeled as saved and offline: no departures the recorded board did not
 * contain (no schedule fallback), no live labels and no current car numbers.
 *
 * Needs SFN_API_BASE_URL and SFN_TEST_NOW (see scripts/test-android-e2e.sh); skipped otherwise.
 */
@RunWith(AndroidJUnit4::class)
class HttpOfflineFlowTest {
	private val network = NativeNetworkAcceptanceRule()
	private val compose = createEmptyComposeRule()
	@get:Rule val rules: RuleChain = RuleChain.outerRule(network).around(compose)

	/** A recorded departure whose trip details the recorded server also serves. */
	private class Candidate(val departure: Departure, val detail: TripDetail, val currentCars: Boolean) {
		val key: String get() = departure.tripKey
	}

	@Test
	fun savedBoardRideAndTrainStayLabeledAcrossConnectivityLossRecreationAndReopen() {
		val server = network.requireRecordedServer()
		val evidence = network.evidence

		// The recorded responses, read through the same client class and gate the app uses.
		val recordedBoard = network.io { network.client().board(server.station) }
		val recordedByKey = recordedBoard.departures.associateBy { it.key }
		val candidates = network.io { tripsOnBoard(recordedBoard, server.now) }.sortedByDescending { it.currentCars }
		assertTrue("The recorded board for ${server.station} needs two trips with details; found ${candidates.size}.", candidates.size >= 2)
		evidence.note("recorded board ${server.station}: ${recordedBoard.departures.size} departures, ${candidates.size} trips with details, ${candidates.count { it.currentCars }} with current car numbers")

		val preflight = network.gate.passed.size
		network.persist(Settings(), server.station)
		network.installApp()
		var scenario = ActivityScenario.launch(MainActivity::class.java)
		try {
			// 1. The live board arrives over recorded HTTP.
			awaitTexts("boardFreshness", "the recorded board to load live") { texts -> texts.any { it == "Live feed" || it == "Partial live data" } }
			assertTrue("The app did not fetch the board over HTTP: ${network.gate.passed}", network.gate.passed.drop(preflight).any { it.contains("/stations/${server.station}/board") })
			assertOnlyRecordedDepartures(recordedByKey.keys)
			network.screenshot("01-live-board")

			// 2. Open a train, preferring one with reported cars, and ride it.
			val ride = candidates.firstOrNull { reveal(it.departure.key) } ?: throw AssertionError("No recorded trip is visible on the board.")
			openDeparture(ride)
			val liveFeeds = feedDescriptions()
			assertTrue("Online train details must not be labeled offline: $liveFeeds", liveFeeds.isNotEmpty() && liveFeeds.none { it.startsWith("Feed offline") })
			assertFalse(exists("offlineEstimateLabel"))
			evidence.note("before live-car assertion: trip=${ride.key}, recorded current cars=${ride.currentCars}, feed=$liveFeeds; detail scroll containers=" +
				compose.onAllNodes(hasScrollToIndexAction() and hasTestTag("trainDetails")).fetchSemanticsNodes().size +
				", descendant scroll containers=" + compose.onAllNodes(hasScrollToIndexAction() and hasAnyAncestor(hasTestTag("trainDetails"))).fetchSemanticsNodes().size)
			compose.onAllNodes(isRoot(), useUnmergedTree = true).printToLog("SfnHttpBeforeLiveCars", maxDepth = Int.MAX_VALUE)
			network.screenshot("02-live-train-before-car-assertion")
			network.saveBitmap("02-live-train-app-content", compose.onRoot().captureToImage().asAndroidBitmap())
			if (ride.currentCars) assertTrue("Reported car numbers should show while the trip is live.", scrollIn("trainDetails", hasCarNumbers))
			assertTrue("The app did not fetch the trip over HTTP", network.gate.passed.drop(preflight).any { it.contains("/trips?") })
			network.screenshot("02-live-train")
			tapInScreen("trainDetails", "startRide")
			await("the ride to start") { exists("endRide") }
			assertEquals(ride.key, network.io { network.cache().activeRideRecord() }?.key)
			evidence.note("riding ${ride.key} (current cars: ${ride.currentCars})")
			back()

			// 3. Save a different train offline by hand.
			val saved = candidates.firstOrNull { it.key != ride.key && reveal(it.departure.key) } ?: throw AssertionError("No second recorded trip is visible on the board.")
			openDeparture(saved)
			tapInScreen("trainDetails", "saveTripOffline")
			await("the train to be saved offline") { exists("removeSavedTrip") }
			assertEquals(listOf(saved.key), network.io { network.cache().entries() }.filter { it.manual }.map { it.key })
			evidence.note("saved ${saved.key} by hand")
			back()
			scrollBoardToTop()
			await("the ride banner") { exists("activeRideBanner") }
			awaitTexts("savedTrips", "the saved trains chip") { it.contains("Saved trains (1)") }
			network.screenshot("03-ride-and-saved")

			// 4. Connectivity loss: the same activity keeps only saved data, labeled offline.
			val passedBeforeLoss = network.gate.passed.size
			network.loseConnectivity()
			assertOfflineBoard(recordedByKey.keys)
			network.screenshot("04-offline-board")

			// 5. Activity recreation keeps the labels.
			scenario.recreate()
			assertOfflineBoard(recordedByKey.keys)
			network.screenshot("05-recreated-offline-board")

			// 6. Reopen: a new activity, view model and stores read only what was persisted.
			scenario.close()
			scenario = ActivityScenario.launch(MainActivity::class.java)
			assertOfflineBoard(recordedByKey.keys)
			network.screenshot("06-reopened-offline-board")
			assertPersisted(server.station, recordedByKey, ride, saved)

			// 7. The ride and the saved train open from disk as offline estimates without car numbers.
			scrollBoardToTop()
			node("openRide").performClick()
			assertOfflineTrain("kept for your ride", "07-reopened-ride-offline-header")
			network.screenshot("07-reopened-ride-offline")
			back()
			scrollBoardToTop()
			node("savedTrips").performClick()
			await("the saved trains list") { exists("savedTrip_${saved.key}") }
			network.screenshot("08-reopened-saved-list")
			node("savedTrip_${saved.key}").performClick()
			assertOfflineTrain("kept until you remove it", "09-reopened-saved-offline-header")
			network.screenshot("09-reopened-saved-offline")

			assertEquals("No request may succeed after connectivity loss: ${network.gate.passed.drop(passedBeforeLoss)}", passedBeforeLoss, network.gate.passed.size)
			assertTrue("Requests left the fixture origin: ${network.gate.foreign}", network.gate.foreign.isEmpty())
			evidence.note("after loss: ${network.gate.refused.size} requests refused by the gate, ${network.gate.failed.size} failed at the socket, none succeeded")
		} finally {
			scenario.close()
		}
	}

	// MARK: Recorded data

	private suspend fun tripsOnBoard(board: Board, now: Double): List<Candidate> {
		val client = network.client()
		return board.departures
			.filter { Display.boardable(it) && !OfflineIdentity.isPositionalTrip(it.tripKey) && (it.time ?: 0.0) >= now - 30 }
			.distinctBy { it.tripKey }.take(16)
			.mapNotNull { departure ->
				val detail = runCatching { client.trip(departure.tripKey) }.getOrNull()?.takeIf { it.train.key == departure.tripKey } ?: return@mapNotNull null
				val consist = detail.train.consist
				Candidate(departure, detail, consist != null && consist.cars.isNotEmpty() && Display.currentConsist(consist, now))
			}
	}

	/** The disk copies match the recorded responses: nothing invented, nothing re-timed. */
	private fun assertPersisted(station: String, recorded: Map<String, Departure>, ride: Candidate, saved: Candidate) {
		val cache = network.cache()
		assertEquals(ride.key, network.io { cache.activeRideRecord() }?.key)
		assertEquals(listOf(saved.key), network.io { cache.entries() }.filter { it.manual }.map { it.key })
		val board = network.io { cache.boardSnapshot(station) } ?: throw AssertionError("The board was not persisted.")
		board.board.departures.forEach { row ->
			val source = recorded[row.key] ?: throw AssertionError("Persisted departure ${row.key} is not in the recorded board.")
			assertEquals("Persisted time for ${row.key}", source.time, row.time)
			assertEquals("Persisted source time for ${row.key}", source.timestamp, row.timestamp, 0.0)
		}
		for (candidate in listOf(ride, saved)) {
			val trip = network.io { cache.tripSnapshot(candidate.key) }?.train ?: throw AssertionError("Trip ${candidate.key} was not persisted.")
			assertEquals("Persisted stops for ${candidate.key}", candidate.detail.train.stops.map { it.id to (it.arrival ?: it.departure) }, trip.stops.map { it.id to (it.arrival ?: it.departure) })
			assertEquals("Persisted source time for ${candidate.key}", candidate.detail.train.timestamp, trip.timestamp, 0.0)
		}
		network.evidence.note("persisted board (${board.board.departures.size} rows), ride and saved train match the recorded HTTP responses")
	}

	// MARK: Offline assertions

	private fun assertOfflineBoard(recordedKeys: Set<String>) {
		scrollBoardToTop()
		awaitTexts("boardFreshness", "the board to be labeled saved and offline", 45_000) { it.contains("Saved board · offline") }
		// The notice depends on whether a refresh was attempted after loading; when shown it must be this one.
		val notice = texts("boardError")
		assertTrue("Board notice: $notice", notice.isEmpty() || notice == listOf(NO_CONNECTION_BOARD))
		network.evidence.note("offline board notice: ${notice.ifEmpty { listOf("(none)") }}")
		val estimate = texts("boardOfflineEstimate")
		assertTrue("Saved board times must say they are estimates with their source age: $estimate", estimate.any { ESTIMATE.matches(it) })
		assertFalse("Offline readiness is a live-only label", exists("offlineReadiness"))
		await("the ride banner") { exists("activeRideBanner") }
		val banner = texts("activeRideBanner")
		assertTrue("Ride banner: $banner", banner.any { it.startsWith("Your ride") })
		assertTrue("The ride banner must label saved times as estimates: $banner", banner.any { ESTIMATE_PREFIX.containsMatchIn(it) })
		assertTrue(texts("savedTrips").contains("Saved trains (1)"))
		assertOnlyRecordedDepartures(recordedKeys)
		scrollBoardToTop()
	}

	private fun assertOfflineTrain(kept: String, screenshot: String) {
		await("offline train details") { exists("offlineEstimateLabel") }
		val estimate = texts("offlineEstimateLabel")
		assertTrue("Train estimate label: $estimate", estimate.any { ESTIMATE.matches(it) })
		val feeds = feedDescriptions()
		assertTrue("Saved trains must be labeled offline, never live: $feeds", feeds.any { it.startsWith("Feed offline") } && feeds.none { it.startsWith("Feed live") })
		val screen = texts("trainDetails")
		assertTrue("Provenance should say '$kept': $screen", screen.any { it.contains(kept) })
		assertTrue(screen.contains(NO_CONNECTION_TRAIN))
		assertTrue(screen.contains("Car numbers and the train's current position are not shown offline."))
		assertTrue("The car numbers fact should say they are not shown offline", screen.contains("Not shown offline"))
		network.screenshot(screenshot)
		assertTrue("Saved stops should be labeled as a saved pattern", scrollIn("trainDetails", hasText("Saved stopping pattern")))
		assertFalse("Car numbers must not be presented as current offline", scrollIn("trainDetails", hasCarNumbers))
	}

	/** Every departure in the whole board list is one the recorded HTTP board contained. */
	private fun assertOnlyRecordedDepartures(recordedKeys: Set<String>) {
		val shown = allDepartureKeys()
		assertTrue("The board shows no departures", shown.isNotEmpty())
		val invented = shown - recordedKeys
		assertTrue("Departures not in the recorded board (schedule fallback?): $invented", invented.isEmpty())
	}

	// MARK: Navigation

	private fun node(tag: String): SemanticsNodeInteraction = compose.onAllNodesWithTag(tag).onFirst()

	private fun boardList(): SemanticsNodeInteraction = node("boardList")

	private fun scrollBoardToTop() {
		await("the board list") { exists("boardList") }
		boardList().performScrollToIndex(0)
		compose.waitForIdle()
	}

	/** Scrolls the board until a departure row is composed; false when the board does not show it. */
	private fun reveal(key: String): Boolean {
		scrollBoardToTop()
		return try { boardList().performScrollToNode(hasTestTag("departure_$key")); true } catch (_: AssertionError) { false }
	}

	private fun openDeparture(candidate: Candidate) {
		assertTrue("Departure ${candidate.departure.key} is not on the board", reveal(candidate.departure.key))
		node("departure_${candidate.departure.key}").performClick()
		await("train details for ${candidate.key}") { exists("trainDetails") && feedDescriptions().isNotEmpty() }
	}

	private fun scrollIn(screen: String, target: SemanticsMatcher): Boolean {
		// ListScreen tags its LazyColumn directly; other containers may tag a parent.
		// A missing container is a broken test locator, never proof that offline car tiles are absent.
		val containers = compose.onAllNodes(hasScrollToIndexAction() and (hasTestTag(screen) or hasAnyAncestor(hasTestTag(screen))))
		assertEquals("Expected one scrollable screen tagged $screen", 1, containers.fetchSemanticsNodes().size)
		return try {
			containers.onFirst().performScrollToNode(target)
			true
		} catch (error: AssertionError) {
			// Only a completed search with no matching row means absence. Timeouts and
			// other Compose assertion failures must still fail the acceptance test.
			if (!error.message.orEmpty().startsWith("No node found that matches ${target.description} in scrollable container")) throw error
			assertEquals("The scrollable screen $screen disappeared while looking for $target", 1, containers.fetchSemanticsNodes().size)
			network.evidence.note("No matching row in $screen for ${target.description}: ${error.message}")
			false
		}
	}

	private fun tapInScreen(screen: String, tag: String) {
		assertTrue("$tag is not on $screen", scrollIn(screen, hasTestTag(tag)))
		node(tag).performClick()
	}

	private fun back() {
		when {
			exists("navigateBack") -> node("navigateBack").performClick()
			exists("closeScreen") -> node("closeScreen").performClick()
			else -> UiDevice.getInstance(network.instrumentation).pressBack()
		}
		await("the board") { exists("boardList") }
	}

	/** Departure keys on the whole board, collected by scrolling to its end. */
	private fun allDepartureKeys(): Set<String> {
		scrollBoardToTop()
		val keys = linkedSetOf<String>()
		var unchanged = 0
		repeat(60) {
			val before = keys.size
			keys += compose.onAllNodes(tagPrefix("departure_")).fetchSemanticsNodes(atLeastOneRootRequired = false)
				.mapNotNull { it.config.getOrNull(SemanticsProperties.TestTag)?.removePrefix("departure_") }
			if (keys.size == before) unchanged += 1 else unchanged = 0
			if (unchanged >= 3) return keys
			boardList().performTouchInput { swipeUp() }
			compose.waitForIdle()
		}
		return keys
	}

	// MARK: Semantics

	private fun exists(tag: String): Boolean = compose.onAllNodesWithTag(tag, useUnmergedTree = true).fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty()

	private fun texts(tag: String): List<String> = compose.onAllNodesWithTag(tag, useUnmergedTree = true).fetchSemanticsNodes(atLeastOneRootRequired = false).flatMap { allTexts(it) }

	private fun allTexts(node: SemanticsNode): List<String> = node.config.getOrNull(SemanticsProperties.Text).orEmpty().map { it.text } + node.children.flatMap { allTexts(it) }

	/** The train summary's spoken feed state, such as "Feed live, 8s ago" or "Feed offline, 8s ago". */
	private fun feedDescriptions(): List<String> = compose.onAllNodes(
		SemanticsMatcher("feed state") { node -> node.config.getOrNull(SemanticsProperties.ContentDescription)?.any { it.startsWith("Feed ") } == true },
		useUnmergedTree = true,
	).fetchSemanticsNodes(atLeastOneRootRequired = false).flatMap { it.config[SemanticsProperties.ContentDescription] }

	private fun await(what: String, timeout: Long = 30_000, condition: () -> Boolean) {
		try { compose.waitUntil(timeout, condition) } catch (_: ComposeTimeoutException) { throw AssertionError("Timed out after ${timeout}ms waiting for $what") }
	}

	private fun awaitTexts(tag: String, what: String, timeout: Long = 30_000, condition: (List<String>) -> Boolean) {
		try { compose.waitUntil(timeout) { condition(texts(tag)) } } catch (_: ComposeTimeoutException) { throw AssertionError("Timed out after ${timeout}ms waiting for $what; $tag shows ${texts(tag)}") }
	}

	private fun tagPrefix(prefix: String) = SemanticsMatcher("test tag starts with $prefix") { it.config.getOrNull(SemanticsProperties.TestTag)?.startsWith(prefix) == true }

	private companion object {
		const val NO_CONNECTION_BOARD = "No connection. Showing a saved board; times are offline estimates."
		const val NO_CONNECTION_TRAIN = "No connection. Showing offline estimates."
		val ESTIMATE = Regex("^(Offline estimate|Last known times) · source \\d+[smh] ago$")
		val ESTIMATE_PREFIX = Regex("^(Offline estimate|Last known times) · source \\d+[smh] ago")
		/** Car tiles and the car numbers header appear only while a consist is current. */
		val hasCarNumbers = SemanticsMatcher("car numbers") { node ->
			node.config.getOrNull(SemanticsProperties.ContentDescription)?.any { it.startsWith("Car ") } == true ||
				node.config.getOrNull(SemanticsProperties.Text)?.any { it.text.startsWith("Car numbers · ") } == true ||
				node.config.getOrNull(SemanticsProperties.TestTag)?.let { it == "favoriteConsist" || it.startsWith("favoriteCar_") } == true
		}
	}
}
