package nyc.juliet.subwaysfornerds.core

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.*

enum class Freshness(val id: String) { LIVE("live"), STALE("stale"), EXPIRED("expired"), UNAVAILABLE("unavailable") }
data class Countdown(val value: String, val unit: String)
data class RegionalRoute(val label: String, val name: String, val colors: List<Long>)
data class VehiclePositionDisplay(val location: String, val age: String, val lastKnown: Boolean)
object TransitLinks {
	const val njtDepartures = "https://www.njtransit.com/dv-to"
	const val njtSchedules = "https://www.njtransit.com/light-rail-to"
	const val njtAlerts = "https://www.njtransit.com/travel-alerts-to"
	const val njtAccessibility = "https://www.njtransit.com/ride-lightrail"
}

/** Pure display policy shared by the app and widget renderer. All times are source Unix seconds. */
open class DisplayRules {
	private val eastern = ZoneId.of("America/New_York")
	private val twelveHour = DateTimeFormatter.ofPattern("h:mm a", Locale.US).withZone(eastern)
	private val twentyFourHour = DateTimeFormatter.ofPattern("HH:mm", Locale.US).withZone(eastern)
	fun freshness(timestamp: Double?, now: Double, staleAfter: Double? = null): Freshness {
		if (timestamp == null || !timestamp.isFinite() || timestamp <= 0 || !now.isFinite() || timestamp > now) return Freshness.UNAVAILABLE
		return if (now - timestamp > 300) Freshness.EXPIRED else if (now - timestamp > (staleAfter ?: 90.0)) Freshness.STALE else Freshness.LIVE
	}
	fun predictionStaleAfter(staleAfter: Double?, feed: String): Double = staleAfter ?: if (feed.startsWith("njt-")) 60.0 else 90.0
	fun freshness(row: Departure, now: Double): Freshness = freshness(row.timestamp, now, predictionStaleAfter(row.staleAfter, row.feed))
	fun freshness(train: Train, now: Double): Freshness = freshness(train.timestamp, now, predictionStaleAfter(train.staleAfter, train.feed))
	fun freshness(source: SourceState, now: Double): Freshness = freshness(source.timestamp, now, predictionStaleAfter(source.staleAfter, source.id))
	fun countdown(time: Double?, timestamp: Double, now: Double, cached: Boolean = false, timeFormat: String = "12h", staleAfter: Double? = null): Countdown {
		if (time == null || !time.isFinite()) return Countdown("—", "no estimate")
		if (cached || freshness(timestamp, now, staleAfter) != Freshness.LIVE) return Countdown(clockTime(time, timeFormat), "last estimate")
		val seconds = time - now
		return if (seconds < -30) Countdown("—", "awaiting update") else Countdown(if (seconds < 60) "<1" else floor(seconds / 60).toLong().toString(), "min")
	}
	fun hasLivePredictions(board: Board, now: Double, cached: Boolean = false): Boolean {
		if (cached || board.usesExternalDepartures) return false
		board.njt?.takeIf { it.configured }?.let { if (it.predictions.error != null || freshness(it.predictions, now) != Freshness.LIVE) return false }
		return board.departures.any { boardable(it) && it.time != null && freshness(it, now) == Freshness.LIVE && it.time >= now - 30 }
	}
	fun njtPredictionMessage(board: Board, now: Double, cached: Boolean = false): String? {
		val njt = board.njt ?: return null
		if (!njt.configured || board.departures.isNotEmpty()) return null
		return if (cached || njt.predictions.error != null || freshness(njt.predictions, now) != Freshness.LIVE)
			"NJ Transit arrival predictions are unavailable. Check official departure tools for current information."
		else "No arrival predictions are currently reported. Check official departure tools for upcoming trains."
	}
	fun vehiclePosition(position: VehiclePosition?, now: Double, cached: Boolean = false): VehiclePositionDisplay? {
		if (position == null || !position.timestamp.isFinite() || position.timestamp <= 0 || position.timestamp > now || now - position.timestamp > 300 ||
			!validCoordinate(position.lat, position.lon) || position.lat == 0.0 && position.lon == 0.0) return null
		return VehiclePositionDisplay(position.stopName?.trim()?.takeIf { it.isNotEmpty() } ?: String.format(Locale.US, "GPS %.5f, %.5f", position.lat, position.lon), ageLabel(position.timestamp, now), cached || now - position.timestamp > 60)
	}
	fun currentVehiclePositions(positions: List<VehiclePosition>?, now: Double): List<VehiclePosition> = positions.orEmpty().filter { vehiclePosition(it, now) != null }
	fun currentVehiclePositions(positions: List<VehiclePosition>?, routes: List<String>, now: Double): List<VehiclePosition> = currentVehiclePositions(positions, now).filter { it.route in routes }
	fun vehiclePositionLabel(position: VehiclePosition, now: Double, cached: Boolean = false): String {
		val display = vehiclePosition(position, now, cached) ?: return "GPS report unavailable"
		return (if (display.lastKnown) "Last known · " else "") + display.location + " · source " + display.age
	}
	fun clockTime(seconds: Double?, format: String = "12h"): String {
		if (seconds == null || !seconds.isFinite()) return "—"
		return try { (if (format == "24h") twentyFourHour else twelveHour).format(Instant.ofEpochMilli((seconds * 1000).toLong())) } catch (_: Exception) { "—" }
	}
	fun clockDateTime(seconds: Double, format: String = "12h"): String = if (!seconds.isFinite()) "—" else DateTimeFormatter.ofPattern(if (format == "24h") "M/d/yyyy HH:mm:ss" else "M/d/yyyy h:mm:ss a", Locale.US).withZone(eastern).format(Instant.ofEpochMilli((seconds * 1000).toLong()))
	fun publishedClockText(text: String, format: String = "12h"): String {
		if (format != "24h") return text
		val match = Regex("^((?:0?[1-9]|1[0-2])/(?:0?[1-9]|[12][0-9]|3[01])/[0-9]{4}\\s+)([0-9]{1,2}):([0-9]{2})\\s+([AP]M)$", RegexOption.IGNORE_CASE).matchEntire(text) ?: return text
		val hour = match.groupValues[2].toInt(); val minute = match.groupValues[3].toInt()
		if (hour !in 1..12 || minute !in 0..59) return text
		return match.groupValues[1] + String.format(Locale.US, "%02d:%02d", hour % 12 + if (match.groupValues[4].uppercase() == "PM") 12 else 0, minute)
	}
	fun ageLabel(timestamp: Double?, now: Double): String {
		if (timestamp == null || !timestamp.isFinite() || timestamp <= 0 || !now.isFinite()) return "not received"
		val seconds = max(0.0, now - timestamp).toLong()
		return if (seconds < 60) "${seconds}s ago" else if (seconds < 3600) "${seconds / 60}m ago" else "${seconds / 3600}h ago"
	}
	fun boardable(departure: Departure): Boolean = departure.relationship !in listOf("SKIPPED", "CANCELED", "DELETED", "NO_DATA")
	/** The platform line of a row; [provenance] adds whether the track is reported or only scheduled. */
	fun boardingLabel(departure: Departure, provenance: Boolean = true): String {
		val area = departure.area.trim().ifEmpty { departure.partId }
		val actual = departure.actualTrack?.trim()?.takeIf { it.isNotEmpty() }
		val track = actual ?: departure.scheduledTrack?.trim()?.takeIf { it.isNotEmpty() } ?: return "$area · Track unknown"
		val label = "Track $track"; val provenanceLabel = if (actual == null) "scheduled" else "reported"
		val suffix = if (provenance) " · $provenanceLabel" else ""
		return if (area == label || area.endsWith(" · $label")) "$area$suffix" else "$area · $label$suffix"
	}
	fun currentConsist(consist: Consist?, now: Double): Boolean = consist != null && listOf(consist.updatedAt, consist.fetchedAt).all { it.isFinite() && it > 0 && now - it <= 300 && it <= now + 60 }
	fun consistSummary(cars: List<ConsistCar>): String {
		val ranges = mutableListOf<String>(); var start = 0
		while (start < cars.size) {
			var end = start
			val first = cars[start].number.toLongOrNull(); val next = cars.getOrNull(start + 1)?.number?.toLongOrNull()
			if (first != null && next != null && abs(next - first) == 1L) {
				val step = next - first
				while (end + 1 < cars.size) { val current = cars[end].number.toLongOrNull(); val following = cars[end + 1].number.toLongOrNull(); if (current == null || following == null || following - current != step) break; end++ }
			}
			ranges += if (end == start) cars[start].number else "${cars[start].number}–${cars[end].number}"; start = end + 1
		}
		return ranges.joinToString(", ")
	}
	fun displayRoute(route: String): String = mapOf("GS" to "S", "FS" to "S", "H" to "S", "SI" to "SIR")[route] ?: route
	fun regionalRoute(route: String): RegionalRoute? = when (route) {
		"NJT-HBLR" -> RegionalRoute("HBLR", "NJ Transit Hudson–Bergen Light Rail", listOf(0x70452B))
		"NJT-NLR" -> RegionalRoute("NLR", "NJ Transit Newark Light Rail", listOf(0x2767AD))
		"NJT-RIVER" -> RegionalRoute("River LINE", "NJ Transit River LINE", listOf(0x327448))
		"PATH-NWK-WTC" -> RegionalRoute("NWK–WTC", "PATH NWK–WTC", listOf(0xD93A30))
		"PATH-HOB-WTC" -> RegionalRoute("HOB–WTC", "PATH HOB–WTC", listOf(0x65C100))
		"PATH-JSQ-33" -> RegionalRoute("JSQ–33", "PATH JSQ–33", listOf(0xFF9900))
		"PATH-HOB-33" -> RegionalRoute("HOB–33", "PATH HOB–33", listOf(0x4D92FB))
		"PATH-JSQ-33-HOB" -> RegionalRoute("JSQ–33 via HOB", "PATH JSQ–33 via HOB", listOf(0x4D92FB, 0xFF9900))
		else -> if (route.startsWith("PATH")) RegionalRoute("PATH", "PATH", listOf(0x62666B)) else null
	}
	fun routeLabel(route: String): String = regionalRoute(route)?.label ?: displayRoute(route)
	fun directionLabel(direction: String): String = when (direction) { "NORTH" -> "Northbound"; "SOUTH" -> "Southbound"; "TO_NY" -> "To New York"; "TO_NJ" -> "To New Jersey"; "ALL" -> "All directions"; else -> "Direction unknown" }
	fun stationMatches(station: Station, query: String): Boolean {
		val boroughs = mapOf("NJ" to "New Jersey", "M" to "Manhattan", "B" to "Brooklyn", "Bk" to "Brooklyn", "Bx" to "Bronx", "Q" to "Queens", "SI" to "Staten Island")
		val text = listOf(station.name, station.municipality.orEmpty(), boroughs[station.borough] ?: station.borough, if (station.routes.any { it.startsWith("NJT-") }) "NJT light rail lightrail" else "", station.routes.joinToString(" "), station.routes.joinToString(" ", transform = ::routeLabel), station.parts.joinToString(" ") { it.line }, station.parts.joinToString(" ") { it.stationId }).joinToString(" ")
		fun normalize(s: String) = s.lowercase(Locale.US).replace(Regex("[–—-]"), " ")
		val haystack = normalize(text); return normalize(query).split(Regex("\\s+")).filter { it.isNotEmpty() }.all { haystack.contains(it) }
	}
	fun distanceMeters(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
		val rad = Math.PI / 180; val a = sin((lat2 - lat1) * rad / 2).pow(2) + cos(lat1 * rad) * cos(lat2 * rad) * sin((lon2 - lon1) * rad / 2).pow(2)
		return 6_371_000 * 2 * atan2(sqrt(min(1.0, a)), sqrt(max(0.0, 1 - a)))
	}
	fun changeStale(change: TripChange, now: Double, cached: Boolean = false): Boolean = cached || change.evidence.any { it.unavailable == true || freshness(it.timestamp, now, it.staleAfter) != Freshness.LIVE }
	fun changeSummary(change: TripChange): TripChange = change.copy(description = null)
	fun changesAhead(changes: List<TripChange>?, index: Int): List<TripChange> = changes.orEmpty().filter { it.stopIndices.any { i -> i >= index } }.sortedWith(compareBy<TripChange> { changeRank(it, index) }.thenBy { it.id }).map {
		if (it.kind in listOf("track", "boarding") && index !in it.stopIndices) it.copy(label = it.label + " · ahead" + (it.location?.let { place -> " at $place" } ?: "")) else it
	}
	private fun changeRank(change: TripChange, index: Int): Int = when {
		change.kind in listOf("track", "boarding") && index in change.stopIndices -> 0
		change.kind == "cancellation" -> 1
		change.classification in listOf("unplanned", "unknown") -> if (change.advisory == true) 3 else 2
		change.classification == "planned" -> 4
		else -> 5
	}
}
object TransitDisplay : DisplayRules()
object Display : DisplayRules()
internal fun validCoordinate(lat: Double, lon: Double): Boolean = lat.isFinite() && lon.isFinite() && abs(lat) <= 90 && abs(lon) <= 180
