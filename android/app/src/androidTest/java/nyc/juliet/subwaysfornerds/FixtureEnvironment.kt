package nyc.juliet.subwaysfornerds

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.util.Log
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.hasScrollToNodeAction
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.isRoot
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.junit4.ComposeTestRule
import androidx.compose.ui.test.printToLog
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import kotlinx.serialization.builtins.ListSerializer
import nyc.juliet.subwaysfornerds.core.AccountSession
import nyc.juliet.subwaysfornerds.core.AndroidAuthPending
import nyc.juliet.subwaysfornerds.core.AuthConfig
import nyc.juliet.subwaysfornerds.core.Board
import nyc.juliet.subwaysfornerds.core.FleetDetail
import nyc.juliet.subwaysfornerds.core.FleetPackJob
import nyc.juliet.subwaysfornerds.core.FleetPackSelection
import nyc.juliet.subwaysfornerds.core.FleetPage
import nyc.juliet.subwaysfornerds.core.PRODUCTION_API_BASE
import nyc.juliet.subwaysfornerds.core.Settings
import nyc.juliet.subwaysfornerds.core.SettingsRevision
import nyc.juliet.subwaysfornerds.core.Station
import nyc.juliet.subwaysfornerds.core.StationContext
import nyc.juliet.subwaysfornerds.core.StationLocation
import nyc.juliet.subwaysfornerds.core.TransferProgress
import nyc.juliet.subwaysfornerds.core.TransferPhase
import nyc.juliet.subwaysfornerds.core.TransferResult
import nyc.juliet.subwaysfornerds.core.TransitException
import nyc.juliet.subwaysfornerds.core.TransitJson
import nyc.juliet.subwaysfornerds.core.TripDetail
import nyc.juliet.subwaysfornerds.data.AndroidSettingsStore
import nyc.juliet.subwaysfornerds.data.AndroidTransitCache
import nyc.juliet.subwaysfornerds.ui.AppContainer
import nyc.juliet.subwaysfornerds.ui.AppDependencies
import nyc.juliet.subwaysfornerds.ui.DeviceSettingsStorage
import nyc.juliet.subwaysfornerds.ui.LaunchOptions
import nyc.juliet.subwaysfornerds.ui.TestLaunchGate
import nyc.juliet.subwaysfornerds.ui.UiFlags
import nyc.juliet.subwaysfornerds.ui.account.SessionVault
import nyc.juliet.subwaysfornerds.ui.data.AccountService
import nyc.juliet.subwaysfornerds.ui.data.LocationException
import nyc.juliet.subwaysfornerds.ui.data.LocationPermission
import nyc.juliet.subwaysfornerds.ui.data.LocationSource
import nyc.juliet.subwaysfornerds.ui.data.TransferSink
import nyc.juliet.subwaysfornerds.ui.data.TransitService
import nyc.juliet.subwaysfornerds.ui.data.WidgetHooks
import nyc.juliet.subwaysfornerds.ui.data.SettingsStorage
import org.junit.rules.ExternalResource
import org.junit.rules.TestWatcher
import org.junit.runner.Description
import java.io.File
import java.io.IOException

/** Recorded fixture time: eight seconds after the recorded board's prediction source. */
const val FIXTURE_NOW = 1_788_656_340.0
const val FIXTURE_STATION = "602"
const val FIXTURE_TRIP = "gtfs-l|20260905|122300_L..N|"

fun asset(name: String): String =
	InstrumentationRegistry.getInstrumentation().context.assets.open("fixtures/$name").use { it.readBytes().toString(Charsets.UTF_8) }

/**
 * Serves recorded fixture JSON for the one recorded station and trip. Every other request fails as
 * a network outage would, so tests see the app's honest unavailable states rather than invented data.
 */
class FixtureTransitService(var online: Boolean = true) : TransitService {
	override val baseUrl = "https://fixture.invalid/api/v1/"
	override val host = "fixture.invalid"
	val requests = mutableListOf<String>()
	private val catalog by lazy { TransitJson.decodeFromString(ListSerializer(Station.serializer()), asset("catalog.json")) }
	private val board by lazy { TransitJson.decodeFromString(Board.serializer(), asset("board.json")) }
	private val trip by lazy { TransitJson.decodeFromString(TripDetail.serializer(), asset("trip.json")) }

	private suspend fun respond(name: String, progress: TransferSink?) {
		requests += name
		if (!online) throw IOException("The fixture network is offline.")
		progress?.invoke(TransferProgress(TransferPhase.REQUESTING, host = host))
		progress?.invoke(TransferProgress(TransferPhase.FINISHED, 1, 1, host))
	}
	override suspend fun stations(progress: TransferSink?): List<Station> { respond("stations", progress); return catalog }
	override suspend fun board(stationID: String, progress: TransferSink?): Board {
		respond("board:$stationID", progress)
		if (stationID != FIXTURE_STATION) throw IOException("No recorded board for $stationID.")
		return board
	}
	override suspend fun trip(key: String, progress: TransferSink?): TripDetail {
		respond("trip:$key", progress)
		if (key != FIXTURE_TRIP) throw TransitException.NotFound()
		return trip
	}
	override suspend fun transfers(key: String, stopID: String, sequence: Int?, progress: TransferSink?): TransferResult {
		respond("transfers:$key:$stopID", progress)
		return TransitJson.decodeFromString(TransferResult.serializer(), asset("transfers.json"))
	}
	override suspend fun context(stationID: String, progress: TransferSink?): StationContext {
		respond("context:$stationID", progress)
		return TransitJson.decodeFromString(StationContext.serializer(), asset("context.json"))
	}
	override suspend fun fleet(query: Map<String, String>, progress: TransferSink?): FleetPage {
		respond("fleet", progress)
		return TransitJson.decodeFromString(FleetPage.serializer(), asset("fleet-page.json"))
	}
	override suspend fun fleetDetail(kind: String, id: String, progress: TransferSink?): FleetDetail {
		respond("fleetDetail:$kind:$id", progress)
		return TransitJson.decodeFromString(FleetDetail.serializer(), asset("fleet-detail.json"))
	}
	override suspend fun prepareFleetPack(selection: FleetPackSelection): FleetPackJob = throw IOException("Fleet packs are not recorded.")
	override suspend fun fleetPackStatus(jobID: String): FleetPackJob = throw IOException("Fleet packs are not recorded.")
}

class FixtureLocation(var permission: LocationPermission = LocationPermission.NOT_REQUESTED, var location: StationLocation? = null) : LocationSource {
	override fun foregroundPermission() = permission
	override val foregroundPermissionNames: Array<String> = emptyArray()
	override fun backgroundAllowed() = false
	override suspend fun locate(timeoutMillis: Long): StationLocation = location ?: throw LocationException("Could not get your location. Search for a station or try again.")
	override suspend fun backgroundEnabled() = false
	override suspend fun setBackgroundEnabled(value: Boolean) {}
	override suspend fun publishAppLocation(location: StationLocation) {}
}

/** Records what the app hands to widgets without scheduling real widget work during tests. */
class RecordingWidgetHooks : WidgetHooks {
	@Volatile var settingsChanges = 0
	val savedBoards: MutableList<String> = java.util.Collections.synchronizedList(mutableListOf())
	override suspend fun settingsChanged() { settingsChanges += 1 }
	override suspend fun boardSaved(board: Board) { savedBoards += board.station.id }
	fun clear() { settingsChanges = 0; savedBoards.clear() }
}

/** Accounts are disabled on the fixture server, as on production today. */
class DisabledAccounts : AccountService {
	override suspend fun config() = AuthConfig(enabled = false)
	override suspend fun startAndroid(provider: String, intent: String, token: String?): AndroidAuthPending = throw IOException("Accounts are disabled.")
	override suspend fun exchangeAndroid(callback: String, pending: AndroidAuthPending, token: String?): AccountSession = throw IOException("Accounts are disabled.")
	override suspend fun account(token: String): AccountSession = throw IOException("Accounts are disabled.")
	override suspend fun settings(token: String): SettingsRevision = throw IOException("Accounts are disabled.")
	override suspend fun putSettings(token: String, settings: Settings, revision: Long): SettingsRevision = throw IOException("Accounts are disabled.")
	override suspend fun logout(token: String) {}
	override suspend fun unlink(provider: String, token: String) {}
	override suspend fun deleteAccount(token: String) {}
}

class MemoryVault : SessionVault {
	private var token: String? = null
	private var pending: AndroidAuthPending? = null
	override suspend fun load() = token
	override suspend fun save(token: String) { this.token = token }
	override suspend fun clear() { token = null; pending = null }
	override suspend fun loadPending() = pending
	override suspend fun savePending(pending: AndroidAuthPending) { this.pending = pending }
	override suspend fun clearPending() { pending = null }
}

/** Installs fixture dependencies for the next activity launch and clears this app's own saved data. */
object FixtureEnvironment {
	val transit = FixtureTransitService()
	val location = FixtureLocation()
	val widgets = RecordingWidgetHooks()

	fun install(settings: Settings? = null, lastStation: String = FIXTURE_STATION, online: Boolean = true, settingsStorage: (SettingsStorage) -> SettingsStorage = { it }) {
		val context = InstrumentationRegistry.getInstrumentation().targetContext
		TestLaunchGate.disarm()
		AppContainer.launchOptions = null
		LaunchOptions.resetState(context)
		transit.online = online
		transit.requests.clear()
		widgets.clear()
		if (settings != null) kotlinx.coroutines.runBlocking {
			AndroidSettingsStore(context).replaceFromImport(settings, lastStation)
		}
		AppContainer.overrides = { app ->
			AppDependencies(
				settingsStore = settingsStorage(DeviceSettingsStorage(AndroidSettingsStore(app))),
				cache = { endpoint -> cache(app, endpoint) },
				transit = { transit },
				fleet = null,
				location = location,
				widgets = widgets,
				clock = { FIXTURE_NOW },
				fixedNow = FIXTURE_NOW,
				debug = true,
				locationDisabled = false,
				flags = UiFlags.Memory(),
				// The fixture decides connectivity, so the emulator's own network can't flip the app offline.
				fixedConnectivity = online,
			)
		}
		AppContainer.accountOverride = { DisabledAccounts() }
		AppContainer.vaultOverride = { MemoryVault() }
	}

	/**
	 * The app's real offline store, on the fixture clock so saved times match the recorded board. The
	 * app keys saved data by its endpoint, which stays the production default under fixture transit.
	 */
	fun cache(context: Context, endpoint: String = PRODUCTION_API_BASE): AndroidTransitCache =
		AndroidTransitCache(File(context.applicationContext.noBackupFilesDir, "transit-v1"), endpoint) { FIXTURE_NOW }

	fun recordedBoard(): Board = TransitJson.decodeFromString(Board.serializer(), asset("board.json"))
}

private fun screenshotFile(name: String): File {
	val context = InstrumentationRegistry.getInstrumentation().targetContext
	val directory = File(context.getExternalFilesDir(null), "screenshots").apply { mkdirs() }
	return File(directory, "$name.png")
}

/** Saves a PNG of a node for review; returns its path on the device. */
fun SemanticsNodeInteraction.saveScreenshot(name: String): String {
	val file = screenshotFile(name)
	file.outputStream().use { captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it) }
	Log.i("SubwaysScreenshots", file.absolutePath)
	return file.absolutePath
}

/**
 * Keeps evidence of a failed test while its activity is still on screen: a device screenshot and the
 * semantics tree in logcat. Place it inside the compose rule so it runs before the activity closes.
 */
class FailureArtifacts(private val compose: ComposeTestRule) : TestWatcher() {
	override fun failed(e: Throwable?, description: Description) {
		val name = "FAILED-${description.testClass.simpleName}-${description.methodName}"
		runCatching {
			val bitmap = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot() ?: return@runCatching
			screenshotFile(name).outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
		}
		runCatching { compose.onAllNodes(isRoot(), useUnmergedTree = true).printToLog(name, maxDepth = Int.MAX_VALUE) }
	}
}

/** The recorded first northbound L train at 14 St-Union Sq. */
const val FIRST_NORTH_L = "departure_gtfs-l|20260905|122300_L..N||L03N|0"
val anyDeparture = SemanticsMatcher("is a departure row") { it.config.getOrNull(SemanticsProperties.TestTag)?.startsWith("departure_") == true }
private val boardList = hasTestTag("boardList") and hasScrollToNodeAction()

/** Waits for the board's first rows; later rows are composed only when scrolled into view. */
@OptIn(ExperimentalTestApi::class)
fun ComposeTestRule.waitForDepartures(timeoutMillis: Long = 30_000) = waitUntilAtLeastOneExists(anyDeparture, timeoutMillis)

/** Scrolls the board list until the departure is on screen; fails if the list has no such row. */
fun ComposeTestRule.scrollToDeparture(tag: String): SemanticsNodeInteraction {
	onNode(boardList).performScrollToNode(hasTestTag(tag))
	return onNodeWithTag(tag)
}

/** Scrolls the board list, whose header holds the station card and filter chips, to a tagged node. */
fun ComposeTestRule.boardNode(tag: String): SemanticsNodeInteraction {
	onNode(boardList).performScrollToNode(hasTestTag(tag))
	return onNodeWithTag(tag)
}

/**
 * Launches MainActivity for a test and closes it only after the failure rule has run, so a failed
 * test's screenshot shows the app rather than the launcher. Use it as the outermost rule.
 */
class LaunchedActivities : ExternalResource() {
	private val scenarios = mutableListOf<ActivityScenario<MainActivity>>()
	fun launch(intent: Intent? = null): ActivityScenario<MainActivity> =
		(if (intent != null) ActivityScenario.launch<MainActivity>(intent) else ActivityScenario.launch(MainActivity::class.java)).also { scenarios += it }

	override fun after() {
		scenarios.forEach { runCatching { it.close() } }
		scenarios.clear()
		// Also activities started from outside the test, such as by a shell intent.
		InstrumentationRegistry.getInstrumentation().runOnMainSync {
			listOf(Stage.RESUMED, Stage.PAUSED, Stage.STOPPED).forEach { stage ->
				ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(stage).forEach { it.finish() }
			}
		}
	}
}

/**
 * Delivers a VIEW link the way a browser or widget host does: from outside the app, resolved by the
 * real manifest filters. The shell does not interpret the link, so `&` and `|` need no quoting.
 */
fun sendViewIntentFromShell(link: String) {
	val instrumentation = InstrumentationRegistry.getInstrumentation()
	val output = instrumentation.uiAutomation.executeShellCommand("am start -W -a android.intent.action.VIEW -d $link ${instrumentation.targetContext.packageName}")
	android.os.ParcelFileDescriptor.AutoCloseInputStream(output).use { it.readBytes() }
}

/** Searches the whole board list for the departure; true only if it is present after filtering. */
fun ComposeTestRule.boardListHas(tag: String): Boolean = runCatching { onNode(boardList).performScrollToNode(hasTestTag(tag)) }.isSuccess
