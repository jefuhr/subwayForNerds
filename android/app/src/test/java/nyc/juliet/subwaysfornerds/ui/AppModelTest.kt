package nyc.juliet.subwaysfornerds.ui

import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import nyc.juliet.subwaysfornerds.core.AppStorageBreakdown
import nyc.juliet.subwaysfornerds.core.Board
import nyc.juliet.subwaysfornerds.core.DeviceNetworkStatus
import nyc.juliet.subwaysfornerds.core.FleetPackJob
import nyc.juliet.subwaysfornerds.core.NerdsCodec
import nyc.juliet.subwaysfornerds.core.NetworkActivityState
import nyc.juliet.subwaysfornerds.core.NetworkTransport
import nyc.juliet.subwaysfornerds.core.Settings
import nyc.juliet.subwaysfornerds.core.SourceState
import nyc.juliet.subwaysfornerds.core.SystemRuntimeStatus
import nyc.juliet.subwaysfornerds.core.TransitJson
import nyc.juliet.subwaysfornerds.data.OfflineFetchTarget
import nyc.juliet.subwaysfornerds.ui.navigation.AppTab
import nyc.juliet.subwaysfornerds.ui.navigation.Route
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.IOException

/** Drives the real model against real on-disk stores, recorded fixtures and a frozen clock. */
class AppModelTest {
	private val harness = ModelHarness()
	private val transit get() = harness.transit
	private val widgets get() = harness.widgets
	private lateinit var model: AppModel

	@After fun tearDown() = harness.close()

	private fun start(online: Boolean = true) { model = harness.create(online) }
	private fun activate() { harness.scope.launch { model.runWhileActive() } }
	private fun <T> onModel(block: suspend () -> T): T = harness.onModel(block)
	private fun waitFor(message: String, condition: () -> Boolean) = harness.waitFor(message, condition = condition)

	@Test fun liveBoardIsShownAndSavedForOffline() {
		start()
		activate()
		waitFor("the live board") { model.board != null && !model.boardIsCached && model.boardSavedAt != null }
		assertEquals(STATION, model.board!!.station.id)
		assertNull(model.boardError)
		assertNotNull(model.boardSavedAt)
		assertTrue(transit.requests.contains("board:$STATION"))
		// Widgets receive the same merged, untrimmed board the screen shows.
		waitFor("the widget board hook") { widgets.boards.any { it.station.id == STATION } }
		assertEquals(model.board!!.departures.size, widgets.boards.last { it.station.id == STATION }.departures.size)
	}

	@Test fun offlineWithoutASavedBoardSaysSo() {
		start(online = false)
		onModel { model.setNetworkConnected(false) }
		waitFor("the disconnect") { !model.connected }
		activate()
		waitFor("the offline notice") { model.boardError == "No connection and no saved board for this station. Choose a saved station or reconnect." }
		assertNull(model.board)
	}

	@Test fun savedBoardStaysAsOfflineEstimatesWhenTheFeedFails() {
		start()
		activate()
		waitFor("the live board to be saved") { model.boardSavedAt != null && !model.boardIsCached }
		transit.online = false
		onModel { model.setNetworkConnected(false) }
		waitFor("the saved board") { model.boardIsCached && !model.connected }
		assertNotNull(model.board)
		// The offline estimate card says it; a saved board never carries an error notice.
		assertNull(model.boardError)
	}

	@Test fun aSavedBoardWhileConnectedHasNoErrorNoticeEither() {
		start()
		activate()
		waitFor("the live board to be saved") { model.boardSavedAt != null && !model.boardIsCached }
		transit.online = false
		// An explicit refresh joins a fetch already in flight, so ask until the failure is handled.
		repeat(100) {
			if (onModel { model.boardIsCached }) return@repeat
			onModel { model.refreshBoard() }
			Thread.sleep(50)
		}
		waitFor("the saved board after a failed refresh") { model.boardIsCached }
		assertTrue("The device is still connected; only the feed failed", model.connected)
		assertNotNull(model.board)
		assertNull(model.boardError)
	}

	@Test fun withoutASavedBoardAFailedFeedStillSaysSo() {
		start(online = false)
		activate()
		waitFor("the feed failure notice") { model.boardError == "Could not reach the train feed. Pull to retry or choose a saved station." }
		assertNull(model.board)
	}

	@Test fun anOfflineCardTapShowsSystemStatusInSettings() {
		start()
		onModel { model.navigator.show(Route.SystemStatus, AppTab.SETTINGS) }
		assertEquals(AppTab.SETTINGS, model.navigator.tab)
		assertEquals(listOf<Route>(Route.SystemStatus), model.navigator.stack(AppTab.SETTINGS))
		onModel { model.navigator.back() }
		assertEquals(AppTab.SETTINGS, model.navigator.tab)
		assertTrue(model.navigator.stack(AppTab.SETTINGS).isEmpty())
	}

	@Test fun aFailedSourceKeepsItsLastRowsOnScreen() {
		start()
		activate()
		waitFor("the live board") { model.board != null && !model.boardIsCached }
		val earlierL = model.board!!.departures.filter { it.feed == "gtfs-l" }.map { it.key }.toSet()
		assertTrue(earlierL.isNotEmpty())
		// The next response lost the L feed: no L rows and an error on its source.
		val recorded = TransitJson.decodeFromString(Board.serializer(), fixture("board.json"))
		transit.boardOverride = { id ->
			if (id != STATION) null else recorded.copy(
				departures = recorded.departures.filter { it.feed != "gtfs-l" },
				sources = recorded.sources.map { if (it.id == "gtfs-l") SourceState(it.id, null, NOW, "Feed unavailable") else it },
			)
		}
		// An explicit refresh joins a fetch already in flight, so ask until a fresh request goes out.
		val before = transit.requests.size
		repeat(50) {
			if (transit.requests.drop(before).contains("board:$STATION")) return@repeat
			onModel { model.refreshBoard() }
			Thread.sleep(50)
		}
		waitFor("the merged board") { model.board?.sources?.any { it.id == "gtfs-l" && it.error != null } == true }
		// The failed L feed keeps its last saved rows (the per-line quota copy) instead of blanking.
		val keptL = model.board!!.departures.filter { it.feed == "gtfs-l" }.map { it.key }
		assertTrue(keptL.isNotEmpty())
		assertTrue(earlierL.containsAll(keptL))
	}

	@Test fun configuredNjtStationsAreStillPlanned() {
		start()
		activate()
		waitFor("the catalog") { model.stations.isNotEmpty() }
		val njt = model.stations.first { it.isNjt && it.departureMode == "external" }
		onModel { model.toggleFavorite(njt.id) }
		val targets = onModel { model.plannedRequests() }.map { it.target }
		assertTrue(OfflineFetchTarget.Board(njt.id) in targets)
	}

	@Test fun favoritesPersistAndBecomeStationPages() {
		start()
		activate()
		waitFor("the catalog") { model.stations.isNotEmpty() }
		onModel { model.toggleFavorite(STATION); model.selectStation("610") }
		assertEquals(listOf("610", STATION), onModel { model.stationPages })
		onModel { model.toggleFavorite("610") }
		assertEquals(listOf(STATION, "610"), onModel { model.stationPages })
		waitFor("favorites to save") { runBlocking { harness.storage.store.load().favorites } == listOf(STATION, "610") }
		assertTrue(widgets.changes > 0)
	}

	@Test fun filtersAreRememberedPerStationAndResetKeepsTheView() {
		start()
		onModel { model.setDirection("NORTH"); model.toggleRoute("L"); model.setBoardView("service"); model.resetFilters() }
		assertEquals("ALL", model.preference.direction)
		assertTrue(model.preference.routes.isEmpty())
		assertEquals("service", model.preference.view)
	}

	@Test fun hiddenLinesHideStationsAndKeepKeysCanonical() {
		start()
		activate()
		waitFor("the live board") { model.board != null }
		onModel { model.setLine("6X", enabled = false) }
		waitFor("hidden lines to be accepted") { model.hiddenRoutes == listOf("6") }
		assertTrue(model.displayBoard!!.departures.none { it.route == "6" || it.route == "6X" })
		assertEquals(listOf("6"), runBlocking { harness.storage.store.load().hiddenRoutes })
	}

	@Test fun combinedStationsMergeMembersAndNameWhereToBoard() {
		start()
		activate()
		waitFor("the catalog") { model.stations.isNotEmpty() }
		val id = onModel { model.saveCombinedStation(null, "Union Sq + Grand Central", listOf(STATION, "610")) }
		waitFor("both member boards to settle") { model.combinedBoard?.origins?.isNotEmpty() == true && model.combinedBoard?.warnings?.any { it.contains("Feed unavailable") } == true }
		assertEquals(id, model.stationID)
		assertTrue(model.combinedBoard!!.origins.values.all { it.station.id == STATION })
		assertTrue(model.combinedBoard!!.warnings.any { it.startsWith("Grand Central-42 St") })
		assertEquals("direction", model.preference.view)
	}

	/** A two-member combined station whose members both load live, so saved copies exist for each. */
	private fun startLiveCombinedStation() {
		start()
		activate()
		waitFor("the catalog") { model.stations.isNotEmpty() }
		val recorded = TransitJson.decodeFromString(Board.serializer(), fixture("board.json"))
		val other = model.stations.first { it.id == "610" }
		transit.boardOverride = { id -> if (id == "610") recorded.copy(station = other) else null }
		val id = onModel { model.saveCombinedStation(null, "Union Sq + Grand Central", listOf(STATION, "610")) }
		waitFor("both members live") { model.stationID == id && model.combinedBoard?.members?.let { members -> members.size == 2 && members.all { it.board != null && !it.cached } } == true && !model.boardIsCached }
	}

	@Test fun aCombinedStationOfSavedBoardsHasNoErrorNoticeEither() {
		startLiveCombinedStation()
		waitFor("both members saved to disk") { model.boardSavedAt != null }
		transit.online = false
		onModel { model.setNetworkConnected(false) }
		waitFor("the saved combined board") { model.boardIsCached && model.combinedBoard?.members?.all { it.cached && it.board != null } == true }
		// Core still words each cached member for the widget; the app's board shows no notice for them.
		assertTrue(model.combinedBoard!!.members.size == 2)
		assertNull(model.boardError)
	}

	@Test fun aFailedRefreshOverASavedCombinedBoardHasNoErrorNotice() {
		startLiveCombinedStation()
		// Still connected, but the feed fails: each member keeps its last board with a "Feed unavailable" error.
		transit.online = false
		repeat(100) {
			if (onModel { model.combinedBoard?.members?.all { it.cached && it.error != null } } == true) return@repeat
			onModel { model.refreshBoard() }
			Thread.sleep(50)
		}
		waitFor("the members' failed refreshes") { model.combinedBoard?.members?.all { it.cached && it.board != null && it.error != null } == true }
		assertTrue(model.connected)
		assertNull(model.boardError)
	}

	@Test fun aCombinedStationStillReportsMembersThatFailed() {
		start()
		activate()
		waitFor("the catalog") { model.stations.isNotEmpty() }
		onModel { model.saveCombinedStation(null, "Union Sq + Grand Central", listOf(STATION, "610")) }
		waitFor("the failed member to be reported") { model.boardError?.contains("Grand Central-42 St: Feed unavailable") == true }
		assertTrue("A saved member must not add a notice of its own: ${model.boardError}", model.boardError?.contains("Saved departures") != true)
	}

	@Test fun aFailedAcceptanceKeepsPreviousSettingsAndThePreview() {
		start()
		onModel { model.previewSettingsFile(fixture("combined-stations.nerds")) }
		val file = model.pendingImport!!
		harness.storage.failAccepted = IOException("disk full")
		try { onModel { model.importSettings(file) }; fail("The import should report the failed save") } catch (_: IOException) {}
		assertNotNull(model.pendingImport)
		assertEquals(STATION, model.stationID)
		assertEquals("12h", model.timeFormat)
		assertEquals("12h", runBlocking { harness.storage.store.load().units.time })
		harness.storage.failAccepted = null
		onModel { model.importSettings(file) }
		assertNull(model.pendingImport)
		assertTrue(model.stationID.startsWith("combined:"))
		assertEquals("24h", model.timeFormat)
		assertEquals("24h", runBlocking { harness.storage.store.load().units.time })
	}

	@Test fun anEditDuringAcceptanceIsKeptAndSavedAfterwards() {
		start()
		onModel {
			model.acceptSettings(sync = null) { current ->
				// The rider changes the theme while the accepted settings are being saved.
				model.setTheme("kuromi")
				current.copy(units = current.units.copy(time = "24h"))
			}
		}
		assertEquals("24h", model.timeFormat)
		assertEquals("kuromi", model.settings.theme)
		waitFor("the edit to save") { runBlocking { harness.storage.store.load() }.let { it.theme == "kuromi" && it.units.time == "24h" } }
	}

	@Test fun aStationChosenDuringASyncAcceptanceStaysChosenAndSaved() {
		start()
		harness.storage.acceptDelayMillis = 400
		val accepting = harness.scope.launch { model.acceptSettings(sync = null) { it.copy(theme = "night") } }
		waitFor("the acceptance to start saving") { harness.storage.acceptsInFlight > 0 }
		// The rider picks another station while the account's settings are being saved.
		onModel { model.selectStation("610") }
		runBlocking { accepting.join() }
		assertEquals("610", model.stationID)
		assertEquals("night", model.settings.theme)
		waitFor("the chosen station to be saved") { runBlocking { harness.storage.store.lastStation() } == "610" }
		Thread.sleep(300)
		assertEquals("A later write must not restore the old station", "610", runBlocking { harness.storage.store.lastStation() })
	}

	@Test fun aSecondStationChoiceDuringTheFollowUpWriteStaysSelected() {
		start()
		val accepting = kotlinx.coroutines.CompletableDeferred<Unit>()
		val accepted = kotlinx.coroutines.CompletableDeferred<Unit>()
		val savingStation = kotlinx.coroutines.CompletableDeferred<Unit>()
		val savedStation = kotlinx.coroutines.CompletableDeferred<Unit>()
		harness.storage.beforeAccepted = { accepting.complete(Unit); accepted.await() }
		harness.storage.beforeLastStation = { if (it == "610") { savingStation.complete(Unit); savedStation.await() } }
		val job = harness.scope.launch { model.acceptSettings(sync = null) { it.copy(theme = "night") } }
		runBlocking { accepting.await() }
		onModel { model.selectStation("610") }
		accepted.complete(Unit)
		runBlocking { savingStation.await() }
		onModel { model.selectStation("635") }
		savedStation.complete(Unit)
		runBlocking { job.join() }
		assertEquals("The second tap must survive acceptance publication", "635", model.stationID)
		waitFor("the latest station to save") { runBlocking { harness.storage.store.lastStation() } == "635" }
	}

	@Test fun unreadableSettingsAreNeverReplacedExceptByImport() {
		harness.storage.failRead = IOException("damaged")
		start()
		assertTrue(model.settingsUnreadable)
		onModel { model.setTheme("kuromi") }
		assertEquals("subway", model.settings.theme)
		try { onModel { model.acceptSettings(sync = null) { it.copy(theme = "night") } }; fail("Acceptance must not replace unreadable settings") } catch (_: Exception) {}
		harness.storage.failRead = null
		onModel { model.previewSettingsFile(fixture("settings.nerds")) }
		onModel { model.importSettings(model.pendingImport!!) }
		assertFalse(model.settingsUnreadable)
	}

	@Test fun savingATripAndStartingARideAreProtectedOnDevice() {
		start()
		activate()
		waitFor("the live board") { model.board != null }
		onModel { model.saveTripOffline(TRIP, null, model.departureOrigin("gtfs-l|20260905|122300_L..N||L03N|0")) }
		assertTrue(model.isTripSaved(TRIP))
		onModel { model.startRide(TRIP, null) }
		assertEquals(TRIP, model.activeRide?.key)
		onModel { model.endRide() }
		assertNull(model.activeRide)
		assertTrue(model.isTripSaved(TRIP))
	}

	@Test fun pathArrivalsCannotBecomeRides() {
		start()
		onModel { model.startRide("path|33|1", null) }
		assertEquals("PATH reports identify a station arrival, not one train, so rides can't follow them.", model.offlineActionError)
	}

	@Test fun importPreviewsBeforeReplacingSettings() {
		start()
		onModel { model.previewSettingsFile(fixture("combined-stations.nerds")) }
		assertNotNull(model.pendingImport)
		assertEquals(AppTab.SETTINGS, model.navigator.tab)
		assertEquals(Route.ImportPreview, model.navigator.overlays.last())
		onModel { model.importSettings(model.pendingImport!!) }
		assertNull(model.pendingImport)
		assertTrue(runBlocking { harness.storage.store.lastStation() }.startsWith("combined:"))
		assertEquals(NerdsCodec.decode(fixture("combined-stations.nerds")).settings.favorites, model.favorites)
	}

	@Test fun invalidFilesNeverReplaceSettings() {
		start()
		onModel { model.previewSettingsFile("{\"format\":\"something-else\"}") }
		assertNull(model.pendingImport)
		assertEquals("This is not a valid Subway Nerds settings file.", model.settingsError)
	}

	@Test fun nearbyAsksForPermissionOnlyWhenTapped() {
		start()
		assertNull(model.permissionRequest)
		onModel { model.locateNearby() }
		assertEquals(PermissionPurpose.NEARBY, model.permissionRequest)
		onModel { model.permissionResult(granted = false) }
		assertNull(model.permissionRequest)
		assertEquals("Location permission is off. You can still search for any station, or allow location in Settings.", model.locationError)
	}

	@Test fun rideLinksOpenTheTripWithoutChangingStation() {
		start()
		onModel { model.openRideLink(TRIP) }
		assertEquals(STATION, model.stationID)
		assertEquals(listOf<Route>(Route.Train(TRIP)), model.navigator.stack(AppTab.BOARD))
	}

	@Test fun foregroundStartupWaitsForRestoredSettings() {
		val saved = "https://dev.fixture.invalid/api/v1/"
		runBlocking {
			harness.storage.store.saveAccepted(Settings(theme = "night"), "610", null)
			harness.storage.store.saveApiBase(saved)
		}
		harness.storage.readDelayMillis = 300
		model = harness.create(waitForLoad = false, debug = true)
		// The activity starts while saved settings are still loading.
		activate()
		waitFor("the restored station's board request") { transit.requests.contains("board:610") }
		assertTrue(harness.requestEndpoints.isNotEmpty())
		assertTrue("No request may use the default endpoint: ${harness.requestEndpoints}", harness.requestEndpoints.all { it == saved })
		assertFalse("The default station must never be fetched first", transit.requests.contains("board:$STATION"))
		assertEquals("night", model.settings.theme)
	}

	@Test fun reconnectDuringHydrationCannotFetchTheDefaultEndpoint() {
		val saved = "https://dev.fixture.invalid/api/v1/"
		runBlocking {
			harness.storage.store.saveAccepted(Settings(theme = "night"), "610", null)
			harness.storage.store.saveApiBase(saved)
		}
		val reading = kotlinx.coroutines.CompletableDeferred<Unit>()
		val read = kotlinx.coroutines.CompletableDeferred<Unit>()
		harness.storage.beforeSnapshot = { reading.complete(Unit); read.await() }
		model = harness.create(waitForLoad = false, debug = true)
		runBlocking { reading.await() }
		activate()
		onModel { model.setNetworkConnected(false) }
		waitFor("offline callback") { !model.connected }
		onModel { model.setNetworkConnected(true) }
		waitFor("online callback") { model.connected }
		// Drain the model thread after the reconnect work was queued, with storage still held.
		onModel { kotlinx.coroutines.yield() }
		val beforeHydration = harness.requestEndpoints.toList()
		read.complete(Unit)
		waitFor("the restored station's board request") { transit.requests.contains("board:610") }
		assertTrue("Requests escaped the hydration barrier: $beforeHydration", beforeHydration.isEmpty())
		assertTrue(harness.requestEndpoints.all { it == saved })
	}

	@Test fun leavingTheAppStopsPreparingAFleetPack() {
		transit.preparingJob = FleetPackJob("job-1", "preparing")
		start()
		onModel { model.fleet.prepare() }
		waitFor("the first status check") { transit.fleetStatusChecks >= 1 }
		onModel { model.suspend() }
		waitFor("preparation to stop") { !model.fleet.isPreparing && !model.fleet.isDownloading }
		val checks = transit.fleetStatusChecks
		// The server is polled once a second while preparing; nothing should poll after leaving.
		Thread.sleep(2_500)
		assertEquals(checks, transit.fleetStatusChecks)
		assertEquals("Preparing the fleet pack stopped because the app left the screen. Your saved fleet is still available. Prepare it again to continue.", model.fleet.error)
	}

	@Test fun systemStatusReadsTheDeviceAndRecordsServerResponseTime() {
		val reads = java.util.concurrent.atomic.AtomicInteger()
		harness.systemStatus = {
			reads.incrementAndGet()
			SystemRuntimeStatus(storage = AppStorageBreakdown(appApkBytes = 1_000, fleetBytes = 500), thermalStatus = "Light", appVersion = "0.1.0 (1)")
		}
		start()
		assertNull(model.lastApiLatencyMs)
		activate()
		waitFor("the live board") { model.board != null && !model.boardIsCached }
		assertNotNull("a completed request records its response time", model.lastApiLatencyMs)
		onModel { model.refreshSystemStatus() }
		assertEquals(1, reads.get())
		assertEquals(1_500L, model.systemStatus.storage.totalAppBytes)
		assertEquals("Light", model.systemStatus.thermalStatus)
		assertEquals(model.lastApiLatencyMs, model.systemStatus.lastApiLatencyMs)
		// Offline storage is measured with the same refresh.
		assertNotNull(model.offlineUsage)
		assertFalse(model.refreshingSystemStatus)
		// A collector failure keeps the last reading instead of blanking the screen.
		harness.systemStatus = { throw IllegalStateException("StatFs unavailable") }
		onModel { model.refreshSystemStatus() }
		assertEquals("Light", model.systemStatus.thermalStatus)
		assertFalse(model.refreshingSystemStatus)
	}

	@Test fun deviceNetworkStatusFollowsConnectivityWithoutAnObservation() {
		start()
		assertEquals(NetworkActivityState.CONNECTED, model.deviceNetworkStatus.state)
		onModel { model.setNetworkConnected(false) }
		waitFor("the disconnect") { !model.connected }
		assertEquals(NetworkActivityState.SEARCHING, model.deviceNetworkStatus.state)
		assertEquals("Searching for Wi-Fi or cellular signal…", model.deviceNetworkHeadline)
		// The loading bar says what the phone is doing instead of a generic wait.
		assertTrue(model.boardLoad.detail, model.boardLoad.detail.startsWith("Searching for Wi-Fi or cellular signal… · Waiting to request departures"))
		onModel { model.setNetworkConnected(true) }
		waitFor("the reconnect") { model.connected }
		assertEquals(NetworkActivityState.CONNECTED, model.deviceNetworkStatus.state)
	}

	@Test fun anObservedNetworkExplainsWhyTheAppIsOffline() {
		start()
		activate()
		waitFor("the live board") { model.board != null && !model.boardIsCached }
		val portal = DeviceNetworkStatus.observe(true, listOf(NetworkTransport.WIFI), internet = true, validated = false, captivePortal = true, notMetered = true, notRoaming = true, notSuspended = true, airplaneMode = false, networkName = "\"Station Wi-Fi\"")
		onModel { model.setNetworkConnected(false, portal) }
		waitFor("the disconnect") { !model.connected }
		assertEquals("Connected to Station Wi-Fi · sign-in required (captive portal)", model.deviceNetworkHeadline)
		assertTrue(model.deviceNetworkDetail, model.deviceNetworkDetail.startsWith("Wi-Fi · Waiting for internet access to refresh departures ("))
		val airplane = DeviceNetworkStatus(state = NetworkActivityState.OFFLINE, airplaneMode = true)
		onModel { model.setDeviceNetworkStatus(airplane) }
		assertEquals("Offline · Airplane mode is on", model.deviceNetworkHeadline)
		assertFalse(model.connected)
	}

	@Test fun aSimulatedOutageIsReportedAsSuch() {
		model = harness.create(debug = true)
		onModel { model.setDeviceNetworkStatus(DeviceNetworkStatus.observe(true, listOf(NetworkTransport.CELLULAR), true, true, false, false, true, true, false)) }
		assertEquals("Connected via Cellular", model.deviceNetworkHeadline)
		onModel { model.setSimulatedOutage(true) }
		waitFor("the simulated outage") { !model.connected }
		assertEquals(NetworkActivityState.SIMULATED_OUTAGE, model.deviceNetworkStatus.state)
		assertEquals("Simulated outage · network requests paused", model.deviceNetworkHeadline)
		assertTrue(model.deviceNetworkDetail, model.deviceNetworkDetail.startsWith("Metered · Automatic refreshes paused until the simulated outage ends"))
		onModel { model.setSimulatedOutage(false) }
		waitFor("the outage to end") { model.connected }
		assertEquals("Connected via Cellular", model.deviceNetworkHeadline)
	}

	@Test fun stationLinksArrivingBeforeLoadWaitAndThenOpen() {
		harness.storage.readDelayMillis = 300
		model = harness.create(waitForLoad = false)
		onModel { model.openStationLink("610") }
		// Without a saved catalog the link is dropped rather than guessed; a favorite or catalog station opens.
		harness.waitFor("settings to load") { model.loaded }
		assertEquals(STATION, model.stationID)
	}
}
