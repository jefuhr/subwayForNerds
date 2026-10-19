package nyc.juliet.subwaysfornerds.ui.map

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import nyc.juliet.subwaysfornerds.core.SlowZoneDisplay
import nyc.juliet.subwaysfornerds.core.TrackMapSlowZoneDisplay
import nyc.juliet.subwaysfornerds.ui.theme.TextRoles
import nyc.juliet.subwaysfornerds.ui.theme.palette

@Composable
internal fun SlowZoneLegend(map: TrackMapModel, now: Double) {
	if (map.snapshot?.slowZones == null) return
	TextButton(onClick = { map.showSlowZoneList = true }, contentPadding = PaddingValues(vertical = 2.dp), modifier = Modifier.testTag("track-map-slow-zones")) {
		Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
			Box(Modifier.size(width = 22.dp, height = 5.dp).background(SlowZoneAmber))
			Text(map.slowZoneStatus(now) + " · Transit Lab · Details", style = TextRoles.caption, color = palette.ink, modifier = Modifier.weight(1f))
		}
	}
}

@Composable
internal fun SlowZoneList(map: TrackMapModel, now: Double) {
	val value = map.snapshot?.slowZones
	val active = TrackMapSlowZoneDisplay.isActive(value, now)
	val zones = map.slowZones(now)
	AlertDialog(
		onDismissRequest = { map.showSlowZoneList = false },
		title = { Text("Estimated slow zones", style = TextRoles.headline) },
		confirmButton = { TextButton(onClick = { map.showSlowZoneList = false }, modifier = Modifier.testTag("track-map-slow-zone-close")) { Text("Close") } },
		text = {
			LazyColumn(Modifier.fillMaxWidth().testTag("track-map-slow-zone-list"), verticalArrangement = Arrangement.spacedBy(8.dp)) {
				item("status") { Text(map.slowZoneStatus(now), style = TextRoles.footnote, color = palette.ink) }
				item("source") { Text(SlowZoneDisplay.attribution, style = TextRoles.caption, color = palette.muted) }
				if (active && value != null && value.unmappedCount > 0) item("unmapped") {
					Text("${value.unmappedCount} estimated zones have no reviewed map location and are not highlighted. This count covers all lines.", style = TextRoles.caption, color = palette.muted)
				}
				if (active && zones.isEmpty()) item("empty") { Text("No estimated slow zones match these lines.", style = TextRoles.caption, color = palette.muted) }
				items(zones, key = { "zone:${it.id}" }) { zone ->
					Column(Modifier.fillMaxWidth().testTag("track-map-slow-zone-${zone.id}").semantics(mergeDescendants = true) { contentDescription = TrackMapSlowZoneDisplay.detail(zone) }) {
						Text("Estimated ${SlowZoneDisplay.label(zone)}", style = TextRoles.subheadline, color = palette.ink)
						Text(zone.segment, style = TextRoles.footnote, color = palette.ink)
						Text("Typically +${SlowZoneDisplay.seconds(zone.extraSeconds)} · ${SlowZoneDisplay.seconds(zone.baselineSeconds)} baseline", style = TextRoles.caption, color = palette.ink)
						Text("Since ${SlowZoneDisplay.date(zone.since)} · through ${SlowZoneDisplay.date(zone.through)}", style = TextRoles.caption2, color = palette.muted)
						if (zone.paths.isEmpty()) Text("Location not highlighted: no reviewed map geometry", style = TextRoles.caption, color = palette.muted)
					}
					HorizontalDivider(color = palette.line)
				}
			}
		},
	)
}
