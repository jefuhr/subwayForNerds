package nyc.juliet.subwaysfornerds.ui

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

private val eastern: ZoneId = ZoneId.of("America/New_York")
private val twelveHourDate = DateTimeFormatter.ofPattern("MMM d, yyyy 'at' h:mm a", Locale.US).withZone(eastern)
private val twentyFourHourDate = DateTimeFormatter.ofPattern("MMM d, yyyy 'at' HH:mm", Locale.US).withZone(eastern)

/** A New York date and time, always labeled ET, e.g. "Oct 13, 2026 at 9:41 PM ET". */
fun easternDate(timestamp: Double, timeFormat: String = "12h"): String {
	if (!timestamp.isFinite()) return "—"
	val formatter = if (timeFormat == "24h") twentyFourHourDate else twelveHourDate
	return formatter.format(Instant.ofEpochMilli((timestamp * 1000).toLong())) + " ET"
}

/** Whole numbers with thousands separators, as riders see counts in iOS. */
fun counted(value: Number): String = String.format(Locale.US, "%,d", value.toLong())
