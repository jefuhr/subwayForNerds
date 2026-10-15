package nyc.juliet.subwaysfornerds.core

import java.math.BigInteger

data class DepartureGroup(val id: String, val direction: String, val partId: String, val track: String?, val reportedTrack: Boolean, val label: String, val service: String?, val departures: List<Departure>) {
	val key: String get() = id
}
object BoardOrdering {
	val directions = listOf("NORTH", "SOUTH", "TO_NY", "TO_NJ", "UNKNOWN")
	fun sorted(departures: List<Departure>): List<Departure> = departures.sortedWith(compareBy<Departure> { it.time ?: Double.POSITIVE_INFINITY }.thenBy { it.key })
	fun routeFamily(route: String): String = when (route) {
		"1", "2", "3" -> "1 / 2 / 3"; "4", "5", "6", "4X", "5X", "6X" -> "4 / 5 / 6"; "7", "7X" -> "7"
		"A", "C", "E" -> "A / C / E"; "B", "D", "F", "FX", "M" -> "B / D / F / M"; "N", "Q", "R", "W" -> "N / Q / R / W"; "J", "Z" -> "J / Z"
		"GS" -> "42 St Shuttle"; "FS" -> "Franklin Shuttle"; "H" -> "Rockaway Shuttle"; "SI" -> "SIR"; else -> route
	}
	private fun natural(a: String, b: String): Int {
		val x = Regex("[0-9]+|[^0-9]+").findAll(a).map { it.value }.toList(); val y = Regex("[0-9]+|[^0-9]+").findAll(b).map { it.value }.toList()
		for (i in 0 until minOf(x.size, y.size)) {
			val result = if (x[i][0].isDigit() && y[i][0].isDigit()) BigInteger(x[i]).compareTo(BigInteger(y[i])) else x[i].compareTo(y[i], ignoreCase = true)
			if (result != 0) return result
		}
		return x.size.compareTo(y.size)
	}
	fun groupDepartures(board: Board, direction: String = "ALL", routes: List<String> = emptyList(), order: String = "track", now: Double, cached: Boolean = false, cachedDepartureKeys: Set<String>? = null): List<DepartureGroup> {
		val view = order.takeIf { it in listOf("track", "direction", "family", "corridor", "service") } ?: "track"
		data class Key(val direction: String, val identity: List<String>, val label: String)
		val selected = board.departures.filter {
			it.relationship != "NO_DATA" && (direction == "ALL" || it.direction == direction) && (routes.isEmpty() || Display.displayRoute(it.route) in routes) &&
			((cachedDepartureKeys?.contains(it.key) ?: cached) || Display.freshness(it, now) != Freshness.LIVE || (it.time ?: Double.POSITIVE_INFINITY) >= now - 30)
		}
		val groups = selected.groupBy { row ->
			val dir = row.direction.takeIf { it in directions } ?: "UNKNOWN"
			val label = when (view) { "family" -> routeFamily(row.route); "corridor" -> board.station.parts.firstOrNull { it.id == row.partId }?.line ?: row.partId; "service" -> row.route; else -> "" }
			val identity = when (view) { "track" -> listOf(row.partId, row.actualTrack ?: row.scheduledTrack ?: "?"); "corridor" -> listOf(row.partId); else -> listOf(label) }
			Key(dir, identity, label)
		}.map { (key, rows) ->
			val sorted = sorted(rows); val first = sorted.first()
			DepartureGroup((listOf(view, key.direction) + key.identity).joinToString("") { "${it.toByteArray(Charsets.UTF_8).size}:$it" }, key.direction, first.partId,
				if (view == "track") first.actualTrack ?: first.scheduledTrack else null, view == "track" && first.actualTrack != null, key.label, if (view == "service") first.route else null, sorted)
		}
		return groups.sortedWith { a, b ->
			if (view == "track") compareValuesBy(a, b, { it.departures.first().direction }, { it.partId }, { it.track.orEmpty() }, { it.id })
			else {
				val labels = natural(a.label, b.label)
				if (view == "service" && labels != 0) labels else {
					val dir = directions.indexOf(a.direction).compareTo(directions.indexOf(b.direction))
					if (dir != 0) dir else if (labels != 0) labels else a.id.compareTo(b.id)
				}
			}
		}
	}
}
fun groupDepartures(board: Board, direction: String = "ALL", routes: List<String> = emptyList(), order: String = "track", now: Double, cached: Boolean = false, cachedDepartureKeys: Set<String>? = null): List<DepartureGroup> = BoardOrdering.groupDepartures(board, direction, routes, order, now, cached, cachedDepartureKeys)

fun widgetDepartures(board: Board, preference: StationSettings, limit: Int, now: Double, cached: Boolean = false, hiddenRoutes: List<String> = emptyList(), cachedDepartureKeys: Set<String>? = null): List<DepartureGroup> {
	val filtered = board.departures.filter { LineVisibility.isEnabled(it.route, hiddenRoutes) && Display.boardable(it) && (preference.routes.isEmpty() || Display.displayRoute(it.route) in preference.routes) && ((cachedDepartureKeys?.contains(it.key) ?: cached) || Display.freshness(it, now) != Freshness.LIVE || (it.time ?: Double.POSITIVE_INFINITY) >= now - 30) }
	val selected = filtered.groupBy { it.direction }.values.flatMap { rows ->
		rows.sortedWith(compareBy<Departure> { if ((cached || cachedDepartureKeys?.isNotEmpty() == true) && (it.time ?: Double.NEGATIVE_INFINITY) < now) 1 else 0 }.thenBy { it.time ?: Double.POSITIVE_INFINITY }.thenBy { it.key }).take(maxOf(0, limit))
	}
	return groupDepartures(board.copy(departures = selected), order = preference.view, now = now, cached = cached, cachedDepartureKeys = cachedDepartureKeys)
}
fun widgetTrainDetails(row: Departure, options: WidgetDisplay, now: Double, cached: Boolean = false): String {
	val values = mutableListOf<String>()
	if ("track" in options.fields) (row.actualTrack ?: row.scheduledTrack)?.let { values += "T$it" }
	if ("service" in options.fields && row.pattern.isNotEmpty()) values += row.pattern + if (row.patternSource == "inferred") " · est." else ""
	if (!cached && Display.currentConsist(row.consist, now)) row.consist?.let { consist ->
		val before = values.size
		if ("carType" in options.fields) consist.cars.mapNotNull { it.type }.distinct().sorted().joinToString("/").takeIf { it.isNotEmpty() }?.let { values += it }
		if ("carCount" in options.fields && consist.cars.isNotEmpty()) values += "${consist.cars.size} cars"
		if ("carNumbers" in options.fields && consist.cars.isNotEmpty()) values += Display.consistSummary(consist.cars)
		if (values.size > before && Display.freshness(consist.updatedAt, now) != Freshness.LIVE) values += "last reported"
	}
	if ("location" in options.fields) {
		if (row.vehiclePosition != null) Display.vehiclePosition(row.vehiclePosition, now, cached)?.let { values += Display.vehiclePositionLabel(row.vehiclePosition, now, cached) }
		else if (!row.feed.startsWith("njt-") && row.location.isNotEmpty()) values += row.location + if (cached) " · last reported" else ""
	}
	return values.joinToString(" · ")
}

object WidgetBoards {
	fun departures(board: Board, preference: StationSettings, limit: Int, now: Double, cached: Boolean = false, hiddenRoutes: List<String> = emptyList(), cachedDepartureKeys: Set<String>? = null): List<DepartureGroup> = widgetDepartures(board, preference, limit, now, cached, hiddenRoutes, cachedDepartureKeys)
	fun trainDetails(row: Departure, display: WidgetDisplay, now: Double, cached: Boolean = false): String = widgetTrainDetails(row, display, now, cached)
}
