package nyc.juliet.subwaysfornerds.ui.board

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import nyc.juliet.subwaysfornerds.core.Countdown
import nyc.juliet.subwaysfornerds.core.Departure
import nyc.juliet.subwaysfornerds.core.Display
import nyc.juliet.subwaysfornerds.core.Freshness
import nyc.juliet.subwaysfornerds.core.OfflineDisplay
import nyc.juliet.subwaysfornerds.core.OfflineSettings
import nyc.juliet.subwaysfornerds.core.TrainFavoriteMatch
import nyc.juliet.subwaysfornerds.core.TrainFavoriteRules
import nyc.juliet.subwaysfornerds.core.TrainFavorites
import nyc.juliet.subwaysfornerds.ui.components.ChangeIcons
import nyc.juliet.subwaysfornerds.ui.components.RouteBullet
import nyc.juliet.subwaysfornerds.ui.theme.TextRoles
import nyc.juliet.subwaysfornerds.ui.theme.palette
import kotlin.math.roundToInt

/** Formatting rules for one departure row, kept out of the composable so they can be tested. */
object DepartureFormat {
	/** Cached rows count down the saved prediction on the device clock and say so. */
	fun countdown(departure: Departure, now: Double, cached: Boolean, preferences: OfflineSettings, timeFormat: String): Countdown {
		// An unassigned train has no saved prediction to count down from.
		if (cached && departure.assigned == false && Display.boardable(departure)) return Countdown(Display.clockTime(departure.time, timeFormat), "not assigned")
		return OfflineDisplay.countdown(departure, now, cached, preferences, timeFormat)
	}

	fun historical(departure: Departure, now: Double, cached: Boolean): Boolean =
		cached || Display.freshness(departure, now) != Freshness.LIVE || departure.locationTimestamp?.let { now - it > 90 } == true

	/** Minutes after the previous boardable train on the same platform and track, live only. */
	fun gap(departure: Departure, previous: Departure?, now: Double, cached: Boolean): Int? {
		if (cached || !Display.boardable(departure) || previous == null) return null
		if (Display.freshness(previous, now) != Freshness.LIVE || Display.freshness(departure, now) != Freshness.LIVE) return null
		val before = previous.time ?: return null
		val after = departure.time ?: return null
		return ((after - before) / 60).roundToInt()
	}

	fun positionDetail(departure: Departure, now: Double): String {
		var detail = "Stop-relative position"
		departure.stopsAway?.takeIf { it >= 0 }?.let { detail = "$it ${if (it == 1) "stop" else "stops"} away" }
		departure.locationTimestamp?.let { detail += " · " + Display.ageLabel(it, now) }
		return detail
	}

	fun consistLine(departure: Departure, now: Double, cached: Boolean): String? {
		val consist = departure.consist ?: return null
		if (cached || !Display.currentConsist(consist, now)) return null
		val types = consist.cars.mapNotNull { it.type }.distinct().sorted().joinToString(" / ")
		val age = if (Display.freshness(consist.updatedAt, now) == Freshness.LIVE) "" else " · last reported"
		return "$types · ${Display.consistSummary(consist.cars)}$age"
	}

	fun favoriteLabel(match: TrainFavoriteMatch): String =
		if (match.exactConsist) "Favorite consist" else "Favorite cars: " + match.carIDs.joinToString(", ") { TrainFavoriteRules.label(it) }

	/** The previous boardable departure on the same direction, platform and track. */
	fun previous(departures: List<Departure>, index: Int): Departure? {
		val departure = departures[index]
		return departures.take(index).lastOrNull { candidate ->
			Display.boardable(candidate) && candidate.direction == departure.direction && candidate.partId == departure.partId &&
				(candidate.actualTrack ?: candidate.scheduledTrack) == (departure.actualTrack ?: departure.scheduledTrack)
		}
	}

	/** The same predecessor rule for a whole group, in one pass rather than a prefix scan per row. */
	fun predecessors(departures: List<Departure>): List<Departure?> {
		data class BoardingPlace(val direction: String, val partID: String, val track: String?)
		val latest = mutableMapOf<BoardingPlace, Departure>()
		return departures.map { departure ->
			val place = BoardingPlace(departure.direction, departure.partId, departure.actualTrack ?: departure.scheduledTrack)
			val previous = latest[place]
			if (Display.boardable(departure)) latest[place] = departure
			previous
		}
	}
}

@Composable
fun DepartureRow(
	departure: Departure,
	now: Double,
	cached: Boolean,
	previous: Departure?,
	showPlatform: Boolean,
	preferences: OfflineSettings,
	timeFormat: String,
	favorites: TrainFavorites,
	modifier: Modifier = Modifier,
	boardingStation: String? = null,
) {
	val countdown = DepartureFormat.countdown(departure, now, cached, preferences, timeFormat)
	val match = favorites.match(departure.consist, departure.feed, now, cached)
	val gap = DepartureFormat.gap(departure, previous, now, cached)
	val boardable = Display.boardable(departure)
	Column(
		modifier
			.fillMaxWidth()
			.then(if (match != null) Modifier.background(palette.accentTint, RoundedCornerShape(8.dp)).padding(horizontal = 4.dp, vertical = 2.dp) else Modifier)
			.semantics(mergeDescendants = true) {},
		verticalArrangement = Arrangement.spacedBy(2.dp),
	) {
		if (boardingStation != null) Text("Board at $boardingStation", style = TextRoles.caption.copy(fontWeight = FontWeight.SemiBold), color = palette.muted)
		Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.Top) {
			RouteBullet(departure.route, small = true)
			Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
				Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.Top) {
					Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
						Text(
							departure.destination,
							style = TextRoles.subheadlineBold,
							textDecoration = if (boardable) null else TextDecoration.LineThrough,
						)
						Row(horizontalArrangement = Arrangement.spacedBy(5.dp), verticalAlignment = Alignment.CenterVertically) {
							Text(departure.pattern + if (departure.patternSource == "inferred") " · est." else "", style = TextRoles.caption2, color = palette.muted)
							ChangeIcons(departure.changes.orEmpty(), now, alerts = departure.alerts, cached = cached)
						}
					}
					CountdownColumn(departure, countdown, cached, timeFormat)
				}
				if (showPlatform) Text(Display.boardingLabel(departure), style = TextRoles.caption2, color = palette.muted, modifier = Modifier.testTag("boardingPlatform_${departure.key}"))
				val position = departure.vehiclePosition
				if (position != null) {
					Display.currentVehiclePositions(listOf(position), now).firstOrNull()?.let { Text(Display.vehiclePositionLabel(it, now, cached), style = TextRoles.caption) }
				} else if (!departure.feed.startsWith("njt-") && departure.location.isNotEmpty()) {
					Text((if (DepartureFormat.historical(departure, now, cached)) "Last report: " else "") + departure.location, style = TextRoles.caption)
				}
				Row {
					if (!departure.feed.startsWith("njt-")) Text(DepartureFormat.positionDetail(departure, now), style = TextRoles.caption2, color = palette.muted, modifier = Modifier.weight(1f))
					else androidx.compose.foundation.layout.Spacer(Modifier.weight(1f))
					if (gap != null && gap > 0) Text("+${gap}m after previous", style = TextRoles.caption2, color = palette.muted)
				}
				DepartureFormat.consistLine(departure, now, cached)?.let { Text(it, style = TextRoles.caption2, color = palette.muted, maxLines = 1, overflow = TextOverflow.Ellipsis) }
				if (match != null) {
					Row(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
						Icon(Icons.Filled.Star, contentDescription = null, tint = palette.action, modifier = Modifier.size(12.dp))
						Text(DepartureFormat.favoriteLabel(match), style = TextRoles.caption2.copy(fontWeight = FontWeight.SemiBold))
					}
				}
				if (departure.assigned == false) Text("Not yet assigned", style = TextRoles.caption2.copy(fontWeight = FontWeight.SemiBold))
				if (!boardable) Text(departure.relationship?.lowercase() ?: "Not boarding", style = TextRoles.caption.copy(fontWeight = FontWeight.Bold))
			}
		}
	}
}

/** The arrival stays the strongest text in a row; "min" is set smaller than the value. */
@Composable
private fun CountdownColumn(departure: Departure, countdown: Countdown, cached: Boolean, timeFormat: String) {
	Column(horizontalAlignment = Alignment.End, modifier = Modifier.widthIn(min = 56.dp)) {
		if (Display.boardable(departure)) {
			Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(2.dp)) {
				Text(countdown.value, style = TextRoles.title2, textAlign = TextAlign.End)
				if (countdown.unit == "min") Text("min", style = TextRoles.caption2.copy(fontWeight = FontWeight.SemiBold), modifier = Modifier.padding(bottom = 4.dp))
			}
			Text(
				if (countdown.unit == "min") (if (cached) "offline est. " else "") + Display.clockTime(departure.time, timeFormat) else countdown.unit,
				style = TextRoles.caption2,
				color = palette.muted,
				textAlign = TextAlign.End,
			)
		} else {
			Text("—", style = TextRoles.title2)
			Text("not boarding", style = TextRoles.caption2, color = palette.muted)
		}
	}
}
