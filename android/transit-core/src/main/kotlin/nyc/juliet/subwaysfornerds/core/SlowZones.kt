package nyc.juliet.subwaysfornerds.core

import java.time.LocalDate
import kotlin.math.max
import kotlin.math.roundToLong

/** Slow zone wording, matching the web client's shared/slow-zones.ts and SlowZones.tsx exactly. */
object SlowZoneDisplay {
	const val attribution = "Slow zones are estimated from weekday daytime run times by Transit Lab (transitlab.nyc, CC BY 4.0), built from MTA data. " +
		"Not an official MTA speed restriction list; the slow section can be anywhere between the two stops."
	private val months = listOf("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")

	/** Unknown future kinds read as an ordinary slow zone. */
	fun label(zone: SlowZoneEstimate): String = if (zone.kind == "disruption") "major slowdown" else "slow zone"

	/** Whole seconds: "42s", "1m 32s", or "2m" with nothing left over. */
	fun seconds(value: Double): String {
		val total = if (value.isFinite()) max(0L, value.roundToLong()) else 0L
		return if (total < 60) "${total}s" else "${total / 60}m" + if (total % 60 != 0L) " ${total % 60}s" else ""
	}

	/** "2026-08-10" -> "Aug 10", read as a calendar date so the device time zone never shifts the day. */
	fun date(value: String): String = runCatching { LocalDate.parse(value) }.getOrNull()?.let { "${months[it.monthValue - 1]} ${it.dayOfMonth}" } ?: value

	fun tag(zone: SlowZoneEstimate): String = "+" + seconds(zone.extraSeconds)

	fun accessibilityLabel(zone: SlowZoneEstimate): String = "In an estimated ${label(zone)}: ${zone.segment}, typically ${seconds(zone.extraSeconds)} slower"

	fun summary(zones: List<TrainSlowZone>?): String? {
		if (zones.isNullOrEmpty()) return null
		return "${zones.size} estimated slow ${if (zones.size == 1) "zone" else "zones"} ahead · about +${seconds(zones.sumOf { it.extraSeconds })} typical"
	}

	/** "now" marks the current zone only while the trip report is live. */
	fun heading(zone: TrainSlowZone, live: Boolean): String = label(zone) + if (zone.current == true && live) " · now" else ""

	fun detail(zone: SlowZoneEstimate): String =
		"${zone.segment} · +${seconds(zone.extraSeconds)} on a ${seconds(zone.baselineSeconds)} run · since ${date(zone.since)}"

	/** The segment row's spoken label: its two visible lines, marked as an estimate. */
	fun segmentAccessibilityLabel(zone: TrainSlowZone, live: Boolean): String = "Estimated ${heading(zone, live)}: ${detail(zone)}"

	/** Zones keyed by the stop their row goes before; indexes outside this snapshot's stops are skipped. */
	fun byStop(train: Train): Map<Int, List<TrainSlowZone>> =
		train.slowZones.orEmpty().filter { it.toIndex in train.stops.indices }.groupBy { it.toIndex }
}
