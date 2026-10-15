package nyc.juliet.subwaysfornerds.ui

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.job
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.builtins.ListSerializer
import nyc.juliet.subwaysfornerds.core.Board
import nyc.juliet.subwaysfornerds.core.FleetDetail
import nyc.juliet.subwaysfornerds.core.FleetPackJob
import nyc.juliet.subwaysfornerds.core.FleetPackSelection
import nyc.juliet.subwaysfornerds.core.FleetPage
import nyc.juliet.subwaysfornerds.core.Settings
import nyc.juliet.subwaysfornerds.core.Station
import nyc.juliet.subwaysfornerds.core.StationContext
import nyc.juliet.subwaysfornerds.core.StationLocation
import nyc.juliet.subwaysfornerds.core.TransferResult
import nyc.juliet.subwaysfornerds.core.TransitException
import nyc.juliet.subwaysfornerds.core.TransitJson
import nyc.juliet.subwaysfornerds.core.TripDetail
import nyc.juliet.subwaysfornerds.data.AndroidSettingsStore
import nyc.juliet.subwaysfornerds.data.AndroidTransitCache
import nyc.juliet.subwaysfornerds.data.LocalSettingsSnapshot
import nyc.juliet.subwaysfornerds.data.SyncBaseline
import nyc.juliet.subwaysfornerds.ui.data.LocationException
import nyc.juliet.subwaysfornerds.ui.data.LocationPermission
import nyc.juliet.subwaysfornerds.ui.data.LocationSource
import nyc.juliet.subwaysfornerds.ui.data.SettingsStorage
import nyc.juliet.subwaysfornerds.ui.data.TransferSink
import nyc.juliet.subwaysfornerds.ui.data.TransitService
import nyc.juliet.subwaysfornerds.ui.data.WidgetHooks
import org.junit.Assert.fail
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.util.concurrent.Executors

internal const val NOW = 1_788_656_340.0
internal const val STATION = "602"
internal const val TRIP = "gtfs-l|20260905|122300_L..N|"

internal fun fixture(name: String): String = ModelHarness::class.java.classLoader!!.getResource("fixtures/$name")!!.readText()

internal class FakeTransit : TransitService {
	var online = true
	/** Replaces the recorded board for one fetch, for merge and failure scenarios. */
	var boardOverride: ((String) -> Board?)? = null
	val requests = mutableListOf<String>()
	override val baseUrl = "https://fixture.invalid/api/v1/"
	override val host = "fixture.invalid"
	private fun call(name: String) { requests += name; if (!online) throw IOException("offline") }
	override suspend fun stations(progress: TransferSink?): List<Station> { call("stations"); return TransitJson.decodeFromString(ListSerializer(Station.serializer()), fixture("catalog.json")) }
	override suspend fun board(stationID: String, progress: TransferSink?): Board {
		call("board:$stationID")
		boardOverride?.invoke(stationID)?.let { return it }
		if (stationID != STATION) throw IOException("not recorded")
		return TransitJson.decodeFromString(Board.serializer(), fixture("board.json"))
	}
	override suspend fun trip(key: String, progress: TransferSink?): TripDetail {
		call("trip:$key")
		if (key != TRIP) throw TransitException.NotFound()
		return TransitJson.decodeFromString(TripDetail.serializer(), fixture("trip.json"))
	}
	override suspend fun transfers(key: String, stopID: String, sequence: Int?, progress: TransferSink?): TransferResult = TransitJson.decodeFromString(TransferResult.serializer(), fixture("transfers.json"))
	override suspend fun context(stationID: String, progress: TransferSink?): StationContext = StationContext()
	override suspend fun fleet(query: Map<String, String>, progress: TransferSink?): FleetPage = throw IOException("not recorded")
	override suspend fun fleetDetail(kind: String, id: String, progress: TransferSink?): FleetDetail = throw IOException("not recorded")
	/** A pack the server keeps preparing; null when packs are unavailable. */
	var preparingJob: FleetPackJob? = null
	@Volatile var fleetStatusChecks = 0
	override suspend fun prepareFleetPack(selection: FleetPackSelection): FleetPackJob = preparingJob ?: throw IOException("not recorded")
	override suspend fun fleetPackStatus(jobID: String): FleetPackJob { fleetStatusChecks += 1; return preparingJob ?: throw IOException("not recorded") }
}

/** Tags each request with the endpoint whose service made it, to prove which endpoint startup used. */
internal class EndpointTransit(private val endpoint: String, private val delegate: FakeTransit, private val log: MutableList<String>) : TransitService by delegate {
	override suspend fun stations(progress: TransferSink?): List<Station> { log += endpoint; return delegate.stations(progress) }
	override suspend fun board(stationID: String, progress: TransferSink?): Board { log += endpoint; return delegate.board(stationID, progress) }
	override suspend fun trip(key: String, progress: TransferSink?): TripDetail { log += endpoint; return delegate.trip(key, progress) }
}

internal class FakeLocation(var permission: LocationPermission = LocationPermission.NOT_REQUESTED, var fix: StationLocation? = null) : LocationSource {
	override fun foregroundPermission() = permission
	override val foregroundPermissionNames = emptyArray<String>()
	override fun backgroundAllowed() = false
	override suspend fun locate(timeoutMillis: Long) = fix ?: throw LocationException("Could not get your location. Search for a station or try again.")
	override suspend fun backgroundEnabled() = false
	override suspend fun setBackgroundEnabled(value: Boolean) {}
	override suspend fun publishAppLocation(location: StationLocation) {}
}

internal class CountingWidgets : WidgetHooks {
	var changes = 0
	val boards = mutableListOf<Board>()
	override suspend fun settingsChanged() { changes += 1 }
	override suspend fun boardSaved(board: Board) { boards += board }
}

/** Real device storage with an optional delay or failure, for restoration and acceptance races. */
internal class TestSettingsStorage(directory: File) : SettingsStorage {
	val store = AndroidSettingsStore(directory)
	var readDelayMillis = 0L
	/** Holds each acceptance before it writes, so edits can land while it is in flight. */
	var acceptDelayMillis = 0L
	@Volatile var acceptsInFlight = 0
	var failAccepted: Exception? = null
	var failRead: Exception? = null
	val accepted = mutableListOf<Settings>()
	var beforeSnapshot: (suspend () -> Unit)? = null
	var beforeAccepted: (suspend () -> Unit)? = null
	var beforeLastStation: (suspend (String) -> Unit)? = null
	override suspend fun snapshot(): LocalSettingsSnapshot {
		beforeSnapshot?.invoke()
		if (readDelayMillis > 0) delay(readDelayMillis)
		failRead?.let { throw it }
		return store.snapshot()
	}
	var failSave: Exception? = null
	override suspend fun save(settings: Settings) { failSave?.let { throw it }; store.save(settings) }
	override suspend fun saveLastStation(id: String) {
		beforeLastStation?.invoke(id)
		store.saveLastStation(id)
	}
	override suspend fun saveApiBase(base: String) = store.saveApiBase(base)
	override suspend fun saveAccepted(settings: Settings, lastStation: String, baseline: SyncBaseline?, replaceUnreadable: Boolean) {
		acceptsInFlight += 1
		try {
			beforeAccepted?.invoke()
			if (acceptDelayMillis > 0) delay(acceptDelayMillis)
			failAccepted?.let { throw it }
			store.saveAccepted(settings, lastStation, baseline, replaceUnreadable)
			accepted += settings
		} finally { acceptsInFlight -= 1 }
	}
}

/** The model on its own thread with real stores in a temporary directory. */
internal class ModelHarness : AutoCloseable {
	val directory: File = Files.createTempDirectory("ux-model").toFile()
	private val executor = Executors.newSingleThreadExecutor()
	val scope = CoroutineScope(SupervisorJob() + executor.asCoroutineDispatcher())
	val transit = FakeTransit()
	val location = FakeLocation()
	val widgets = CountingWidgets()
	val storage = TestSettingsStorage(File(directory, "settings"))
	/** The endpoint of every transit request, in order. */
	val requestEndpoints: MutableList<String> = java.util.Collections.synchronizedList(mutableListOf())
	lateinit var model: AppModel

	fun <T> onModel(block: suspend () -> T): T = runBlocking { withContext(scope.coroutineContext) { block() } }

	fun waitFor(message: String, timeoutMillis: Long = 30_000, condition: () -> Boolean) {
		val started = System.currentTimeMillis()
		val deadline = started + timeoutMillis
		while (!onModel { condition() }) {
			if (System.currentTimeMillis() > deadline) {
				val state = if (::model.isInitialized) onModel { "board error: ${model.boardError}; connected: ${model.connected}" } else "no model"
				fail("Timed out waiting for $message; requests: ${transit.requests}; $state")
			}
			Thread.sleep(20)
		}
		val took = System.currentTimeMillis() - started
		if (took > 2_000) println("waited ${took}ms for $message")
	}

	fun create(online: Boolean = true, waitForLoad: Boolean = true, debug: Boolean = false): AppModel {
		transit.online = online
		model = onModel {
			AppModel(scope, AppDependencies(
				settingsStore = storage,
				cache = { endpoint -> AndroidTransitCache(File(directory, "cache"), endpoint) { NOW } },
				transit = { endpoint -> EndpointTransit(endpoint, transit, requestEndpoints) },
				fleet = null,
				location = location,
				widgets = widgets,
				clock = { NOW },
				fixedNow = NOW,
				debug = debug,
			))
		}
		if (waitForLoad) waitFor("settings to load") { model.loaded }
		return model
	}

	/**
	 * Cancels the model and waits for its coroutines to unwind on their own thread before stopping it.
	 * Fetches hold permits of the process-wide TransitFetchSlots; a coroutine that can never resume
	 * would keep its permit and starve the next test's fetches.
	 */
	override fun close() {
		runBlocking { withTimeoutOrNull(10_000) { scope.coroutineContext.job.cancelAndJoin() } }
		executor.shutdownNow()
		directory.deleteRecursively()
	}
}
