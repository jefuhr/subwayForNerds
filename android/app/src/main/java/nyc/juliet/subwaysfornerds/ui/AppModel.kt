package nyc.juliet.subwaysfornerds.ui

import androidx.compose.runtime.Stable
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.structuralEqualityPolicy
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import nyc.juliet.subwaysfornerds.core.Board
import nyc.juliet.subwaysfornerds.core.CombinedStation
import nyc.juliet.subwaysfornerds.core.Departure
import nyc.juliet.subwaysfornerds.core.DeviceNetworkStatus
import nyc.juliet.subwaysfornerds.core.Display
import nyc.juliet.subwaysfornerds.core.NerdsCodec
import nyc.juliet.subwaysfornerds.core.NerdsFile
import nyc.juliet.subwaysfornerds.core.NetworkActivityState
import nyc.juliet.subwaysfornerds.core.OfflineEndpoint
import nyc.juliet.subwaysfornerds.core.OfflineIdentity
import nyc.juliet.subwaysfornerds.core.OfflineSettings
import nyc.juliet.subwaysfornerds.core.PRODUCTION_API_BASE
import nyc.juliet.subwaysfornerds.core.Settings
import nyc.juliet.subwaysfornerds.core.SettingsException
import nyc.juliet.subwaysfornerds.core.SettingsMerge
import nyc.juliet.subwaysfornerds.core.Station
import nyc.juliet.subwaysfornerds.core.StationLocation
import nyc.juliet.subwaysfornerds.core.StationSelection
import nyc.juliet.subwaysfornerds.core.StationSettings
import nyc.juliet.subwaysfornerds.core.SystemRuntimeStatus
import nyc.juliet.subwaysfornerds.core.TrainFavorites
import nyc.juliet.subwaysfornerds.core.TransferFilter
import nyc.juliet.subwaysfornerds.core.TransferResult
import nyc.juliet.subwaysfornerds.core.TripDetail
import nyc.juliet.subwaysfornerds.core.WidgetDisplay
import nyc.juliet.subwaysfornerds.core.WidgetSettings
import nyc.juliet.subwaysfornerds.core.WidgetStationSelection
import nyc.juliet.subwaysfornerds.core.LockScreenSettings
import nyc.juliet.subwaysfornerds.core.LoadProgress
import nyc.juliet.subwaysfornerds.core.TransitException
import nyc.juliet.subwaysfornerds.data.ActiveRideRecord
import nyc.juliet.subwaysfornerds.data.AndroidTransitCache
import nyc.juliet.subwaysfornerds.data.CacheFailure
import nyc.juliet.subwaysfornerds.data.CacheUsage
import nyc.juliet.subwaysfornerds.data.CachedTrip
import nyc.juliet.subwaysfornerds.data.OfflineFetchOutcome
import nyc.juliet.subwaysfornerds.data.OfflineFetchPriority
import nyc.juliet.subwaysfornerds.data.OfflineFetchRequest
import nyc.juliet.subwaysfornerds.data.OfflineFetchTarget
import nyc.juliet.subwaysfornerds.data.OfflinePlanner
import nyc.juliet.subwaysfornerds.data.SyncBaseline
import nyc.juliet.subwaysfornerds.data.TransitRefreshCoordinator
import nyc.juliet.subwaysfornerds.ui.data.FleetStorage
import nyc.juliet.subwaysfornerds.ui.data.LocationException
import nyc.juliet.subwaysfornerds.ui.data.LocationPermission
import nyc.juliet.subwaysfornerds.ui.data.LocationSource
import nyc.juliet.subwaysfornerds.ui.data.TransitService
import nyc.juliet.subwaysfornerds.ui.data.TransferSink
import nyc.juliet.subwaysfornerds.ui.data.WidgetHooks
import nyc.juliet.subwaysfornerds.ui.data.SettingsStorage
import nyc.juliet.subwaysfornerds.ui.navigation.AppNavigator
import nyc.juliet.subwaysfornerds.ui.navigation.AppTab
import nyc.juliet.subwaysfornerds.ui.navigation.Route
import nyc.juliet.subwaysfornerds.ui.map.TrackMapModel
import nyc.juliet.subwaysfornerds.ui.theme.AppTheme
import java.util.UUID

/** Latest fetched details for an open trip, and why the latest refresh failed. */
data class LiveTrip(val detail: TripDetail? = null, val failure: TripFailure? = null)

sealed interface TripFailure {
	data object NotFound : TripFailure
	data class Unavailable(val message: String) : TripFailure
}

/** How much of the selected station is saved for offline use. */
data class OfflineReadiness(
	val stationID: String? = null,
	val boardSaved: Boolean = false,
	val boardFailed: Boolean = false,
	/** Next trips per line and direction the preferences ask to keep. */
	val wanted: List<String> = emptyList(),
	val saved: Set<String> = emptySet(),
	val partial: Set<String> = emptySet(),
) {
	val savedCount: Int get() = wanted.count { it in saved }
}

/** Why the activity should show the system location dialog. */
enum class PermissionPurpose { NEARBY, STARTUP, WIDGET }

/** The optional widget background location, which starts disabled. */
data class WidgetLocationStatus(val enabled: Boolean = false, val backgroundAllowed: Boolean = false, val foregroundAllowed: Boolean = false) {
	val summary: String get() = when {
		!enabled -> "Off · widgets use your saved or app-chosen station"
		!foregroundAllowed -> "Location permission is off · widgets keep a saved station"
		!backgroundAllowed -> "Needs “Allow all the time” on the app's permission page"
		else -> "On · widgets may use a recent location"
	}
}

/** Everything the model talks to. Tests replace the network, location and widget hooks. */
class AppDependencies(
	val settingsStore: SettingsStorage,
	val cache: (endpoint: String) -> AndroidTransitCache,
	val transit: (endpoint: String) -> TransitService,
	val fleet: FleetStorage?,
	val location: LocationSource,
	val widgets: WidgetHooks,
	val clock: () -> Double = { System.currentTimeMillis() / 1000.0 },
	/** A frozen clock for deterministic screenshots and tests. */
	val fixedNow: Double? = null,
	/** Debug builds may select a development API and simulate an outage. */
	val debug: Boolean = false,
	val defaultEndpoint: String = PRODUCTION_API_BASE,
	/** Location is never used, as in the iOS SFN_DISABLE_LOCATION test setting. */
	val locationDisabled: Boolean = false,
	/** Device-local answers to one-time prompts. */
	val flags: UiFlags = UiFlags.Memory(),
	/** An API base chosen by an armed instrumentation test; never set by external intents. */
	val endpointOverride: String? = null,
	/** A fixed network state for in-process instrumentation; the device's network callback is not used. */
	val fixedConnectivity: Boolean? = null,
	/** Reads storage, memory and device health for the system status screen; called off the main thread. */
	val systemStatus: () -> SystemRuntimeStatus = { SystemRuntimeStatus() },
)

/** Device-local interface choices that are not portable settings. */
interface UiFlags {
	fun get(key: String): Boolean
	fun set(key: String, value: Boolean)

	class Memory : UiFlags {
		private val values = mutableMapOf<String, Boolean>()
		override fun get(key: String) = values[key] ?: false
		override fun set(key: String, value: Boolean) { values[key] = value }
	}

	companion object {
		const val STARTUP_LOCATION_DECLINED = "startupLocationDeclined"
		const val LOCATION_REQUESTED = "locationRequested"
	}
}

/**
 * App state and orchestration, ported from the iOS AppModel: station selection, live and
 * saved boards, combined stations, the shared refresh cadence, rides, saved trains, catalog,
 * location and portable settings. Every mutation happens on the main thread.
 */
@Stable
class AppModel(private val scope: CoroutineScope, private val deps: AppDependencies) {
	val navigator = AppNavigator()

	// MARK: Settings

	var settings by mutableStateOf(Settings()); private set
	private var durableSettings = Settings()
	var stationID by mutableStateOf("602"); private set
	var syncBaseline by mutableStateOf<SyncBaseline?>(null); private set
	var settingsError by mutableStateOf<String?>(null)
	/** The saved record could not be read; only an explicit import may replace it, and accounts never sync it. */
	var settingsUnreadable by mutableStateOf(false); private set
	var pendingImport by mutableStateOf<NerdsFile?>(null)
	var loaded by mutableStateOf(false); private set
	private val loadedSignal = kotlinx.coroutines.CompletableDeferred<Unit>()
	/** Waits until saved settings, station and sync baseline are restored (or found unreadable). */
	suspend fun awaitLoaded() = loadedSignal.await()
	/** Account sync listens for local edits. */
	var settingsDidChange: (() -> Unit)? = null

	val favorites: List<String> by derivedStateOf(structuralEqualityPolicy()) { settings.favorites }
	val theme: AppTheme get() = AppTheme.forId(settings.theme)
	val timeFormat: String get() = settings.units.time
	val distanceUnit: String get() = settings.units.distance
	val offlinePreferences: OfflineSettings get() = settings.offline
	val hiddenRoutes: List<String> by derivedStateOf(structuralEqualityPolicy()) { settings.hiddenRoutes }
	val combinedStations: Map<String, CombinedStation> by derivedStateOf(structuralEqualityPolicy()) { settings.combinedStations }
	val trainFavorites: TrainFavorites get() = settings.trainFavorites

	// MARK: Network and catalog

	var endpoint by mutableStateOf(deps.defaultEndpoint); private set
	var service: TransitService = deps.transit(deps.defaultEndpoint); private set
	private var cache: AndroidTransitCache = deps.cache(deps.defaultEndpoint)
	var stations by mutableStateOf<List<Station>>(emptyList()); private set
	var catalogError by mutableStateOf<String?>(null); private set
	var connected by mutableStateOf(true); private set
	private var networkConnected = true
	/** Set only by instrumentation fixtures; the activity then skips the device network callback. */
	val fixedConnectivity: Boolean? get() = deps.fixedConnectivity
	var outageSimulated by mutableStateOf(false); private set
	/** What the phone's default network is doing, shown wherever the app explains being offline. */
	@set:JvmName("storeDeviceNetworkStatus")
	var deviceNetworkStatus by mutableStateOf(DeviceNetworkStatus()); private set
	/** The activity's last reading of the default network; null when only connected/disconnected is known. */
	private var observedNetworkStatus: DeviceNetworkStatus? = null
	/** Boards and trips in the automatic fetch plan, counted when the plan last changed. */
	var plannedRequestCount by mutableStateOf(0); private set
	val deviceNetworkHeadline: String get() = deviceNetworkStatus.headline
	val deviceNetworkDetail: String get() = deviceNetworkStatus.detailLine(plannedRequestCount, fetchProgress.size, endpointHost)
	private val endpointHost: String? get() = runCatching { java.net.URI(endpoint).host }.getOrNull()
	/** How long the last successful catalog, board or train request took to a complete response. */
	var lastApiLatencyMs by mutableStateOf<Long?>(null); private set

	// MARK: System status

	var systemStatus by mutableStateOf(SystemRuntimeStatus()); private set
	var refreshingSystemStatus by mutableStateOf(false); private set

	// MARK: Board

	var board by mutableStateOf<Board?>(null); private set
	var boardIsCached by mutableStateOf(true); private set
	var boardError by mutableStateOf<String?>(null); private set
	/** When the displayed board came from the offline cache, the time it was saved. */
	var boardSavedAt by mutableStateOf<Double?>(null); private set
	var combinedBoard by mutableStateOf<CombinedView?>(null); private set
	private var memberBoards = mapOf<String, MemberBoard>()
	var now by mutableStateOf(deps.fixedNow ?: deps.clock()); private set
	/** Byte progress of board and trip downloads a screen is waiting on. */
	var fetchProgress by mutableStateOf<Map<OfflineFetchTarget, LoadProgress>>(emptyMap()); private set
	private val fetchTokens = mutableMapOf<OfflineFetchTarget, UUID>()

	// MARK: Location

	var nearbyLocation by mutableStateOf<StationLocation?>(null); private set
	var locationError by mutableStateOf<String?>(null); private set
	var locating by mutableStateOf(false); private set
	/** Set when the activity should ask for location permission; cleared once it answers. */
	var permissionRequest by mutableStateOf<PermissionPurpose?>(null); private set
	/** Startup location stays off until the rider allows it from the board card. */
	var startupLocationDeclined by mutableStateOf(deps.flags.get(UiFlags.STARTUP_LOCATION_DECLINED)); private set
	private var widgetLocation: StationLocation? = null
	var widgetLocationStatus by mutableStateOf(WidgetLocationStatus()); private set
	val debugBuild: Boolean get() = deps.debug

	// MARK: Offline transit

	var activeRide by mutableStateOf<ActiveRideRecord?>(null); private set
	var activeRideTrip by mutableStateOf<CachedTrip?>(null); private set
	var savedTrips by mutableStateOf<List<CachedTrip>>(emptyList()); private set
	var offlineUsage by mutableStateOf<CacheUsage?>(null); private set
	/** Steps of the first storage check, while the Offline screen has no usage to show yet. */
	var storageCheck by mutableStateOf<LoadProgress?>(null); private set
	private var storageCheckToken: UUID? = null
	var offlineFailures by mutableStateOf<List<CacheFailure>>(emptyList()); private set
	var offlineActionError by mutableStateOf<String?>(null)
	var readiness by mutableStateOf(OfflineReadiness()); private set
	/** Latest fetched details for trips whose details are open, kept after the connection drops. */
	var liveTrips by mutableStateOf<Map<String, LiveTrip>>(emptyMap()); private set
	private val openTrips = mutableMapOf<String, Int>()
	/** Trips fetched as automatic next-trip snapshots, stored regardless of "save opened trips". */
	private var snapshotKeys = setOf<String>()
	/** Favorite and nearby boards fetched in the background, kept only when other-station trips are preloaded. */
	private var surroundingBoards = mapOf<String, Board>()

	// MARK: Station pages (web StationPager parity)

	/** A non-favorite station browsed this visit keeps its own page until favorited. */
	var temporaryStation by mutableStateOf<String?>(null); private set
	/** The one startup fix that ordered favorite pages by distance. */
	private var visitLocation by mutableStateOf<StationLocation?>(null)
	/** Pages stop reordering once the rider starts browsing them. */
	private var browsing = false
	/** A widget link that arrived before saved settings finished loading. */
	private var pendingStationLink: String? = null
	/** Board groups showing every train rather than the first five. */
	var expandedGroups by mutableStateOf<Set<String>>(emptySet()); private set
	fun toggleGroupExpanded(id: String) { expandedGroups = if (id in expandedGroups) expandedGroups - id else expandedGroups + id }

	// MARK: Lifecycle bookkeeping

	private var active = false
	private var activeGeneration = 0
	private var boardGeneration = 0
	private var catalogGeneration = 0
	private var lastCatalogAttempt = 0.0
	private var favoriteStartupAttempted = false
	private var closestFavoriteJob: Job? = null
	private var restoreJob: Job? = null
	private var failuresJob: Job? = null
	private val coordinator = TransitRefreshCoordinator(scope, { request -> performFetch(request) }, { deps.fixedNow ?: deps.clock() })

	val fleet: FleetPackModel = FleetPackModel(scope, this, deps.fleet)
	/** The track map tab; it polls only while visible and while the app is in the foreground. */
	val trackMap: TrackMapModel = TrackMapModel(scope, { version, progress -> service.trackMapSnapshot(version, progress) }, { deps.fixedNow ?: deps.clock() })

	// MARK: Derived stations

	/** Catalog snapshots survive clock ticks and unrelated settings changes. */
	val allStations: List<Station> by derivedStateOf(structuralEqualityPolicy()) {
		val catalog = stations
		val definitions = combinedStations
		catalog + definitions.keys.sorted().mapNotNull { id ->
			definitions[id]?.let { CoreBridge.combinedStation(id, it.name, it.stationIDs, catalog) }
		}
	}
	val visibleStations: List<Station> by derivedStateOf(structuralEqualityPolicy()) {
		val hidden = hiddenRoutes
		val definitions = combinedStations
		val visible = stations.mapNotNull { CoreBridge.visibleStation(it, hidden) }
		visible + definitions.keys.sorted().mapNotNull { id ->
			definitions[id]?.let { CoreBridge.combinedStation(id, it.name, it.stationIDs, visible) }
		}
	}
	val station: Station? get() = board?.station ?: allStations.firstOrNull { it.id == stationID }
	val displayBoard: Board? by derivedStateOf(structuralEqualityPolicy()) { board?.let { CoreBridge.visibleBoard(it, hiddenRoutes) } }
	val cachedDepartureKeys: Set<String>? by derivedStateOf(structuralEqualityPolicy()) {
		combinedBoard?.let { combined ->
			if (!connected) combined.board.departures.map { it.key }.toSet() else combined.cachedDepartureKeys
		}
	}
	val selectedMemberIDs: List<String> get() = combinedStations[stationID]?.stationIDs ?: listOf(stationID)
	val favoriteStations: List<Station> by derivedStateOf(structuralEqualityPolicy()) {
		val visible = visibleStations
		favorites.mapNotNull { id -> visible.firstOrNull { it.id == id } }
	}
	val preference: StationSettings get() = boardPreference(stationID, settings)
	private fun boardPreference(id: String, value: Settings): StationSettings =
		value.stations[id] ?: StationSettings(view = if (value.combinedStations[id] == null) "track" else "direction")
	/** Core still checks time-sensitive membership every tick; equal groups retain their identity. */
	val departureGroups: List<DepartureSection> by derivedStateOf(structuralEqualityPolicy()) {
		val selected = preference
		displayBoard?.let { CoreBridge.groups(it, selected.direction, selected.routes, selected.view, now, boardIsCached, cachedDepartureKeys) }.orEmpty()
	}
	val isProduction: Boolean get() = OfflineEndpoint.key(endpoint) == OfflineEndpoint.productionKey
	val usesWidgetLocation: Boolean get() {
		val selection = if (settings.widgets.stationSelection.followApp) settings.stationSelection else settings.widgets.stationSelection.selection
		return selection.mode != "favorite" || favorites.isNotEmpty()
	}

	fun departureOrigin(key: String): BoardOrigin? {
		combinedBoard?.origins?.get(key)?.let { return it }
		val board = board ?: return pinnedOrigins[key]
		if (combinedBoard != null) return pinnedOrigins[key]
		val departure = board.departures.firstOrNull { it.key == key } ?: return pinnedOrigins[key]
		return BoardOrigin(board.station, departure, boardIsCached, boardSavedAt)
	}
	/** Boarding context of open trains, captured before a transfer's station board replaced their board. */
	private var pinnedOrigins = mapOf<String, BoardOrigin>()
	/**
	 * Where each open train boards, by trip, frozen when a transfer's station board opened. A
	 * captured absence stays absent, so the newly selected board is never taken as the origin.
	 */
	private var frozenBoarding = mapOf<String, BoardOrigin?>()

	/** The boarding station and row for a ride or saved train: given, frozen, or else from the current board. */
	internal fun boardingOrigin(key: String, origin: BoardOrigin?): BoardOrigin? {
		// A frozen origin lasts only while that train's screen can still be returned to.
		pruneNavigationState()
		return origin ?: if (key in frozenBoarding) frozenBoarding[key] else currentBoardOrigin(key)
	}
	private fun currentBoardOrigin(key: String): BoardOrigin? {
		val departure = boardDeparture(key) ?: return null
		val station = board?.station ?: return null
		return BoardOrigin(station, departure, boardIsCached, boardSavedAt)
	}
	fun departureIsCached(key: String): Boolean = !connected || (combinedBoard?.origins?.get(key)?.cached ?: boardIsCached)
	fun realStationIDs(ids: List<String>): List<String> = ids.flatMap { combinedStations[it]?.stationIDs ?: listOf(it) }.distinct().sorted()
	fun isTripSaved(key: String): Boolean = savedTrips.any { it.key == key }

	/** Pages for the station pager: a temporary station, favorites by distance, then the current station. */
	val stationPages: List<String> by derivedStateOf(structuralEqualityPolicy()) {
		val ordered = orderedFavoriteIDs()
		val temporary = temporaryStation?.takeIf { it !in favorites }
		buildList {
			temporary?.let { add(it) }
			addAll(ordered)
			if (stationID !in favorites && stationID != temporary) add(stationID)
		}.distinct()
	}
	private fun orderedFavoriteIDs(): List<String> {
		val saved = favoriteStations.distinctBy { it.id }
		val location = visitLocation ?: return saved.map { it.id }
		return saved.sortedBy { location.distanceMeters(it) }.map { it.id }
	}
	fun stationName(id: String): String = allStations.firstOrNull { it.id == id }?.name ?: combinedStations[id]?.name ?: "Station $id"

	init {
		// Derived state must exist before a main-immediate scope can begin restoring settings.
		scope.launch { load() }
	}

	// MARK: Loading

	private suspend fun load() {
		val snapshot = try { deps.settingsStore.snapshot() } catch (error: CancellationException) { throw error } catch (error: Exception) { null }
		if (snapshot == null) {
			settingsUnreadable = true
			settingsError = "Saved settings could not be read. Restore a .nerds backup to recover your preferences."
		}
		val loadedSettings = snapshot?.settings ?: Settings()
		settings = loadedSettings
		durableSettings = loadedSettings
		stationID = snapshot?.lastStation ?: "602"
		syncBaseline = snapshot?.baseline
		val savedEndpoint = deps.endpointOverride ?: snapshot?.apiBase?.takeIf { deps.debug }
		savedEndpoint?.let { saved ->
			if (saved != endpoint) { endpoint = saved; service = deps.transit(saved); cache = deps.cache(saved) }
		}
		temporaryStation = stationID.takeIf { it !in favorites }
		stations = runCatching { cache.catalog() }.getOrDefault(emptyList())
		loaded = true
		watchFailures()
		// Assigned before the signal, so foreground startup can wait for restoration.
		restoreJob = scope.launch { restoreOffline() }
		loadedSignal.complete(Unit)
		pendingStationLink?.let { pendingStationLink = null; openStationLink(it) }
		loadCachedBoard(stationID)
		planOffline()
		deps.widgets.settingsChanged()
	}

	private fun watchFailures() {
		failuresJob?.cancel()
		val watched = cache
		failuresJob = scope.launch { watched.failures.collect { if (watched === cache) offlineFailures = it } }
	}

	// MARK: Selection

	/** An explicit station choice. It always takes priority over automatic selection. */
	fun selectStation(id: String, fromPager: Boolean = false) = selectStation(id, fromPager, keepNavigation = false)

	/** `keepNavigation` leaves every tab's screens in place, for a board opened from connections. */
	private fun selectStation(id: String, fromPager: Boolean, keepNavigation: Boolean) {
		favoriteStartupAttempted = true
		browsing = true
		if (id !in favorites) temporaryStation = id
		if (!fromPager && !keepNavigation) navigator.select(AppTab.BOARD)
		if (id == stationID) return
		stationID = id
		expandedGroups = emptySet()
		boardGeneration += 1
		memberBoards = emptyMap()
		combinedBoard = null
		board = null
		boardSavedAt = null
		boardIsCached = true
		boardError = null
		// Swiping pages on a board opened from connections keeps the way back to them.
		val returning = fromPager && navigator.stack(AppTab.BOARD).lastOrNull() is Route.StationBoard
		if (!keepNavigation && !returning) navigator.clear(AppTab.BOARD)
		pruneNavigationState()
		persistLastStation()
		scope.launch { loadCachedBoard(id); refreshBoard() }
		planOffline()
	}

	/**
	 * "Open station board" from connections: selects the transfer station's normal board and keeps
	 * the train and transfer to return to. Open trains keep boarding where they were opened.
	 */
	fun openTransferStationBoard(id: String) {
		val from = navigator.tab
		val trains = AppTab.entries.flatMap { navigator.stack(it) }.filterIsInstance<Route.Train>()
		pinnedOrigins = pinnedOrigins + trains.mapNotNull { it.origin }.mapNotNull { key -> departureOrigin(key)?.let { key to it } }
		frozenBoarding = trains.filter { it.tripKey !in frozenBoarding }
			.associate { it.tripKey to (it.origin?.let(::departureOrigin) ?: currentBoardOrigin(it.tripKey)) } + frozenBoarding
		selectStation(id, fromPager = false, keepNavigation = true)
		navigator.openStationBoard(id, from)
		pruneNavigationState()
	}

	/** Latest connections per open transfer screen, so returning shows rows at once while refreshing. */
	private var transferResults = mapOf<Route.Transfers, TransferResult>()
	fun rememberedTransfers(route: Route.Transfers): TransferResult? = transferResults[route]
	fun rememberTransfers(route: Route.Transfers, value: TransferResult) {
		pruneNavigationState()
		transferResults = transferResults + (route to value)
	}

	/** Captured origins and connections are kept only while a screen that uses them can be returned to. */
	private fun pruneNavigationState() {
		val routes = AppTab.entries.flatMap { navigator.stack(it) } + navigator.overlays
		val origins = routes.filterIsInstance<Route.Train>().mapNotNull { it.origin }.toSet()
		pinnedOrigins = pinnedOrigins.filterKeys { it in origins }
		val trips = routes.filterIsInstance<Route.Train>().map { it.tripKey }.toSet()
		frozenBoarding = frozenBoarding.filterKeys { it in trips }
		transferResults = transferResults.filterKeys { it in routes }
	}

	fun toggleFavorite(id: String) {
		browsing = true
		if (id in favorites && id == stationID) temporaryStation = id
		if (id !in favorites && temporaryStation == id) temporaryStation = null
		updateSettings { it.copy(favorites = if (id in it.favorites) it.favorites - id else it.favorites + id) }
		planOffline()
	}
	fun toggleFavoriteCar(id: String) {
		if (!TrainFavorites.validCarID(id)) return
		updateSettings { value -> val cars = value.trainFavorites.cars; value.copy(trainFavorites = value.trainFavorites.copy(cars = if (id in cars) cars - id else cars + id)) }
	}
	fun toggleFavoriteConsist(ids: List<String>) {
		if (ids.size !in 1..20 || ids.distinct().size != ids.size || !ids.all(TrainFavorites::validCarID)) return
		updateSettings { value ->
			val favorites = value.trainFavorites
			val key = TrainFavorites.consistKey(ids)
			val consists = if (favorites.containsConsist(ids)) favorites.consists.filter { TrainFavorites.consistKey(it) != key } else favorites.consists + listOf(ids.sorted())
			value.copy(trainFavorites = favorites.copy(consists = consists))
		}
	}
	fun setDistanceUnit(value: String) = updateSettings { it.copy(units = it.units.copy(distance = value)) }
	fun setTimeFormat(value: String) = updateSettings { it.copy(units = it.units.copy(time = value)) }
	fun setTrainMatch(value: String) = updateSettings { it.copy(trainFavorites = it.trainFavorites.copy(match = value)) }
	fun setStationSelection(value: StationSelection) {
		// A settings change must not let an older startup location request navigate.
		favoriteStartupAttempted = true
		updateSettings { it.copy(stationSelection = value) }
	}
	fun setWidgetStationSelection(value: WidgetStationSelection) = updateSettings { it.copy(widgets = it.widgets.copy(stationSelection = value)) }
	fun setTheme(id: String) = updateSettings { it.copy(theme = id) }

	private fun updatePreference(change: (StationSettings) -> StationSettings) {
		val id = stationID
		val value = change(preference)
		updateSettings { it.copy(stations = it.stations + (id to value)) }
	}
	fun setDirection(direction: String) = updatePreference { it.copy(direction = direction) }
	fun toggleRoute(route: String) = updatePreference { it.copy(routes = if (route in it.routes) it.routes - route else it.routes + route) }
	fun setBoardView(view: String) = updatePreference { it.copy(view = view) }
	/** Resetting filters keeps the station's chosen board view. */
	fun resetFilters() = updatePreference { StationSettings(view = it.view) }
	fun clearRoutes() = updatePreference { it.copy(routes = emptyList()) }

	// MARK: Transfer filters

	fun setSeparateTransferFilters(value: Boolean) = updateSettings { it.copy(transfers = it.transfers.copy(separateFilters = value)) }

	/**
	 * Filters for connections at a transfer station, keyed by that station and never by the
	 * selected board. Shared mode uses the station's board filters; separate mode its own entry,
	 * or the board filters until the entry is first saved.
	 */
	fun transferFilter(stationID: String): TransferFilter = transferFilter(stationID, settings)
	private fun transferFilter(id: String, value: Settings): TransferFilter {
		if (value.transfers.separateFilters) value.transfers.stations[id]?.let { return it }
		return boardPreference(id, value).let { TransferFilter(it.direction, it.routes) }
	}

	/** Separate mode copies a transfer station's board filters once, when its connections are first shown. */
	fun useTransferFilter(stationID: String) = updateSettings { seeded(it, stationID) }
	private fun seeded(value: Settings, id: String): Settings =
		if (!value.transfers.separateFilters || id in value.transfers.stations) value
		else value.copy(transfers = value.transfers.copy(stations = value.transfers.stations + (id to transferFilter(id, value))))

	private fun updateTransferFilter(stationID: String, change: (TransferFilter) -> TransferFilter) = updateSettings { value ->
		if (value.transfers.separateFilters) {
			val next = change(transferFilter(stationID, value))
			value.copy(transfers = value.transfers.copy(stations = value.transfers.stations + (stationID to next)))
		} else {
			// Shared mode edits the station's own board filters and keeps its board view.
			val board = boardPreference(stationID, value)
			val next = change(TransferFilter(board.direction, board.routes))
			value.copy(stations = value.stations + (stationID to board.copy(direction = next.direction, routes = next.routes)))
		}
	}
	fun setTransferDirection(stationID: String, direction: String) = updateTransferFilter(stationID) { it.copy(direction = direction) }
	/** Chips show display lines, so an imported alias such as GS is selected, and cleared, by its S chip. */
	fun toggleTransferRoute(stationID: String, route: String) = updateTransferFilter(stationID) { filter ->
		val line = Display.displayRoute(route)
		val selected = filter.routes.filter { Display.displayRoute(it) == line }
		filter.copy(routes = if (selected.isNotEmpty()) filter.routes - selected.toSet() else filter.routes + line)
	}
	fun clearTransferRoutes(stationID: String) = updateTransferFilter(stationID) { it.copy(routes = emptyList()) }
	fun resetTransferFilters(stationID: String) = updateTransferFilter(stationID) { TransferFilter() }

	// MARK: Widget preferences

	fun setWidgetDisplay(value: WidgetDisplay) = updateSettings { it.copy(widgets = it.widgets.copy(display = value)) }
	fun setWidgetLockScreen(value: LockScreenSettings) = updateSettings { it.copy(widgets = it.widgets.copy(lockScreen = value)) }
	fun setWidgetMatchApp(value: Boolean) = updateSettings { it.copy(widgets = it.widgets.copy(matchAppFilters = value)) }
	private fun widgetPreference(id: String, widgets: WidgetSettings): StationSettings = widgets.stations[id] ?: StationSettings(view = "direction")
	fun setWidgetView(view: String, stationID: String) = updateSettings { value ->
		value.copy(widgets = value.widgets.copy(stations = value.widgets.stations + (stationID to widgetPreference(stationID, value.widgets).copy(view = view))))
	}
	fun setWidgetRoute(route: String, enabled: Boolean, stationID: String) = updateSettings { value ->
		val current = widgetPreference(stationID, value.widgets)
		if ((route in current.routes) == enabled) value
		else value.copy(widgets = value.widgets.copy(stations = value.widgets.stations + (stationID to current.copy(routes = if (enabled) current.routes + route else current.routes - route))))
	}
	fun clearWidgetRoutes(stationID: String) = updateSettings { value ->
		value.copy(widgets = value.widgets.copy(stations = value.widgets.stations + (stationID to widgetPreference(stationID, value.widgets).copy(routes = emptyList()))))
	}

	// MARK: Lines and combined stations

	val allLineKeys: List<String> get() = (stations.flatMap { it.routes } + hiddenRoutes + (board?.departures?.map { it.route } ?: emptyList()))
		.map(CoreBridge::lineKey).distinct().sortedWith(NaturalOrder)
	fun setLine(route: String, enabled: Boolean) {
		val key = CoreBridge.lineKey(route)
		setHiddenLines(if (enabled) hiddenRoutes.filter { CoreBridge.lineKey(it) != key } else hiddenRoutes + key)
	}
	fun setHiddenLines(routes: List<String>) {
		val keys = routes.map(CoreBridge::lineKey).distinct().sorted()
		scope.launch {
			try {
				acceptSettings(sync = syncBaseline, notify = true) { it.copy(hiddenRoutes = keys) }
				favoriteStartupAttempted = true
			} catch (error: CancellationException) { throw error }
			catch (error: Exception) { settingsError = saveFailure(error) }
		}
	}

	/** Saves a combined station and opens its board. Returns its ID; throws when it cannot be saved. */
	suspend fun saveCombinedStation(id: String?, name: String, stationIDs: List<String>): String {
		val key = id ?: "combined:" + UUID.randomUUID().toString().lowercase()
		acceptSettings(lastStation = key, sync = syncBaseline, notify = true) { current ->
			val next = current.copy(combinedStations = current.combinedStations + (key to CombinedStation(name.trim(), stationIDs.distinct().sorted())))
			if (id == null) next.copy(stations = next.stations + (key to StationSettings(view = "direction"))) else next
		}
		navigator.select(AppTab.BOARD)
		return key
	}
	suspend fun deleteCombinedStation(id: String) {
		if (combinedStations[id] == null) return
		acceptSettings(sync = syncBaseline, notify = true) { current ->
			current.copy(
				combinedStations = current.combinedStations - id,
				favorites = current.favorites - id,
				stations = current.stations - id,
				widgets = current.widgets.copy(stations = current.widgets.stations - id),
			)
		}
	}

	// MARK: Persisting settings

	/** Ordinary saves and accepted replacements share one lock, so neither can overwrite the other out of order. */
	private val settingsWrites = Mutex()

	private fun saveFailure(error: Exception): String =
		"Settings could not be saved on this device. Your previous preferences are unchanged. " + (error.message ?: "")

	/** Applies a local edit at once and saves it; a failed save restores the previous durable value. */
	private fun updateSettings(change: (Settings) -> Settings) {
		val next = try { NerdsCodec.validate(change(settings)) } catch (error: Exception) { settingsError = error.message; return }
		if (next == settings) return
		if (settingsUnreadable) {
			settingsError = "Saved settings could not be read. Restore a .nerds backup before changing preferences."
			return
		}
		settings = next
		scope.launch { persistLocal() }
	}

	/** Saves the latest local settings, whatever edits arrived while earlier saves were running. */
	private suspend fun persistLocal() {
		var offlineChanged = false
		var saved = false
		settingsWrites.withLock {
			val value = settings
			if (value == durableSettings) return@withLock
			try {
				deps.settingsStore.save(value)
				offlineChanged = durableSettings.offline != value.offline
				durableSettings = value
				saved = true
				if (settingsError?.startsWith("Settings could not be saved") == true) settingsError = null
			} catch (error: CancellationException) { throw error }
			catch (error: Exception) {
				if (settings == value) settings = durableSettings
				settingsError = saveFailure(error)
			}
		}
		if (!saved) return
		settingsDidChange?.invoke()
		deps.widgets.settingsChanged()
		if (offlineChanged) offlinePreferencesChanged()
	}

	fun setOfflinePreferences(value: OfflineSettings) {
		val bounded = value.copy(tripDetailsPerLineDirection = minOf(value.tripDetailsPerLineDirection, value.departuresPerLineDirection))
		updateSettings { it.copy(offline = bounded) }
		if (!bounded.preloadOtherStationTrips) surroundingBoards = emptyMap()
		planOffline()
	}

	private suspend fun offlinePreferencesChanged() {
		runCatching { cache.setPreferences(offlinePreferences) }
		runCatching { cache.prune() }
		reloadOfflineStatus()
	}

	suspend fun acceptSettings(next: Settings, lastStation: String? = null, sync: SyncBaseline?, notify: Boolean = false, replacingUnreadable: Boolean = false) =
		acceptSettings(lastStation, sync, notify, replacingUnreadable) { next }

	/**
	 * Replaces settings from an import, an account merge or a structural edit. Settings, the
	 * station and the sync baseline are saved together first; nothing is published unless that
	 * succeeds, so a failure keeps the previous durable values and throws. `compute` receives the
	 * current local settings inside the save lock. The selected station falls back to a visible
	 * member when its combined station disappears.
	 */
	suspend fun acceptSettings(lastStation: String? = null, sync: SyncBaseline?, notify: Boolean = false, replacingUnreadable: Boolean = false, compute: (Settings) -> Settings) {
		var offlineChanged = false
		settingsWrites.withLock {
			if (settingsUnreadable && !replacingUnreadable) throw SettingsException("Saved settings could not be read. Restore a .nerds backup first.")
			val before = settings
			val valid = NerdsCodec.validate(compute(before))
			val savedStation = stationFor(lastStation ?: stationID, valid)
			deps.settingsStore.saveAccepted(valid, savedStation, sync, replacingUnreadable)
			// A local edit made while saving stays on top of the accepted settings and saves next.
			val current = settings
			val published = if (current == before) valid else runCatching { NerdsCodec.validate(SettingsMerge.merge(before, current, valid).settings) }.getOrDefault(valid)
			// Read the latest tap after storage returns, then publish without another suspension.
			// A follow-up write belongs to the serialized queue and must never publish an old tap.
			val selected = stationFor(lastStation ?: stationID, published)
			val definitionChanged = combinedStations[selected] != published.combinedStations[selected]
			offlineChanged = durableSettings.offline != valid.offline
			settingsUnreadable = false
			settings = published
			durableSettings = valid
			syncBaseline = sync
			settingsError = null
			if (lastStation != null) favoriteStartupAttempted = true
			if (selected != stationID || definitionChanged) {
				stationID = selected
				favoriteStartupAttempted = true
				boardGeneration += 1
				memberBoards = emptyMap()
				combinedBoard = null
				board = null; boardSavedAt = null; boardIsCached = true; boardError = null
				if (selected !in valid.favorites) temporaryStation = selected
				scope.launch { loadCachedBoard(selected); refreshBoard() }
			}
			if (selected != savedStation) persistLastStation()
			if (published != valid) scope.launch { persistLocal() }
		}
		if (offlineChanged) offlinePreferencesChanged()
		deps.widgets.settingsChanged()
		if (notify) settingsDidChange?.invoke()
		planOffline()
	}

	/** The station to keep under `valid`: a removed combined station falls back to a visible member. */
	private fun stationFor(id: String, valid: Settings): String {
		if (!id.startsWith("combined:") || valid.combinedStations[id] != null) return id
		val visible = stations.mapNotNull { CoreBridge.visibleStation(it, valid.hiddenRoutes) }
		return combinedStations[id]?.stationIDs?.firstOrNull { member -> visible.any { it.id == member } } ?: visible.firstOrNull()?.id ?: stations.firstOrNull()?.id ?: "602"
	}

	/**
	 * Saves the selected station after any acceptance in progress, so an older accepted station can't
	 * overwrite a newer choice. It saves whatever is selected when its turn comes.
	 */
	private fun persistLastStation() {
		scope.launch { settingsWrites.withLock { runCatching { deps.settingsStore.saveLastStation(stationID) } } }
	}

	/** A `.nerds` file chosen in the importer or opened from another app. Shows a preview first. */
	fun previewSettingsFile(text: String?, error: String? = null) {
		navigator.select(AppTab.SETTINGS)
		if (text == null) { settingsError = error ?: "Choose a .nerds settings file."; return }
		try {
			pendingImport = NerdsCodec.decode(text)
			settingsError = null
			navigator.push(Route.ImportPreview)
		} catch (failure: Exception) {
			settingsError = (failure as? SettingsException)?.message ?: "This settings file could not be read. Choose a valid .nerds file."
		}
	}
	/** Replaces this device's settings with a previewed file. Throws, keeping the preview, if saving fails. */
	suspend fun importSettings(file: NerdsFile) {
		acceptSettings(lastStation = file.lastStation, sync = syncBaseline, notify = true, replacingUnreadable = true) { file.settings }
		pendingImport = null
	}
	fun cancelImport() { pendingImport = null }
	fun exportSettings(): String = NerdsCodec.encode(settings, stationID)

	// MARK: Endpoint (debug)

	fun useEndpoint(value: String) {
		val cleaned = value.trim()
		val url = runCatching { java.net.URI(cleaned) }.getOrNull()
		if (url == null || url.scheme?.lowercase() !in setOf("http", "https") || url.host == null || url.userInfo != null || url.query != null || url.fragment != null) {
			throw IllegalArgumentException("Enter a complete HTTP or HTTPS API URL, including its /api/v1/ path.")
		}
		val normalized = if (cleaned.endsWith("/")) cleaned else "$cleaned/"
		endpoint = normalized
		boardGeneration += 1; catalogGeneration += 1
		memberBoards = emptyMap(); combinedBoard = null
		service = deps.transit(normalized)
		cache = deps.cache(normalized)
		watchFailures()
		boardIsCached = true
		fleet.endpointChanged()
		trackMap.endpointChanged()
		lastCatalogAttempt = 0.0
		// Cached content belongs to one endpoint; restore this endpoint's ride and boards.
		board = null; boardSavedAt = null; activeRide = null; activeRideTrip = null; savedTrips = emptyList(); surroundingBoards = emptyMap(); liveTrips = emptyMap()
		readiness = OfflineReadiness()
		scope.launch {
			runCatching { deps.settingsStore.saveApiBase(normalized) }
			restoreOffline(); planOffline()
			refreshCatalog(); refreshBoard()
		}
	}

	fun setSimulatedOutage(value: Boolean) {
		if (value == outageSimulated) return
		outageSimulated = value
		publishNetworkStatus()
		scope.launch { connectionChanged() }
	}

	// MARK: Lifecycle

	/** Runs while the app is in the foreground; cancelled when it leaves. */
	suspend fun runWhileActive() {
		activeGeneration += 1
		val generation = activeGeneration
		try {
			// Nothing starts from defaults: the saved endpoint, station and preferences come first.
			awaitLoaded()
			deps.fleet?.setForeground(true)
			refreshLocationStatus()
			fleet.refreshManifest()
			restoreJob?.join()
			expireOfflineEntries()
			if (generation != activeGeneration) return
			// Reconnect callbacks cannot start requests until the saved endpoint and offline state exist.
			active = true
			coordinator.setConnected(connected)
			coordinator.setForeground(true)
			trackMap.setForeground(true)
			planOffline()
			coroutineScope {
				launch { clockLoop() }
				launch { loadInitialCatalog() }
				launch { widgetLocationLoop() }
				launch { refreshBoard() }
			}
		} finally {
			if (activeGeneration == generation) { active = false; trackMap.setForeground(false) }
		}
	}

	/** The app left the foreground. Prefetch pauses; a new visit starts at the closest favorite again. */
	fun suspend() {
		active = false
		activeGeneration += 1
		// Fleet downloads are foreground-bound; leaving cancels one and keeps the previous saved fleet.
		fleet.leavingForeground()
		deps.fleet?.setForeground(false)
		scope.launch { coordinator.setForeground(false) }
		trackMap.setForeground(false)
		favoriteStartupAttempted = false
		browsing = false
		closestFavoriteJob?.cancel()
		closestFavoriteJob = null
	}

	/** The device's default network changed. Without [status], the shown status follows [value] alone. */
	fun setNetworkConnected(value: Boolean, status: DeviceNetworkStatus? = null) {
		networkConnected = value
		observedNetworkStatus = status
		publishNetworkStatus()
		scope.launch { connectionChanged() }
	}

	/** A new reading of the default network that does not change whether the app is online. */
	fun setDeviceNetworkStatus(status: DeviceNetworkStatus) {
		observedNetworkStatus = status
		publishNetworkStatus()
	}

	private fun publishNetworkStatus() {
		val base = observedNetworkStatus ?: if (networkConnected) DeviceNetworkStatus() else DeviceNetworkStatus(state = NetworkActivityState.SEARCHING, validated = false)
		deviceNetworkStatus = if (outageSimulated) base.copy(state = NetworkActivityState.SIMULATED_OUTAGE) else base
	}

	private suspend fun connectionChanged() {
		val isConnected = networkConnected && !outageSimulated
		if (isConnected == connected) return
		connected = isConnected
		trackMap.setConnected(isConnected)
		// Reconnecting makes every tracked fetch due at once (recovery refresh).
		coordinator.setConnected(isConnected)
		if (!active) return
		if (isConnected) {
			coroutineScope {
				launch { refreshCatalog(force = true) }
				launch { refreshBoard() }
			}
		} else showSavedBoard(stationID)
	}

	private suspend fun clockLoop() {
		while (currentCoroutineActive()) {
			now = deps.fixedNow ?: deps.clock()
			delay(1000)
		}
	}
	private suspend fun currentCoroutineActive(): Boolean = kotlin.coroutines.coroutineContext.isActive

	private suspend fun loadInitialCatalog() {
		coroutineScope {
			val catalog = async { refreshCatalog() }
			// Saved catalogs can choose the closest favorite without waiting for the network.
			openClosestFavoriteOnce()
			catalog.await()
		}
	}

	private suspend fun widgetLocationLoop() {
		while (currentCoroutineActive()) {
			refreshWidgetLocation()
			delay(30_000)
		}
	}

	/** Keeps the widget's closest station current while the app is in use, without prompting. */
	private suspend fun refreshWidgetLocation() {
		if (!active || deps.locationDisabled || !usesWidgetLocation) return
		if (deps.location.foregroundPermission() != LocationPermission.GRANTED) return
		runCatching { currentLocation() }
	}

	// MARK: Catalog

	suspend fun refreshCatalog(force: Boolean = false) {
		val attempt = deps.clock()
		if (!force && attempt - lastCatalogAttempt <= 5) return
		lastCatalogAttempt = attempt
		catalogGeneration += 1
		val generation = catalogGeneration
		val requested = endpoint
		try {
			val value = timed { service.stations() }
			if (generation != catalogGeneration || requested != endpoint) return
			stations = value
			rebuildCombinedBoard()
			runCatching { cache.saveCatalog(value) }
			deps.widgets.settingsChanged()
			catalogError = null
			if (active) openClosestFavoriteOnce()
		} catch (error: CancellationException) { throw error }
		catch (_: Exception) {
			if (generation == catalogGeneration && requested == endpoint) catalogError = "Station catalog unavailable. Saved stations remain available; reconnect to load every station."
		}
	}

	// MARK: Boards

	/** Fetches the selected board now, ahead of automatic work. Returns at once without a connection. */
	suspend fun refreshBoard() {
		if (!loaded) return
		val id = stationID
		if (combinedStations[id] != null) {
			loadCachedBoard(id)
			val requested = endpoint
			val members = selectedMemberIDs.filter { member -> stations.any { it.id == member && (it.departureMode != "external" || it.isNjt) } }
			coroutineScope {
				members.forEach { member -> launch { coordinator.request(OfflineFetchRequest(requested, OfflineFetchTarget.Board(member), OfflineFetchPriority.EXPLICIT)) } }
			}
			if (id == stationID && requested == endpoint) rebuildCombinedBoard()
			return
		}
		// External directory stations are skipped, but NJT stations get one request that can discover configured predictions.
		val current = station
		if (current != null && current.departureMode == "external" && !current.isNjt && board?.njt?.configured != true) return
		val outcome = coordinator.request(OfflineFetchRequest(endpoint, OfflineFetchTarget.Board(id), OfflineFetchPriority.EXPLICIT))
		if (outcome == OfflineFetchOutcome.PAUSED && id == stationID) showSavedBoard(id)
	}

	/** Shows a station's saved board until a live one arrives. Never replaces live data. */
	suspend fun loadCachedBoard(id: String) {
		val requested = endpoint
		val definition = combinedStations[id]
		if (definition != null) {
			val generation = boardGeneration
			for (member in definition.stationIDs) {
				val cached = runCatching { cache.boardSnapshot(member) }.getOrNull()
				if (id != stationID || generation != boardGeneration || requested != endpoint || combinedStations[id] != definition) return
				if (memberBoards[member]?.board == null && cached != null) {
					memberBoards = memberBoards + (member to MemberBoard(cached.board.station, cached.board, cached = true, savedAt = cached.savedAt))
				}
			}
			rebuildCombinedBoard()
			return
		}
		val cached = runCatching { cache.boardSnapshot(id) }.getOrNull() ?: return
		if (id != stationID || requested != endpoint) return
		if (board != null && !(boardIsCached && board?.station?.id != id)) return
		board = cached.board
		boardSavedAt = cached.savedAt
		boardIsCached = true
		updateReadiness()
	}

	/** Keeps the board on screen as offline estimates when it cannot be refreshed. */
	private suspend fun showSavedBoard(id: String) {
		if (combinedStations[id] != null) {
			if (id != stationID) return
			memberBoards = memberBoards.mapValues { it.value.copy(cached = true) }
			loadCachedBoard(id)
			rebuildCombinedBoard()
			return
		}
		boardIsCached = true
		if (board == null) loadCachedBoard(id)
		if (id != stationID) return
		boardError = if (board == null) {
			if (connected) "Could not reach the train feed. Pull to retry or choose a saved station." else "No connection and no saved board for this station. Choose a saved station or reconnect."
		} else {
			if (connected) "Showing a saved board. Reconnect for current predictions." else "No connection. Showing a saved board; times are offline estimates."
		}
	}

	private fun rebuildCombinedBoard() {
		val definition = combinedStations[stationID] ?: return
		val combinedStation = CoreBridge.combinedStation(stationID, definition.name, definition.stationIDs, stations)
			?: Station(stationID, definition.name, "", lat = 0.0, lon = 0.0)
		val members = definition.stationIDs.map { id ->
			memberBoards[id] ?: run {
				val member = stations.firstOrNull { it.id == id }
				MemberBoard(
					member ?: Station(id, id, "", lat = 0.0, lon = 0.0), null, cached = true,
					error = when {
						member == null -> "Station missing from catalog"
						member.departureMode == "external" && !member.isNjt -> "Use official departure tools"
						connected -> "Loading departures…"
						else -> "No saved board"
					},
				)
			}
		}
		val value = CoreBridge.combine(combinedStation, members)
		combinedBoard = value
		board = value.board
		boardIsCached = !connected || members.none { it.board != null && !it.cached }
		boardError = value.warnings.takeIf { it.isNotEmpty() }?.joinToString("\n")
		val supported = members.filter { it.station.departureMode != "external" || it.station.isNjt }
		boardSavedAt = if (supported.isNotEmpty() && supported.all { it.savedAt != null }) supported.mapNotNull { it.savedAt }.minOrNull() else null
		updateReadiness()
		readiness = readiness.copy(boardSaved = boardSavedAt != null)
	}

	/** The bar shown before the selected station has any departures on screen. */
	val boardLoad: LoadProgress get() {
		val subject = station?.let { "departures for ${it.name}" } ?: "departures"
		return fetchProgress[OfflineFetchTarget.Board(stationID)] ?: waitingLoad(subject, connected, deviceNetworkStatus)
	}
	/** The bar shown while an open train has no details yet. */
	fun tripLoad(key: String): LoadProgress = fetchProgress[OfflineFetchTarget.Trip(key)] ?: waitingLoad("train details", connected, deviceNetworkStatus)

	// MARK: Trips

	/** Fetches a trip now, for opening details or pulling to refresh. */
	suspend fun refreshTrip(key: String): OfflineFetchOutcome =
		coordinator.request(OfflineFetchRequest(endpoint, OfflineFetchTarget.Trip(key), OfflineFetchPriority.EXPLICIT))

	/** Train details register for their lifetime so fetched details stay available offline. */
	fun openTrip(key: String) {
		openTrips[key] = (openTrips[key] ?: 0) + 1
		if (openTrips[key] == 1) planOffline()
	}
	fun closeTrip(key: String) {
		val count = openTrips[key] ?: return
		if (count > 1) { openTrips[key] = count - 1; return }
		openTrips.remove(key)
		liveTrips = liveTrips - key
		planOffline()
	}

	suspend fun cachedTrip(key: String): CachedTrip? = runCatching { cache.tripSnapshot(key) }.getOrNull()

	/** "Save trip offline": kept until removed. Without details, the board's onward stops are saved as a labeled partial trip. */
	suspend fun saveTripOffline(key: String, detail: TripDetail?, origin: BoardOrigin? = null) {
		val requested = endpoint
		try {
			if (detail != null) cache.saveTrip(detail, manual = true)
			else if (cache.tripSnapshot(key) == null) {
				val boarding = boardingOrigin(key, origin) ?: throw IllegalStateException("No train details are available to save yet. Reconnect and try again.")
				cache.saveDeparture(boarding.departure, boarding.station, manual = true)
			}
			cache.setManuallySaved(key, true)
			if (requested == endpoint) offlineActionError = null
		} catch (error: CancellationException) { throw error }
		catch (error: Exception) { if (requested == endpoint) offlineActionError = "Could not save this train offline. " + (error.message ?: "") }
		reloadOfflineStatus()
	}

	/** Explicit removal from the saved list. The snapshot may then expire automatically. */
	suspend fun removeSavedTrip(key: String) {
		try { cache.setManuallySaved(key, false); offlineActionError = null }
		catch (error: CancellationException) { throw error }
		catch (error: Exception) { offlineActionError = "Could not remove this saved train. " + (error.message ?: "") }
		reloadOfflineStatus()
	}

	/** "I'm on this train": one active ride, protected across relaunch until ended. */
	suspend fun startRide(key: String, detail: TripDetail?, origin: BoardOrigin? = null) {
		if (OfflineIdentity.isPositionalTrip(key)) {
			offlineActionError = "PATH reports identify a station arrival, not one train, so rides can't follow them."
			return
		}
		val requested = endpoint
		val boarding = boardingOrigin(key, origin)
		try {
			if (detail != null) cache.saveTrip(detail)
			else if (cache.tripSnapshot(key) == null && boarding != null) cache.saveDeparture(boarding.departure, boarding.station)
			cache.setActiveRide(key)
			val ride = cache.activeRideRecord()
			val trip = cache.tripSnapshot(key)
			if (requested != endpoint) return
			activeRide = ride
			activeRideTrip = trip
			offlineActionError = null
		} catch (error: CancellationException) { throw error }
		catch (error: Exception) { offlineActionError = "Could not start this ride. " + (error.message ?: "") }
		deps.widgets.settingsChanged()
		planOffline()
		reloadOfflineStatus()
	}

	suspend fun endRide() {
		try {
			cache.setActiveRide(null)
			activeRide = null
			activeRideTrip = null
			offlineActionError = null
		} catch (error: CancellationException) { throw error }
		catch (error: Exception) { offlineActionError = "Could not end this ride. " + (error.message ?: "") }
		deps.widgets.settingsChanged()
		planOffline()
		reloadOfflineStatus()
	}

	/** Clears automatic boards and trips for this endpoint. Saved trains and the ride are kept. */
	suspend fun removeAutomaticOfflineData() {
		try { cache.clearAutomatic(); offlineActionError = null }
		catch (error: CancellationException) { throw error }
		catch (error: Exception) { offlineActionError = "Could not clear automatic downloads. " + (error.message ?: "") }
		surroundingBoards = emptyMap()
		reloadOfflineStatus()
	}

	fun dismissOfflineFailures() { cache.clearFailures() }

	private fun boardDeparture(key: String): Departure? {
		val departure = board?.departures?.firstOrNull { it.tripKey == key } ?: return null
		return combinedBoard?.origins?.get(departure.key)?.departure ?: departure
	}

	// MARK: Offline status

	/** Restores this endpoint's cached board, active ride and saved trips. */
	suspend fun restoreOffline() {
		val requested = endpoint
		runCatching { cache.setPreferences(offlinePreferences) }
		// Retention applies before anything persisted is shown, including offline relaunches.
		runCatching { cache.prune() }
		if (requested != endpoint) return
		if (board == null) loadCachedBoard(stationID)
		val ride = runCatching { cache.activeRideRecord() }.getOrNull()
		val rideTrip = ride?.let { runCatching { cache.tripSnapshot(it.key) }.getOrNull() }
		if (requested != endpoint) return
		activeRide = ride
		activeRideTrip = rideTrip
		reloadOfflineStatus()
	}

	/** Applies retention when the app returns; an expired automatic board on screen is dropped. */
	private suspend fun expireOfflineEntries() {
		val requested = endpoint
		runCatching { cache.prune() }
		val id = stationID
		if (combinedStations[id] != null) {
			for (member in selectedMemberIDs) {
				val saved = runCatching { cache.boardSnapshot(member) }.getOrNull()
				if (requested != endpoint || id != stationID) return
				val current = memberBoards[member]
				if (current?.cached == true && current.savedAt != null && saved == null) memberBoards = memberBoards - member
			}
			rebuildCombinedBoard()
			reloadOfflineStatus()
			return
		}
		val stillSaved = runCatching { cache.boardSnapshot(id) }.getOrNull() != null
		if (requested != endpoint || id != stationID) return
		if (boardIsCached && boardSavedAt != null && !stillSaved) { board = null; boardSavedAt = null }
		reloadOfflineStatus()
	}

	/** Times one API request; only a complete response updates the server response time. */
	private suspend fun <T> timed(request: suspend () -> T): T {
		val started = System.nanoTime()
		val value = request()
		val ms = (System.nanoTime() - started) / 1_000_000
		lastApiLatencyMs = ms
		systemStatus = systemStatus.copy(lastApiLatencyMs = ms)
		return value
	}

	/** Reads the device off the main thread and remeasures offline storage and the saved fleet. A failed read keeps the last one. */
	suspend fun refreshSystemStatus() {
		if (refreshingSystemStatus) return
		refreshingSystemStatus = true
		try {
			val status = withContext(Dispatchers.IO) { runCatching { deps.systemStatus() }.getOrNull() }
			if (status != null) systemStatus = status.copy(lastApiLatencyMs = lastApiLatencyMs)
			reloadOfflineStatus()
			fleet.refreshManifest()
		} finally {
			refreshingSystemStatus = false
		}
	}

	suspend fun reloadOfflineStatus() {
		val requested = endpoint
		// Only the first check shows its steps; later ones refresh numbers already on screen.
		val token = UUID.randomUUID()
		val showSteps = offlineUsage == null
		if (showSteps) { storageCheckToken = token; storageCheck = LoadProgress.step(0, 3, "Reading saved trains") }
		val saved = runCatching { cache.entries().filter { it.manual } }.getOrDefault(savedTrips)
		if (showSteps && storageCheckToken == token) storageCheck = LoadProgress.step(1, 3, "Reading save errors")
		val ride = runCatching { cache.activeRideRecord() }.getOrNull()
		if (showSteps && storageCheckToken == token) storageCheck = LoadProgress.step(2, 3, "Measuring offline storage")
		val usage = runCatching { cache.usage() }.getOrNull()
		if (showSteps && storageCheckToken == token) { storageCheck = null; storageCheckToken = null }
		if (requested != endpoint) return
		savedTrips = saved.sortedByDescending { it.savedAt }
		if (ride?.key != activeRide?.key) {
			activeRide = ride
			activeRideTrip = ride?.let { runCatching { cache.tripSnapshot(it.key) }.getOrNull() }
		}
		offlineUsage = usage
		refreshReadiness()
	}

	private fun updateReadiness() {
		if (readiness.stationID != stationID) readiness = OfflineReadiness(stationID = stationID)
		val board = board
		if (board == null || board.station.id != stationID) { readiness = readiness.copy(wanted = emptyList()); return }
		readiness = readiness.copy(
			boardSaved = readiness.boardSaved || boardSavedAt != null,
			wanted = OfflinePlanner.tripKeysToSnapshot(board, offlinePreferences),
		)
	}

	private suspend fun refreshReadiness() {
		updateReadiness()
		val wanted = readiness.wanted
		if (wanted.isEmpty()) return
		val requested = endpoint
		val id = stationID
		val saved = mutableSetOf<String>()
		val partial = mutableSetOf<String>()
		for (key in wanted) {
			val trip = runCatching { cache.tripSnapshot(key) }.getOrNull() ?: continue
			if (trip.isComplete) saved += key else partial += key
		}
		if (id != stationID || requested != endpoint) return
		readiness = readiness.copy(saved = saved, partial = partial)
	}

	/**
	 * The automatic fetch set. Only the active ride and the selected board refresh every 10 s;
	 * next-trip snapshots, favorites and boards near the viewed station use the 30 s cadence.
	 */
	fun planOffline() {
		if (!loaded) return
		val requests = plannedRequests()
		plannedRequestCount = requests.size
		updateReadiness()
		scope.launch { coordinator.updatePlan(requests) }
	}

	fun plannedRequests(): List<OfflineFetchRequest> {
		// Persistence owns the plan: selected/combined members, favorites, boards near the viewed station,
		// next-trip quotas and the ride. Eligibility includes configured NJT stations in the catalog.
		val viewed = station
		val boards = buildList {
			if (combinedStations[stationID] != null) addAll(memberBoards.values.mapNotNull { it.board })
			else board?.takeIf { it.station.id == stationID }?.let { add(it) }
			if (offlinePreferences.preloadOtherStationTrips) addAll(surroundingBoards.values)
		}
		val planned = if (viewed != null) OfflinePlanner.requests(endpoint, viewed, stations, settings, boards, activeRide, null)
		else listOfNotNull(activeRide?.key?.takeUnless(OfflineIdentity::isPositionalTrip)?.let { OfflineFetchRequest(endpoint, OfflineFetchTarget.Trip(it), OfflineFetchPriority.ACTIVE_RIDE) })
		// Every open train refreshes on the selected cadence, including details stacked under connections.
		val opened = openTrips.keys.sorted().filterNot(OfflineIdentity::isPositionalTrip).map { OfflineFetchRequest(endpoint, OfflineFetchTarget.Trip(it), OfflineFetchPriority.SELECTED) }
		val requests = (planned + opened).groupBy { it.identity }.values.map { values -> values.minBy { it.priority.ordinal } }
		// Automatic next-trip snapshots are stored even when "save trains I open" is off.
		snapshotKeys = (planned.mapNotNull { (it.target as? OfflineFetchTarget.Trip)?.key?.takeIf { _ -> it.priority == OfflineFetchPriority.BACKGROUND } }).toSet()
		return requests
	}

	/** The coordinator's only network path. Calling the public refresh methods here would deadlock. */
	private suspend fun performFetch(request: OfflineFetchRequest) {
		if (OfflineEndpoint.key(request.endpoint) != OfflineEndpoint.key(endpoint)) return
		when (val target = request.target) {
			is OfflineFetchTarget.Board -> performBoard(target.stationID)
			is OfflineFetchTarget.Trip -> performTrip(target.key)
		}
	}

	/** Only newer source data replaces a snapshot; the store keeps the previous source time otherwise. */
	private suspend fun performBoard(id: String) {
		val requested = endpoint
		val generation = boardGeneration
		val client = service
		val target = OfflineFetchTarget.Board(id)
		val subject = (stations.firstOrNull { it.id == id } ?: station?.takeIf { it.id == id })?.let { "departures for ${it.name}" } ?: "departures"
		val token = if (board == null && id == stationID) trackFetch(target) else null
		try {
			val value = timed { client.board(id, token?.let { sink(target, it, subject) }) }
			if (requested != endpoint) return
			val member = combinedStations[stationID] != null && id in selectedMemberIDs && generation == boardGeneration
			val selected = id == stationID && generation == boardGeneration
			val viewed = station
			val distance = if (member || selected) null else viewed?.let { Display.distanceMeters(it.lat, it.lon, value.station.lat, value.station.lon) }
			// The visible board is source-merged with the saved copy, untrimmed: an older or failed
			// source group keeps its last rows instead of blanking. Only the disk copy has quotas.
			val merged = try { cache.saveBoardMerged(value, if (member || selected) null else viewed?.id, distance) }
				catch (error: CancellationException) { throw error } catch (_: Exception) { null }
			val shown = merged ?: value
			val savedAt = if (merged != null) runCatching { cache.boardSnapshot(id)?.savedAt }.getOrNull() else null
			if (requested != endpoint) return
			if (member) {
				if (generation != boardGeneration || id !in selectedMemberIDs) return
				memberBoards = memberBoards + (id to MemberBoard(shown.station, shown, cached = !connected, savedAt = savedAt))
				rebuildCombinedBoard()
				deps.widgets.boardSaved(shown)
				planOffline()
				return
			}
			if (selected) {
				if (id != stationID) return
				board = shown
				boardIsCached = !connected
				boardError = null
				now = deps.fixedNow ?: deps.clock()
				if (savedAt != null) boardSavedAt = savedAt
				updateReadiness()
				readiness = readiness.copy(boardSaved = merged != null, boardFailed = merged == null)
				deps.widgets.boardSaved(shown)
				planOffline()
				refreshReadiness()
				return
			}
			if (id in realStationIDs(favorites)) deps.widgets.boardSaved(shown)
			if (offlinePreferences.preloadOtherStationTrips && surroundingBoards[id] != shown) {
				surroundingBoards = surroundingBoards + (id to shown)
				planOffline()
			}
		} catch (error: CancellationException) { throw error }
		catch (_: Exception) {
			if (combinedStations[stationID] != null && id in selectedMemberIDs && requested == endpoint && generation == boardGeneration) {
				val cached = runCatching { cache.boardSnapshot(id) }.getOrNull()
				if (requested != endpoint || generation != boardGeneration || id !in selectedMemberIDs) return
				val member = stations.firstOrNull { it.id == id }
				if (member != null) {
					val previous = memberBoards[id]
					memberBoards = memberBoards + (id to MemberBoard(member, cached?.board ?: previous?.board, cached = true, savedAt = cached?.savedAt ?: previous?.savedAt, error = "Feed unavailable"))
				}
				rebuildCombinedBoard()
				return
			}
			if (id != stationID || requested != endpoint || generation != boardGeneration) return
			showSavedBoard(id)
		} finally {
			token?.let { endFetch(target, it) }
		}
	}

	private suspend fun performTrip(key: String) {
		val requested = endpoint
		val client = service
		val target = OfflineFetchTarget.Trip(key)
		val token = if (openTrips[key] != null && liveTrips[key]?.detail == null) trackFetch(target) else null
		try {
			val value = timed { client.trip(key, token?.let { sink(target, it, "train details") }) }
			if (requested != endpoint) return
			val open = openTrips[key] != null
			if (open) liveTrips = liveTrips + (key to LiveTrip(detail = value))
			if (!OfflineIdentity.isPositionalTrip(key) && (key in snapshotKeys || activeRide?.key == key || isTripSaved(key) || open && offlinePreferences.saveOpenedTrips)) {
				runCatching { cache.saveTrip(value) }
				if (activeRide?.key == key) {
					val trip = runCatching { cache.tripSnapshot(key) }.getOrNull()
					if (requested == endpoint && activeRide?.key == key) { activeRideTrip = trip; deps.widgets.settingsChanged() }
				}
			}
		} catch (error: CancellationException) { throw error }
		catch (error: Exception) {
			// A trip missing from the feed is not a cancellation; any snapshot stays as saved.
			if (requested == endpoint && openTrips[key] != null) {
				val failure = if (error is TransitException.NotFound) TripFailure.NotFound else TripFailure.Unavailable(error.message ?: "Train update unavailable.")
				liveTrips = liveTrips + (key to (liveTrips[key] ?: LiveTrip()).copy(failure = failure))
			}
		} finally {
			token?.let { endFetch(target, it) }
		}
		if (key in readiness.wanted) refreshReadiness()
	}

	private fun trackFetch(target: OfflineFetchTarget): UUID = UUID.randomUUID().also { fetchTokens[target] = it }
	private fun sink(target: OfflineFetchTarget, token: UUID, subject: String): TransferSink = { progress ->
		if (fetchTokens[target] == token) fetchProgress = fetchProgress + (target to progress.load(subject))
	}
	private fun endFetch(target: OfflineFetchTarget, token: UUID) {
		if (fetchTokens[target] != token) return
		fetchTokens.remove(target)
		fetchProgress = fetchProgress - target
	}

	/** The age offline estimates are based on: the oldest prediction, never alerts or car reports. */
	fun predictionSourceTimestamp(board: Board): Double? {
		board.departures.map { it.timestamp }.filter { it > 0 }.minOrNull()?.let { return it }
		return board.sources.filter { it.id !in setOf("subway-alerts", "helium") }.mapNotNull { it.timestamp }.filter { it > 0 }.minOrNull()
	}

	// MARK: Location

	/** "Stations near me". Asks for permission first when the rider has not answered yet. */
	fun locateNearby() {
		nearbyLocation = null
		if (deps.locationDisabled) { locationError = "Location is disabled. You can still search for any station."; return }
		when (deps.location.foregroundPermission()) {
			LocationPermission.GRANTED -> scope.launch { performNearby() }
			LocationPermission.NOT_REQUESTED -> permissionRequest = PermissionPurpose.NEARBY
			LocationPermission.DENIED -> {
				// The system dialog may still be shown again when Android allows it; otherwise riders use Settings.
				permissionRequest = PermissionPurpose.NEARBY
			}
		}
	}

	suspend fun refreshLocationStatus() {
		widgetLocationStatus = WidgetLocationStatus(
			enabled = runCatching { deps.location.backgroundEnabled() }.getOrDefault(false),
			backgroundAllowed = deps.location.backgroundAllowed(),
			foregroundAllowed = deps.location.foregroundPermission() == LocationPermission.GRANTED,
		)
	}

	/** Turns the optional widget background location on or off. Permission prompts belong to the activity. */
	fun setWidgetBackgroundLocation(value: Boolean) {
		scope.launch {
			runCatching { deps.location.setBackgroundEnabled(value) }
			refreshLocationStatus()
			deps.widgets.settingsChanged()
		}
	}

	fun locationForegroundPermission(): LocationPermission = deps.location.foregroundPermission()

	/** Asks the activity for foreground location on behalf of widgets. */
	fun requestWidgetLocationPermission() { permissionRequest = PermissionPurpose.WIDGET }

	/** The rider allowed startup location from the board's location card. */
	fun allowStartupLocation() {
		if (deps.location.foregroundPermission() == LocationPermission.GRANTED) { favoriteStartupAttempted = false; scope.launch { openClosestFavoriteOnce() }; return }
		permissionRequest = PermissionPurpose.STARTUP
	}
	fun declineStartupLocation() {
		startupLocationDeclined = true
		deps.flags.set(UiFlags.STARTUP_LOCATION_DECLINED, true)
	}

	/** The board offers startup location only when it would be used and the rider has not answered. */
	val permissionCardVisible: Boolean get() = loaded && !deps.locationDisabled && !startupLocationDeclined && stations.isNotEmpty() &&
		(settings.stationSelection.mode != "favorite" || favoriteStations.isNotEmpty()) &&
		permissionRequest == null && deps.location.foregroundPermission() == LocationPermission.NOT_REQUESTED

	/** The activity's permission dialog finished. */
	fun permissionResult(granted: Boolean) {
		val purpose = permissionRequest ?: return
		permissionRequest = null
		deps.flags.set(UiFlags.LOCATION_REQUESTED, true)
		scope.launch { refreshLocationStatus() }
		if (!granted) {
			locationError = "Location permission is off. You can still search for any station, or allow location in Settings."
			if (purpose == PermissionPurpose.STARTUP) declineStartupLocation()
			return
		}
		when (purpose) {
			PermissionPurpose.NEARBY -> scope.launch { performNearby() }
			PermissionPurpose.STARTUP -> { favoriteStartupAttempted = false; scope.launch { openClosestFavoriteOnce() } }
			PermissionPurpose.WIDGET -> setWidgetBackgroundLocation(true)
		}
	}

	private suspend fun performNearby() {
		if (locating) return
		locating = true
		locationError = null
		try { nearbyLocation = currentLocation() }
		catch (error: CancellationException) { throw error }
		catch (error: Exception) { locationError = error.message ?: "Could not get your location. Search for a station or try again." }
		finally { locating = false }
	}

	private suspend fun currentLocation(): StationLocation {
		val location = deps.location.locate()
		if (!location.isUsable(deps.clock())) throw LocationException("Could not get a current location. Search for a station or try again.")
		widgetLocation = location
		runCatching { deps.location.publishAppLocation(location) }
		return location
	}

	/**
	 * Opens the closest favorite once per foreground visit. A rider passes a different closest
	 * favorite at nearly every stop, so it never navigates away from a ride or a manual choice.
	 */
	private suspend fun openClosestFavoriteOnce() {
		if (activeRide != null || !active || deps.locationDisabled || favoriteStartupAttempted || stations.isEmpty()) return
		if (settings.stationSelection.mode == "favorite" && favoriteStations.isEmpty()) return
		if (deps.location.foregroundPermission() != LocationPermission.GRANTED) return
		val initial = stationID
		val job = closestFavoriteJob ?: scope.launch {
			try {
				val location = currentLocation()
				if (!active || favoriteStartupAttempted) return@launch
				// Favorite pages take the visit's order once, unless the rider is already browsing them.
				if (!browsing) visitLocation = location
				if (initial != stationID || activeRide != null) return@launch
				if (!location.isUsable(deps.clock())) return@launch
				val closest = settings.stationSelection.select(visibleStations, favorites, location, stationID, deps.clock()) ?: return@launch
				if (closest.id != stationID) {
					favoriteStartupAttempted = true
					stationID = closest.id
					temporaryStation = closest.id.takeIf { it !in favorites }
					boardGeneration += 1
					memberBoards = emptyMap(); combinedBoard = null; board = null; boardSavedAt = null; boardIsCached = true; boardError = null
					persistLastStation()
					loadCachedBoard(closest.id)
					planOffline()
					refreshBoard()
				}
			} catch (error: CancellationException) { throw error }
			catch (error: Exception) { locationError = error.message }
			finally { closestFavoriteJob = null }
		}.also { closestFavoriteJob = it }
		job.join()
	}

	// MARK: Links

	/** A widget or notification link. Ride links open the trip without changing the station. */
	fun openStationLink(id: String) {
		if (!loaded) { pendingStationLink = id; return }
		if (combinedStations[id] == null && stations.none { it.id == id } && (id.startsWith("combined:") || id !in favorites)) return
		selectStation(id)
	}
	fun openRideLink(key: String) {
		favoriteStartupAttempted = true
		navigator.closeOverlays()
		navigator.show(Route.Train(key), AppTab.BOARD)
		pruneNavigationState()
	}

	/** Runs `block` on the model's scope, for screens that start model work. */
	fun launch(block: suspend CoroutineScope.() -> Unit): Job = scope.launch(block = block)
}

/** Orders mixed letters and numbers the way riders expect: 2 before 10. */
object NaturalOrder : Comparator<String> {
	private val parts = Regex("[0-9]+|[^0-9]+")
	override fun compare(a: String, b: String): Int {
		val left = parts.findAll(a).map { it.value }.toList()
		val right = parts.findAll(b).map { it.value }.toList()
		for (index in 0 until minOf(left.size, right.size)) {
			val x = left[index]; val y = right[index]
			val result = if (x[0].isDigit() && y[0].isDigit()) {
				val xx = x.trimStart('0').ifEmpty { "0" }; val yy = y.trimStart('0').ifEmpty { "0" }
				xx.length.compareTo(yy.length).takeIf { it != 0 } ?: xx.compareTo(yy)
			} else x.lowercase().compareTo(y.lowercase())
			if (result != 0) return result
		}
		return left.size.compareTo(right.size)
	}
}
