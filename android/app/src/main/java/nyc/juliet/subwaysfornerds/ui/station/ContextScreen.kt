package nyc.juliet.subwaysfornerds.ui.station

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Accessible
import androidx.compose.material.icons.filled.Map
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import nyc.juliet.subwaysfornerds.core.Display
import nyc.juliet.subwaysfornerds.core.LoadProgress
import nyc.juliet.subwaysfornerds.core.Station
import nyc.juliet.subwaysfornerds.core.StationContext
import nyc.juliet.subwaysfornerds.core.TransitJson
import nyc.juliet.subwaysfornerds.core.TransitLinks
import nyc.juliet.subwaysfornerds.ui.AppModel
import nyc.juliet.subwaysfornerds.ui.CoreBridge
import nyc.juliet.subwaysfornerds.ui.components.LinkButton
import nyc.juliet.subwaysfornerds.ui.components.ListScreen
import nyc.juliet.subwaysfornerds.ui.components.LoadingBar
import nyc.juliet.subwaysfornerds.ui.components.NavigationRow
import nyc.juliet.subwaysfornerds.ui.components.Notice
import nyc.juliet.subwaysfornerds.ui.components.RawJsonDisclosure
import nyc.juliet.subwaysfornerds.ui.components.RouteStrip
import nyc.juliet.subwaysfornerds.ui.components.RowContainer
import nyc.juliet.subwaysfornerds.ui.components.ScreenExit
import nyc.juliet.subwaysfornerds.ui.components.SourcesTable
import nyc.juliet.subwaysfornerds.ui.components.openLink
import nyc.juliet.subwaysfornerds.ui.components.section
import nyc.juliet.subwaysfornerds.ui.navigation.Route
import nyc.juliet.subwaysfornerds.ui.theme.TextRoles
import nyc.juliet.subwaysfornerds.ui.theme.palette

/** Equipment status rules from the iOS context view. */
object StationContextRules {
	fun outageFresh(context: StationContext?, connected: Boolean, error: String?, now: Double): Boolean {
		val outages = context?.sources?.firstOrNull { it.id == "outages" } ?: return false
		return connected && error == null && (outages.timestamp ?: 0.0) > 0 && outages.error == null && now - (outages.fetchedAt ?: 0.0) <= 120
	}

	fun equipmentStatus(equipment: Map<String, String>, context: StationContext, fresh: Boolean): Pair<String, Boolean> {
		val reports = context.outages.filter { (it["equipment"] ?: it["equipmentno"]) == equipment["equipmentno"] }
		val current = reports.filter { it["isupcomingoutage"] != "Y" }
		val equipmentFetched = context.sources.firstOrNull { it.id == "equipment" }?.fetchedAt != null
		val status = when {
			current.isNotEmpty() -> "Outage reported"
			fresh && equipmentFetched -> if (equipment["isactive"] == "N") "Inactive" else "No current outage reported"
			else -> "Status unknown"
		}
		return status to current.isNotEmpty()
	}

	fun adaLabel(ada: String): String = when (ada) {
		"1" -> "ADA accessible"; "2" -> "Partially accessible"; "0" -> "Not ADA accessible"; else -> "Accessibility information unavailable"
	}

	fun entranceUrl(entrance: Map<String, String>): String? {
		val lat = entrance["entrance_latitude"]?.toDoubleOrNull() ?: return null
		val lon = entrance["entrance_longitude"]?.toDoubleOrNull() ?: return null
		if (kotlin.math.abs(lat) > 90 || kotlin.math.abs(lon) > 180) return null
		return "https://www.openstreetmap.org/?mlat=$lat&mlon=$lon#map=19/$lat/$lon"
	}
}

/** Accessibility, elevators and escalators, and entrances for a station; member list for combined stations. */
@Composable
fun ContextScreen(model: AppModel, stationID: String, exit: ScreenExit, close: () -> Unit, open: (Route) -> Unit) {
	val station = model.allStations.firstOrNull { it.id == stationID } ?: model.station?.takeIf { it.id == stationID }
	var context by remember(stationID) { mutableStateOf<StationContext?>(null) }
	var error by remember(stationID) { mutableStateOf<String?>(null) }
	var progress by remember(stationID) { mutableStateOf<LoadProgress?>(null) }
	var generation by remember(stationID) { mutableIntStateOf(0) }
	val lifecycle = LocalLifecycleOwner.current.lifecycle
	val subject = "elevator, escalator and entrance records"
	val combined = model.combinedStations[stationID]
	val external = station?.departureMode == "external"

	suspend fun refresh() {
		if (station == null || station.isCombined || external) return
		val requested = model.endpoint
		generation += 1
		val current = generation
		val waiting = context == null
		if (waiting) progress = null
		try {
			val value = model.service.context(stationID, if (waiting) { update -> if (current == generation) progress = update.load(subject) } else null)
			if (requested != model.endpoint || current != generation) return
			context = value; error = null
		} catch (failure: CancellationException) { throw failure }
		catch (_: Exception) { if (requested == model.endpoint && current == generation) error = "Station context unavailable. Previous equipment reports may be stale." }
	}

	LaunchedEffect(stationID, model.endpoint, model.connected) {
		if (station == null || station.isCombined || external) return@LaunchedEffect
		lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) { while (true) { refresh(); delay(60_000) } }
	}

	ListScreen(station?.name ?: "Station info", exit = exit, onExit = close, onRefresh = { refresh() }, tag = "stationContext") {
		if (station == null) {
			section("missing") { row { RowContainer { Notice("This station is not in the saved catalog. Reconnect to load it.") } } }
			return@ListScreen
		}
		if (combined != null) {
			section("members", header = "Member stations") {
				combined.stationIDs.forEach { id ->
					row(id) {
						val member = model.stations.firstOrNull { it.id == id }
						if (member != null) NavigationRow(member.name, { open(Route.StationInfo(member.id)) }, leading = null, subtitle = null)
						else RowContainer { Text("Unavailable station $id", style = TextRoles.subheadline, color = palette.muted) }
					}
				}
			}
			return@ListScreen
		}
		if (external) {
			section("external") {
				row {
					RowContainer {
						Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
							Text(station.parts.firstOrNull()?.line ?: "NJ Transit light rail", style = TextRoles.headline)
							Text((station.municipality?.let { "$it · " } ?: "") + "NJ Transit station ${station.parts.firstOrNull()?.stationId ?: station.id}", style = TextRoles.subheadline)
						}
					}
				}
				row { RowContainer { Notice("Live equipment status and entrance details are not connected for this station.") } }
				row { LinkButton("NJ Transit light rail accessibility and travel information", TransitLinks.njtAccessibility, Modifier.padding(start = 4.dp)) }
			}
			return@ListScreen
		}
		section("ada", header = "Accessibility") {
			station.parts.forEach { part ->
				row(part.id) {
					RowContainer(Modifier.semantics(mergeDescendants = true) {}) {
						Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
							Row(verticalAlignment = Alignment.CenterVertically) {
								Text(part.line, style = TextRoles.subheadlineBold, modifier = Modifier.weight(1f))
								Icon(Icons.AutoMirrored.Filled.Accessible, contentDescription = null, tint = if (part.ada == "1") palette.action else palette.muted, modifier = Modifier.size(15.dp))
								Text(" " + StationContextRules.adaLabel(part.ada), style = TextRoles.caption.copy(fontWeight = FontWeight.SemiBold), color = if (part.ada == "1") palette.action else palette.muted)
							}
							if (part.adaNotes.isNotEmpty()) Text(part.adaNotes, style = TextRoles.caption)
							Text("${part.id} · ${part.north} / ${part.south}", style = TextRoles.caption2, color = palette.muted)
						}
					}
				}
			}
		}
		error?.let { message -> section("error") { row { RowContainer { Notice(message) } } } }
		val current = context
		if (current == null) {
			if (error == null) section("loading") {
				row {
					val load = progress ?: nyc.juliet.subwaysfornerds.ui.waitingLoad(subject, model.connected)
					RowContainer { LoadingBar("Loading station context", load.fraction?.toFloat(), load.percentLabel, load.spokenPercent, load.detail, Modifier.testTag("contextLoading")) }
				}
			}
			return@ListScreen
		}
		val fresh = StationContextRules.outageFresh(current, model.connected, error, model.now)
		val outageSource = current.sources.firstOrNull { it.id == "outages" }
		val equipmentSource = current.sources.firstOrNull { it.id == "equipment" }
		section(
			"equipment", header = "Elevators & escalators",
			footer = outageSource?.fetchedAt?.let { "Outage feed fetched ${Display.ageLabel(it, model.now)}" } ?: "Outage feed not yet received",
		) {
			if (!fresh) row { RowContainer { Notice("Current equipment status is unavailable or stale") } }
			current.equipment.forEachIndexed { index, equipment -> row("equipment$index") { EquipmentRow(model, equipment, current, fresh) } }
			if (current.equipment.isEmpty()) row {
				RowContainer { Text(if (equipmentSource?.fetchedAt == null) "Equipment feed not yet available" else "No equipment records matched this station", style = TextRoles.subheadline, color = palette.muted) }
			}
		}
		section("entrances", header = "Entrances · ${current.entrances.size}") {
			current.entrances.forEachIndexed { index, entrance -> row("entrance$index") { EntranceRow(station, entrance, index) } }
			if (current.entrances.isEmpty()) row { RowContainer { Text("No entrance data available", style = TextRoles.subheadline, color = palette.muted) } }
		}
		if (current.sources.isNotEmpty()) section("sources", header = "Source freshness") { row { RowContainer { SourcesTable(current.sources, model.now) } } }
		section("raw") { row { RawJsonDisclosure("Published station records", TransitJson.encodeToJsonElement(StationContext.serializer(), current)) } }
	}
}

@Composable
private fun EquipmentRow(model: AppModel, equipment: Map<String, String>, context: StationContext, fresh: Boolean) {
	val (status, outage) = StationContextRules.equipmentStatus(equipment, context, fresh)
	val reports = context.outages.filter { (it["equipment"] ?: it["equipmentno"]) == equipment["equipmentno"] }
	var expanded by rememberSaveable(equipment["equipmentno"]) { mutableStateOf(false) }
	RowContainer {
		Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
			Row(verticalAlignment = Alignment.Top) {
				Text("${equipment["equipmentno"] ?: "Equipment"} · ${equipment["shortdescription"] ?: equipment["serving"].orEmpty()}", style = TextRoles.subheadlineBold, modifier = Modifier.weight(1f))
				Text(status, style = TextRoles.caption.copy(fontWeight = FontWeight.SemiBold), color = if (outage) palette.warning else palette.muted)
			}
			equipment["serving"]?.let { Text(it, style = TextRoles.caption) }
			reports.forEach { report ->
				Text(
					(if (report["isupcomingoutage"] == "Y") "Upcoming: " else "") + (report["reason"] ?: "Outage") + " · " +
						Display.publishedClockText(report["outagedate"] ?: "Time unknown", model.timeFormat) + " → " +
						Display.publishedClockText(report["estimatedreturntoservice"] ?: "Return time unknown", model.timeFormat),
					style = TextRoles.caption2, color = palette.muted,
				)
			}
			val alternative = equipment["alternativeroute"]
			if (reports.isNotEmpty() && !alternative.isNullOrEmpty()) {
				Text(
					if (expanded) "Hide travel alternative" else "Travel alternative",
					style = TextRoles.caption.copy(fontWeight = FontWeight.SemiBold), color = palette.action,
					modifier = Modifier.heightIn(min = 48.dp).clickable(role = Role.Button) { expanded = !expanded }.padding(vertical = 14.dp),
				)
				if (expanded) Text(alternative, style = TextRoles.caption)
			}
		}
	}
}

@Composable
private fun EntranceRow(station: Station, entrance: Map<String, String>, index: Int) {
	val context = LocalContext.current
	Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 4.dp, top = 4.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
		Column(Modifier.weight(1f)) {
			Text("${entrance["constituent_station_name"] ?: station.name} · ${entrance["entrance_type"] ?: "Entrance"}", style = TextRoles.subheadlineBold)
			Text("Entry ${entrance["entry_allowed"]?.lowercase() ?: "unknown"} · exit ${entrance["exit_allowed"]?.lowercase() ?: "unknown"}", style = TextRoles.caption2, color = palette.muted)
		}
		StationContextRules.entranceUrl(entrance)?.let { url ->
			IconButton(onClick = { openLink(context, url) }, modifier = Modifier.semantics { contentDescription = "View entrance ${index + 1} on map" }) {
				Icon(Icons.Filled.Map, contentDescription = null, tint = palette.action)
			}
		}
	}
}
