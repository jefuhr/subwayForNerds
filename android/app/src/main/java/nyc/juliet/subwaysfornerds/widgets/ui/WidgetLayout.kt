package nyc.juliet.subwaysfornerds.widgets.ui

import nyc.juliet.subwaysfornerds.core.Display
import nyc.juliet.subwaysfornerds.core.WidgetDisplay
import nyc.juliet.subwaysfornerds.widgets.runtime.WidgetColumn
import nyc.juliet.subwaysfornerds.widgets.runtime.WidgetDeparture
import nyc.juliet.subwaysfornerds.widgets.runtime.WidgetSnapshot
import kotlin.math.floor

/**
 * Widget presentation rules, kept apart from Glance so they can be tested. Android widgets
 * show arrival clocks, which stay true between refreshes, beside the source report time.
 */
object WidgetLayout {
	private val regular = listOf("NORTH", "SOUTH")
	private val regional = listOf("TO_NY", "TO_NJ")

	/** Whether a board mixes subway and PATH directions, which cannot share two compass columns. */
	fun mixed(snapshot: WidgetSnapshot): Boolean {
		val directions = snapshot.columns.map { it.direction }.toSet()
		return directions.any { it in regular } && directions.any { it in regional } && snapshot.columns.any { it.direction in regional && it.rows.isNotEmpty() } && snapshot.columns.any { it.direction in regular && it.rows.isNotEmpty() }
	}

	/** Both directions are always represented, in the Home screen or lock screen order. */
	fun columns(snapshot: WidgetSnapshot, lockScreen: Boolean): List<WidgetColumn> {
		val path = snapshot.columns.any { it.direction in regional && it.rows.isNotEmpty() } && snapshot.columns.none { it.direction in regular && it.rows.isNotEmpty() } ||
			snapshot.columns.isNotEmpty() && snapshot.columns.all { it.direction in regional }
		val pair = if (path) regional else regular
		val ordered = if (!lockScreen) pair else {
			val downtownLeft = snapshot.lockScreen.directionOrder != "uptownLeft"
			val left = if (path) "TO_NJ" else "SOUTH"
			val right = if (path) "TO_NY" else "NORTH"
			if (downtownLeft) listOf(left, right) else listOf(right, left)
		}
		return ordered.map { direction -> snapshot.columns.firstOrNull { it.direction == direction } ?: WidgetColumn(direction, Display.directionLabel(direction), emptyList()) }
	}

	/** One merged list for mixed subway and PATH boards, each row keeping its own direction. */
	fun mergedRows(snapshot: WidgetSnapshot): List<WidgetDeparture> =
		snapshot.columns.flatMap { it.rows }.sortedWith(compareBy<WidgetDeparture> { it.arrival ?: Double.POSITIVE_INFINITY }.thenBy { it.departure.key })

	/** The most trains per direction that fit; a chosen count is an upper limit. Never fewer than one. */
	fun rowsThatFit(heightDp: Float, headerDp: Float, footerDp: Float, rowDp: Float, limit: Int, maximum: Int): Int {
		val available = heightDp - headerDp - footerDp
		val fit = if (rowDp <= 0f) maximum else floor(available / rowDp).toInt()
		val cap = if (limit <= 0) maximum else minOf(limit, maximum)
		return fit.coerceIn(1, maxOf(1, cap))
	}

	fun shows(display: WidgetDisplay, field: String): Boolean = field in display.fields

	/** "12:34" without AM/PM; the report time carries it. */
	fun shortClock(time: Double?, format: String): String = Display.clockTime(time, format).substringBefore(' ')

	/** The arrival shown for a row: a clock time, or "Passed" once a saved estimate has gone by. */
	fun arrival(row: WidgetDeparture, now: Double, format: String): String {
		val time = row.arrival ?: return "—"
		if (!Display.boardable(row.departure)) return "—"
		if (row.cached && time < now) return "Passed"
		return shortClock(time, format)
	}

	/** Source time for live rows; offline estimates and last known times always say so with their age. */
	fun reportLabel(snapshot: WidgetSnapshot, now: Double): String? {
		val source = snapshot.sourceTime ?: return if (snapshot.estimated) "Offline · source time unknown" else null
		if (!snapshot.estimated) return "As of " + Display.clockTime(source, snapshot.timeFormat)
		return (if (snapshot.estimateUsable) "Offline estimate" else "Last known times") + " · " + Display.ageLabel(source, now)
	}

	fun arrow(direction: String): String = when (direction) { "NORTH" -> "↑"; "SOUTH" -> "↓"; "TO_NY" -> "→"; "TO_NJ" -> "←"; else -> "•" }

	fun shortDirection(direction: String): String = when (direction) { "NORTH" -> "↑ N"; "SOUTH" -> "↓ S"; "TO_NY" -> "→ NY"; "TO_NJ" -> "← NJ"; else -> "?" }

	/** Spoken description of one row, for TalkBack on the widget. */
	fun rowDescription(row: WidgetDeparture, now: Double, format: String, detail: String): String {
		val arrival = arrival(row, now, format)
		val when_ = if (arrival == "Passed") "estimate passed" else "arriving $arrival"
		return listOf(
			"${Display.routeLabel(row.route)} to ${row.destination}",
			Display.directionLabel(row.departure.direction),
			when_,
			if (row.cached) "offline estimate" else "estimated arrival",
			row.originLabel?.let { "board at $it" },
			detail.takeIf { it.isNotEmpty() },
		).filterNotNull().joinToString(", ")
	}
}
