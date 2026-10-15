package nyc.juliet.subwaysfornerds.ui.train

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.DirectionsSubway
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import nyc.juliet.subwaysfornerds.core.Departure
import nyc.juliet.subwaysfornerds.core.Display
import nyc.juliet.subwaysfornerds.core.Freshness
import nyc.juliet.subwaysfornerds.core.LoadProgress
import nyc.juliet.subwaysfornerds.core.OfflineDisplay
import nyc.juliet.subwaysfornerds.core.OfflineIdentity
import nyc.juliet.subwaysfornerds.core.Station
import nyc.juliet.subwaysfornerds.core.TransferFilter
import nyc.juliet.subwaysfornerds.core.TransferResult
import nyc.juliet.subwaysfornerds.data.CachedTrip
import nyc.juliet.subwaysfornerds.ui.AppModel
import nyc.juliet.subwaysfornerds.ui.CoreBridge
import nyc.juliet.subwaysfornerds.ui.board.BoardLogic
import nyc.juliet.subwaysfornerds.ui.board.StationFilterRow
import nyc.juliet.subwaysfornerds.ui.components.ActionButton
import nyc.juliet.subwaysfornerds.ui.components.ActionChip
import nyc.juliet.subwaysfornerds.ui.components.ChangeIcons
import nyc.juliet.subwaysfornerds.ui.components.ChipRow
import nyc.juliet.subwaysfornerds.ui.components.ListScreen
import nyc.juliet.subwaysfornerds.ui.components.LoadingBar
import nyc.juliet.subwaysfornerds.ui.components.Notice
import nyc.juliet.subwaysfornerds.ui.components.RouteBullet
import nyc.juliet.subwaysfornerds.ui.components.RowContainer
import nyc.juliet.subwaysfornerds.ui.components.ScreenExit
import nyc.juliet.subwaysfornerds.ui.components.SourcesTable
import nyc.juliet.subwaysfornerds.ui.components.section
import nyc.juliet.subwaysfornerds.ui.navigation.Route
import nyc.juliet.subwaysfornerds.ui.theme.TextRoles
import nyc.juliet.subwaysfornerds.ui.theme.palette

/** Connections grouped by line, direction and boarding area. Only live, enabled, future departures. */
data class ConnectionGroup(val id: String, val route: String, val direction: String, val area: String, val departures: List<Departure>)

object Connections {
	fun stale(data: TransferResult?, connected: Boolean, now: Double): Boolean {
		if (data == null) return true
		return !connected || Display.freshness(data.originTimestamp, now, data.originStaleAfter) != Freshness.LIVE || (data.arrival?.let { it < now } == true)
	}

	/** Filters only narrow the rows; grouping, gaps and the 30-minute window stay as the server reports them. */
	fun groups(data: TransferResult, hiddenRoutes: List<String>, now: Double, filter: TransferFilter = TransferFilter()): List<ConnectionGroup> =
		data.connections.filter {
			CoreBridge.lineEnabled(it.route, hiddenRoutes) && Display.freshness(it, now) == Freshness.LIVE && (it.time ?: Double.NEGATIVE_INFINITY) >= now &&
				(filter.direction == "ALL" || it.direction == filter.direction) && (filter.routes.isEmpty() || Display.displayRoute(it.route) in filter.routes.map(Display::displayRoute))
		}
			.groupBy { "${Display.routeLabel(it.route)} · ${Display.directionLabel(it.direction)} · ${it.area}" }
			.map { (key, rows) ->
				val sorted = rows.sortedBy { it.time ?: 0.0 }
				ConnectionGroup(key, sorted[0].route, sorted[0].direction, sorted[0].area, sorted)
			}
			.sortedBy { it.id }

	enum class Empty { NONE, FILTERED }

	/** Why no groups show: nothing is reported, or the station's filters exclude every reported row. */
	fun empty(data: TransferResult, hiddenRoutes: List<String>, now: Double, filter: TransferFilter): Empty? = when {
		groups(data, hiddenRoutes, now, filter).isNotEmpty() -> null
		filter != TransferFilter() && groups(data, hiddenRoutes, now).isNotEmpty() -> Empty.FILTERED
		else -> Empty.NONE
	}

	/** Line chips from the transfer station's lines and every reported connection, so they stay put between refreshes. */
	fun lineChoices(station: Station?, data: TransferResult?, hiddenRoutes: List<String>): List<String> =
		BoardLogic.lineChoices(station?.routes.orEmpty() + data?.connections?.map { it.route }.orEmpty(), hiddenRoutes, CoreBridge::visibleRoutes)

	/** The transfer station: the response's, or the stop's station before a response arrives. Never the selected board. */
	fun targetStationID(route: Route.Transfers, data: TransferResult?): String? = data?.station?.id ?: route.stationID

	fun gapLabel(departure: Departure): String? = departure.gap?.let { gap ->
		"${if (gap < 60) "<1" else (gap / 60).toInt().toString()} min after arrival · ${departure.basis ?: "departure"}${if (departure.basis == "arrival") " fallback" else ""}"
	}
}

@Composable
fun TransferScreen(model: AppModel, route: Route.Transfers, exit: ScreenExit, close: () -> Unit, open: (Route) -> Unit) {
	// Returning from the station board shows the last rows at once, still gated by freshness, while refreshing.
	var data by remember(route) { mutableStateOf(model.rememberedTransfers(route)) }
	var error by remember(route) { mutableStateOf<String?>(null) }
	var progress by remember(route) { mutableStateOf<LoadProgress?>(null) }
	var requestGeneration by remember(route) { mutableIntStateOf(0) }
	val lifecycle = LocalLifecycleOwner.current.lifecycle
	val subject = "connecting departures at ${route.stopName}"
	val now = model.now

	suspend fun refresh() {
		// Connections need live predictions; offline there is nothing honest to show.
		if (!model.connected) { error = "Connections need a live feed. Reconnect for current estimates."; return }
		val requestedEndpoint = model.endpoint
		requestGeneration += 1
		val generation = requestGeneration
		val waiting = data == null
		if (waiting) progress = null
		try {
			val value = model.service.transfers(route.tripKey, route.stopID, route.sequence, if (waiting) { update -> if (generation == requestGeneration) progress = update.load(subject) } else null)
			if (requestedEndpoint != model.endpoint || generation != requestGeneration) return
			data = value; error = null
			model.rememberTransfers(route, value)
		} catch (failure: CancellationException) { throw failure }
		catch (_: Exception) {
			if (requestedEndpoint == model.endpoint && generation == requestGeneration) error = "Transfer predictions unavailable. Reconnect for current estimates."
		}
	}

	// Polls every 10 seconds while visible and connected, like the iOS screen.
	LaunchedEffect(route, model.endpoint, model.connected) {
		lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
			while (true) { refresh(); delay(10_000) }
		}
	}

	val current = data
	val stale = Connections.stale(current, model.connected, now)
	val stationID = Connections.targetStationID(route, current)
	val station = current?.station ?: stationID?.let { id -> model.allStations.firstOrNull { it.id == id } }
	val filter = stationID?.let(model::transferFilter) ?: TransferFilter()
	// Separate filters start as a copy of the station's board filters the first time it is shown, or when turned on here.
	val separate = model.settings.transfers.separateFilters
	LaunchedEffect(stationID, separate) { if (stationID != null && separate) model.useTransferFilter(stationID) }

	ListScreen(route.stopName, exit = exit, onExit = close, onRefresh = { refresh() }, tag = "transfersScreen") {
		section("station") {
			row {
				ChipRow(Modifier.padding(horizontal = 12.dp)) {
					ActionChip(
						"Open station board", { stationID?.let(model::openTransferStationBoard) },
						Modifier.testTag("openTransferStationBoard"), icon = Icons.Filled.DirectionsSubway, enabled = stationID != null,
					)
				}
			}
		}
		model.settingsError?.let { message -> section("settingsError") { row { RowContainer { Notice(message, Modifier.testTag("transferSettingsError")) } } } }
		error?.let { message -> section("error") { row { RowContainer { Notice(message) } } } }
		if (current == null) {
			if (error == null) section("loading") {
				row {
					val load = progress ?: nyc.juliet.subwaysfornerds.ui.waitingLoad(subject, model.connected)
					RowContainer { LoadingBar("Checking connecting departures", load.fraction?.toFloat(), load.percentLabel, load.spokenPercent, load.detail, Modifier.testTag("transfersLoading")) }
				}
			}
			return@ListScreen
		}
		section("arrival", footer = "Next 30 minutes · raw time gaps, no walking allowance. Boarding areas may require stairs, passageways, or different platform access. Connections are not guaranteed.") {
			row {
				RowContainer {
					Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
						Text(
							"Your train: ${Display.clockTime(current.arrival, model.timeFormat)} estimated ${current.basis}${if (current.basis == "departure") " (arrival unavailable)" else ""}",
							style = TextRoles.subheadlineBold,
						)
						Text("Updated ${Display.ageLabel(current.originTimestamp, now)}", style = TextRoles.caption, color = palette.muted)
					}
				}
			}
			if (stale) row { RowContainer { Notice("Predictions are stale or the arrival estimate has passed. Awaiting an update.", Modifier.testTag("transfersStale")) } }
			current.message?.let { message -> row { RowContainer { Notice(message) } } }
		}
		if (stationID != null) section(
			"filters",
			footer = if (separate) "Filters saved for transfers at this station only." else "Filters shared with this station's board.",
		) {
			row("filters") {
				androidx.compose.foundation.layout.Box(Modifier.padding(start = 12.dp, end = 4.dp, top = 2.dp, bottom = 2.dp)) {
					StationFilterRow(
						directions = BoardLogic.directionOptions(station),
						direction = filter.direction,
						onDirection = { model.setTransferDirection(stationID, it) },
						routes = Connections.lineChoices(station, current, model.hiddenRoutes),
						selectedRoutes = filter.routes.map(Display::displayRoute),
						onToggleRoute = { model.toggleTransferRoute(stationID, it) },
						onAllRoutes = { model.clearTransferRoutes(stationID) },
						tagPrefix = "transfer_",
					)
				}
			}
		}
		val live = !stale && error == null
		val groups = if (live) Connections.groups(current, model.hiddenRoutes, now, filter) else emptyList()
		groups.forEach { group ->
			section("group:${group.id}", headerContent = {
				Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.semantics(mergeDescendants = true) { heading() }) {
					RouteBullet(group.route, small = true)
					Text("${Display.directionLabel(group.direction)} · ${group.area}", style = TextRoles.caption.copy(fontWeight = FontWeight.SemiBold), color = palette.muted)
				}
			}) {
				group.departures.forEach { departure ->
					row(departure.key) {
						Row(
							Modifier.fillMaxWidth().heightIn(min = 48.dp).clickable(role = Role.Button) { open(Route.Train(departure.tripKey)) }
								.padding(horizontal = 16.dp, vertical = 6.dp).semantics(mergeDescendants = true) {}.testTag("connection_${departure.key}"),
							verticalAlignment = Alignment.CenterVertically,
						) {
							Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
								Row(horizontalArrangement = Arrangement.spacedBy(5.dp), verticalAlignment = Alignment.CenterVertically) {
									Text(departure.destination, style = TextRoles.subheadlineBold)
									ChangeIcons(departure.changes.orEmpty(), now)
								}
								Text(departure.actualTrack?.let { "Reported track $it" } ?: departure.scheduledTrack?.let { "Scheduled track $it" } ?: "Track not reported", style = TextRoles.caption2, color = palette.muted)
								Connections.gapLabel(departure)?.let { Text(it, style = TextRoles.caption2, color = palette.muted) }
							}
							Text(Display.clockTime(departure.time, model.timeFormat), style = TextRoles.subheadline)
						}
					}
				}
			}
		}
		if (live && current.message == null) when (Connections.empty(current, model.hiddenRoutes, now, filter)) {
			Connections.Empty.FILTERED -> section("filtered") {
				row { RowContainer { Text("No connecting departures match this station's filters.", style = TextRoles.footnote, color = palette.muted, modifier = Modifier.testTag("transfersFiltered")) } }
				row { ActionButton("Reset filters", { stationID?.let(model::resetTransferFilters) }, Modifier.padding(start = 4.dp).testTag("resetTransferFilters")) }
			}
			Connections.Empty.NONE -> section("none") {
				row { RowContainer { Text("No matching connecting departures are currently reported.", style = TextRoles.footnote, color = palette.muted, modifier = Modifier.testTag("transfersNone")) } }
			}
			null -> {}
		}
		section("sources", header = "Prediction sources") { row { RowContainer { SourcesTable(current.sources, now) } } }
	}
}

/** Trains saved with "Save trip offline". They stay until removed here or from the train. */
@Composable
fun SavedTripsScreen(model: AppModel, exit: ScreenExit, close: () -> Unit, open: (Route) -> Unit) {
	val scope = rememberCoroutineScope()
	var removing by remember { mutableStateOf<CachedTrip?>(null) }
	LaunchedEffect(Unit) { model.reloadOfflineStatus() }
	ListScreen("Saved trains", exit = exit, onExit = close, tag = "savedTripsScreen") {
		model.offlineActionError?.let { message -> section("error") { row { RowContainer { Notice(message) } } } }
		section("trips", footer = "Saved trains stay on this device until you remove them. Their times are the predictions from when they were saved.") {
			model.savedTrips.forEach { trip ->
				row(trip.key) {
					Row(verticalAlignment = Alignment.CenterVertically) {
						Row(
							Modifier.weight(1f).heightIn(min = 48.dp)
								.clickable(role = Role.Button) { open(Route.Train(trip.key, snapshotOnly = OfflineIdentity.isPositionalTrip(trip.key))) }
								.padding(start = 16.dp, top = 8.dp, bottom = 8.dp)
								.semantics(mergeDescendants = true) {}
								.testTag("savedTrip_${trip.key}"),
							horizontalArrangement = Arrangement.spacedBy(8.dp),
						) {
							trip.train?.route?.let { RouteBullet(it, small = true) }
							Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
								Text(trip.train?.destination ?: "Saved train", style = TextRoles.subheadlineBold)
								Text(
									"${trip.train?.let { Display.directionLabel(it.direction) } ?: "Direction unknown"} · saved ${Display.ageLabel(trip.savedAt, model.now)} · source ${Display.ageLabel(trip.sourceTimestamp, model.now)}",
									style = TextRoles.caption2, color = palette.muted,
								)
								OfflineDisplay.completenessLabel(trip.isComplete)?.let { Text(it, style = TextRoles.caption2.copy(fontWeight = FontWeight.SemiBold)) }
								if (model.activeRide?.key == trip.key) Text("Your current ride", style = TextRoles.caption2.copy(fontWeight = FontWeight.SemiBold), color = palette.action)
							}
						}
						IconButton(
							onClick = { removing = trip },
							modifier = Modifier.testTag("removeSavedTrip_${trip.key}").semantics { contentDescription = "Remove saved train ${trip.train?.destination ?: trip.key}" },
						) { Icon(Icons.Filled.Delete, contentDescription = null, tint = palette.danger) }
					}
				}
			}
			if (model.savedTrips.isEmpty()) row { RowContainer { Text("Use Save trip offline in train details to keep a train here.", style = TextRoles.footnote, color = palette.muted) } }
		}
	}
	removing?.let { trip ->
		AlertDialog(
			onDismissRequest = { removing = null },
			title = { Text("Remove this saved train?") },
			text = { Text("Its offline snapshot may then expire with other cached trips.") },
			confirmButton = { TextButton(onClick = { removing = null; scope.launch { model.removeSavedTrip(trip.key) } }) { Text("Remove saved train", color = palette.danger) } },
			dismissButton = { TextButton(onClick = { removing = null }) { Text("Cancel", color = palette.action) } },
		)
	}
}
