package nyc.juliet.subwaysfornerds.ui.map

import android.provider.Settings as AndroidSettings
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.FitScreen
import androidx.compose.material.icons.filled.MyLocation
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.ViewList
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameMillis
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext
import nyc.juliet.subwaysfornerds.core.Display
import nyc.juliet.subwaysfornerds.core.Station
import nyc.juliet.subwaysfornerds.core.TrackMapCamera
import nyc.juliet.subwaysfornerds.core.TrackMapCertainty
import nyc.juliet.subwaysfornerds.core.TrackMapHitTest
import nyc.juliet.subwaysfornerds.core.TrackMapPlacement
import nyc.juliet.subwaysfornerds.core.TrackMapStation
import nyc.juliet.subwaysfornerds.core.TrackMapSlowZoneDisplay
import nyc.juliet.subwaysfornerds.core.TrackMapTrain
import nyc.juliet.subwaysfornerds.ui.AppModel
import nyc.juliet.subwaysfornerds.ui.components.ChipRow
import nyc.juliet.subwaysfornerds.ui.components.ChoiceChip
import nyc.juliet.subwaysfornerds.ui.components.EmptyState
import nyc.juliet.subwaysfornerds.ui.components.LoadingBar
import nyc.juliet.subwaysfornerds.ui.components.RouteBullet
import nyc.juliet.subwaysfornerds.ui.navigation.Route
import nyc.juliet.subwaysfornerds.ui.theme.TextRoles
import nyc.juliet.subwaysfornerds.ui.theme.palette

private const val FRAME_MILLIS = 33L

/** Something a tap on the map can mean. */
private sealed interface MapChoice {
	data class Train(val train: TrackMapTrain, val detail: String) : MapChoice
	data class Station(val station: TrackMapStation) : MapChoice
}

/**
 * The Map tab: the reviewed track map artwork, rendered natively in tiles, with live trains on its rails.
 * Snapshots poll only while this screen is visible and not covered, and the app is in the foreground.
 */
@Composable
fun TrackMapScreen(model: AppModel, open: (Route) -> Unit) {
	val map = model.trackMap
	val context = LocalContext.current
	LaunchedEffect(map) { map.loadAssets(AndroidTrackMapAssets(context.applicationContext)) }
	val covered = model.navigator.overlays.isNotEmpty()
	DisposableEffect(map, covered) {
		map.setVisible(!covered)
		onDispose { map.setVisible(false) }
	}
	Box(Modifier.fillMaxSize().background(palette.background)) {
		when (val state = map.assets) {
			is TrackMapAssetState.Ready -> ReadyMap(model, map, state.resources, open)
			is TrackMapAssetState.Unavailable -> MapUnavailable(map, state.detail, null)
			TrackMapAssetState.Idle, TrackMapAssetState.Loading -> MapUnavailable(map, null, null)
		}
	}
}

@Composable
private fun MapUnavailable(map: TrackMapModel, detail: String?, attribution: String?) {
	Column(Modifier.fillMaxSize().padding(24.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
		StatusLine(map.status(map.clock()))
		if (detail != null) EmptyState("Track map unavailable", detail)
		attribution?.let { Credit(it) }
	}
}

@Composable
private fun StatusLine(text: String, modifier: Modifier = Modifier) {
	Text(
		text,
		style = TextRoles.footnote,
		color = palette.ink,
		modifier = modifier.testTag("track-map-status").semantics { liveRegion = LiveRegionMode.Polite },
	)
}

@Composable
private fun Credit(text: String) {
	Text(text, style = TextRoles.caption2, color = palette.muted, maxLines = 3, overflow = TextOverflow.Ellipsis)
}

@Composable
private fun rememberReducedMotion(): Boolean {
	val resolver = LocalContext.current.contentResolver
	var reduced by remember { mutableStateOf(false) }
	// Re-read on resume, so turning animations off in system settings applies on return.
	LifecycleResumeEffect(resolver) {
		reduced = runCatching { AndroidSettings.Global.getFloat(resolver, AndroidSettings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f }.getOrDefault(false)
		onPauseOrDispose {}
	}
	return reduced
}

@Composable
private fun ReadyMap(model: AppModel, map: TrackMapModel, resources: TrackMapResources, open: (Route) -> Unit) {
	val topology = resources.topology
	val page = topology.page
	val opened by produceState<Result<TrackMapRenderer>?>(null, resources) {
		// Opening is not interrupted, so a document opened as the screen leaves is still closed below.
		val result = withContext(NonCancellable) { runCatching { TrackMapRenderer.open(resources.pdf, page, Runtime.getRuntime().maxMemory()) } }
		value = result
		awaitDispose { result.getOrNull()?.close() }
	}
	val renderer = opened?.getOrNull()
	opened?.exceptionOrNull()?.let { error ->
		MapUnavailable(map, error.message ?: "The installed track map artwork could not be opened.", topology.attribution)
		return
	}
	val reducedMotion = rememberReducedMotion()
	var frameNow by remember { mutableDoubleStateOf(map.clock()) }
	// Expiry ticks independently of train animation and of successful network polls.
	var slowZoneNow by remember { mutableDoubleStateOf(map.clock()) }
	LaunchedEffect(map.active, map.snapshot?.slowZones) {
		slowZoneNow = map.clock()
		while (map.active && TrackMapSlowZoneDisplay.isActive(map.snapshot?.slowZones, slowZoneNow)) {
			val remaining = (map.snapshot?.slowZones?.expiresAt ?: break) - slowZoneNow
			delay(kotlin.math.ceil(remaining * 1000).toLong().coerceIn(1L, 1000L))
			slowZoneNow = map.clock()
		}
	}
	val now = maxOf(model.now, slowZoneNow)
	val markers = map.markers(now, reducedMotion)
	// The frame ticker runs only while the map is on screen in the foreground and something moves.
	val animating = map.active && !reducedMotion && renderer != null && markers.any { it.display.animating }
	// Drawing and hit testing sample the same current frame without restarting active gestures.
	val renderTime = { if (animating) maxOf(frameNow, now) else now }
	LaunchedEffect(animating) {
		if (!animating) return@LaunchedEffect
		while (isActive) { withFrameMillis { }; frameNow = map.clock(); delay(FRAME_MILLIS) }
	}
	renderer?.let { LaunchedEffect(it) { it.run() } }
	var choices by remember { mutableStateOf<List<MapChoice>?>(null) }
	val focus = LocalFocusManager.current
	BackHandler(enabled = map.showTrainList || map.showSlowZoneList) { map.showTrainList = false; map.showSlowZoneList = false }

	fun openTrain(key: String) { choices = null; open(Route.Train(key)) }
	fun openStation(id: String) { choices = null; model.openTransferStationBoard(id) }
	fun fit() { map.viewSize?.let { (w, h) -> map.fit(w, h) } }

	val visibleMarkers = map.viewSize?.let { (w, h) ->
		val view = map.camera?.viewport(w, h)
		if (view == null) markers else markers.filter { val p = view.toScreen(it.display.point); p.x in 0.0..w && p.y in 0.0..h }
	} ?: markers
	val unplaced = map.rows(now).count { it.train.placement == TrackMapPlacement.UNPLACED || it.train.point == null }

	BoxWithConstraints(Modifier.fillMaxSize()) {
		val wide = maxWidth >= 600.dp
		val listHeight = maxHeight * 0.45f
		Column(Modifier.fillMaxSize()) {
			MapChrome(map, model.stations, onFit = ::fit, onSearchResult = { station -> map.focus(station); map.query = ""; focus.clearFocus() }, onOpenStation = ::openStation, visibleCount = visibleMarkers.size)
			Row(Modifier.weight(1f).fillMaxWidth()) {
				Box(Modifier.weight(1f).fillMaxHeight().onSizeChanged {
					if (it.width > 0 && it.height > 0) {
						map.viewSize = it.width.toDouble() to it.height.toDouble()
						map.focusInitial((model.selectedMemberIDs + model.stationID).distinct(), it.width.toDouble(), it.height.toDouble())
					}
				}) {
					if (renderer != null) {
						val description = "Track map. ${markers.size} trains drawn. $unplaced not on the map. ${map.slowZoneStatus(now)}. Amber lines show estimated slow zones. Use Trains for the train list, line filter and slow zone details."
						TrackMapCanvas(
							map, renderer, page,
							time = renderTime,
							reducedMotion = reducedMotion,
							description = description,
							onTap = { at, radius ->
								// One hit opens directly; overlapping trains and stations ask which was meant.
								val found = choicesAt(map, at, radius, renderTime(), reducedMotion)
								when (val only = found.singleOrNull()) {
									is MapChoice.Train -> openTrain(only.train.key)
									is MapChoice.Station -> openStation(only.station.stationId)
									null -> if (found.isNotEmpty()) choices = found
								}
							},
							onFit = ::fit,
							modifier = Modifier.fillMaxSize(),
						)
					} else {
						Text("Rendering map…", style = TextRoles.footnote, color = palette.muted, modifier = Modifier.align(Alignment.Center))
					}
					MapFooter(map, now, topology.attribution, topology.coverage.notes.firstOrNull()?.startsWith("PARTIAL") == true, Modifier.align(Alignment.BottomStart))
				}
				if (wide && map.showTrainList) {
					VerticalDivider(color = palette.line)
					TrainList(map, visibleMarkers, markers, now, ::openTrain, Modifier.width(360.dp).fillMaxHeight())
				}
			}
			if (!wide && map.showTrainList) {
				HorizontalDivider(color = palette.line)
				TrainList(map, visibleMarkers, markers, now, ::openTrain, Modifier.fillMaxWidth().heightIn(max = listHeight))
			}
		}
	}
	if (map.showSlowZoneList) SlowZoneList(map, now)
	choices?.let { found -> OverlapChooser(found, onTrain = ::openTrain, onStation = ::openStation, onDismiss = { choices = null }) }
}

private fun choicesAt(map: TrackMapModel, at: Offset, radius: Float, now: Double, reducedMotion: Boolean): List<MapChoice> {
	val camera = map.camera ?: return emptyList()
	val (w, h) = map.viewSize ?: return emptyList()
	val view = camera.viewport(w, h)
	val markers = map.markers(now, reducedMotion)
	val trains = TrackMapHitTest.within(markers.map { it to view.toScreen(it.display.point) }, at.x.toDouble(), at.y.toDouble(), radius.toDouble())
		.map { MapChoice.Train(it.train, trainDetail(it)) }
	val stations = TrackMapHitTest.within(map.topology?.stations.orEmpty().map { it to view.toScreen(it.point) }, at.x.toDouble(), at.y.toDouble(), radius.toDouble())
		.distinctBy { it.stationId }.map { MapChoice.Station(it) }
	return trains + stations
}

private fun trainDetail(marker: TrackMapMarker): String =
	listOf(TrackMapCertainty.track(marker.train), TrackMapCertainty.position(marker.train), TrackMapCertainty.freshness(marker.evidence)).joinToString(" · ")

@Composable
private fun MapChrome(map: TrackMapModel, catalog: List<Station>, onFit: () -> Unit, onSearchResult: (TrackMapStation) -> Unit, onOpenStation: (String) -> Unit, visibleCount: Int) {
	Column(Modifier.fillMaxWidth().background(palette.background).padding(horizontal = 12.dp, vertical = 4.dp)) {
		Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
			OutlinedTextField(
				value = map.query,
				onValueChange = { map.query = it },
				placeholder = { Text("Find a station on the map") },
				leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
				trailingIcon = { if (map.query.isNotEmpty()) IconButton(onClick = { map.query = "" }) { Icon(Icons.Filled.Clear, contentDescription = "Clear search") } },
				singleLine = true,
				keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, imeAction = ImeAction.Search),
				keyboardActions = KeyboardActions(onSearch = { map.search(map.query, catalog).firstOrNull()?.let { onSearchResult(it.station) } }),
				colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = palette.accent, unfocusedBorderColor = palette.line, cursorColor = palette.action),
				modifier = Modifier.weight(1f).testTag("track-map-search"),
			)
			IconButton(onClick = onFit, modifier = Modifier.testTag("track-map-fit")) {
				Icon(Icons.Filled.FitScreen, contentDescription = "Fit whole map", tint = palette.action)
			}
			TextButton(
				onClick = { map.showTrainList = !map.showTrainList },
				modifier = Modifier.testTag("track-map-trains").semantics { contentDescription = if (map.showTrainList) "Hide visible trains list, $visibleCount trains" else "Show visible trains list, $visibleCount trains" },
			) {
				Icon(Icons.Filled.ViewList, contentDescription = null, tint = palette.action, modifier = Modifier.size(18.dp))
				Text(" Trains $visibleCount", style = TextRoles.caption, color = palette.ink)
			}
		}
		val results = map.search(map.query, catalog)
		if (map.query.isNotBlank()) {
			if (results.isEmpty()) Text("No mapped station matches.", style = TextRoles.caption, color = palette.muted, modifier = Modifier.padding(vertical = 4.dp))
			results.forEach { result ->
				Row(
					Modifier.fillMaxWidth().clickable(onClickLabel = "Show on map") { onSearchResult(result.station) }.padding(vertical = 2.dp).testTag("track-map-result-${result.stationId}"),
					verticalAlignment = Alignment.CenterVertically,
				) {
					Icon(Icons.Filled.MyLocation, contentDescription = null, tint = palette.action, modifier = Modifier.size(16.dp))
					Column(Modifier.weight(1f).padding(start = 6.dp)) {
						Text(result.title, style = TextRoles.subheadline, color = palette.ink)
						if (result.subtitle.isNotEmpty()) Text(result.subtitle, style = TextRoles.caption, color = palette.muted)
					}
					TextButton(onClick = { onOpenStation(result.stationId) }, modifier = Modifier.semantics { contentDescription = "${result.title} departures" }) { Text("Board", style = TextRoles.caption) }
				}
			}
		}
	}
}

@Composable
private fun MapFooter(map: TrackMapModel, now: Double, attribution: String, partial: Boolean, modifier: Modifier) {
	Surface(color = palette.card.copy(alpha = 0.94f), modifier = modifier.fillMaxWidth()) {
		Column(Modifier.padding(horizontal = 12.dp, vertical = 6.dp)) {
			if (map.snapshot == null) map.progress?.let { load -> LoadingBar("Loading train positions", load.fraction?.toFloat(), load.percentLabel, load.spokenPercent, load.detail) }
			StatusLine(map.status(now))
			if (partial) Text("Partial coverage", style = TextRoles.caption2, color = palette.muted)
			Credit(attribution)
		}
	}
}

@Composable
private fun TrainList(map: TrackMapModel, visible: List<TrackMapMarker>, plotted: List<TrackMapMarker>, now: Double, onOpen: (String) -> Unit, modifier: Modifier) {
	val visibleKeys = visible.mapTo(HashSet()) { it.train.key }
	val plottedKeys = plotted.mapTo(HashSet()) { it.train.key }
	val elsewhere = plotted.filter { it.train.key !in visibleKeys }
	val unplaced = map.rows(now).filter { it.train.key !in plottedKeys }
	Surface(color = palette.card, modifier = modifier) {
		Column {
			Row(Modifier.fillMaxWidth().padding(start = 12.dp), verticalAlignment = Alignment.CenterVertically) {
				Text("Trains in view (${visible.size})", style = TextRoles.headline, color = palette.ink, modifier = Modifier.weight(1f).semantics { contentDescription = "${visible.size} trains in view" })
				IconButton(onClick = { map.showTrainList = false }) { Icon(Icons.Filled.Close, contentDescription = "Close trains list") }
			}
			LazyColumn(Modifier.fillMaxWidth().testTag("track-map-train-list")) {
				if (map.routes.isNotEmpty()) item(key = "route-filter") { RouteFilter(map) }
				item(key = "slow-zones") { Box(Modifier.padding(horizontal = 12.dp)) { SlowZoneLegend(map, now) } }
				items(visible, key = { it.train.key }) { marker -> TrainRow(map, TrackMapRow(marker.train, marker.evidence), marker, onOpen) }
				if (elsewhere.isNotEmpty()) {
					item(key = "elsewhere-heading") { TrainListHeading("Elsewhere on the map (${elsewhere.size})") }
					items(elsewhere, key = { it.train.key }) { marker -> TrainRow(map, TrackMapRow(marker.train, marker.evidence), marker, onOpen) }
				}
				if (unplaced.isNotEmpty()) {
					item(key = "unplaced-heading") { TrainListHeading("Not on the map (${unplaced.size})") }
					items(unplaced, key = { it.train.key }) { row -> TrainRow(map, row, null, onOpen) }
				}
				if (plotted.isEmpty() && unplaced.isEmpty()) {
					item(key = "empty") { Text("No trains match these lines right now.", style = TextRoles.caption, color = palette.muted, modifier = Modifier.padding(12.dp)) }
				}
			}
		}
	}
}

/** Line chips edit the same selected lines that filter the map markers and the lists below. */
@Composable
private fun RouteFilter(map: TrackMapModel) {
	ChipRow(Modifier.fillMaxWidth().padding(horizontal = 12.dp)) {
		ChoiceChip("All lines", map.routeFilter.isEmpty(), { map.clearRoutes() })
		map.routes.forEach { route ->
			val label = Display.displayRoute(route)
			ChoiceChip(label, route in map.routeFilter, { map.toggleRoute(route) }, contentDescription = "Line $label${if (route in map.routeFilter) ", shown" else ""}")
		}
	}
}

@Composable
private fun TrainListHeading(text: String) {
	Text(text, style = TextRoles.subheadline.copy(fontWeight = FontWeight.SemiBold), color = palette.muted, modifier = Modifier.padding(12.dp))
}

@Composable
private fun TrainRow(map: TrackMapModel, row: TrackMapRow, marker: TrackMapMarker?, onOpen: (String) -> Unit) {
	val train = row.train
	val track = TrackMapCertainty.track(train)
	val position = if (marker != null) TrackMapCertainty.position(train) else "Not on the map"
	val freshness = TrackMapCertainty.freshness(row.evidence)
	val reason = if (marker == null) train.reason ?: "No reliable current position" else null
	val label = Display.displayRoute(train.route)
	Row(
		Modifier.fillMaxWidth().clickable { onOpen(train.key) }.padding(horizontal = 12.dp, vertical = 8.dp).testTag("track-map-train-${train.key}")
			.semantics(mergeDescendants = true) { contentDescription = listOfNotNull("Line $label to ${train.destination}", track, position, freshness, reason).joinToString(". ") },
		verticalAlignment = Alignment.CenterVertically,
		horizontalArrangement = Arrangement.spacedBy(10.dp),
	) {
		RouteBullet(train.route, small = true)
		Column(Modifier.weight(1f)) {
			Text(train.destination, style = TextRoles.subheadline.copy(fontWeight = FontWeight.SemiBold), color = palette.ink, maxLines = 2, overflow = TextOverflow.Ellipsis)
			Text(track, style = TextRoles.caption, color = palette.ink, modifier = Modifier.testTag("track-map-track-certainty"))
			Text(position, style = TextRoles.caption, color = palette.ink, modifier = Modifier.testTag("track-map-position-certainty"))
			if (reason != null) Text(reason, style = TextRoles.caption, color = palette.muted)
			Text(freshness, style = TextRoles.caption, color = if (row.evidence.freshness == nyc.juliet.subwaysfornerds.core.TrackMapFreshness.LIVE) palette.muted else palette.warning)
		}
		if (marker != null) IconButton(onClick = { val topology = map.topology ?: return@IconButton; map.camera = TrackMapCamera.centered(marker.display.point, maxOf(map.camera?.scale ?: 0.0, TrackMapCamera.DETAIL_SCALE), topology.page) }) {
			Icon(Icons.Filled.MyLocation, contentDescription = "Show line $label to ${train.destination} on the map", tint = palette.action)
		}
	}
}

@Composable
private fun OverlapChooser(choices: List<MapChoice>, onTrain: (String) -> Unit, onStation: (String) -> Unit, onDismiss: () -> Unit) {
	AlertDialog(
		onDismissRequest = onDismiss,
		confirmButton = {},
		dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
		title = { Text("Choose", style = TextRoles.headline) },
		text = {
			LazyColumn(Modifier.testTag("track-map-chooser")) {
				items(choices, key = { when (it) { is MapChoice.Train -> "t:${it.train.key}"; is MapChoice.Station -> "s:${it.station.id}" } }) { choice ->
					when (choice) {
						is MapChoice.Train -> Row(
							Modifier.fillMaxWidth().clickable { onTrain(choice.train.key) }.padding(vertical = 8.dp).testTag("track-map-choice-${choice.train.key}")
								.semantics(mergeDescendants = true) {},
							verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp),
						) {
							RouteBullet(choice.train.route, small = true)
							Column(Modifier.weight(1f)) {
								Text(choice.train.destination, style = TextRoles.subheadline, color = palette.ink)
								Text(choice.detail, style = TextRoles.caption, color = palette.muted)
							}
						}
						is MapChoice.Station -> Row(
							Modifier.fillMaxWidth().clickable { onStation(choice.station.stationId) }.padding(vertical = 8.dp).testTag("track-map-choice-station-${choice.station.stationId}"),
							verticalAlignment = Alignment.CenterVertically,
						) {
							Text("${choice.station.name} departures", style = TextRoles.subheadline, color = palette.action)
						}
					}
				}
			}
		},
	)
}
