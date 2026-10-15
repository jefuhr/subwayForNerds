package nyc.juliet.subwaysfornerds.data

import nyc.juliet.subwaysfornerds.core.*

data class BoardMerge(val board: Board, val advanced: Boolean, val predictionsAdvanced: Boolean)
data class NearbyCacheStation(val station: Station, val distanceMeters: Double)

object OfflinePlanner {
	/** Viewed/combined members first, then favorites and station-centered nearby boards. Hidden lines only affect eligibility. */
	fun requests(endpoint: String, viewed: Station, catalog: List<Station>, settings: Settings, boards: List<Board> = emptyList(), activeRide: ActiveRideRecord? = null, openedTripKey: String? = null): List<OfflineFetchRequest> {
		val requests = mutableListOf<OfflineFetchRequest>()
		fun board(id: String, priority: OfflineFetchPriority) {
			val station = catalog.firstOrNull { it.id == id } ?: return
			if (LineVisibility.station(station, settings.hiddenRoutes) != null && (station.departureMode != "external" || station.isNjt)) requests += OfflineFetchRequest(endpoint, OfflineFetchTarget.Board(id), priority)
		}
		val viewedIDs = settings.combinedStations[viewed.id]?.stationIDs ?: listOf(viewed.id)
		viewedIDs.forEach { board(it, OfflineFetchPriority.SELECTED) }
		settings.favorites.forEach { favorite -> (settings.combinedStations[favorite]?.stationIDs ?: listOf(favorite)).forEach { board(it, OfflineFetchPriority.BACKGROUND) } }
		viewedIDs.mapNotNull { id -> catalog.firstOrNull { it.id == id } }.forEach { station -> surroundingStations(station, catalog, settings.offline).forEach { board(it.station.id, OfflineFetchPriority.BACKGROUND) } }
		for (snapshot in boards) if (snapshot.station.id in viewedIDs || settings.offline.preloadOtherStationTrips) {
			tripKeysToSnapshot(snapshot.copy(departures = snapshot.departures.filter { LineVisibility.isEnabled(it.route, settings.hiddenRoutes) }), settings.offline).forEach { key -> requests += OfflineFetchRequest(endpoint, OfflineFetchTarget.Trip(key), OfflineFetchPriority.BACKGROUND) }
		}
		activeRide?.key?.takeUnless { it.startsWith("path|") }?.let { requests += OfflineFetchRequest(endpoint, OfflineFetchTarget.Trip(it), OfflineFetchPriority.ACTIVE_RIDE) }
		openedTripKey?.takeUnless { it.startsWith("path|") }?.let { requests += OfflineFetchRequest(endpoint, OfflineFetchTarget.Trip(it), OfflineFetchPriority.SELECTED) }
		return requests.groupBy { it.identity }.values.map { values -> values.minBy { it.priority.ordinal } }
	}

	fun retainedBoard(board: Board, preferences: OfflineSettings): Board {
		val counts = mutableMapOf<Pair<String, String>, Int>()
		return board.copy(departures = board.departures.filter { row ->
			val key = row.route to row.direction
			val count = (counts[key] ?: 0) + 1
			counts[key] = count
			count <= preferences.departuresPerLineDirection
		})
	}
	fun tripKeysToSnapshot(board: Board, preferences: OfflineSettings): List<String> {
		val counts = mutableMapOf<Pair<String, String>, Int>()
		val seen = mutableSetOf<String>()
		val maximum = minOf(preferences.tripDetailsPerLineDirection, preferences.departuresPerLineDirection)
		return board.departures.filter { row ->
			val key = row.route to row.direction
			if (row.assigned == false || row.relationship in setOf("CANCELED", "DELETED", "NO_DATA") || row.tripKey.isEmpty()
				|| row.tripKey.startsWith("path|") || row.tripKey in seen || (counts[key] ?: 0) >= maximum) false
			else { seen.add(row.tripKey); counts[key] = (counts[key] ?: 0) + 1; true }
		}.map { it.tripKey }
	}

	/** Arrival feeds, alerts/car assignments and NJT GPS retain independent clocks. */
	fun mergeBoard(fetched: Board, stored: Board?): BoardMerge {
		if (stored == null) return BoardMerge(fetched, true, true)
		fun groupTime(board: Board, id: String, errorsAccepted: Boolean): Double? {
			val source = board.sources.firstOrNull { it.id == id }
			if (source != null) return source.timestamp?.takeIf { it.isFinite() && it > 0 && (errorsAccepted || source.error == null) }
			return board.departures.filter { it.feed == id }.map { it.timestamp }.filter { it.isFinite() && it > 0 }.maxOrNull()
		}
		val ids = (fetched.sources.map { it.id } + stored.sources.map { it.id } + fetched.departures.map { it.feed } + stored.departures.map { it.feed }).distinct()
		var advanced = false
		var predictionsAdvanced = false
		var alertsFromFetched: Boolean? = null
		val departures = mutableListOf<Departure>()
		val sources = mutableListOf<SourceState>()
		for (id in ids) {
			val newTime = groupTime(fetched, id, false)
			val oldTime = groupTime(stored, id, true)
			val incoming = fetched.sources.firstOrNull { it.id == id }
			val previous = stored.sources.firstOrNull { it.id == id }
			val takeNew = newTime != null && (oldTime == null || newTime >= oldTime)
			if (newTime != null && (oldTime == null || newTime > oldTime)) {
				advanced = true
				if (id !in setOf("helium", "subway-alerts", fetched.njt?.positions?.id, stored.njt?.positions?.id) && !(id.startsWith("njt-") && (id.endsWith("-positions") || id.endsWith("-gps")))) predictionsAdvanced = true
			}
			if (takeNew && previous?.error != null && incoming?.error == null) advanced = true
			if (id == "subway-alerts") alertsFromFetched = takeNew
			departures += (if (takeNew) fetched else stored).departures.filter { it.feed == id }
			(if (takeNew) incoming else (previous ?: incoming?.let { it.copy(timestamp = oldTime ?: it.timestamp) })?.let { value -> value.copy(error = incoming?.error ?: value.error) })?.let { sources += it }
		}
		val positions = (stored.vehiclePositions.orEmpty() + fetched.vehiclePositions.orEmpty()).groupBy { it.id }
			.mapValues { (_, values) -> values.maxBy { it.timestamp } }.values.sortedBy { it.id }
		val vehiclePositions = if (stored.vehiclePositions == null && fetched.vehiclePositions == null) null else positions
		fun retainedSource(incoming: SourceState, previous: SourceState): SourceState =
			if (incoming.error == null && (incoming.timestamp ?: 0.0) >= (previous.timestamp ?: 0.0)) incoming
			else previous.copy(error = incoming.error ?: previous.error)
		var njt = fetched.njt ?: stored.njt
		val previousNjt = stored.njt
		if (njt != null && previousNjt != null) njt = njt.copy(
			predictions = retainedSource(njt.predictions, previousNjt.predictions),
			positions = retainedSource(njt.positions, previousNjt.positions),
		)
		if (vehiclePositions != stored.vehiclePositions || njt != stored.njt) advanced = true
		val merged = fetched.copy(
			generatedAt = if (predictionsAdvanced) fetched.generatedAt else stored.generatedAt,
			departures = departures.sortedBy { it.time ?: Double.POSITIVE_INFINITY },
			sources = sources,
			alerts = if (alertsFromFetched ?: advanced) fetched.alerts else stored.alerts,
			vehiclePositions = vehiclePositions, njt = njt,
		)
		return BoardMerge(merged, advanced, predictionsAdvanced)
	}

	fun surroundingStations(viewed: Station, catalog: List<Station>, preferences: OfflineSettings): List<NearbyCacheStation> {
		if (preferences.nearbyRadiusFeet <= 0) return emptyList()
		return catalog.filter { it.id != viewed.id && !it.id.startsWith("combined:") }.map { station ->
			NearbyCacheStation(station, distanceMeters(viewed.lat, viewed.lon, station.lat, station.lon))
		}.filter { it.distanceMeters <= preferences.nearbyRadiusFeet * 0.3048 }
			.sortedWith(compareBy<NearbyCacheStation> { it.distanceMeters }.thenBy { it.station.id })
	}

	internal fun distanceMeters(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
		if (!listOf(lat1, lon1, lat2, lon2).all { it.isFinite() } || kotlin.math.abs(lat1) > 90 || kotlin.math.abs(lat2) > 90 || kotlin.math.abs(lon1) > 180 || kotlin.math.abs(lon2) > 180) return Double.POSITIVE_INFINITY
		val a = Math.toRadians(lat2 - lat1); val b = Math.toRadians(lon2 - lon1)
		val h = kotlin.math.sin(a / 2).let { it * it } + kotlin.math.cos(Math.toRadians(lat1)) * kotlin.math.cos(Math.toRadians(lat2)) * kotlin.math.sin(b / 2).let { it * it }
		return 6_371_000 * 2 * kotlin.math.atan2(kotlin.math.sqrt(h.coerceIn(0.0, 1.0)), kotlin.math.sqrt((1 - h).coerceIn(0.0, 1.0)))
	}
}
