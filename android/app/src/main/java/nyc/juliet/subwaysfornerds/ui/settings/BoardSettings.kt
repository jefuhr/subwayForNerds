package nyc.juliet.subwaysfornerds.ui.settings

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.RadioButton
import androidx.compose.material3.RadioButtonDefaults
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import nyc.juliet.subwaysfornerds.core.Display
import nyc.juliet.subwaysfornerds.core.StationSelection
import nyc.juliet.subwaysfornerds.core.TrainFavoriteRules
import nyc.juliet.subwaysfornerds.core.Units
import nyc.juliet.subwaysfornerds.ui.AppModel
import nyc.juliet.subwaysfornerds.ui.CoreBridge
import nyc.juliet.subwaysfornerds.ui.Labels
import nyc.juliet.subwaysfornerds.ui.NaturalOrder
import nyc.juliet.subwaysfornerds.ui.components.ActionButton
import nyc.juliet.subwaysfornerds.ui.components.FavoriteStar
import nyc.juliet.subwaysfornerds.ui.components.ListScreen
import nyc.juliet.subwaysfornerds.ui.components.NavigationRow
import nyc.juliet.subwaysfornerds.ui.components.Notice
import nyc.juliet.subwaysfornerds.ui.components.RouteStrip
import nyc.juliet.subwaysfornerds.ui.components.RowContainer
import nyc.juliet.subwaysfornerds.ui.components.ScreenExit
import nyc.juliet.subwaysfornerds.ui.components.section
import nyc.juliet.subwaysfornerds.ui.fleet.SwitchRow
import nyc.juliet.subwaysfornerds.ui.navigation.Route
import nyc.juliet.subwaysfornerds.ui.theme.TextRoles
import nyc.juliet.subwaysfornerds.ui.theme.palette
import kotlin.math.roundToInt
import kotlinx.coroutines.CancellationException

@Composable
fun CombinedStationsScreen(model: AppModel, exit: ScreenExit, close: () -> Unit, open: (Route) -> Unit) {
	ListScreen("Combined stations", exit = exit, onExit = close, tag = "combinedStations") {
		section("create") {
			row {
				TextButton(onClick = { model.navigator.push(Route.CombinedEditor()) }, modifier = Modifier.padding(start = 4.dp).testTag("addCombinedStation")) {
					Icon(Icons.Filled.Add, contentDescription = null, tint = palette.action); Text(" Create combined station", color = palette.action)
				}
			}
		}
		section("list", header = "Your combined stations") {
			model.combinedStations.keys.sorted().forEach { id ->
				val definition = model.combinedStations[id] ?: return@forEach
				row(id) { NavigationRow(definition.name, { model.navigator.push(Route.CombinedEditor(id)) }, Modifier.testTag("editCombinedStation_$id"), subtitle = "${definition.stationIDs.size} stations") }
			}
			if (model.combinedStations.isEmpty()) row { RowContainer { Text("No combined stations yet.", style = TextRoles.footnote, color = palette.muted) } }
		}
	}
}

/** Creates or edits a combined station: a name and at least two member stations. */
@Composable
fun CombinedEditorScreen(model: AppModel, route: Route.CombinedEditor, close: () -> Unit) {
	val id = route.id
	val definition = id?.let { model.combinedStations[it] }
	var name by rememberSaveable(id) { mutableStateOf(definition?.name.orEmpty()) }
	var selected by rememberSaveable(id) { mutableStateOf(definition?.stationIDs.orEmpty().toSet().toList()) }
	var query by rememberSaveable(id) { mutableStateOf("") }
	var error by rememberSaveable(id) { mutableStateOf<String?>(null) }
	var confirmDelete by rememberSaveable(id) { mutableStateOf(false) }
	var saving by remember { mutableStateOf(false) }
	val matches = model.stations.filter { Display.stationMatches(it, query) }
		.sortedWith(compareBy<nyc.juliet.subwaysfornerds.core.Station> { it.id !in selected }.thenComparator { a, b -> NaturalOrder.compare(a.name, b.name) })
	val canSave = name.trim().isNotEmpty() && selected.size >= 2 && !saving
	ListScreen(
		if (id == null) "New combined station" else "Edit combined station", exit = ScreenExit.CLOSE, onExit = close, tag = "combinedEditor",
		actions = {
			TextButton(
				onClick = {
					saving = true
					// The model's scope finishes the save even if this screen closes meanwhile.
					model.launch {
						try {
							model.saveCombinedStation(id, name, selected)
							close()
							if (route.closePickerOnSave) model.navigator.closeOverlays()
						} catch (failure: CancellationException) { throw failure }
						catch (failure: Exception) { error = failure.message ?: "This combined station could not be saved." }
						finally { saving = false }
					}
				},
				enabled = canSave,
				modifier = Modifier.testTag("saveCombinedStation"),
			) { Text("Save", color = if (canSave) palette.action else palette.muted) }
		},
	) {
		section("name") {
			row {
				OutlinedTextField(
					value = name, onValueChange = { name = it }, label = { Text("Combined station name") }, singleLine = true,
					keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
					colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = palette.accent, unfocusedBorderColor = palette.line),
					modifier = Modifier.fillMaxWidth().padding(12.dp).testTag("combinedStationName"),
				)
			}
			row {
				OutlinedTextField(
					value = query, onValueChange = { query = it }, placeholder = { Text("Find stations to combine") }, singleLine = true,
					leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
					trailingIcon = { if (query.isNotEmpty()) IconButton(onClick = { query = "" }) { Icon(Icons.Filled.Clear, contentDescription = "Clear station search") } },
					keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, imeAction = ImeAction.Search),
					colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = palette.accent, unfocusedBorderColor = palette.line),
					modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp).testTag("combinedStationSearch"),
				)
			}
		}
		if (id != null) section("delete") { row { ActionButton("Delete combined station", { confirmDelete = true }, Modifier.padding(start = 4.dp).testTag("deleteCombinedStation"), destructive = true) } }
		error?.let { message -> section("error") { row { RowContainer { Notice(message) } } } }
		section("members", header = "${selected.size} selected") {
			selected.filter { member -> model.stations.none { it.id == member } }.sorted().forEach { missing ->
				row("missing:$missing") {
					Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).clickable(role = Role.Button) { selected = selected - missing }.padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
						Icon(Icons.Filled.Warning, contentDescription = null, tint = palette.warning)
						Text("  Unavailable station $missing · remove", style = TextRoles.subheadline)
					}
				}
			}
			matches.forEach { station ->
				row(station.id) {
					val isSelected = station.id in selected
					Row(
						Modifier.fillMaxWidth().heightIn(min = 48.dp)
							.selectable(isSelected, role = Role.Checkbox) { selected = if (isSelected) selected - station.id else selected + station.id }
							.padding(horizontal = 16.dp, vertical = 8.dp)
							.testTag("combinedStationMember_${station.id}"),
						verticalAlignment = Alignment.CenterVertically,
					) {
						Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
							Text(station.name, style = TextRoles.subheadlineBold)
							Text((station.municipality?.let { "$it · " } ?: "") + Labels.borough(station.borough), style = TextRoles.caption, color = palette.muted)
							RouteStrip(station.routes)
							if (CoreBridge.visibleStation(station, model.hiddenRoutes) == null) Text("Lines hidden in settings", style = TextRoles.caption, color = palette.muted)
						}
						Icon(if (isSelected) Icons.Filled.CheckCircle else Icons.Outlined.Circle, contentDescription = null, tint = palette.action)
					}
				}
			}
		}
	}
	if (confirmDelete && id != null) AlertDialog(
		onDismissRequest = { confirmDelete = false },
		title = { Text("Delete combined station?") },
		text = { Text("Its favorite and board filters will be removed. Original stations and saved trips stay available.") },
		confirmButton = {
			TextButton(onClick = {
				confirmDelete = false
				saving = true
				model.launch {
					try { model.deleteCombinedStation(id); close() }
					catch (failure: CancellationException) { throw failure }
					catch (failure: Exception) { error = failure.message ?: "This combined station could not be deleted." }
					finally { saving = false }
				}
			}, modifier = Modifier.testTag("confirmDeleteCombinedStation")) { Text("Delete combined station", color = palette.danger) }
		},
		dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel", color = palette.action) } },
	)
}

/** Automatic station choice for the board or for widgets, with the favorite radius editor. */
@Composable
fun StationSelectionScreen(model: AppModel, widget: Boolean, exit: ScreenExit, close: () -> Unit) {
	val widgetSelection = model.settings.widgets.stationSelection
	val selection = if (widget) widgetSelection.selection else model.settings.stationSelection
	fun save(value: StationSelection) {
		if (widget) model.setWidgetStationSelection(widgetSelection.copy(selection = value)) else model.setStationSelection(value)
	}
	val identifier = if (widget) "widget" else "app"
	ListScreen(if (widget) "Widget station" else "Station selection", exit = exit, onExit = close, tag = "stationSelection_$identifier") {
		if (widget) section("follow") {
			row { SwitchRow("Follow app station selection", widgetSelection.followApp, { model.setWidgetStationSelection(widgetSelection.copy(followApp = it)) }, Modifier.testTag("widgetFollowAppStation")) }
			if (widgetSelection.followApp) {
				row { RowContainer { LabeledValue("App setting", Labels.stationModeTitle(model.settings.stationSelection.mode)) } }
				if (model.settings.stationSelection.mode == "nearbyFavorite") row { RowContainer { LabeledValue("Radius", Units.radiusLabel(model.settings.stationSelection.radiusFeet, model.distanceUnit)) } }
			}
		}
		if (widget && widgetSelection.followApp) return@ListScreen
		section("mode", header = "Open automatically") {
			Labels.stationModes.forEach { mode ->
				row(mode) {
					Row(
						Modifier.fillMaxWidth().heightIn(min = 48.dp).selectable(selection.mode == mode, role = Role.RadioButton) { save(selection.copy(mode = mode)) }
							.padding(horizontal = 16.dp).testTag("${identifier}StationMode_$mode"),
						verticalAlignment = Alignment.CenterVertically,
					) {
						Text(Labels.stationModeTitle(mode), style = TextRoles.subheadline, modifier = Modifier.weight(1f))
						RadioButton(selected = selection.mode == mode, onClick = null, colors = RadioButtonDefaults.colors(selectedColor = palette.action))
					}
				}
			}
		}
		if (selection.mode == "nearbyFavorite") section("radius", header = "Favorite radius") { row { RadiusEditor(selection.radiusFeet, model.distanceUnit, identifier) { save(selection.copy(radiusFeet = it)) } } }
	}
}

/** Text and slider for the radius in the rider's units; decimals convert to the nearest whole foot. */
@Composable
private fun RadiusEditor(radiusFeet: Int, unit: String, identifier: String, commit: (Int) -> Unit) {
	val radiusUnit = Labels.radiusUnit(unit)
	var text by rememberSaveable(radiusFeet, unit) { mutableStateOf(Units.radiusInput(radiusFeet, radiusUnit)) }
	var draft by rememberSaveable(radiusFeet) { mutableFloatStateOf(radiusFeet.toFloat()) }
	val valid = Units.radiusFeet(text, radiusUnit)
	fun commitText() { valid?.let { if (it != radiusFeet) commit(it) }; text = Units.radiusInput(valid ?: radiusFeet, radiusUnit) }
	LaunchedEffect(text) { valid?.let { draft = it.toFloat() } }
	Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
		OutlinedTextField(
			value = text, onValueChange = { text = it }, singleLine = true,
			label = { Text("Radius ($radiusUnit)") },
			keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal, imeAction = ImeAction.Done),
			keyboardActions = KeyboardActions(onDone = { commitText() }),
			isError = valid == null,
			colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = palette.accent, unfocusedBorderColor = palette.line),
			modifier = Modifier.fillMaxWidth().onFocusChanged { if (!it.isFocused) commitText() }
				.semantics { contentDescription = "Radius in ${Units.spokenName(radiusUnit)}" }.testTag("${identifier}RadiusFeet"),
		)
		Slider(
			value = draft, onValueChange = { draft = it; text = Units.radiusInput(it.roundToInt(), radiusUnit) },
			onValueChangeFinished = { commit(draft.roundToInt().coerceIn(1, 26400)) },
			valueRange = 1f..26400f,
			colors = SliderDefaults.colors(thumbColor = palette.selection, activeTrackColor = palette.selection, inactiveTrackColor = palette.line),
			modifier = Modifier.semantics { contentDescription = "Favorite radius"; stateDescription = "${Units.radiusInput(draft.roundToInt(), radiusUnit)} ${Units.spokenName(radiusUnit)}" }.testTag("${identifier}RadiusSlider"),
		)
		Text(Units.radiusLabel(draft.roundToInt(), unit), style = TextRoles.footnote, color = palette.muted)
		if (valid == null) Text(Units.radiusRangeDescription(radiusUnit), style = TextRoles.footnote, color = palette.danger)
	}
}

/** Saved cars and consists, with an undo after removal. */
@Composable
fun FavoriteTrainsScreen(model: AppModel, exit: ScreenExit, close: () -> Unit, open: (Route) -> Unit) {
	var removedCar by rememberSaveable { mutableStateOf<String?>(null) }
	var removedConsist by rememberSaveable { mutableStateOf<List<String>?>(null) }
	val favorites = model.trainFavorites
	ListScreen("Favorite trains", exit = exit, onExit = close, tag = "favoriteTrains") {
		if (removedCar != null || removedConsist != null) section("undo") {
			row {
				Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
					Text("Favorite removed", style = TextRoles.subheadline, modifier = Modifier.weight(1f))
					TextButton(
						onClick = {
							removedCar?.let { if (it !in model.trainFavorites.cars) model.toggleFavoriteCar(it) }
							removedConsist?.let { if (!model.trainFavorites.containsConsist(it)) model.toggleFavoriteConsist(it) }
							if (model.settingsError == null) { removedCar = null; removedConsist = null }
						},
						modifier = Modifier.semantics { contentDescription = "Undo removal" }.testTag("undoTrainRemoval"),
					) { Text("Undo", color = palette.action) }
				}
			}
		}
		section("match", header = "Match saved consists") {
			Labels.trainMatches.forEach { match ->
				row(match) {
					Row(
						Modifier.fillMaxWidth().heightIn(min = 48.dp).selectable(favorites.match == match, role = Role.RadioButton) { model.setTrainMatch(match) }
							.padding(horizontal = 16.dp).testTag("favoriteTrainMatch_$match"),
						verticalAlignment = Alignment.CenterVertically,
					) {
						Text(Labels.trainMatchTitle(match), style = TextRoles.subheadline, modifier = Modifier.weight(1f))
						RadioButton(selected = favorites.match == match, onClick = null, colors = RadioButtonDefaults.colors(selectedColor = palette.action))
					}
				}
			}
		}
		section("cars", header = "Cars") {
			favorites.cars.forEach { id ->
				row(id) {
					Row(verticalAlignment = Alignment.CenterVertically) {
						NavigationRow(TrainFavoriteRules.label(id), { open(Route.FleetDetail(id, "cars")) }, Modifier.weight(1f))
						FavoriteStar(true, "Remove favorite car ${TrainFavoriteRules.label(id)}", {
							model.toggleFavoriteCar(id)
							if (model.settingsError == null) { removedCar = id; removedConsist = null }
						}, Modifier.testTag("removeFavoriteCar_$id"))
					}
				}
			}
			if (favorites.cars.isEmpty()) row { RowContainer { Text("Star a car in train or fleet details.", style = TextRoles.footnote, color = palette.muted) } }
		}
		section("consists", header = "Consists") {
			favorites.consists.forEachIndexed { index, ids ->
				row("consist$index") {
					Row(Modifier.padding(start = 16.dp), verticalAlignment = Alignment.CenterVertically) {
						Column(Modifier.weight(1f)) {
							Text("${ids.size} cars", style = TextRoles.subheadlineBold)
							Text(ids.joinToString(" · ") { TrainFavoriteRules.label(it) }, style = TextRoles.caption, color = palette.muted)
						}
						FavoriteStar(true, "Remove favorite consist, ${ids.size} cars", {
							model.toggleFavoriteConsist(ids)
							if (model.settingsError == null) { removedConsist = ids; removedCar = null }
						}, Modifier.testTag("removeFavoriteConsist"))
					}
				}
			}
			if (favorites.consists.isEmpty()) row { RowContainer { Text("Star a whole consist in train or fleet details.", style = TextRoles.footnote, color = palette.muted) } }
		}
	}
}
