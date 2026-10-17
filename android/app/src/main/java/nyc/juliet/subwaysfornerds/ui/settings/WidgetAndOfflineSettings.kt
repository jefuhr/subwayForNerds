package nyc.juliet.subwaysfornerds.ui.settings

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import nyc.juliet.subwaysfornerds.core.Display
import nyc.juliet.subwaysfornerds.core.FleetPackSelection
import nyc.juliet.subwaysfornerds.core.LockScreenSettings
import nyc.juliet.subwaysfornerds.core.OfflineSettings
import nyc.juliet.subwaysfornerds.core.StationSettings
import nyc.juliet.subwaysfornerds.core.Units
import nyc.juliet.subwaysfornerds.core.WidgetDisplay
import nyc.juliet.subwaysfornerds.ui.AppModel
import nyc.juliet.subwaysfornerds.ui.ByteCounts
import nyc.juliet.subwaysfornerds.ui.CoreBridge
import nyc.juliet.subwaysfornerds.ui.Labels
import nyc.juliet.subwaysfornerds.ui.components.ActionButton
import nyc.juliet.subwaysfornerds.ui.components.ChipRow
import nyc.juliet.subwaysfornerds.ui.components.ChoiceChip
import nyc.juliet.subwaysfornerds.ui.components.ListScreen
import nyc.juliet.subwaysfornerds.ui.components.LoadingBar
import nyc.juliet.subwaysfornerds.ui.components.NavigationRow
import nyc.juliet.subwaysfornerds.ui.components.Notice
import nyc.juliet.subwaysfornerds.ui.components.RouteBullet
import nyc.juliet.subwaysfornerds.ui.components.RowContainer
import nyc.juliet.subwaysfornerds.ui.components.ScreenExit
import nyc.juliet.subwaysfornerds.ui.components.section
import nyc.juliet.subwaysfornerds.ui.fleet.SwitchRow
import nyc.juliet.subwaysfornerds.ui.navigation.Route
import nyc.juliet.subwaysfornerds.ui.theme.TextRoles
import nyc.juliet.subwaysfornerds.ui.theme.palette

/**
 * Home screen or lock screen widget display. Portable choices Android cannot honor, such as
 * countdown arrival styles, stay stored for other devices and are labeled as such.
 */
@Composable
fun WidgetDisplayScreen(model: AppModel, lockScreen: Boolean, exit: ScreenExit, close: () -> Unit) {
	val widgets = model.settings.widgets
	val options = if (lockScreen) widgets.lockScreen.display else widgets.display
	val prefix = if (lockScreen) "widgetLock" else "widget"
	fun save(value: WidgetDisplay) { if (lockScreen) model.setWidgetLockScreen(widgets.lockScreen.copy(display = value)) else model.setWidgetDisplay(value) }
	val fields = if (lockScreen) Labels.lockScreenFields else Labels.widgetFields
	ListScreen(if (lockScreen) "Lock screen display" else "Home screen display", exit = exit, onExit = close, tag = "${prefix}DisplayScreen") {
		section(
			"refresh", header = "Refresh",
			footer = "Your preferred interval is saved with your settings. Android refreshes widgets in the background no more often than every 15 minutes; the refresh button and opening the app update them sooner.",
		) {
			row {
				ChipRow(Modifier.padding(horizontal = 12.dp).testTag("${prefix}RefreshInterval")) {
					val current = options.refreshInterval ?: 5
					Labels.refreshIntervals.forEach { minutes -> ChoiceChip(if (minutes == 1) "1 min" else "$minutes min", current == minutes, { save(options.copy(refreshInterval = minutes)) }, contentDescription = Labels.refreshTitle(minutes)) }
				}
			}
		}
		section(
			"layout", header = "Layout",
			footer = if (lockScreen) "Each direction gets its own column. Fit as many as possible fills the available space with up to six trains per direction. Lock screen widgets appear only where your device's launcher supports them."
			else "Directions use arrows. Train counts adapt to the widget size and text size. Lock screen display is configured separately.",
		) {
			row { SwitchRow("Compact rows", options.compact, { save(options.copy(compact = it)) }, Modifier.testTag("${prefix}Compact")) }
			row {
				Column(Modifier.padding(vertical = 4.dp)) {
					Text("Trains per direction", style = TextRoles.subheadline, modifier = Modifier.padding(horizontal = 16.dp))
					ChipRow(Modifier.padding(horizontal = 12.dp).testTag("${prefix}TrainCount")) {
						ChoiceChip(if (lockScreen) "Fit as many as possible" else "Fit automatically", options.trainsPerDirection == 0, { save(options.copy(trainsPerDirection = 0)) })
						(1..(if (lockScreen) 6 else 8)).forEach { count -> ChoiceChip("$count", options.trainsPerDirection == count, { save(options.copy(trainsPerDirection = count)) }) }
					}
				}
			}
			if (lockScreen) row {
				Column(Modifier.padding(vertical = 4.dp)) {
					Text("Direction order", style = TextRoles.subheadline, modifier = Modifier.padding(horizontal = 16.dp))
					ChipRow(Modifier.padding(horizontal = 12.dp).testTag("widgetLockDirectionOrder")) {
						Labels.directionOrders.forEach { order -> ChoiceChip(Labels.directionOrderTitle(order), widgets.lockScreen.directionOrder == order, { model.setWidgetLockScreen(widgets.lockScreen.copy(directionOrder = order)) }) }
					}
				}
			}
			row {
				Column(Modifier.padding(vertical = 4.dp)) {
					Text("Arrival display on iPhone and iPad", style = TextRoles.subheadline, modifier = Modifier.padding(horizontal = 16.dp))
					ChipRow(Modifier.padding(horizontal = 12.dp).testTag("${prefix}TimeStyle")) {
						Labels.timeStyles.forEach { style -> ChoiceChip(Labels.timeStyleTitle(style), options.timeStyle == style, { save(options.copy(timeStyle = style)) }) }
					}
					Text("Android widgets always show arrival clock times with the report time, so they stay accurate between refreshes.", style = TextRoles.caption, color = palette.muted, modifier = Modifier.padding(horizontal = 16.dp))
				}
			}
		}
		section(
			"fields", header = "Show information",
			footer = if (lockScreen) "These settings apply only to lock screen widgets. Car details appear only when reported and still current. Saved predictions always remain marked as offline estimates."
			else "These settings apply only to Home screen widgets, in either filter mode. Car details appear only when reported and still current. Small widgets shorten details to fit. Saved predictions always remain marked as offline estimates.",
		) {
			if (lockScreen) row { SwitchRow("Show service icons", widgets.lockScreen.showService, { model.setWidgetLockScreen(widgets.lockScreen.copy(showService = it)) }, Modifier.testTag("widgetLockShowService")) }
			fields.forEach { field ->
				row(field) {
					val title = if (lockScreen && field == "service") "Service details (local / express)" else Labels.widgetFieldTitle(field)
					SwitchRow(title, field in options.fields, { enabled ->
						save(options.copy(fields = (if (enabled) options.fields + field else options.fields - field).distinct().sorted()))
					}, Modifier.testTag("${prefix}Field_$field"))
				}
			}
		}
		section("reset") {
			row {
				ActionButton("Reset widget display", {
					if (lockScreen) model.setWidgetLockScreen(LockScreenSettings()) else model.setWidgetDisplay(WidgetDisplay())
				}, Modifier.padding(start = 4.dp).testTag("${prefix}DisplayReset"))
			}
		}
	}
}

/** Independent widget line filters and grouping for one favorite station. */
@Composable
fun WidgetFiltersScreen(model: AppModel, stationID: String, exit: ScreenExit, close: () -> Unit) {
	val station = model.allStations.firstOrNull { it.id == stationID }
	val preference = model.settings.widgets.stations[stationID] ?: StationSettings(view = "direction")
	ListScreen(station?.name ?: "Widget filters", exit = exit, onExit = close, tag = "widgetFilters") {
		section("lines", header = "Widget lines", footer = "With no lines selected, all globally enabled lines are shown. Global line settings always apply.") {
			row {
				Row(
					Modifier.fillMaxWidth().heightIn(min = 48.dp).selectable(preference.routes.isEmpty(), role = Role.RadioButton) { model.clearWidgetRoutes(stationID) }
						.padding(horizontal = 16.dp).testTag("widgetAllLines"),
					verticalAlignment = Alignment.CenterVertically,
				) {
					Text("All lines", style = TextRoles.subheadline, modifier = Modifier.weight(1f))
					if (preference.routes.isEmpty()) Icon(Icons.Filled.Check, contentDescription = null, tint = palette.action)
				}
			}
			val routes = CoreBridge.visibleRoutes(station?.routes.orEmpty().map(Display::displayRoute).distinct().sorted(), model.hiddenRoutes)
			routes.forEach { route ->
				row(route) {
					val on = route in preference.routes
					Row(
						Modifier.fillMaxWidth().heightIn(min = 52.dp).toggleable(on, role = Role.Switch) { model.setWidgetRoute(route, it, stationID) }
							.padding(horizontal = 16.dp, vertical = 6.dp).testTag("widgetRoute_$route"),
						verticalAlignment = Alignment.CenterVertically,
					) {
						RouteBullet(route, small = true)
						Text("  Line $route", style = TextRoles.subheadline, modifier = Modifier.weight(1f))
						androidx.compose.material3.Switch(checked = on, onCheckedChange = null, colors = androidx.compose.material3.SwitchDefaults.colors(checkedTrackColor = palette.selection, checkedThumbColor = androidx.compose.ui.graphics.Color.White))
					}
				}
			}
		}
		section("grouping", header = "Grouping", footer = "The smallest widgets show the next train in each direction. Larger widgets show more trains with your chosen grouping.") {
			row {
				ChipRow(Modifier.padding(horizontal = 12.dp).testTag("widgetGrouping")) {
					Labels.boardViews.forEach { view -> ChoiceChip(Labels.boardViewTitle(view), preference.view == view, { model.setWidgetView(view, stationID) }, contentDescription = Labels.boardViewLabel(view)) }
				}
			}
		}
	}
}

/** Offline caching preferences, storage use and removal. Preferences sync; cached content stays here. */
@Composable
fun OfflineSettingsScreen(model: AppModel, exit: ScreenExit, close: () -> Unit, open: (Route) -> Unit) {
	val scope = rememberCoroutineScope()
	var confirmClear by rememberSaveable { mutableStateOf(false) }
	var working by rememberSaveable { mutableStateOf(false) }
	val preferences = model.offlinePreferences
	fun update(change: (OfflineSettings) -> OfflineSettings) = model.setOfflinePreferences(change(preferences))
	LaunchedEffect(Unit) { model.reloadOfflineStatus() }
	ListScreen("Offline", exit = exit, onExit = close, tag = "offlineSettingsScreen") {
		model.offlineActionError?.let { message -> section("actionError") { row { RowContainer { Notice(message, Modifier.testTag("offlineSettingsError")) } } } }
		model.settingsError?.let { message -> section("settingsError") { row { RowContainer { Notice(message) } } } }
		section("storage", header = "Connection and storage", footer = "Offline boards, trips and your ride stay on this device and do not sync. These preferences transfer with your settings.") {
			// What the phone's network is doing comes first, so the rider knows why boards are or are not refreshing.
			row {
				RowContainer {
					Column(Modifier.testTag("deviceNetworkStatus").semantics(mergeDescendants = true) {}) {
						Text(model.deviceNetworkHeadline, style = TextRoles.subheadline.copy(fontWeight = FontWeight.SemiBold))
						Text(model.deviceNetworkStatus.linkFacts.joinToString(" · "), style = TextRoles.caption, color = palette.muted, modifier = Modifier.testTag("deviceNetworkDetail"))
					}
				}
			}
			row {
				RowContainer {
					Column(Modifier.testTag("offlineSyncActivity").semantics(mergeDescendants = true) {}) {
						val inFlight = model.fetchProgress.size
						LabeledValue("Automatic refreshes", if (model.connected) "Active" else "Paused")
						Text(
							"${model.plannedRequestCount} boards and trips tracked" + (if (inFlight > 0) " · $inFlight downloading" else "") + " · " + model.deviceNetworkDetail,
							style = TextRoles.caption, color = palette.muted,
						)
					}
				}
			}
			val usage = model.offlineUsage
			if (usage != null) {
				row { RowContainer { LabeledValue("Stored", "${ByteCounts.file(usage.totalBytes)} of ${preferences.storageLimitMiB} MiB", Modifier.testTag("offlineUsage")) } }
				row {
					RowContainer {
						Text("${usage.boardCount} boards · ${usage.tripCount} trips · ${usage.savedTripCount} saved" + (if (usage.protectedBytes > 0) " · ${ByteCounts.file(usage.protectedBytes)} kept" else ""), style = TextRoles.caption, color = palette.muted)
					}
				}
				if (usage.overLimit) row { RowContainer { Notice("Saved trains and your ride use more than the limit. They are never removed automatically.") } }
			} else row {
				val load = model.storageCheck ?: nyc.juliet.subwaysfornerds.core.LoadProgress.step(0, 3, "Reading saved trains")
				RowContainer { LoadingBar("Checking storage", load.fraction?.toFloat(), load.percentLabel, load.spokenPercent, load.detail, Modifier.testTag("offlineStorageLoading")) }
			}
			model.offlineFailures.forEachIndexed { index, failure ->
				row("failure$index") { RowContainer { Notice("Could not save ${failure.operation} ${Display.ageLabel(failure.failedAt, model.now)}: ${failure.message}") } }
			}
			if (model.offlineFailures.isNotEmpty()) row { ActionButton("Dismiss save errors", { model.dismissOfflineFailures() }, Modifier.padding(start = 4.dp)) }
			row { NavigationRow("Saved trains", { open(Route.SavedTrips) }, Modifier.testTag("offlineSavedTrains"), value = "${model.savedTrips.size}") }
			row { ActionButton("Clear automatic downloads", { confirmClear = true }, Modifier.padding(start = 4.dp).testTag("clearAutomaticOffline"), enabled = !working, destructive = true) }
		}
		section("viewed", header = "Viewed station", footer = "Each board you view keeps its next departures for every line and direction, plus full stop lists for the next trains, while you are connected.") {
			row {
				Stepper("Departures per line and direction", preferences.departuresPerLineDirection, 1..20, "offlineDepartures") { value -> update { it.copy(departuresPerLineDirection = value) } }
			}
			row {
				Stepper("Full trips per line and direction", minOf(preferences.tripDetailsPerLineDirection, preferences.departuresPerLineDirection), 0..preferences.departuresPerLineDirection, "offlineTripDetails") { value -> update { it.copy(tripDetailsPerLineDirection = value) } }
			}
			row { SwitchRow("Save trains I open", preferences.saveOpenedTrips, { value -> update { it.copy(saveOpenedTrips = value) } }, Modifier.testTag("offlineSaveOpenedTrips")) }
		}
		section(
			"other", header = "Other stations",
			footer = "Favorite boards, and boards within this straight-line distance of the station you are viewing, are saved in the background while the app is open. Your location is not used. Saving their trips works for favorites even with the distance off.",
		) {
			row {
				ChipRow(Modifier.padding(horizontal = 12.dp).testTag("offlineRadius")) {
					listOf(0, 1320, 2640, 5280, 10560, 26400).forEach { feet ->
						ChoiceChip(if (feet == 0) "Off" else Units.radiusLabel(feet, model.distanceUnit), preferences.nearbyRadiusFeet == feet, { update { it.copy(nearbyRadiusFeet = feet) } }, Modifier.testTag("offlineRadius_$feet"))
					}
				}
			}
			row { SwitchRow("Also save trips at favorite and nearby stations", preferences.preloadOtherStationTrips, { value -> update { it.copy(preloadOtherStationTrips = value) } }, Modifier.testTag("offlinePreloadOtherTrips")) }
		}
		section(
			"estimates", header = "Offline countdowns",
			footer = "Without a connection, countdowns use saved predictions until their source is this old, then show the last clock times. Every offline time is labeled as an estimate with its source age; passed times say estimate passed.",
		) {
			row {
				ChipRow(Modifier.padding(horizontal = 12.dp)) {
					listOf(5, 15, 30, 60, 120).forEach { minutes -> ChoiceChip("$minutes min", preferences.estimateLimitMinutes == minutes, { update { it.copy(estimateLimitMinutes = minutes) } }, Modifier.testTag("offlineEstimateLimit_$minutes")) }
				}
			}
		}
		section(
			"retention", header = "Keep automatic copies",
			footer = "Automatic boards and trips expire after this many hours and the oldest are removed above the storage limit. Saved trains and your current ride are kept until you remove them.",
		) {
			row { ChipRow(Modifier.padding(horizontal = 12.dp)) { listOf(1, 6, 12, 24).forEach { hours -> ChoiceChip("$hours h", preferences.retentionHours == hours, { update { it.copy(retentionHours = hours) } }, Modifier.testTag("offlineRetention_$hours")) } } }
			row { ChipRow(Modifier.padding(horizontal = 12.dp)) { listOf(25, 50, 100, 250).forEach { mib -> ChoiceChip("$mib MiB", preferences.storageLimitMiB == mib, { update { it.copy(storageLimitMiB = mib) } }, Modifier.testTag("offlineStorageLimit_$mib")) } } }
		}
		section("ride", footer = "While you are on a train, Home screen and lock screen widgets show its next stops instead of a station board.") {
			row { SwitchRow("Widgets follow my ride", preferences.widgetsFollowActiveRide, { value -> update { it.copy(widgetsFollowActiveRide = value) } }, Modifier.testTag("offlineWidgetsFollowRide")) }
		}
	}
	if (confirmClear) AlertDialog(
		onDismissRequest = { confirmClear = false },
		title = { Text("Clear automatic downloads?") },
		text = { Text("Removes boards and trips saved automatically for this server. Saved trains and your current ride are kept. Boards are saved again while you browse online.") },
		confirmButton = { TextButton(onClick = { confirmClear = false; scope.launch { working = true; model.removeAutomaticOfflineData(); working = false } }, modifier = Modifier.testTag("confirmClearAutomatic")) { Text("Clear automatic downloads", color = palette.danger) } },
		dismissButton = { TextButton(onClick = { confirmClear = false }) { Text("Cancel", color = palette.action) } },
	)
}

/** A labeled count with 48 dp minus and plus buttons, like an iOS stepper. */
@Composable
private fun Stepper(title: String, value: Int, range: IntRange, tag: String, set: (Int) -> Unit) {
	Row(
		Modifier.fillMaxWidth().heightIn(min = 52.dp).padding(start = 16.dp, end = 4.dp)
			.semantics(mergeDescendants = true) { contentDescription = "$title: $value" }.testTag(tag),
		verticalAlignment = Alignment.CenterVertically,
	) {
		Text("$title: $value", style = TextRoles.subheadline, modifier = Modifier.weight(1f))
		IconButton(onClick = { set(value - 1) }, enabled = value > range.first, modifier = Modifier.testTag("${tag}_decrement")) {
			Icon(Icons.Filled.Remove, contentDescription = "Decrease $title", tint = if (value > range.first) palette.action else palette.line)
		}
		IconButton(onClick = { set(value + 1) }, enabled = value < range.last, modifier = Modifier.testTag("${tag}_increment")) {
			Icon(Icons.Filled.Add, contentDescription = "Increase $title", tint = if (value < range.last) palette.action else palette.line)
		}
	}
}

/** Choose car types, estimated home yards, and 7 or 30 days of history for the fleet download. */
@Composable
fun FleetPackScopeScreen(model: AppModel, exit: ScreenExit, close: () -> Unit) {
	val fleet = model.fleet
	val selection = fleet.selection
	val disabled = fleet.isDownloading
	LaunchedEffect(Unit) { fleet.loadFacets() }
	fun toggled(value: String, values: List<String>) = if (value in values) values - value else (values + value).sorted()
	ListScreen("Fleet download scope", exit = exit, onExit = close, tag = "fleetPackScopeScreen") {
		section("history", footer = "Everything includes all car types and estimated home yards, with the history window chosen above.") {
			row {
				ChipRow(Modifier.padding(horizontal = 12.dp).testTag("fleetPackHistory")) {
					listOf(7, 30).forEach { days -> ChoiceChip("$days days", selection.historyDays == days, { fleet.chooseSelection(selection.copy(historyDays = days)) }, enabled = !disabled) }
				}
			}
			row { ActionButton("Everything", { fleet.chooseSelection(FleetPackSelection(historyDays = selection.historyDays)) }, Modifier.padding(start = 4.dp).testTag("fleetPackEverything"), enabled = !disabled) }
		}
		section("equipment", header = "Car types", footer = "Select multiple exact equipment types. Choosing All car types removes this filter.") {
			row { ScopeChoice("All car types", selection.equipment.isEmpty(), "fleetPackAllEquipment", !disabled) { fleet.chooseSelection(selection.copy(equipment = emptyList())) } }
			(fleet.facets.equipment + selection.equipment).filter { it.isNotEmpty() }.distinct().sorted().forEach { equipment ->
				row(equipment) { ScopeChoice(equipment, equipment in selection.equipment, "fleetPackEquipment_$equipment", !disabled) { fleet.chooseSelection(selection.copy(equipment = toggled(equipment, selection.equipment))) } }
			}
		}
		section(
			"yards", header = "Estimated home yards",
			footer = "Yards are estimates from reports and source records. Multiple yard selections match exact names. Unknown includes cars without an estimated home yard. Car type and yard filters must both match.",
		) {
			row { ScopeChoice("All estimated home yards", selection.yards.isEmpty(), "fleetPackAllYards", !disabled) { fleet.chooseSelection(selection.copy(yards = emptyList())) } }
			(fleet.facets.yard + selection.yards + "unknown").filter { it.isNotEmpty() }.distinct().sorted().forEach { yard ->
				row(yard) { ScopeChoice(if (yard == "unknown") "Unknown / unreported" else yard, yard in selection.yards, "fleetPackYard_$yard", !disabled) { fleet.chooseSelection(selection.copy(yards = toggled(yard, selection.yards))) } }
			}
		}
		fleet.facetsError?.let { message -> section("facetsError") { row { RowContainer { Notice(message) } } } }
		section("reload") { row { ActionButton("Reload car types and yards", { model.launch { fleet.loadFacets() } }, Modifier.padding(start = 4.dp), enabled = model.connected) } }
	}
}

@Composable
private fun ScopeChoice(title: String, selected: Boolean, tag: String, enabled: Boolean, onClick: () -> Unit) {
	Row(
		Modifier.fillMaxWidth().heightIn(min = 48.dp).toggleable(selected, enabled = enabled, role = Role.Checkbox) { onClick() }.padding(horizontal = 16.dp).testTag(tag),
		verticalAlignment = Alignment.CenterVertically,
	) {
		Text(title, style = TextRoles.subheadline, color = if (enabled) palette.ink else palette.muted, modifier = Modifier.weight(1f))
		if (selected) Icon(Icons.Filled.Check, contentDescription = null, tint = palette.action)
	}
}
