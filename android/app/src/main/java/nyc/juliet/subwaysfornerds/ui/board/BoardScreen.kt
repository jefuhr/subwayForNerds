package nyc.juliet.subwaysfornerds.ui.board

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.ChevronLeft
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.CloudDone
import androidx.compose.material.icons.filled.CloudDownload
import androidx.compose.material.icons.filled.CloudOff
import androidx.compose.material.icons.filled.DownloadForOffline
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.LocationOn
import androidx.compose.material.icons.filled.MyLocation
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Sensors
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.SwapVert
import androidx.compose.material.icons.filled.Map
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch
import nyc.juliet.subwaysfornerds.core.Board
import nyc.juliet.subwaysfornerds.core.Departure
import nyc.juliet.subwaysfornerds.core.Display
import nyc.juliet.subwaysfornerds.core.OfflineDisplay
import nyc.juliet.subwaysfornerds.core.Station
import nyc.juliet.subwaysfornerds.core.TransitLinks
import nyc.juliet.subwaysfornerds.ui.AppModel
import nyc.juliet.subwaysfornerds.ui.CoreBridge
import nyc.juliet.subwaysfornerds.ui.DepartureSection
import nyc.juliet.subwaysfornerds.ui.Labels
import nyc.juliet.subwaysfornerds.ui.components.ActionButton
import nyc.juliet.subwaysfornerds.ui.components.ActionChip
import nyc.juliet.subwaysfornerds.ui.components.ChipRow
import nyc.juliet.subwaysfornerds.ui.components.ChoiceChip
import nyc.juliet.subwaysfornerds.ui.components.EmptyState
import nyc.juliet.subwaysfornerds.ui.components.ExpandRow
import nyc.juliet.subwaysfornerds.ui.components.FavoriteStar
import nyc.juliet.subwaysfornerds.ui.components.LinkButton
import nyc.juliet.subwaysfornerds.ui.components.ListHeader
import nyc.juliet.subwaysfornerds.ui.components.LoadingBar
import nyc.juliet.subwaysfornerds.ui.components.Notice
import nyc.juliet.subwaysfornerds.ui.components.RouteBullet
import nyc.juliet.subwaysfornerds.ui.components.RowContainer
import nyc.juliet.subwaysfornerds.ui.components.SourcesTable
import nyc.juliet.subwaysfornerds.ui.components.openLink
import nyc.juliet.subwaysfornerds.ui.components.section
import nyc.juliet.subwaysfornerds.ui.navigation.Route
import nyc.juliet.subwaysfornerds.ui.navigation.StationPickerMode
import nyc.juliet.subwaysfornerds.ui.theme.TextRoles
import nyc.juliet.subwaysfornerds.ui.theme.palette

/**
 * The board: station heading and actions, filters, grouped departures and feed check. With
 * two or more station pages, riders swipe between them like the web board's station pager.
 * `onBack` shows a back arrow when the board was opened from connections.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun BoardScreen(model: AppModel, open: (Route) -> Unit, selected: Route?, modifier: Modifier = Modifier, onBack: (() -> Unit)? = null) {
	val scope = rememberCoroutineScope()
	Scaffold(
		modifier = modifier.testTag("boardScreen"),
		containerColor = palette.background,
		contentWindowInsets = WindowInsets(0, 0, 0, 0),
		topBar = {
			TopAppBar(
				title = { Text("Board", modifier = Modifier.semantics { heading() }) },
				navigationIcon = {
					if (onBack != null) IconButton(onClick = onBack, modifier = Modifier.testTag("navigateBack")) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back") }
				},
				actions = {
					IconButton(onClick = { model.navigator.push(Route.StationPicker(StationPickerMode.SEARCH)) }, modifier = Modifier.testTag("findStation")) {
						Icon(Icons.Filled.Search, contentDescription = "Find a station")
					}
					IconButton(onClick = { model.navigator.push(Route.StationPicker(StationPickerMode.NEARBY)) }, modifier = Modifier.testTag("nearbyFromBoard")) {
						Icon(Icons.Filled.MyLocation, contentDescription = "Stations near me")
					}
					IconButton(onClick = { scope.launch { model.refreshBoard() } }, modifier = Modifier.testTag("refreshBoard")) {
						Icon(Icons.Filled.Refresh, contentDescription = "Refresh departures")
					}
				},
				colors = TopAppBarDefaults.topAppBarColors(containerColor = palette.background, titleContentColor = palette.ink, actionIconContentColor = palette.action),
			)
		},
	) { padding ->
		val pages = model.stationPages
		Box(Modifier.padding(padding).fillMaxSize()) {
			if (pages.size < 2) {
				BoardPage(model, open, selected)
			} else {
				val index = pages.indexOf(model.stationID).coerceAtLeast(0)
				val pager = rememberPagerState(initialPage = index) { pages.size }
				LaunchedEffect(index, pages) {
					if (pager.currentPage != index && !pager.isScrollInProgress) pager.scrollToPage(index)
				}
				LaunchedEffect(pager, pages) {
					snapshotFlow { pager.isScrollInProgress }.distinctUntilChanged().collect { scrolling ->
						if (!scrolling) pages.getOrNull(pager.settledPage)?.let { if (it != model.stationID) model.selectStation(it, fromPager = true) }
					}
				}
				HorizontalPager(state = pager, key = { pages.getOrElse(it) { "page-$it" } }, beyondViewportPageCount = 0, modifier = Modifier.fillMaxSize()) { page ->
					val id = pages.getOrNull(page) ?: return@HorizontalPager
					if (id == model.stationID) BoardPage(model, open, selected, bottomInset = 64.dp)
					else StationPreview(model, id)
				}
				PageDock(
					pages = pages,
					current = index,
					name = model::stationName,
					select = { target -> scope.launch { pager.animateScrollToPage(target) } },
					modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = 8.dp),
				)
			}
		}
	}
}

/** Previous/next buttons and one dot per station page, like the web pager dock. */
@Composable
private fun PageDock(pages: List<String>, current: Int, name: (String) -> String, select: (Int) -> Unit, modifier: Modifier = Modifier) {
	Surface(
		modifier = modifier.testTag("stationPager").semantics { contentDescription = "Station pages, ${current + 1} of ${pages.size}" },
		shape = RoundedCornerShape(24.dp),
		color = palette.card,
		tonalElevation = 2.dp,
		shadowElevation = 6.dp,
		border = androidx.compose.foundation.BorderStroke(1.dp, palette.line),
	) {
		Row(verticalAlignment = Alignment.CenterVertically) {
			IconButton(onClick = { select(current - 1) }, enabled = current > 0, modifier = Modifier.testTag("previousStation")) {
				Icon(Icons.Filled.ChevronLeft, contentDescription = "Previous station", tint = if (current > 0) palette.action else palette.line)
			}
			Row(Modifier.widthIn(max = 220.dp), verticalAlignment = Alignment.CenterVertically) {
				pages.forEachIndexed { index, id ->
					Box(
						Modifier
							.size(width = 18.dp, height = 48.dp)
							.clickable(role = Role.Tab, onClickLabel = "Go to ${name(id)}") { select(index) }
							.semantics { contentDescription = "Go to ${name(id)}, page ${index + 1} of ${pages.size}"; selected = index == current },
						contentAlignment = Alignment.Center,
					) {
						Box(Modifier.size(if (index == current) 9.dp else 7.dp).background(if (index == current) palette.accent else palette.line, CircleShape))
					}
				}
			}
			IconButton(onClick = { select(current + 1) }, enabled = current < pages.lastIndex, modifier = Modifier.testTag("nextStation")) {
				Icon(Icons.Filled.ChevronRight, contentDescription = "Next station", tint = if (current < pages.lastIndex) palette.action else palette.line)
			}
		}
	}
}

/** A neighbor page while swiping: its name and saved board age, never live-looking times. */
@Composable
private fun StationPreview(model: AppModel, id: String) {
	val station = model.allStations.firstOrNull { it.id == id }
	Column(Modifier.fillMaxSize().padding(horizontal = 28.dp, vertical = 16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
		Text(model.stationName(id), style = TextRoles.headline)
		Text(BoardLogic.metadata(station, id, model.combinedStations[id]?.stationIDs?.size), style = TextRoles.caption2, color = palette.muted)
		station?.let { RouteRow(CoreBridge.visibleRoutes(it.routes, model.hiddenRoutes)) }
		Text("Release to open this station's board.", style = TextRoles.footnote, color = palette.muted)
	}
}

@Composable
private fun RouteRow(routes: List<String>) {
	nyc.juliet.subwaysfornerds.ui.components.RouteStrip(routes)
}

/** One station's board list. */
@Composable
fun BoardPage(model: AppModel, open: (Route) -> Unit, selected: Route?, bottomInset: androidx.compose.ui.unit.Dp = 0.dp) {
	val scope = rememberCoroutineScope()
	val listState = rememberLazyListState()
	var refreshing by remember { mutableStateOf(false) }
	val groups = model.departureGroups
	val predecessors = remember(groups) { groups.associate { it.id to DepartureFormat.predecessors(it.departures) } }
	PullToRefreshBox(
		isRefreshing = refreshing,
		onRefresh = { scope.launch { refreshing = true; try { model.refreshBoard() } finally { refreshing = false } } },
		modifier = Modifier.fillMaxSize(),
	) {
		LazyColumn(state = listState, modifier = Modifier.fillMaxSize().testTag("boardList"), contentPadding = PaddingValues(bottom = 24.dp + bottomInset)) {
			boardContent(model, open, selected, groups, predecessors)
		}
	}
}

private fun LazyListScope.boardContent(model: AppModel, open: (Route) -> Unit, selected: Route?, groups: List<DepartureSection>, predecessors: Map<String, List<Departure?>>) {
	val station = model.station
	val board = model.board
	val displayBoard = model.displayBoard
	val now = model.now
	val external = BoardLogic.externalDepartures(board, station)
	val configuredNJT = board?.njt?.configured == true

	section("heading") { row("heading") { StationHeading(model, open, external) } }
	model.settingsError?.let { error -> section("settingsError") { row { RowContainer { Notice(error, Modifier.testTag("boardSettingsError")) } } } }
	if (model.permissionCardVisible) section("locationCard") { row { LocationCard(model) } }
	if (model.activeRide != null) section("ride") { row { ActiveRideBanner(model, open) } }
	if (model.offlineFailures.isNotEmpty()) section("saveFailures") {
		row {
			RowContainer {
				Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.testTag("offlineSaveFailure")) {
					val count = model.offlineFailures.size
					Notice("Offline save failed: ${model.offlineFailures.last().message}${if (count > 1) " (+${count - 1} more)" else ""}. Saved data from before is unchanged.", Modifier.weight(1f))
					TextButton(onClick = { model.dismissOfflineFailures() }) { Text("Dismiss", color = palette.action) }
				}
			}
		}
	}
	if (station != null && station.routes.isNotEmpty() && CoreBridge.visibleRoutes(station.routes, model.hiddenRoutes).isEmpty()) {
		section("allHidden") {
			row { RowContainer { Text("All lines at this station are hidden.", style = TextRoles.subheadline) } }
			row { ActionButton("Manage lines", { model.navigator.push(Route.Lines) }, Modifier.testTag("manageLines").padding(start = 4.dp)) }
		}
		return
	}
	if (external && station != null) { njtDeparturesSection(station, configured = false); return }

	val error = model.boardError
	val live = BoardLogic.live(board, model.combinedBoard, model.connected, model.boardIsCached, now)
	val degraded = BoardLogic.degraded(board, model.combinedBoard, now)
	if (error != null) section("boardError") { row { RowContainer { Notice(error, Modifier.testTag("boardError")) } } }
	else if (degraded && board != null) section("degraded") { row { RowContainer { Notice("Some feeds are stale or unavailable. Check source ages below.") } } }
	if (board != null && model.boardIsCached) section("offline") { row { OfflineStatus(model) } }
	section("filters") { row("filters") { Filters(model) } }

	if (board == null) {
		section("loading") {
			if (error == null) row { val load = model.boardLoad; RowContainer { LoadingBar("Loading departures", load.fraction?.toFloat(), load.percentLabel, load.spokenPercent, load.detail, Modifier.testTag("boardLoading")) } }
			// With no board and no connection, the bar's space says what the phone is doing.
			else if (!model.connected) row { RowContainer { DeviceNetworkSummary(model) } }
			row { ActionButton("Find a station", { model.navigator.push(Route.StationPicker(StationPickerMode.SEARCH)) }, Modifier.padding(start = 4.dp)) }
		}
	} else if (groups.isEmpty()) {
		section("empty") {
			row {
				val title = if (configuredNJT && board.departures.isEmpty()) "No arrival predictions" else "No departures match"
				val description = Display.njtPredictionMessage(board, now, model.boardIsCached)
					?: "An empty board does not mean service is suspended. Try all directions and lines, or refresh the feed."
				EmptyState(title, description, Modifier.fillMaxWidth().padding(horizontal = 16.dp).testTag("boardNoPredictions"))
			}
			row { ActionButton("Reset filters", { model.resetFilters() }, Modifier.padding(start = 4.dp)) }
			if (model.hiddenRoutes.isNotEmpty()) {
				row { RowContainer { Text("Some lines are hidden in settings. Resetting station filters keeps those lines hidden.", style = TextRoles.footnote, color = palette.muted) } }
				row { ActionButton("Manage lines", { model.navigator.push(Route.Lines) }, Modifier.testTag("manageLines").padding(start = 4.dp)) }
			}
		}
	}
	groups.forEach { group -> platformSection(model, group, predecessors.getValue(group.id), station, model.preference.view, now, open, selected) }
	if (configuredNJT && displayBoard != null) {
		njtPositionsSection(displayBoard, now, model.boardIsCached)
		njtDeparturesSection(displayBoard.station, configured = true)
		displayBoard.njt?.cacheError?.let { cacheError -> section("njtCache") { row { RowContainer { Notice("NJ Transit cache: $cacheError") } } } }
	}
	if (board != null) section(
		"feedCheck", header = "Feed check",
		footer = "Times are predictions, not promises. Track labels are feed-reported. Times shown in New York time.",
	) { row { RowContainer { SourcesTable(board.sources, now) } } }
}

@Composable
private fun StationHeading(model: AppModel, open: (Route) -> Unit, external: Boolean) {
	val station = model.station
	val now = model.now
	val live = BoardLogic.live(model.board, model.combinedBoard, model.connected, model.boardIsCached, now)
	val degraded = BoardLogic.degraded(model.board, model.combinedBoard, now)
	val favorite = model.stationID in model.favorites
	Column(Modifier.padding(start = 16.dp, end = 4.dp, top = 2.dp, bottom = 6.dp)) {
		Row(verticalAlignment = Alignment.CenterVertically) {
			Row(
				Modifier.weight(1f).heightIn(min = 48.dp)
					.clickable(role = Role.Button, onClickLabel = "Find a station") { model.navigator.push(Route.StationPicker(StationPickerMode.SEARCH)) }
					.testTag("selectedStation"),
				verticalAlignment = Alignment.CenterVertically,
			) {
				Text(station?.name ?: "Your next train", style = TextRoles.headline, modifier = Modifier.weight(1f, fill = false))
				Icon(Icons.Filled.KeyboardArrowDown, contentDescription = null, tint = palette.muted, modifier = Modifier.size(18.dp))
			}
			FavoriteStar(favorite, if (favorite) "Remove favorite station" else "Favorite this station", { model.toggleFavorite(model.stationID) }, Modifier.testTag("toggleFavorite"))
		}
		androidx.compose.foundation.layout.FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(2.dp), modifier = Modifier.padding(end = 10.dp)) {
			Text(BoardLogic.metadata(station, model.stationID, model.combinedStations[model.stationID]?.stationIDs?.size), style = TextRoles.caption2, color = palette.muted)
			val label = BoardLogic.freshnessLabel(external, live, degraded, model.boardIsCached, model.board != null, model.boardSavedAt)
			Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
				Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(3.dp), modifier = Modifier.testTag("boardFreshness").semantics(mergeDescendants = true) { liveRegion = LiveRegionMode.Polite }) {
					Icon(if (external) Icons.Filled.Map else if (live) Icons.Filled.Sensors else Icons.Filled.Schedule, contentDescription = null, tint = if (live) palette.action else palette.muted, modifier = Modifier.size(13.dp))
					Text(label, style = TextRoles.caption2.copy(fontWeight = FontWeight.SemiBold), color = if (live) palette.action else palette.muted)
				}
				// Kept outside the live region so offline save progress does not interrupt TalkBack.
				if (model.board != null && !model.boardIsCached && !external) OfflineReadinessIcon(model)
			}
		}
		StationActions(model, open, external)
	}
}

/** Station actions and other favorites share one scrolling row rather than a menu. */
@Composable
private fun StationActions(model: AppModel, open: (Route) -> Unit, external: Boolean) {
	val context = LocalContext.current
	ChipRow(Modifier.padding(top = 2.dp)) {
		if (model.station != null) ActionChip("Station info", { open(Route.StationInfo(model.stationID)) }, Modifier.testTag("stationInfo"), icon = Icons.Filled.Info)
		if (external) ActionChip("Alerts", { openLink(context, TransitLinks.njtAlerts) }, icon = Icons.AutoMirrored.Filled.OpenInNew)
		else {
			val count = model.displayBoard?.alerts?.size ?: 0
			ActionChip("Alerts ($count)", { model.navigator.push(Route.Alerts) }, Modifier.testTag("stationAlerts"), icon = Icons.Filled.Warning, iconTint = if (count > 0) palette.warning else palette.muted)
		}
		if (model.savedTrips.isNotEmpty()) ActionChip("Saved trains (${model.savedTrips.size})", { open(Route.SavedTrips) }, Modifier.testTag("savedTrips"), icon = Icons.Filled.DownloadForOffline)
		model.favoriteStations.filter { it.id != model.stationID }.forEach { favorite ->
			ActionChip(favorite.name, { model.selectStation(favorite.id) }, Modifier.testTag("favoriteStation_${favorite.id}").semantics { contentDescription = "Favorite station ${favorite.name}" }, icon = Icons.Filled.Star)
		}
	}
}

/** Saved boards say they are offline estimates and how old their source is. */
@Composable
private fun OfflineStatus(model: AppModel) {
	val board = model.board ?: return
	if (!model.boardIsCached) return
	RowContainer {
		Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
			val source = model.predictionSourceTimestamp(board)
			Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp), modifier = Modifier.testTag("boardOfflineEstimate").semantics(mergeDescendants = true) {}) {
				Icon(Icons.Filled.CloudOff, contentDescription = null, tint = palette.warning, modifier = Modifier.size(15.dp))
				Text(OfflineDisplay.estimateLabel(source, model.now, model.offlinePreferences), style = TextRoles.caption.copy(fontWeight = FontWeight.SemiBold))
			}
			DeviceNetworkSummary(
				model,
				model.boardSavedAt?.let { "Board saved ${Display.ageLabel(it, model.now)}. Countdowns use this device's clock; trains that left are marked estimate passed." }
					?: "Showing the last board from this visit; it was not saved offline.",
			)
		}
	}
}

/** Live boards show how much is ready offline as one compact icon beside the feed label. */
@Composable
private fun OfflineReadinessIcon(model: AppModel) {
	val readiness = model.readiness
	val icon: ImageVector = if (readiness.boardFailed) Icons.Filled.ErrorOutline else if (readiness.boardSaved) Icons.Filled.CloudDone else Icons.Filled.CloudDownload
	Icon(
		icon,
		contentDescription = BoardLogic.readinessLabel(readiness.boardFailed, readiness.boardSaved, readiness.savedCount, readiness.wanted.size, readiness.partial.size),
		tint = palette.muted,
		modifier = Modifier.size(14.dp).testTag("offlineReadiness"),
	)
}

/** What the phone's network is doing and what the app is waiting to fetch, then any board provenance. */
@Composable
private fun DeviceNetworkSummary(model: AppModel, provenance: String? = null) {
	Column(Modifier.testTag("deviceNetworkStatus").semantics(mergeDescendants = true) {}) {
		Text(model.deviceNetworkHeadline, style = TextRoles.caption2.copy(fontWeight = FontWeight.SemiBold), color = palette.ink)
		Text(
			listOfNotNull(model.deviceNetworkDetail, provenance).joinToString(" · "),
			style = TextRoles.caption2, color = palette.muted, modifier = Modifier.testTag("deviceNetworkDetail"),
		)
	}
}

@Composable
private fun Filters(model: AppModel) {
	val preference = model.preference
	Column(Modifier.padding(start = 12.dp, end = 4.dp, top = 2.dp, bottom = 2.dp)) {
		StationFilterRow(
			directions = BoardLogic.directionOptions(model.station),
			direction = preference.direction,
			onDirection = model::setDirection,
			routes = BoardLogic.routeChoices(model.station, model.board, model.hiddenRoutes, CoreBridge::visibleRoutes),
			selectedRoutes = preference.routes,
			onToggleRoute = model::toggleRoute,
			onAllRoutes = model::clearRoutes,
		)
		ChipRow(Modifier.testTag("boardViews")) {
			Labels.boardViews.forEach { view ->
				ChoiceChip(Labels.boardViewTitle(view), preference.view == view, { model.setBoardView(view) }, Modifier.testTag("boardView_$view"), contentDescription = Labels.boardViewLabel(view))
			}
		}
	}
}

private fun LazyListScope.platformSection(model: AppModel, group: DepartureSection, predecessors: List<Departure?>, station: Station?, view: String, now: Double, open: (Route) -> Unit, selected: Route?) {
	val (heading, subtitle) = BoardLogic.heading(group, station, view)
	val key = "group:${group.id}"
	val expandedState = model.expandedGroups
	val expanded = group.id in expandedState
	val shown = if (expanded) group.departures else group.departures.take(5)
	val arrow = when (group.direction) {
		"NORTH" -> Icons.Filled.ArrowUpward; "SOUTH" -> Icons.Filled.ArrowDownward
		"TO_NY" -> Icons.AutoMirrored.Filled.ArrowForward; "TO_NJ" -> Icons.AutoMirrored.Filled.ArrowBack
		else -> Icons.Filled.SwapVert
	}
	section(key, headerContent = {
		Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp), modifier = Modifier.testTag("departureGroup_${group.id}").semantics(mergeDescendants = true) { heading() }) {
			Icon(arrow, contentDescription = null, tint = palette.action, modifier = Modifier.size(14.dp))
			Text("$heading · $subtitle", style = TextRoles.caption, color = palette.muted)
		}
	}) {
		shown.forEachIndexed { index, departure ->
			row(departure.key) {
				val route = Route.Train(departure.tripKey, origin = departure.key)
				val isSelected = selected == route
				Box(
					Modifier.fillMaxWidth()
						.background(if (isSelected) palette.accentTint else androidx.compose.ui.graphics.Color.Transparent)
						.clickable(role = Role.Button, onClickLabel = "Open train details") { open(route) }
						.semantics { this.selected = isSelected }
						.testTag("departure_${departure.key}")
						.padding(start = 16.dp, end = 14.dp, top = 8.dp, bottom = 8.dp),
				) {
					DepartureRow(
						departure, now, model.departureIsCached(departure.key), predecessors[index], view != "track",
						model.offlinePreferences, model.timeFormat, model.trainFavorites,
						boardingStation = if (station?.isCombined == true) model.departureOrigin(departure.key)?.station?.name else null,
					)
				}
			}
		}
		if (group.departures.size > 5) row("more") {
			ExpandRow(if (expanded) "Show fewer trains" else "Show ${group.departures.size - 5} more trains", expanded, { model.toggleGroupExpanded(group.id) })
		}
	}
}

private fun LazyListScope.njtDeparturesSection(station: Station, configured: Boolean) {
	section("njtDepartures", header = "Official departure tools") {
		row {
			RowContainer {
				Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
					Text(station.routes.firstOrNull()?.let { Display.regionalRoute(it)?.name } ?: "NJ Transit light rail", style = TextRoles.headline)
					station.parts.firstOrNull()?.let { part -> Text((station.municipality?.let { "$it · " } ?: "") + "NJ Transit station ${part.stationId}", style = TextRoles.subheadline) }
					if (!configured) Text("Live light rail departures are not connected in this app. Check NJ Transit for upcoming trains, schedules, and service changes.", style = TextRoles.footnote, color = palette.muted)
				}
			}
		}
		row { LinkButton("NJ Transit departures", TransitLinks.njtDepartures, Modifier.padding(start = 4.dp), tag = "njtDepartures") }
		row { LinkButton("Light rail schedules", TransitLinks.njtSchedules, Modifier.padding(start = 4.dp)) }
		row { LinkButton("Service alerts", TransitLinks.njtAlerts, Modifier.padding(start = 4.dp)) }
	}
}

private fun LazyListScope.njtPositionsSection(board: Board, now: Double, cached: Boolean) {
	val positions = Display.currentVehiclePositions(board.vehiclePositions, now)
	section("njtPositions", header = "Reported vehicle locations", footer = "GPS reports age independently of arrival estimates. Locations over five minutes old are hidden.") {
		if (positions.isEmpty()) row { RowContainer { Text("No recent vehicle locations are reported.", style = TextRoles.footnote, color = palette.muted) } }
		positions.forEach { position ->
			row(position.id) {
				RowContainer(Modifier.testTag("njtPosition_${position.id}").semantics(mergeDescendants = true) {}) {
					Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
						RouteBullet(position.route, small = true)
						Column {
							Text("Vehicle ${position.vehicleId}", style = TextRoles.subheadlineBold)
							Text(Display.vehiclePositionLabel(position, now, cached), style = TextRoles.caption, color = palette.muted)
						}
					}
				}
			}
		}
	}
}

/** Explicit, dismissible offer to use location for the closest favorite. Nothing is requested automatically. */
@Composable
private fun LocationCard(model: AppModel) {
	RowContainer(Modifier.testTag("startupLocationCard")) {
		Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
			Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
				Icon(Icons.Filled.LocationOn, contentDescription = null, tint = palette.action, modifier = Modifier.size(16.dp))
				Text("Open your closest favorite automatically?", style = TextRoles.subheadlineBold)
			}
			Text("When you open the app, your location chooses the nearest favorite station. Choosing a station yourself always takes priority. Location stays on this device.", style = TextRoles.caption, color = palette.muted)
			Row {
				TextButton(onClick = { model.allowStartupLocation() }, modifier = Modifier.testTag("allowStartupLocation")) { Text("Allow location", color = palette.action) }
				TextButton(onClick = { model.declineStartupLocation() }) { Text("Not now", color = palette.muted) }
			}
		}
	}
}
