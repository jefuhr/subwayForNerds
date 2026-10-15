package nyc.juliet.subwaysfornerds.ui.settings

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import nyc.juliet.subwaysfornerds.R
import nyc.juliet.subwaysfornerds.core.PRODUCTION_API_BASE
import nyc.juliet.subwaysfornerds.core.Units
import nyc.juliet.subwaysfornerds.ui.AppModel
import nyc.juliet.subwaysfornerds.ui.ByteCounts
import nyc.juliet.subwaysfornerds.ui.Labels
import nyc.juliet.subwaysfornerds.ui.account.AccountModel
import nyc.juliet.subwaysfornerds.ui.components.ActionButton
import nyc.juliet.subwaysfornerds.ui.components.ChipRow
import nyc.juliet.subwaysfornerds.ui.components.ChoiceChip
import nyc.juliet.subwaysfornerds.ui.components.LinkButton
import nyc.juliet.subwaysfornerds.ui.components.ListScreen
import nyc.juliet.subwaysfornerds.ui.components.LoadingBar
import nyc.juliet.subwaysfornerds.ui.components.NavigationRow
import nyc.juliet.subwaysfornerds.ui.components.Notice
import nyc.juliet.subwaysfornerds.ui.components.RowContainer
import nyc.juliet.subwaysfornerds.ui.components.section
import nyc.juliet.subwaysfornerds.ui.counted
import nyc.juliet.subwaysfornerds.ui.easternDate
import nyc.juliet.subwaysfornerds.ui.fleet.SwitchRow
import nyc.juliet.subwaysfornerds.ui.navigation.AppTab
import nyc.juliet.subwaysfornerds.ui.navigation.Route
import nyc.juliet.subwaysfornerds.ui.theme.AppTheme
import nyc.juliet.subwaysfornerds.ui.theme.TextRoles
import nyc.juliet.subwaysfornerds.ui.theme.palette

/** Activity-level actions settings can ask for: system dialogs, file pickers and Custom Tabs. */
interface SettingsActions {
	fun exportSettings()
	fun importSettings()
	/** Asks for foreground location, then explains and opens the background permission page. */
	fun enableWidgetLocation()
	fun openLocationSettings()
}

@Composable
fun SettingsScreen(model: AppModel, account: AccountModel, actions: SettingsActions, open: (Route) -> Unit, wide: Boolean) {
	val fleet = model.fleet
	val scope = rememberCoroutineScope()
	var confirmDelete by rememberSaveable { mutableStateOf(false) }
	LaunchedEffect(Unit) { fleet.loadFacets() }
	ListScreen("Settings", tag = "settingsScreen") {
		section("brand") {
			row {
				Row(Modifier.padding(horizontal = 16.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
					Image(painterResource(R.drawable.kitty), contentDescription = null, modifier = Modifier.size(44.dp))
					Column {
						Text("subways for nerds.", style = TextRoles.headline)
						Text("Know the system. Make your next move.", style = TextRoles.caption, color = palette.muted)
					}
				}
			}
		}
		section("board", header = "Board") {
			row { NavigationRow("Combined stations", { open(Route.CombinedStations) }, Modifier.testTag("combinedStationsSettings")) }
			row { NavigationRow("Lines", { open(Route.Lines) }, Modifier.testTag("lineVisibilitySettings")) }
			row { NavigationRow("Station selection", { open(Route.StationSelectionSettings(widget = false)) }, Modifier.testTag("stationSelectionSettings"), value = Labels.stationModeTitle(model.settings.stationSelection.mode)) }
			row { NavigationRow("Favorite trains", { open(Route.FavoriteTrains) }, Modifier.testTag("favoriteTrainsSettings")) }
			row { SwitchRow("Save transfer filters separately", model.settings.transfers.separateFilters, { model.setSeparateTransferFilters(it) }, Modifier.testTag("separateTransferFilters"), subtitle = TransferText.mode(model.settings.transfers)) }
		}
		section("units", header = "Units", footer = "Applies to the app and widgets. Times are New York time. Automatic uses m/km nearby and ft/mi for favorite radius.") {
			row {
				ChipRow(Modifier.padding(horizontal = 12.dp).semantics { contentDescription = "Distance units" }) {
					Labels.distanceUnits.forEach { unit ->
						ChoiceChip(Units.shortTitle(unit), model.distanceUnit == unit, { model.setDistanceUnit(unit) }, Modifier.testTag("distanceUnits_$unit"), contentDescription = Labels.distanceTitle(unit))
					}
				}
			}
			row {
				ChipRow(Modifier.padding(horizontal = 12.dp).semantics { contentDescription = "Time format" }) {
					Labels.timeFormats.forEach { format -> ChoiceChip(Labels.timeFormatTitle(format), model.timeFormat == format, { model.setTimeFormat(format) }, Modifier.testTag("timeFormat_$format")) }
				}
			}
		}
		section("theme", header = "Theme") { row { ThemeGrid(model, wide) } }
		section(
			"widgets", header = "Widgets",
			footer = "Widgets use your station selection and show both directions with arrival clock times. Android refreshes them in the background at most every 15 minutes; tap a widget's refresh button for a new report.",
		) {
			val widgetSelection = model.settings.widgets.stationSelection
			row { NavigationRow("Widget station", { open(Route.StationSelectionSettings(widget = true)) }, Modifier.testTag("widgetStationSelectionSettings"), value = if (widgetSelection.followApp) "Same as app" else Labels.stationModeTitle(widgetSelection.selection.mode)) }
			row { NavigationRow("Home screen display", { open(Route.WidgetDisplay(lockScreen = false)) }, Modifier.testTag("widgetDisplaySettings")) }
			row { NavigationRow("Lock screen display", { open(Route.WidgetDisplay(lockScreen = true)) }, Modifier.testTag("widgetLockScreenSettings")) }
			row { SwitchRow("Match app filters", model.settings.widgets.matchAppFilters, { model.setWidgetMatchApp(it) }, Modifier.testTag("widgetMatchAppFilters")) }
			if (!model.settings.widgets.matchAppFilters) model.favoriteStations.forEach { station ->
				row(station.id) { NavigationRow(station.name, { open(Route.WidgetFilters(station.id)) }, Modifier.testTag("widgetFilters_${station.id}")) }
			}
			val selection = if (widgetSelection.followApp) model.settings.stationSelection else widgetSelection.selection
			if (model.favorites.isEmpty() && selection.mode == "favorite") row { RowContainer { Text("Add a favorite station or choose Closest station above.", style = TextRoles.footnote, color = palette.muted) } }
			if (model.debugBuild) row { NavigationRow("Widget previews", { open(Route.WidgetPreviews) }, Modifier.testTag("widgetPreviews")) }
		}
		section(
			"widgetLocation", header = "Widget location",
			footer = "Off by default. When on, widgets may use a recent location in the background to choose your station. Android asks separately for background access on the app's permission page. Coordinates stay on this device; without a current fix, widgets keep a saved station and say so.",
		) {
			val status = model.widgetLocationStatus
			row {
				SwitchRow(
					"Use location for widgets", status.enabled,
					{ if (it) actions.enableWidgetLocation() else model.setWidgetBackgroundLocation(false) },
					Modifier.testTag("widgetBackgroundLocation"),
					subtitle = status.summary,
				)
			}
			if (status.enabled && !status.backgroundAllowed) row { ActionButton("Allow background location", { actions.enableWidgetLocation() }, Modifier.padding(start = 4.dp).testTag("allowBackgroundLocation")) }
		}
		section("offline", header = "Offline", footer = "Boards you view, nearby boards, and saved trains work offline, with estimates clearly labeled.") {
			row {
				NavigationRow(
					"Offline boards and trains", { open(Route.OfflineSettings) }, Modifier.testTag("offlineSettings"),
					value = if (model.savedTrips.isEmpty()) "${model.offlinePreferences.departuresPerLineDirection} per line" else "${model.savedTrips.size} saved",
				)
			}
		}
		section(
			"fleet", header = "Offline fleet",
			footer = "Prepare to see the archive size and saved-size estimate, then choose Download or Update. Keep the app open while saving. One validated pack replaces your previous copy. Saved reports are historical; events can mention cars outside the saved scope. Failed or canceled downloads preserve your previous copy.",
		) {
			row { NavigationRow("Download scope", { open(Route.FleetPackScope) }, Modifier.testTag("fleetPackScope"), subtitle = fleet.selection.scopeDescription, enabled = !fleet.isDownloading) }
			val saved = fleet.offlineManifest
			if (saved != null) row {
				RowContainer {
					Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
						LabeledValue("Saved", easternDate(saved.generatedAt, model.timeFormat))
						LabeledValue("Saved size", ByteCounts.file(saved.byteLength))
						Text("${counted(saved.counts.cars)} cars · ${counted(saved.counts.events)} movement events", style = TextRoles.caption)
						Text("History: ${easternDate(saved.historyStart, model.timeFormat)} – ${easternDate(saved.historyEnd, model.timeFormat)}", style = TextRoles.caption, color = palette.muted)
						Text(saved.pack?.selection?.scopeDescription ?: "All cars · Previously saved retained history", style = TextRoles.caption, modifier = Modifier.testTag("savedFleetScope"))
						saved.pack?.let { Text("${counted(it.counts.matchedCars)} selected cars + ${counted(it.counts.linkedCars)} linked cars for complete fixed sets and recent formations.", style = TextRoles.caption) }
					}
				}
			} else row { RowContainer { Text("Save selected cars, their source records and last reports, with 7 or 30 days of movement history.", style = TextRoles.footnote) } }
			fleet.availablePack?.let { pack ->
				row {
					RowContainer {
						Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
							LabeledValue("Archive size", ByteCounts.file(pack.archiveByteLength), Modifier.testTag("fleetPackArchiveSize"))
							LabeledValue("Saved-size estimate", ByteCounts.file(pack.estimatedSavedByteLength), Modifier.testTag("fleetPackSavedEstimate"))
							LabeledValue("Linked cars", counted(pack.counts.linkedCars))
							Text("${counted(pack.counts.matchedCars)} selected cars · ${counted(pack.counts.cars)} cars including linked members · ${counted(pack.counts.events)} movement events", style = TextRoles.caption)
							Text("Prepared ${easternDate(pack.generatedAt, model.timeFormat)}. Linked cars keep documented fixed sets and recent formations complete. Actual saved size may differ from the estimate.", style = TextRoles.caption, color = palette.muted)
						}
					}
				}
			}
			if (fleet.isDownloading) {
				row {
					RowContainer {
						if (fleet.isPreparing) { val load = fleet.packLoad; LoadingBar("Preparing fleet pack", load.fraction?.toFloat(), load.percentLabel, load.spokenPercent, load.detail, Modifier.testTag("preparingFleetPack")) }
						else { val load = fleet.downloadLoad; LoadingBar("Downloading fleet pack", load.fraction?.toFloat(), load.percentLabel, load.spokenPercent, load.detail, Modifier.testTag("fleetDownloadProgress")) }
					}
				}
				row { ActionButton(if (fleet.isPreparing) "Cancel preparation" else "Cancel download", { fleet.cancel() }, Modifier.padding(start = 4.dp).testTag("cancelFleetDownload")) }
			} else row {
				Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp)) {
					if (fleet.availablePack != null) ActionButton(if (saved == null) "Download fleet" else "Update fleet download", { fleet.startDownload() }, Modifier.testTag("downloadFleet"), enabled = fleet.store != null)
					androidx.compose.foundation.layout.Spacer(Modifier.weight(1f))
					ActionButton(if (fleet.availablePack == null) "Prepare download" else "Prepare again", { fleet.prepare() }, Modifier.testTag("checkFleetDownload"), enabled = fleet.store != null && model.connected)
				}
			}
			if (saved != null) row {
				Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp)) {
					ActionButton("Browse saved fleet", { fleet.useSavedFleet = true; model.navigator.select(AppTab.FLEET) }, Modifier.testTag("openSavedFleet"))
					androidx.compose.foundation.layout.Spacer(Modifier.weight(1f))
					if (!fleet.isDownloading) ActionButton("Delete download", { confirmDelete = true }, Modifier.testTag("deleteFleetDownload"), destructive = true)
				}
			}
			if (fleet.store == null) row { RowContainer { Notice("Download storage is unavailable. Try reopening the app.") } }
			fleet.error?.let { message -> row { RowContainer { Notice(message) } } }
		}
		section(
			"transfer", header = "Move your settings",
			footer = "Move combined stations, hidden lines, favorite stations and trains, station selection, themes, filters, widget and offline preferences between devices with a .nerds file. Offline boards, saved trains and your ride stay on this device. No account is needed.",
		) {
			row { ActionButton("Export settings", { actions.exportSettings() }, Modifier.padding(start = 4.dp).testTag("exportSettings")) }
			row { ActionButton("Import settings", { actions.importSettings() }, Modifier.padding(start = 4.dp).testTag("importSettings")) }
			model.settingsError?.let { message -> row { RowContainer { Text(message, style = TextRoles.footnote, color = palette.danger, modifier = Modifier.testTag("settingsError")) } } }
		}
		accountSection(model, account)
		if (model.debugBuild) section("debug", header = "Development server", footer = "Use a reachable API base address ending in /api/v1/. Your favorites, filters, and theme are saved on this device.") {
			row { EndpointEditor(model) }
			row { SwitchRow("Simulate no connection", model.outageSimulated, { model.setSimulatedOutage(it) }, Modifier.testTag("simulateOutage")) }
		}
		section("about", header = "About") {
			row { LinkButton("Web app", "https://juliet.nyc/subwaysForNerds/", Modifier.padding(start = 4.dp)) }
			row { LinkButton("Taking the ferry?", "https://juliet.nyc/ferryTimesMobile/", Modifier.padding(start = 4.dp)) }
			row { LinkButton("Usage statistics", "https://juliet.nyc/subwaysForNerds/stats", Modifier.padding(start = 4.dp)) }
			row { LinkButton("A juliet.nyc project", "https://juliet.nyc", Modifier.padding(start = 4.dp)) }
			row {
				RowContainer {
					Text("Times are predictions, not promises. Location finds nearby and favorite stations in the app and, when allowed, widgets. Location and station search text stay on this device.", style = TextRoles.caption, color = palette.muted)
				}
			}
		}
	}
	if (confirmDelete) AlertDialog(
		onDismissRequest = { confirmDelete = false },
		title = { Text("Delete the saved fleet?") },
		text = { Text("You can download a new copy whenever you are connected.") },
		confirmButton = { TextButton(onClick = { confirmDelete = false; scope.launch { fleet.delete() } }, modifier = Modifier.testTag("confirmDeleteFleet")) { Text("Delete download", color = palette.danger) } },
		dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel", color = palette.action) } },
	)
}

@Composable
fun LabeledValue(label: String, value: String, modifier: Modifier = Modifier) {
	Row(modifier.fillMaxWidth().semantics(mergeDescendants = true) {}) {
		Text(label, style = TextRoles.subheadline, modifier = Modifier.weight(1f))
		Text(value, style = TextRoles.subheadline, color = palette.muted)
	}
}

/** Ten theme tiles: two columns on phones, five on wide windows, one at the largest text sizes. */
@Composable
private fun ThemeGrid(model: AppModel, wide: Boolean) {
	val fontScale = LocalDensity.current.fontScale
	val columns = if (fontScale >= 1.6f) 1 else if (wide) 5 else 2
	Column(Modifier.padding(8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
		AppTheme.all.chunked(columns).forEach { rowThemes ->
			Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
				rowThemes.forEach { theme -> ThemeTile(theme, theme.id == model.settings.theme, { model.setTheme(theme.id) }, Modifier.weight(1f)) }
				repeat(columns - rowThemes.size) { androidx.compose.foundation.layout.Spacer(Modifier.weight(1f)) }
			}
		}
	}
}

@Composable
private fun ThemeTile(theme: AppTheme, isSelected: Boolean, onClick: () -> Unit, modifier: Modifier) {
	val shape = RoundedCornerShape(10.dp)
	Row(
		modifier
			.heightIn(min = 48.dp)
			.background(if (isSelected) palette.accentTint else palette.ink.copy(alpha = 0.05f), shape)
			.border(BorderStroke(if (isSelected) 1.5.dp else 0.dp, if (isSelected) palette.accent else Color.Transparent), shape)
			.clickable(role = Role.RadioButton, onClick = onClick)
			.semantics { selected = isSelected; contentDescription = "${theme.name}. ${theme.note}" }
			.testTag("theme_${theme.id}")
			.padding(8.dp),
		verticalAlignment = Alignment.CenterVertically,
		horizontalArrangement = Arrangement.spacedBy(8.dp),
	) {
		Box(Modifier.size(24.dp).background(theme.background, CircleShape).border(1.dp, palette.ink.copy(alpha = 0.25f), CircleShape), contentAlignment = Alignment.Center) {
			Box(Modifier.size(14.dp).background(theme.accent, CircleShape))
		}
		Text(theme.name, style = TextRoles.footnote.copy(fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold))
	}
}

@Composable
private fun EndpointEditor(model: AppModel) {
	var endpoint by rememberSaveable { mutableStateOf(model.endpoint) }
	var error by rememberSaveable { mutableStateOf<String?>(null) }
	Column(Modifier.padding(horizontal = 12.dp, vertical = 6.dp)) {
		OutlinedTextField(
			value = endpoint, onValueChange = { endpoint = it }, label = { Text("API URL") }, singleLine = true,
			keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, autoCorrectEnabled = false),
			colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = palette.accent, unfocusedBorderColor = palette.line),
			modifier = Modifier.fillMaxWidth().testTag("apiEndpoint"),
		)
		Row {
			TextButton(onClick = { error = runCatching { model.useEndpoint(endpoint) }.exceptionOrNull()?.message; if (error == null) endpoint = model.endpoint }) { Text("Save API address", color = palette.action) }
			androidx.compose.foundation.layout.Spacer(Modifier.weight(1f))
			TextButton(onClick = { endpoint = PRODUCTION_API_BASE; error = runCatching { model.useEndpoint(endpoint) }.exceptionOrNull()?.message }) { Text("Use production server", color = palette.action) }
		}
		error?.let { Notice(it) }
	}
}
