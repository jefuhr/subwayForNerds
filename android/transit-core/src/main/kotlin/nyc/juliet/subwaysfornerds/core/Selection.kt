package nyc.juliet.subwaysfornerds.core

import kotlinx.serialization.Serializable

@Serializable data class StationLocation(val latitude: Double, val longitude: Double, val timestamp: Double = System.currentTimeMillis() / 1000.0) {
	val isValid: Boolean get() = validCoordinate(latitude, longitude)
	fun isUsable(now: Double): Boolean = isValid && timestamp.isFinite() && timestamp > 0 && now.isFinite() && timestamp <= now && now - timestamp < 300
	fun distanceMeters(station: Station): Double {
		val parts = station.parts.filter { validCoordinate(it.lat, it.lon) }
		val points = if (parts.isEmpty()) listOf(station.lat to station.lon) else parts.map { it.lat to it.lon }
		return points.filter { validCoordinate(it.first, it.second) }.minOfOrNull { Display.distanceMeters(latitude, longitude, it.first, it.second) } ?: Double.POSITIVE_INFINITY
	}
	companion object { fun newestUsable(coordinates: List<StationLocation?>, now: Double): StationLocation? = coordinates.filterNotNull().filter { it.isUsable(now) }.maxByOrNull { it.timestamp } }
}
typealias WidgetCoordinate = StationLocation
object StationSelectionRules {
	fun select(stations: List<Station>, favorites: List<String>, selection: StationSelection, location: StationLocation?, previous: String? = null, now: Double): Station? {
		val favoriteStations = favorites.mapNotNull { id -> stations.firstOrNull { it.id == id } }
		val candidates = if (selection.mode == "favorite") favoriteStations else stations
		if (candidates.isEmpty()) return null
		val fallback = candidates.firstOrNull { it.id == previous } ?: favoriteStations.firstOrNull() ?: candidates.firstOrNull()
		if (location == null || !location.isUsable(now)) return fallback
		fun nearest(options: List<Station>): Station? = options.filter { location.distanceMeters(it).isFinite() }.minWithOrNull(compareBy<Station> { location.distanceMeters(it) }.thenBy { !it.isCombined }.thenBy { if (it.isCombined && it.id == previous) 0 else 1 }.thenBy { it.id })
		if (selection.mode == "nearbyFavorite") nearest(favoriteStations)?.let { if (selection.includesFavorite(location.distanceMeters(it))) return it }
		return nearest(candidates) ?: fallback
	}
}
data class TrainFavoriteMatch(val carIDs: List<String>, val exactConsist: Boolean)
object TrainFavoriteRules {
	fun carID(number: String, type: String?, feed: String): String? {
		if (type.isNullOrEmpty() || !(feed == "gtfs" || feed.startsWith("gtfs-"))) return null
		val family = if (type in listOf("R160", "R160A", "R160B")) "R160" else type
		val id = "${if (feed == "gtfs-si") "sir" else "nyct"}:$family:$number"
		return id.takeIf { TrainFavorites.validCarID(it) }
	}
	fun consistIDs(consist: Consist?, feed: String): List<String>? {
		if (consist == null || consist.cars.size !in 1..20) return null
		val ids = consist.cars.mapNotNull { carID(it.number, it.type, feed) }
		return if (ids.size == consist.cars.size && ids.distinct().size == ids.size) ids.sorted() else null
	}
	fun consistKey(ids: List<String>): String = ids.sorted().joinToString("\u001f")
	fun match(consist: Consist?, feed: String, favorites: TrainFavorites, now: Double, cached: Boolean = false): TrainFavoriteMatch? {
		if (cached || !Display.currentConsist(consist, now)) return null
		val ids = consistIDs(consist, feed) ?: return null; val exact = favorites.containsConsist(ids)
		val saved = favorites.cars + if (favorites.match == "anyCar") favorites.consists.flatten() else emptyList()
		val matches = if (exact) ids else ids.filter { it in saved }; return if (matches.isEmpty()) null else TrainFavoriteMatch(matches, exact)
	}
	fun label(id: String): String { val parts = id.split(':'); return if (parts.size != 3) id else "${parts[1]} ${parts[2]}${if (parts[0] == "sir") " · SIR" else ""}" }
}
