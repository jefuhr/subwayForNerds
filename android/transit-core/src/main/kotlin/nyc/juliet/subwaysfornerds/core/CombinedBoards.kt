package nyc.juliet.subwaysfornerds.core

object LineVisibility {
	fun key(route: String): String = mapOf("4X" to "4", "5X" to "5", "6X" to "6", "7X" to "7", "FX" to "F", "GS" to "S", "FS" to "S", "H" to "S", "SI" to "SIR")[route] ?: route
	fun isEnabled(route: String, hiddenRoutes: List<String>): Boolean = hiddenRoutes.none { key(it) == key(route) }
	fun routes(routes: List<String>, hiddenRoutes: List<String>): List<String> = routes.filter { isEnabled(it, hiddenRoutes) }
	fun station(station: Station, hiddenRoutes: List<String>): Station? {
		val visible = routes(station.routes, hiddenRoutes); if (station.routes.isNotEmpty() && visible.isEmpty()) return null
		return station.copy(routes = visible, parts = station.parts.mapNotNull { part -> val next = routes(part.routes, hiddenRoutes); if (part.routes.isNotEmpty() && next.isEmpty()) null else part.copy(routes = next) })
	}
	fun alerts(alerts: List<ServiceAlert>, hiddenRoutes: List<String>): List<ServiceAlert> = alerts.mapNotNull { alert ->
		val selectors = alert.selectors + alert.affectedSelectors.orEmpty(); val scoped = alert.routes + selectors.mapNotNull { it.route }
		if (scoped.isEmpty() || selectors.any { it.route == null } || scoped.any { isEnabled(it, hiddenRoutes) }) alert.copy(routes = routes(alert.routes, hiddenRoutes)) else null
	}
	fun board(board: Board, hiddenRoutes: List<String>): Board = board.copy(station = board.station.copy(routes = routes(board.station.routes, hiddenRoutes)), departures = board.departures.filter { isEnabled(it.route, hiddenRoutes) }, alerts = alerts(board.alerts, hiddenRoutes), vehiclePositions = board.vehiclePositions?.filter { isEnabled(it.route, hiddenRoutes) })
}
data class MemberBoardSnapshot(val station: Station, val board: Board? = null, val cached: Boolean = false, val savedAt: Double? = null, val error: String? = null)
data class DepartureOrigin(val station: Station, val departure: Departure, val cached: Boolean, val savedAt: Double? = null)
data class CombinedBoardSnapshot(val board: Board, val members: List<MemberBoardSnapshot>, val origins: Map<String, DepartureOrigin>) {
	val cachedDepartureKeys: Set<String> get() = origins.filterValues { it.cached }.keys
	val warnings: List<String> get() = members.mapNotNull { member ->
		val message = member.error ?: when { member.board == null -> "Departures unavailable"; member.board.usesExternalDepartures -> "Use official departure tools"; member.cached -> "Saved departures · offline estimates"; else -> null }
		message?.let { "${member.station.name}: $it" }
	}
}
object CombinedBoards {
	private fun identity(stationID: String, key: String): String = "${stationID.toByteArray(Charsets.UTF_8).size}:$stationID${key.toByteArray(Charsets.UTF_8).size}:$key"
	fun station(id: String, name: String, stationIDs: List<String>, catalog: List<Station>): Station? {
		val members = stationIDs.distinct().filter { !it.startsWith("combined:") }.mapNotNull { memberID -> catalog.firstOrNull { it.id == memberID } }
		if (members.isEmpty()) return null
		val parts = members.flatMap { member ->
			member.parts.ifEmpty { listOf(StationPart(member.id, member.id, member.name, member.routes.joinToString(" / "), member.routes, member.lat, member.lon, "", north = "Northbound", south = "Southbound")) }.distinctBy { it.id }.map { it.copy(id = identity(member.id, it.id)) }
		}
		return Station(id, name, if (members.map { it.borough }.distinct().size == 1) members[0].borough else "NYC", members.flatMap { it.routes }.distinct().sorted(), members.map { it.lat }.average(), members.map { it.lon }.average(), parts)
	}
	fun catalog(settings: Settings, catalog: List<Station>): List<Station> {
		val visible = catalog.mapNotNull { LineVisibility.station(it, settings.hiddenRoutes) }
		return visible + settings.combinedStations.toSortedMap().mapNotNull { (id, value) -> station(id, value.name, value.stationIDs, visible) }
	}
	fun origin(snapshot: CombinedBoardSnapshot, departureKey: String): DepartureOrigin? = snapshot.origins[departureKey]
	fun merge(station: Station, members: List<MemberBoardSnapshot>): CombinedBoardSnapshot {
		val distinct = members.distinctBy { it.station.id }; val origins = linkedMapOf<String, DepartureOrigin>(); val departures = mutableListOf<Departure>()
		val sources = linkedMapOf<String, SourceState>(); val alerts = linkedMapOf<String, ServiceAlert>(); val positions = linkedMapOf<String, VehiclePosition>()
		for (member in distinct) {
			val board = member.board ?: continue
			if (!board.usesExternalDepartures) for (row in board.departures) {
				val id = identity(member.station.id, row.key); if (id in origins) continue
				origins[id] = DepartureOrigin(member.station, row, member.cached, member.savedAt); departures += row.copy(key = id, partId = identity(member.station.id, row.partId))
			}
			for (source in board.sources) {
				val prior = sources[source.id]
				fun conservative(a: Double?, b: Double?): Double? = if (a == null || b == null) null else minOf(a, b)
				sources[source.id] = if (prior == null) source else SourceState(source.id, conservative(prior.timestamp, source.timestamp), conservative(prior.fetchedAt, source.fetchedAt), listOfNotNull(prior.error, source.error).distinct().sorted().takeIf { it.isNotEmpty() }?.joinToString("; "), listOfNotNull(prior.staleAfter, source.staleAfter).minOrNull())
			}
			for (alert in board.alerts) if ((alerts[alert.id]?.updatedAt ?: 0.0) <= (alert.updatedAt ?: 0.0)) alerts[alert.id] = alert
			for (position in board.vehiclePositions.orEmpty()) if ((positions[position.id]?.timestamp ?: Double.NEGATIVE_INFINITY) <= position.timestamp) positions[position.id] = position
		}
		return CombinedBoardSnapshot(Board(station, distinct.mapNotNull { it.board?.generatedAt }.minOrNull() ?: 0.0, sources.values.sortedBy { it.id }, BoardOrdering.sorted(departures), alerts.values.sortedBy { it.id }, vehiclePositions = positions.values.sortedBy { it.id }), distinct, origins)
	}
}
