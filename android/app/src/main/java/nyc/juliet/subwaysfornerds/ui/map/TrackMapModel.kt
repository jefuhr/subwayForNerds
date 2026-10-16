package nyc.juliet.subwaysfornerds.ui.map

import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import nyc.juliet.subwaysfornerds.core.Display
import nyc.juliet.subwaysfornerds.core.LoadProgress
import nyc.juliet.subwaysfornerds.core.Station
import nyc.juliet.subwaysfornerds.core.TrackMapCamera
import nyc.juliet.subwaysfornerds.core.TrackMapContract
import nyc.juliet.subwaysfornerds.core.TrackMapContractException
import nyc.juliet.subwaysfornerds.core.TrackMapDisplay
import nyc.juliet.subwaysfornerds.core.TrackMapEdge
import nyc.juliet.subwaysfornerds.core.TrackMapPoint
import nyc.juliet.subwaysfornerds.core.TrackMapPolyline
import nyc.juliet.subwaysfornerds.core.TrackMapEvidence
import nyc.juliet.subwaysfornerds.core.TrackMapEvidenceState
import nyc.juliet.subwaysfornerds.core.TrackMapFreshness
import nyc.juliet.subwaysfornerds.core.TrackMapMotionMath
import nyc.juliet.subwaysfornerds.core.TrackMapPlacement
import nyc.juliet.subwaysfornerds.core.TrackMapSnapshot
import nyc.juliet.subwaysfornerds.core.TrackMapStation
import nyc.juliet.subwaysfornerds.core.TrackMapTopology
import nyc.juliet.subwaysfornerds.core.TrackMapTrain
import nyc.juliet.subwaysfornerds.ui.data.TransferSink
import java.io.File
import java.util.Locale

/** Reviewed map data and the verified artwork it was drawn on. */
class TrackMapResources(val topology: TrackMapTopology, val pdf: File)

/** Loads and verifies the locally installed map; throws [TrackMapUnavailableException] or a contract error. */
interface TrackMapAssetSource {
	suspend fun load(): TrackMapResources
}

class TrackMapUnavailableException(message: String) : Exception(message)

sealed interface TrackMapAssetState {
	data object Idle : TrackMapAssetState
	data object Loading : TrackMapAssetState
	data class Ready(val resources: TrackMapResources) : TrackMapAssetState
	data class Unavailable(val detail: String) : TrackMapAssetState
}

/** One train row with its re-evaluated evidence. */
data class TrackMapRow(val train: TrackMapTrain, val evidence: TrackMapEvidenceState)
/** A train that is drawn now, and where. */
data class TrackMapMarker(val train: TrackMapTrain, val evidence: TrackMapEvidenceState, val display: TrackMapDisplay)
/**
 * One station complex found by search. [station] is the mapped part that matched, which the map focuses.
 * [title] and [subtitle] are rider-facing names, lines and borough; opaque identifiers are never shown.
 */
data class TrackMapSearchResult(val stationId: String, val station: TrackMapStation, val title: String, val subtitle: String)

/**
 * The track map tab's state. Snapshots are requested every 15 s only while the map is visible and the app is
 * in the foreground; leaving either cancels the request in flight. Each snapshot is checked against the
 * installed map before anything is drawn. The camera is the rider's and polling never moves it.
 */
@Stable
class TrackMapModel(
	private val scope: CoroutineScope,
	private val fetch: suspend (mapVersion: String, progress: TransferSink?) -> TrackMapSnapshot,
	/** The app's clock (a fixed fixture clock in tests); evidence ages on it, never on response read times. */
	val clock: () -> Double,
) {
	var assets by mutableStateOf<TrackMapAssetState>(TrackMapAssetState.Idle); private set
	var snapshot by mutableStateOf<TrackMapSnapshot?>(null); private set
	/** A snapshot for another schema, map or artwork; nothing is drawn while set. */
	var contractError by mutableStateOf<String?>(null); private set
	var refreshError by mutableStateOf<String?>(null); private set
	var progress by mutableStateOf<LoadProgress?>(null); private set
	private var connectedState by mutableStateOf(true)
	val connected: Boolean get() = connectedState
	/**
	 * When the connection dropped or a refresh first failed. Motion stops there and no train counts as live
	 * until a snapshot validated against the installed map arrives; reconnecting alone does not clear it.
	 */
	var frozenSince by mutableStateOf<Double?>(null); private set
	/** The map is on screen and the app is in the foreground, so it polls and animates. */
	var active by mutableStateOf(false); private set
	var camera by mutableStateOf<TrackMapCamera?>(null)
	/** The canvas size in pixels, for zoom actions that have no gesture focus. */
	var viewSize: Pair<Double, Double>? = null
	var routeFilter by mutableStateOf<Set<String>>(emptySet()); private set
	var query by mutableStateOf("")
	var showTrainList by mutableStateOf(false)

	private var visible = false
	private var foreground = false
	private var pollJob: Job? = null
	private var assetJob: Job? = null
	private var generation = 0

	val topology: TrackMapTopology? get() = (assets as? TrackMapAssetState.Ready)?.resources?.topology

	fun loadAssets(source: TrackMapAssetSource) {
		if (assets is TrackMapAssetState.Ready || assets is TrackMapAssetState.Loading) return
		assets = TrackMapAssetState.Loading
		assetJob = scope.launch {
			assets = try { TrackMapAssetState.Ready(source.load()) }
			catch (error: CancellationException) { assets = TrackMapAssetState.Idle; throw error }
			catch (error: TrackMapUnavailableException) { TrackMapAssetState.Unavailable(error.message ?: "Track map unavailable.") }
			catch (error: TrackMapContractException) { TrackMapAssetState.Unavailable(error.message ?: "Track map data does not match its artwork.") }
			catch (error: Exception) { TrackMapAssetState.Unavailable("The installed track map could not be read.") }
			updatePolling()
		}
	}

	fun setVisible(value: Boolean) { visible = value; updatePolling() }
	fun setForeground(value: Boolean) { foreground = value; updatePolling() }

	fun setConnected(value: Boolean) {
		if (value == connected) return
		connectedState = value
		if (!value) freeze()
		// Dropping abandons the request in flight; reconnecting refreshes at once rather than waiting out the interval.
		if (pollJob != null) restartPolling()
	}

	private fun freeze() { if (frozenSince == null) frozenSince = clock() }

	/** Another server's trains are never shown on this one's map. */
	fun endpointChanged() {
		generation += 1
		snapshot = null; contractError = null; refreshError = null; progress = null; frozenSince = if (connected) null else clock()
		if (pollJob != null) restartPolling()
	}

	private fun restartPolling() { generation += 1; pollJob?.cancel(); pollJob = null; updatePolling() }

	private fun updatePolling() {
		active = visible && foreground
		val wanted = active && assets is TrackMapAssetState.Ready
		if (!wanted) {
			// A request that ignores cancellation still finds its generation superseded when it returns.
			if (pollJob != null) generation += 1
			pollJob?.cancel(); pollJob = null; progress = null
			return
		}
		if (pollJob?.isActive == true) return
		pollJob = scope.launch {
			while (isActive) {
				refresh()
				delay(TrackMapContract.POLL_MILLIS)
			}
		}
	}

	private suspend fun refresh() {
		val topology = topology ?: return
		if (!connected) return
		val started = ++generation
		val sink: TransferSink? = if (snapshot == null) { value -> if (generation == started) progress = value.load("train positions") } else null
		try {
			val value = fetch(TrackMapContract.MAP_VERSION, sink)
			currentCoroutineContext().ensureActive()
			if (started != generation) return
			snapshot = TrackMapContract.validateSnapshot(value, topology)
			contractError = null; refreshError = null; frozenSince = null
		} catch (error: CancellationException) { throw error }
		catch (error: TrackMapContractException) {
			if (started != generation) return
			snapshot = null; contractError = error.message
			freeze()
		} catch (error: Exception) {
			if (started != generation) return
			// The last snapshot stays, frozen where it was; its rows age by their own evidence times and expire.
			refreshError = error.message ?: "Train positions unavailable."
			freeze()
		} finally {
			if (started == generation) progress = null
		}
	}

	// MARK: Derived

	/** Routes present in the snapshot, in line order. */
	val routes: List<String> get() = snapshot?.trains?.map { it.route }?.distinct()?.sortedWith(compareBy({ routeOrder(it) }, { it })).orEmpty()

	fun toggleRoute(route: String) { routeFilter = if (route in routeFilter) routeFilter - route else routeFilter + route }
	fun clearRoutes() { routeFilter = emptySet() }

	fun rows(now: Double): List<TrackMapRow> {
		val value = snapshot ?: return emptyList()
		val filter = routeFilter
		val frozen = frozenSince != null
		return value.trains.filter { filter.isEmpty() || it.route in filter }.map { train ->
			val evidence = TrackMapEvidence.evaluate(train, value.sources, now)
			// Offline or failing, nothing is live: evidence can only be downgraded, never kept fresh by a dead link.
			TrackMapRow(train, if (frozen && evidence.freshness == TrackMapFreshness.LIVE) evidence.copy(freshness = TrackMapFreshness.STALE) else evidence)
		}
	}

	fun markers(now: Double, reducedMotion: Boolean): List<TrackMapMarker> {
		val motionClock = frozenSince ?: now
		return rows(now).mapNotNull { row ->
			val shown = TrackMapMotionMath.display(row.train, row.evidence, now, motionClock, reducedMotion) ?: return@mapNotNull null
			// A train held on a mapped platform faces along the one directed rail that arrives there, if exactly one does.
			val rail = if (shown.path == null && row.train.placement == TrackMapPlacement.TRACK) railInto(shown.point) else null
			TrackMapMarker(row.train, row.evidence, if (rail != null) shown.copy(heading = rail.headingOrNull(1.0), path = rail, distance = rail.length) else shown)
		}
	}

	private var railIndex: Pair<TrackMapTopology, Map<TrackMapPoint, List<TrackMapEdge>>>? = null
	/**
	 * The one rail a held train can have arrived on: exactly one directed revenue edge ending at its point, and
	 * no two-way rail touching it. Anything else leaves the direction unknown rather than guessed.
	 */
	private fun railInto(point: TrackMapPoint): TrackMapPolyline? {
		val topology = topology ?: return null
		val index = railIndex?.takeIf { it.first === topology }?.second
			?: topology.edges.filter { it.revenue }.flatMap { edge -> if (edge.bidirectional) listOf(edge.points.first() to edge, edge.points.last() to edge) else listOf(edge.points.last() to edge) }
				.groupBy({ it.first }, { it.second }).also { railIndex = topology to it }
		val edge = index[point]?.singleOrNull()?.takeIf { !it.bidirectional } ?: return null
		return TrackMapPolyline(edge.points)
	}

	/**
	 * Stations matching [text], one row per station complex so same-named stops elsewhere stay separate. The
	 * catalog supplies the complex's name, lines and borough; without it the complex's other mapped names do.
	 */
	fun search(text: String, catalog: List<Station> = emptyList()): List<TrackMapSearchResult> {
		val needle = normalize(text)
		if (needle.isEmpty()) return emptyList()
		val parts = topology?.stations.orEmpty().groupBy { it.stationId }
		val known = catalog.associateBy { it.id }
		return parts.mapNotNull { (id, members) ->
			val entry = known[id]
			val match = members.firstOrNull { normalize(it.name).contains(needle) }
				?: members.firstOrNull().takeIf { entry != null && normalize(entry.name).contains(needle) } ?: return@mapNotNull null
			val subtitle = if (entry != null) {
				listOfNotNull(entry.routes.distinct().sortedWith(compareBy({ routeOrder(it) }, { it })).joinToString(" ") { routeLabel(it) }.takeIf { it.isNotEmpty() }, boroughName(entry.borough))
					.joinToString(" · ")
			} else members.map { it.name }.distinct().filter { it != match.name }.takeIf { it.isNotEmpty() }?.let { "Also " + it.joinToString(", ") }.orEmpty()
			TrackMapSearchResult(id, match, entry?.name ?: match.name, subtitle)
		}.take(8)
	}

	/** Centres the selected station the first time the map has a size; otherwise shows the whole map. */
	fun focusInitial(stationIDs: List<String>, width: Double, height: Double) {
		if (camera != null) return
		val topology = topology ?: return
		val station = topology.stations.firstOrNull { it.stationId in stationIDs }
		camera = if (station != null) TrackMapCamera.centered(station.point, TrackMapCamera.STATION_SCALE, topology.page)
		else TrackMapCamera.fit(topology.page, width, height, FIT_PADDING)
	}

	fun fit(width: Double, height: Double) { topology?.let { camera = TrackMapCamera.fit(it.page, width, height, FIT_PADDING) } }

	fun focus(station: TrackMapStation) {
		val topology = topology ?: return
		camera = TrackMapCamera.centered(station.point, maxOf(camera?.scale ?: 0.0, TrackMapCamera.STATION_SCALE), topology.page)
	}

	/** The one status line, distinct for each state the map can be in. */
	fun status(now: Double): String {
		when (val state = assets) {
			TrackMapAssetState.Idle, TrackMapAssetState.Loading -> return "Loading track map…"
			is TrackMapAssetState.Unavailable -> return "Track map unavailable"
			is TrackMapAssetState.Ready -> {}
		}
		contractError?.let { return "Map data mismatch · trains not drawn" }
		val value = snapshot ?: return when {
			!connected -> "Offline · train positions unavailable"
			refreshError != null -> "Train positions unavailable"
			else -> "Loading train positions…"
		}
		val rows = rows(now)
		val live = rows.count { it.evidence.freshness == TrackMapFreshness.LIVE && it.train.placement != TrackMapPlacement.UNPLACED }
		val stale = rows.count { it.evidence.freshness == TrackMapFreshness.STALE && it.train.placement != TrackMapPlacement.UNPLACED }
		val off = rows.size - live - stale
		val parts = if (value.trains.isEmpty()) listOf("No trains reported") else listOf("$live live", "$stale stale", "$off not on map")
		val suffix = when {
			!connected -> " · Offline, motion stopped"
			refreshError != null -> " · Update failed, showing last positions"
			frozenSince != null -> " · Reconnecting, motion stopped"
			else -> ""
		}
		return parts.joinToString(" · ") + suffix
	}

	companion object {
		const val FIT_PADDING = 16.0
		private val order = listOf("1", "2", "3", "4", "5", "6", "6X", "7", "7X", "A", "C", "E", "B", "D", "F", "FX", "M", "G", "J", "Z", "L", "N", "Q", "R", "W", "GS", "FS", "H", "S")
		fun routeOrder(route: String): Int = order.indexOf(route).let { if (it < 0) order.size else it }
		private fun normalize(value: String): String = value.lowercase(Locale.US).replace(Regex("[^a-z0-9]"), "")
		fun routeLabel(route: String): String = Display.displayRoute(route)
		private val boroughs = mapOf("M" to "Manhattan", "B" to "Brooklyn", "Bk" to "Brooklyn", "Bx" to "Bronx", "Q" to "Queens", "SI" to "Staten Island", "NJ" to "New Jersey")
		/** A readable borough, or null for a code this app does not know; codes are never shown as is. */
		fun boroughName(code: String): String? = boroughs[code] ?: code.takeIf { it.length > 3 }
	}
}
