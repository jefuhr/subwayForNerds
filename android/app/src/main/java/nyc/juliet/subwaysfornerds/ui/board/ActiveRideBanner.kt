package nyc.juliet.subwaysfornerds.ui.board

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import nyc.juliet.subwaysfornerds.core.Display
import nyc.juliet.subwaysfornerds.core.Freshness
import nyc.juliet.subwaysfornerds.core.OfflineDisplay
import nyc.juliet.subwaysfornerds.ui.AppModel
import nyc.juliet.subwaysfornerds.ui.components.RouteBullet
import nyc.juliet.subwaysfornerds.ui.components.RowContainer
import nyc.juliet.subwaysfornerds.ui.navigation.Route
import nyc.juliet.subwaysfornerds.ui.theme.TextRoles
import nyc.juliet.subwaysfornerds.ui.theme.palette

/**
 * The followed train, shown on the board until the rider ends it. Times are the saved
 * predictions; offline they are estimates, never observed positions.
 */
@Composable
fun ActiveRideBanner(model: AppModel, open: (Route) -> Unit) {
	val ride = model.activeRide ?: return
	val trip = model.activeRideTrip
	val train = trip?.train
	val now = model.now
	val source = trip?.sourceTimestamp
	val staleAfter = train?.let { Display.predictionStaleAfter(it.staleAfter, it.feed) }
	val cached = !model.connected || Display.freshness(source, now, staleAfter) != Freshness.LIVE
	val stops = trip?.stops.orEmpty()
	val withdrawn = when {
		train?.relationship in setOf("CANCELED", "DELETED") -> "Canceled in the last report · no estimate"
		train?.assigned == false -> "Not assigned to a train in the last report · no estimate"
		else -> null
	}
	val next = if (withdrawn == null) OfflineDisplay.estimatedNextStopIndex(stops, now) else null
	var confirmEnd by rememberSaveable { mutableStateOf(false) }
	RowContainer(Modifier.testTag("activeRideBanner"), padding = PaddingValues(0.dp)) {
		Row(verticalAlignment = Alignment.CenterVertically) {
			Column(
				Modifier.weight(1f)
					.clickable(role = Role.Button, onClickLabel = "Open ride details") { open(Route.Train(ride.key)) }
					.testTag("openRide")
					.padding(start = 16.dp, top = 10.dp, bottom = 10.dp),
				verticalArrangement = Arrangement.spacedBy(4.dp),
			) {
				Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
					train?.route?.let { RouteBullet(it, small = true) }
					Column {
						Text("Your ride" + (train?.let { " · ${it.destination}" } ?: ""), style = TextRoles.subheadlineBold)
						when {
							withdrawn != null -> Text(withdrawn, style = TextRoles.caption)
							next != null -> {
								// Always an estimate: the next stop comes from predictions, never an observed position.
								val stop = stops[next]
								val countdown = OfflineDisplay.countdown(stop, source, now, cached, model.offlinePreferences, model.timeFormat, staleAfter)
								Text(
									"Estimated next stop ${stop.name} · " + if (countdown.unit == "min") "${countdown.value} min" else "${countdown.value} ${countdown.unit}",
									style = TextRoles.caption, modifier = Modifier.testTag("rideNextStop"),
								)
							}
							trip == null -> Text("No saved details for this train yet.", style = TextRoles.caption)
							else -> Text("Every saved stop time has passed · estimate passed", style = TextRoles.caption)
						}
					}
				}
				if (cached && trip != null) {
					Text(OfflineDisplay.estimateLabel(source, now, model.offlinePreferences), style = TextRoles.caption2, color = palette.muted)
				}
				if (trip != null) OfflineDisplay.completenessLabel(trip.isComplete)?.let { Text(it, style = TextRoles.caption2.copy(fontWeight = FontWeight.SemiBold)) }
			}
			IconButton(onClick = { confirmEnd = true }, modifier = Modifier.padding(end = 4.dp).testTag("endRideFromBanner")) {
				Icon(Icons.Filled.Close, contentDescription = "End ride", tint = palette.action)
			}
		}
	}
	if (confirmEnd) AlertDialog(
		onDismissRequest = { confirmEnd = false },
		title = { Text("End this ride?") },
		text = { Text("Its snapshot then expires like other cached trips unless you saved it.") },
		confirmButton = { TextButton(onClick = { confirmEnd = false; model.launch { model.endRide() } }, modifier = Modifier.testTag("confirmEndRide")) { Text("End ride", color = palette.danger) } },
		dismissButton = { TextButton(onClick = { confirmEnd = false }) { Text("Cancel", color = palette.action) } },
	)
}
