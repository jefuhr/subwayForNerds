package nyc.juliet.subwaysfornerds.ui.board

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.MyLocation
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import nyc.juliet.subwaysfornerds.core.Display
import nyc.juliet.subwaysfornerds.core.Station
import nyc.juliet.subwaysfornerds.core.StationLocation
import nyc.juliet.subwaysfornerds.core.Units
import nyc.juliet.subwaysfornerds.ui.AppModel
import nyc.juliet.subwaysfornerds.ui.Labels
import nyc.juliet.subwaysfornerds.ui.components.FavoriteStar
import nyc.juliet.subwaysfornerds.ui.components.ListHeader
import nyc.juliet.subwaysfornerds.ui.components.ListScreen
import nyc.juliet.subwaysfornerds.ui.components.Notice
import nyc.juliet.subwaysfornerds.ui.components.RouteStrip
import nyc.juliet.subwaysfornerds.ui.components.RowContainer
import nyc.juliet.subwaysfornerds.ui.components.ScreenExit
import nyc.juliet.subwaysfornerds.ui.components.section
import nyc.juliet.subwaysfornerds.ui.navigation.Route
import nyc.juliet.subwaysfornerds.ui.navigation.StationPickerMode
import nyc.juliet.subwaysfornerds.ui.theme.TextRoles
import nyc.juliet.subwaysfornerds.ui.theme.palette

/** Search and nearby ordering rules, shared with tests. */
object StationSearch {
	val quickSwitch = listOf("602", "617", "611", "607")

	fun distance(station: Station, location: StationLocation?): Double? = location?.distanceMeters(station)

	/** Matches by name, borough, line or member station; nearby sorts by distance, otherwise favorites first. */
	fun matches(stations: List<Station>, catalog: List<Station>, members: Map<String, List<String>>, query: String, favorites: List<String>, location: StationLocation?): List<Station> {
		val found = stations.filter { station ->
			Display.stationMatches(station, query) || members[station.id]?.any { id -> catalog.firstOrNull { it.id == id }?.let { Display.stationMatches(it, query) } == true } == true
		}
		return if (location != null) found.sortedBy { distance(it, location) ?: Double.POSITIVE_INFINITY }
		else found.sortedWith(compareBy<Station> { it.id !in favorites }.thenComparator { a, b -> nyc.juliet.subwaysfornerds.ui.NaturalOrder.compare(a.name, b.name) })
	}
}

/** "Find a station" and "Stations near you": each presentation starts empty in its own sort mode. */
@Composable
fun StationPickerScreen(model: AppModel, mode: StationPickerMode, close: () -> Unit) {
	var query by rememberSaveable(mode) { mutableStateOf("") }
	var nearbySort by rememberSaveable(mode) { mutableStateOf(mode == StationPickerMode.NEARBY) }
	val location = if (nearbySort) model.nearbyLocation else null
	val focus = remember { FocusRequester() }
	LaunchedEffect(mode) { if (mode == StationPickerMode.NEARBY) model.locateNearby() }
	val members = model.combinedStations.mapValues { it.value.stationIDs }
	val matches = StationSearch.matches(model.visibleStations, model.stations, members, query, model.favorites, location)
	fun choose(station: Station) { model.selectStation(station.id); close() }

	ListScreen(
		title = if (nearbySort) "Stations near you" else "Find a station",
		exit = ScreenExit.CLOSE,
		onExit = close,
		onRefresh = { model.refreshCatalog(force = true) },
		tag = "stationPicker",
	) {
		item("search") {
			OutlinedTextField(
				value = query,
				onValueChange = { query = it },
				placeholder = { Text("Station, line, or borough") },
				leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
				trailingIcon = { if (query.isNotEmpty()) IconButton(onClick = { query = "" }) { Icon(Icons.Filled.Clear, contentDescription = "Clear search") } },
				singleLine = true,
				keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false, imeAction = ImeAction.Search),
				colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = palette.accent, unfocusedBorderColor = palette.line, cursorColor = palette.action),
				modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp).focusRequester(focus).testTag("stationSearchField"),
			)
		}
		section("locate") {
			row {
				Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
					TextButton(
						onClick = { nearbySort = true; model.locateNearby() },
						enabled = !model.locating,
						modifier = Modifier.testTag("nearbyStations"),
					) {
						Icon(Icons.Filled.MyLocation, contentDescription = null, tint = palette.action, modifier = Modifier.size(18.dp))
						Text(if (model.locating) "  Finding your location…" else "  Stations near me", color = palette.action)
					}
					if (location != null) TextButton(onClick = { nearbySort = false }) { Text("Clear nearby sort", color = palette.action) }
				}
			}
			model.locationError?.let { error -> row { RowContainer { Notice(error) } } }
			model.catalogError?.let { error -> row { RowContainer { Notice(error) } } }
		}
		if (query.isEmpty() && !nearbySort) {
			val quick = StationSearch.quickSwitch.mapNotNull { id -> model.visibleStations.firstOrNull { it.id == id } }
			if (quick.isNotEmpty()) section("quick", header = "Quick switch") {
				quick.forEach { station ->
					row(station.id) {
						Text(
							station.name,
							style = TextRoles.subheadline,
							modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).clickable(role = Role.Button) { choose(station) }.padding(horizontal = 16.dp, vertical = 14.dp),
						)
					}
				}
			}
		}
		section("combined") {
			row {
				TextButton(onClick = { model.navigator.push(Route.CombinedEditor(closePickerOnSave = true)) }, modifier = Modifier.padding(start = 4.dp).testTag("addCombinedStation")) {
					Icon(Icons.Filled.Add, contentDescription = null, tint = palette.action)
					Text(" Create combined station", color = palette.action)
				}
			}
		}
		val summary = "${matches.size} station ${if (matches.size == 1) "complex" else "complexes"} · " +
			if (location != null) "closest first" else if (nearbySort && model.locating) "finding your location" else "favorites first"
		section(
			"results",
			headerContent = { ListHeader(summary, Modifier.testTag("nearbyStationSummary")) },
		) {
			matches.forEach { station ->
				row(station.id) { StationResult(model, station, location, { choose(station) }) }
			}
			if (matches.isEmpty()) row {
				RowContainer {
					Text(if (query.isEmpty()) "Connect to load the station catalog." else "No stations match “$query”. Try another name or line.", style = TextRoles.footnote, color = palette.muted, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
				}
			}
		}
	}
}

@Composable
private fun StationResult(model: AppModel, station: Station, location: StationLocation?, choose: () -> Unit) {
	val favorite = station.id in model.favorites
	Row(verticalAlignment = Alignment.CenterVertically) {
		Column(
			Modifier.weight(1f).heightIn(min = 48.dp).clickable(role = Role.Button, onClick = choose)
				.padding(start = 16.dp, top = 8.dp, bottom = 8.dp)
				.semantics(mergeDescendants = true) {}
				.testTag("station_${station.id}"),
			verticalArrangement = Arrangement.spacedBy(3.dp),
		) {
			Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
				Text(station.name, style = TextRoles.subheadlineBold, modifier = Modifier.weight(1f))
				val distance = StationSearch.distance(station, location)?.let { " · " + Units.distanceLabel(it, model.distanceUnit) } ?: ""
				Text((station.municipality?.let { "$it, " } ?: "") + Labels.borough(station.borough) + distance, style = TextRoles.caption2, color = palette.muted, textAlign = TextAlign.End)
			}
			RouteStrip(station.routes)
		}
		FavoriteStar(favorite, (if (favorite) "Remove favorite " else "Favorite ") + station.name, { model.toggleFavorite(station.id) })
	}
}
