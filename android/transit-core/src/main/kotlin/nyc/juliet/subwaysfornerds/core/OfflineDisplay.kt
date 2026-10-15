package nyc.juliet.subwaysfornerds.core

import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import kotlin.math.floor

object OfflineEndpoint {
	const val productionKey = "production"
	fun key(endpoint: String): String {
		val normalized = endpoint.trim().let { if (it.endsWith('/')) it else "$it/" }
		val url = normalized.toHttpUrlOrNull()
		return if (url?.toString() in listOf("https://juliet.nyc/subwaysForNerds/api/v1/", "https://subwaysfornerds.juliet.nyc/api/v1/")) productionKey else normalized
	}
}
object OfflineIdentity {
	fun trip(endpoint: String, tripKey: String): String = "trip\u001f${OfflineEndpoint.key(endpoint)}\u001f$tripKey"
	fun board(endpoint: String, stationID: String): String = "board\u001f${OfflineEndpoint.key(endpoint)}\u001f$stationID"
	fun isPositionalTrip(tripKey: String): Boolean = tripKey.startsWith("path|")
	fun boardSourceTimestamp(board: Board): Double? = (board.sources.mapNotNull { it.timestamp } + board.departures.map { it.timestamp }).filter { it.isFinite() && it > 0 }.maxOrNull()
}
object OfflineDisplay {
	const val estimatedNextStopLabel = "Estimated next stop · not observed"
	const val partialTripLabel = "Partial trip · onward stops from the station board"
	fun isEstimateUsable(timestamp: Double?, now: Double, preferences: OfflineSettings): Boolean = timestamp != null && timestamp.isFinite() && timestamp > 0 && now.isFinite() && timestamp <= now && now - timestamp <= preferences.estimateLimit
	fun prediction(time: Double?, timestamp: Double?, now: Double, preferences: OfflineSettings, timeFormat: String = "12h"): Countdown = countdown(time, timestamp, now, true, preferences, timeFormat)
	fun countdown(time: Double?, timestamp: Double?, now: Double, cached: Boolean, preferences: OfflineSettings, timeFormat: String = "12h", staleAfter: Double? = null): Countdown {
		if (time == null || !time.isFinite()) return Countdown("—", "no estimate")
		if (!cached) return Display.countdown(time, timestamp ?: 0.0, now, false, timeFormat, staleAfter)
		if (time < now) return Countdown(Display.clockTime(time, timeFormat), "estimate passed")
		if (!isEstimateUsable(timestamp, now, preferences)) return Countdown(Display.clockTime(time, timeFormat), "last estimate")
		return Countdown(if (time - now < 60) "<1" else floor((time - now) / 60).toLong().toString(), "min")
	}
	fun countdown(departure: Departure, now: Double, cached: Boolean, preferences: OfflineSettings, timeFormat: String = "12h"): Countdown = withdrawn(departure.relationship)?.let { Countdown("—", it) } ?: countdown(departure.time, departure.timestamp, now, cached, preferences, timeFormat, Display.predictionStaleAfter(departure.staleAfter, departure.feed))
	fun countdown(stop: StopPrediction, sourceTimestamp: Double?, now: Double, cached: Boolean, preferences: OfflineSettings, timeFormat: String = "12h", staleAfter: Double? = null): Countdown = withdrawn(stop.relationship)?.let { Countdown("—", it) } ?: countdown(stop.arrival ?: stop.departure, sourceTimestamp, now, cached, preferences, timeFormat, staleAfter)
	fun estimateLabel(timestamp: Double?, now: Double, preferences: OfflineSettings): String {
		if (timestamp == null || !timestamp.isFinite() || timestamp <= 0) return "Offline · source time unknown · no estimate"
		if (timestamp > now) return "Offline · source time is ahead of this device · no estimate"
		return (if (isEstimateUsable(timestamp, now, preferences)) "Offline estimate · " else "Last known times · ") + "source " + Display.ageLabel(timestamp, now)
	}
	fun estimatedNextStopIndex(stops: List<StopPrediction>, now: Double): Int? = stops.indexOfFirst { withdrawn(it.relationship) == null && (it.arrival ?: it.departure)?.let { time -> time.isFinite() && time >= now } == true }.takeIf { it >= 0 }
	fun currentConsist(consist: Consist?, now: Double, cached: Boolean): Boolean = !cached && Display.currentConsist(consist, now)
	fun completenessLabel(isComplete: Boolean): String? = if (isComplete) null else partialTripLabel
	private fun withdrawn(relationship: String?): String? = when (relationship) { "CANCELED", "DELETED" -> "canceled"; "SKIPPED" -> "skipped"; "NO_DATA" -> "no estimate"; else -> null }
}
