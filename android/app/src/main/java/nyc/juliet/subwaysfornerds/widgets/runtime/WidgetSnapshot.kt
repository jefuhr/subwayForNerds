package nyc.juliet.subwaysfornerds.widgets.runtime

import kotlinx.serialization.Serializable
import nyc.juliet.subwaysfornerds.core.*
import nyc.juliet.subwaysfornerds.data.CachedTrip

@Serializable data class WidgetDeparture(
	val departure: Departure,
	val cached: Boolean,
	val originLabel: String? = null,
	val homeDetail: String = "",
	val lockDetail: String = "",
	val groupLabel: String = "",
	val sourceTime: Double? = null,
	val historicalDetail: String = "",
) {
	val route: String get() = departure.route
	val destination: String get() = departure.destination
	val arrival: Double? get() = departure.time ?: departure.arrival ?: departure.departure
	val boardingArea: String get() = originLabel ?: departure.area
}
@Serializable data class WidgetColumn(val direction: String, val label: String, val rows: List<WidgetDeparture>)
internal data class WidgetSchedulePlan(val cancelOwnWork: Boolean, val refreshAllowed: Boolean, val periodicIntervalMinutes: Long?)
@Serializable data class WidgetSnapshot(
	val stationID: String? = null,
	val stationName: String = "Subway Nerds",
	val themeID: String = "subway",
	val columns: List<WidgetColumn> = emptyList(),
	val sourceTime: Double? = null,
	val generatedAt: Double = 0.0,
	val notice: String? = null,
	val message: String? = null,
	val rideKey: String? = null,
	val ride: CachedTrip? = null,
	val display: WidgetDisplay = WidgetDisplay(),
	val lockScreen: LockScreenSettings = LockScreenSettings(),
	val timeFormat: String = "12h",
	val groupedBy: String = "direction",
	val estimated: Boolean = true,
	val estimateUsable: Boolean = false,
) {
	val north: List<WidgetDeparture> get() = columns.filter { it.direction in listOf("NORTH", "TO_NY") }.flatMap { it.rows }
	val south: List<WidgetDeparture> get() = columns.filter { it.direction in listOf("SOUTH", "TO_NJ") }.flatMap { it.rows }
}

/** Pure projection, evaluated at completion/read time; fetch success never creates freshness. */
object WidgetSnapshotFactory {
	fun board(board: Board, settings: Settings, now: Double, cached: Boolean, notice: String? = null, combined: CombinedBoardSnapshot? = null, message: String? = null): WidgetSnapshot {
		val preference = (if (settings.widgets.matchAppFilters) settings.stations[board.station.id] else settings.widgets.stations[board.station.id]) ?: StationSettings(view = "direction")
		val homeLimit = settings.widgets.display.trainsPerDirection.let { if (it == 0) 14 else it.coerceIn(1, 14) }
		val lockLimit = settings.widgets.lockScreen.display.trainsPerDirection.let { if (it == 0) 6 else it.coerceIn(1, 14) }
		val limit = maxOf(homeLimit, lockLimit)
		val groups = widgetDepartures(board, preference.copy(direction = "ALL"), limit, now, cached, settings.hiddenRoutes, combined?.cachedDepartureKeys)
		val rows = groups.flatMap { group -> group.departures.map { row ->
			val origin = combined?.origins?.get(row.key)
			val sourceBoard = origin?.let { value -> combined?.members?.firstOrNull { it.station.id == value.station.id }?.board } ?: board
			val sourceError = sourceBoard.sources.firstOrNull { it.id == row.feed }?.error != null || (row.feed.startsWith("njt-") && sourceBoard.njt?.predictions?.error != null)
			val historical = (origin?.cached ?: cached) || Display.freshness(row, now) != Freshness.LIVE || sourceError
			val outcome = if (historical) OfflineDisplay.countdown(row, now, true, settings.offline, settings.units.time) else null
			WidgetDeparture(row, historical,
				origin?.let { it.station.parts.firstOrNull { part -> part.id == it.departure.partId }?.name ?: it.station.name },
				widgetTrainDetails(row, settings.widgets.display, now, historical), widgetTrainDetails(row, settings.widgets.lockScreen.display, now, historical),
				group.label.ifEmpty { if (group.track != null) "Track ${group.track}" else Display.directionLabel(group.direction) },
				row.timestamp.takeIf { it.isFinite() && it > 0 }, outcome?.let { if (it.unit == "min") "Offline estimate" else if (it.unit == "estimate passed") "Estimate passed · last known time" else "Last known times" }.orEmpty())
		} }
		val path = board.station.routes.any { it.startsWith("PATH") } || rows.any { it.departure.direction.startsWith("TO_") }
		val regular = board.station.routes.any { !it.startsWith("PATH") } || rows.any { it.departure.direction in listOf("NORTH", "SOUTH") }
		val directions = (if (regular || !path) listOf("NORTH", "SOUTH") else emptyList()) + (if (path) listOf("TO_NY", "TO_NJ") else emptyList()) + rows.map { it.departure.direction }.filter { it !in listOf("NORTH", "SOUTH", "TO_NY", "TO_NJ") }.distinct()
		val sourceTime = rows.mapNotNull { it.sourceTime }.minOrNull() ?: predictionSourceTime(board)
		val estimated = cached || rows.any { it.cached }
		return WidgetSnapshot(board.station.id, board.station.name, settings.theme,
			directions.map { direction -> WidgetColumn(direction, Display.directionLabel(direction), rows.filter { it.departure.direction == direction }) },
			sourceTime, now, notice,
			message ?: if (board.usesExternalDepartures) "Open station for departure times." else Display.njtPredictionMessage(board, now, cached),
			display = settings.widgets.display, lockScreen = settings.widgets.lockScreen, timeFormat = settings.units.time, groupedBy = preference.view,
			estimated = estimated, estimateUsable = sourceTime != null && OfflineDisplay.isEstimateUsable(sourceTime, now, settings.offline))
	}
	fun ride(trip: CachedTrip, settings: Settings, now: Double, cached: Boolean): WidgetSnapshot {
		val train = trip.train ?: return WidgetSnapshot(themeID = settings.theme, message = "Saved ride unavailable.", generatedAt = now)
		val nextIndex = OfflineDisplay.estimatedNextStopIndex(train.stops, now)
		val eligible = train.assigned != false && train.relationship !in listOf("CANCELED", "DELETED", "NO_DATA")
		val upcoming = if (eligible) train.stops.drop(nextIndex ?: train.stops.size) else emptyList()
		val rows = upcoming.take(14).mapIndexed { index, stop -> Departure(
			key = "${trip.key}|$index", tripKey = trip.key, route = train.route, destination = stop.name, direction = train.direction,
			stopId = stop.id, partId = stop.stationId ?: "", area = "", time = stop.arrival ?: stop.departure, arrival = stop.arrival,
			pattern = "", patternSource = "reported", location = "", feed = train.feed, timestamp = train.timestamp,
			scheduledTrack = stop.scheduledTrack, actualTrack = stop.actualTrack, relationship = stop.relationship, staleAfter = train.staleAfter,
		) }
		val station = Station(trip.boardingStationID ?: "ride", train.destination, "", listOf(train.route), 0.0, 0.0)
		val projected = board(Board(station, trip.savedAt, departures = rows), settings, now, cached)
		return projected.copy(rideKey = trip.key, ride = trip.copy(detail = trip.detail?.copy(raw = null, source = null)),
			sourceTime = trip.sourceTime, estimated = cached || Display.freshness(train, now) != Freshness.LIVE,
			estimateUsable = OfflineDisplay.isEstimateUsable(trip.sourceTime, now, settings.offline),
			message = if (!eligible) "Ride predictions unavailable." else if (!trip.isComplete) OfflineDisplay.partialTripLabel else if (nextIndex == null) "No remaining predicted stops." else if (cached) OfflineDisplay.estimatedNextStopLabel else null)
	}
	fun preferredRefreshMinutes(settings: Settings): Long = maxOf(15, settings.widgets.display.refreshInterval ?: 5).toLong()
	internal fun schedulePlan(settings: Settings, installedWidgetCount: Int, deviceUnlocked: Boolean): WidgetSchedulePlan = when {
		!deviceUnlocked -> WidgetSchedulePlan(false, false, null)
		installedWidgetCount <= 0 -> WidgetSchedulePlan(true, false, null)
		else -> WidgetSchedulePlan(false, true, preferredRefreshMinutes(settings))
	}
	private fun predictionSourceTime(board: Board): Double? = (listOfNotNull(board.njt?.predictions?.timestamp) + board.sources.filter { it.id !in listOf("subway-alerts", "helium", board.njt?.positions?.id) && !(it.id.startsWith("njt-") && (it.id.endsWith("-gps") || it.id.endsWith("-positions"))) }.mapNotNull { it.timestamp }).filter { it.isFinite() && it > 0 }.minOrNull()
}
