package nyc.juliet.subwaysfornerds.ui

import nyc.juliet.subwaysfornerds.core.Board
import nyc.juliet.subwaysfornerds.core.BoardOrdering
import nyc.juliet.subwaysfornerds.core.CombinedBoards
import nyc.juliet.subwaysfornerds.core.Departure
import nyc.juliet.subwaysfornerds.core.LineVisibility
import nyc.juliet.subwaysfornerds.core.MemberBoardSnapshot
import nyc.juliet.subwaysfornerds.core.ServiceAlert
import nyc.juliet.subwaysfornerds.core.Station
import nyc.juliet.subwaysfornerds.core.StationSettings
import nyc.juliet.subwaysfornerds.core.WidgetBoards
import nyc.juliet.subwaysfornerds.core.WidgetDisplay

/** A group of departures on the board, in the order and grouping the rider chose. */
data class DepartureSection(
	val id: String,
	val direction: String,
	val partId: String,
	val track: String?,
	val reportedTrack: Boolean,
	val label: String,
	val service: String?,
	val departures: List<Departure>,
)

/** Where a combined-board departure boards, and whether its member board was a saved copy. */
data class BoardOrigin(val station: Station, val departure: Departure, val cached: Boolean, val savedAt: Double?)

/** One member station's board inside a combined station. */
data class MemberBoard(val station: Station, val board: Board?, val cached: Boolean, val savedAt: Double? = null, val error: String? = null)

/** A presentation snapshot of a combined station, never an API request or physical cache. */
data class CombinedView(
	val board: Board,
	val members: List<MemberBoard>,
	val origins: Map<String, BoardOrigin>,
	val cachedDepartureKeys: Set<String>,
	val warnings: List<String>,
)

/**
 * Every call into core's grouping, visibility and combined-station rules. Screens and the
 * model use these names, so core naming changes are absorbed in this one file.
 */
object CoreBridge {
	fun lineKey(route: String): String = LineVisibility.key(route)
	fun lineEnabled(route: String, hiddenRoutes: List<String>): Boolean = LineVisibility.isEnabled(route, hiddenRoutes)
	fun visibleRoutes(routes: List<String>, hiddenRoutes: List<String>): List<String> = LineVisibility.routes(routes, hiddenRoutes)
	fun visibleStation(station: Station, hiddenRoutes: List<String>): Station? = LineVisibility.station(station, hiddenRoutes)
	fun visibleBoard(board: Board, hiddenRoutes: List<String>): Board = LineVisibility.board(board, hiddenRoutes)
	fun visibleAlerts(alerts: List<ServiceAlert>, hiddenRoutes: List<String>): List<ServiceAlert> = LineVisibility.alerts(alerts, hiddenRoutes)

	fun combinedStation(id: String, name: String, stationIDs: List<String>, catalog: List<Station>): Station? =
		CombinedBoards.station(id, name, stationIDs, catalog)

	fun combine(station: Station, members: List<MemberBoard>): CombinedView {
		val merged = CombinedBoards.merge(station, members.map { MemberBoardSnapshot(it.station, it.board, it.cached, it.savedAt, it.error) })
		return CombinedView(
			board = merged.board,
			members = members,
			origins = merged.origins.mapValues { (_, origin) -> BoardOrigin(origin.station, origin.departure, origin.cached, origin.savedAt) },
			cachedDepartureKeys = merged.cachedDepartureKeys,
			warnings = merged.warnings,
		)
	}

	fun groups(
		board: Board,
		direction: String = "ALL",
		routes: List<String> = emptyList(),
		order: String = "track",
		now: Double,
		cached: Boolean = false,
		cachedDepartureKeys: Set<String>? = null,
	): List<DepartureSection> = BoardOrdering.groupDepartures(board, direction, routes, order, now, cached, cachedDepartureKeys).map {
		DepartureSection(it.id, it.direction, it.partId, it.track, it.reportedTrack, it.label, it.service, it.departures)
	}

	/** The soonest trains per direction for widgets and previews, grouped as the station prefers. */
	fun widgetGroups(
		board: Board,
		preference: StationSettings,
		limit: Int,
		now: Double,
		cached: Boolean,
		hiddenRoutes: List<String>,
		cachedDepartureKeys: Set<String>? = null,
	): List<DepartureSection> = WidgetBoards.departures(board, preference, limit, now, cached, hiddenRoutes, cachedDepartureKeys).map {
		DepartureSection(it.id, it.direction, it.partId, it.track, it.reportedTrack, it.label, it.service, it.departures)
	}

	/** Optional car, track and position details, keeping the 90-second and 300-second car rules. */
	fun widgetDetails(row: Departure, display: WidgetDisplay, now: Double, cached: Boolean): String =
		WidgetBoards.trainDetails(row, display, now, cached)
}
