package nyc.juliet.subwaysfornerds.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.DirectionsSubway
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Train
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.NavigationRail
import androidx.compose.material3.NavigationRailItem
import androidx.compose.material3.NavigationRailItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.saveable.SaveableStateHolder
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.isCtrlPressed
import androidx.compose.ui.input.key.isMetaPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import kotlinx.coroutines.launch
import nyc.juliet.subwaysfornerds.ui.navigation.StationPickerMode
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import nyc.juliet.subwaysfornerds.ui.account.AccountModel
import nyc.juliet.subwaysfornerds.ui.board.AlertsScreen
import nyc.juliet.subwaysfornerds.ui.board.BoardScreen
import nyc.juliet.subwaysfornerds.ui.board.LinesScreen
import nyc.juliet.subwaysfornerds.ui.board.StationPickerScreen
import nyc.juliet.subwaysfornerds.ui.components.EmptyState
import nyc.juliet.subwaysfornerds.ui.components.ScreenExit
import nyc.juliet.subwaysfornerds.ui.fleet.FleetDetailScreen
import nyc.juliet.subwaysfornerds.ui.fleet.FleetScreen
import nyc.juliet.subwaysfornerds.ui.navigation.AppTab
import nyc.juliet.subwaysfornerds.ui.navigation.Route
import nyc.juliet.subwaysfornerds.ui.settings.CombinedEditorScreen
import nyc.juliet.subwaysfornerds.ui.settings.CombinedStationsScreen
import nyc.juliet.subwaysfornerds.ui.settings.FavoriteTrainsScreen
import nyc.juliet.subwaysfornerds.ui.settings.FleetPackScopeScreen
import nyc.juliet.subwaysfornerds.ui.settings.ImportPreviewScreen
import nyc.juliet.subwaysfornerds.ui.settings.OfflineSettingsScreen
import nyc.juliet.subwaysfornerds.ui.settings.SettingsActions
import nyc.juliet.subwaysfornerds.ui.settings.SettingsScreen
import nyc.juliet.subwaysfornerds.ui.settings.StationSelectionScreen
import nyc.juliet.subwaysfornerds.ui.settings.SystemStatusScreen
import nyc.juliet.subwaysfornerds.ui.settings.WidgetDisplayScreen
import nyc.juliet.subwaysfornerds.ui.settings.WidgetFiltersScreen
import nyc.juliet.subwaysfornerds.ui.station.ContextScreen
import nyc.juliet.subwaysfornerds.ui.theme.SubwaysTheme
import nyc.juliet.subwaysfornerds.ui.theme.TextRoles
import nyc.juliet.subwaysfornerds.ui.theme.palette
import nyc.juliet.subwaysfornerds.ui.train.SavedTripsScreen
import nyc.juliet.subwaysfornerds.ui.train.TrainDetailScreen
import nyc.juliet.subwaysfornerds.ui.train.TransferScreen
import nyc.juliet.subwaysfornerds.widgets.ui.WidgetPreviewScreen

/** Window widths where the board and fleet keep their list beside details, like iPad's regular size class. */
const val TWO_PANE_WIDTH_DP = 720
/** Window widths that use a navigation rail instead of a bottom bar. */
const val RAIL_WIDTH_DP = 600
private val ListPaneWidth: Dp = 400.dp

@Composable
fun AppRoot(model: AppModel, account: AccountModel, actions: SettingsActions) {
	SubwaysTheme(model.theme) {
		val navigator = model.navigator
		val holder = rememberSaveableStateHolder()
		val scope = rememberCoroutineScope()
		BackHandler(enabled = navigator.canGoBack) { navigator.back() }
		BoxWithConstraints(
			Modifier.fillMaxSize().background(palette.background).semantics { testTagsAsResourceId = true }
				// Hardware keyboards: Ctrl+F finds a station and Ctrl+R refreshes, like Command-F and Command-R on iPad.
				.onPreviewKeyEvent { event ->
					if (event.type != KeyEventType.KeyDown || !(event.isCtrlPressed || event.isMetaPressed)) return@onPreviewKeyEvent false
					when (event.key) {
						Key.F -> { navigator.select(AppTab.BOARD); navigator.push(Route.StationPicker(StationPickerMode.SEARCH)); true }
						Key.R -> { scope.launch { model.refreshBoard() }; true }
						else -> false
					}
				},
		) {
			val rail = maxWidth >= RAIL_WIDTH_DP.dp
			val twoPane = maxWidth - (if (rail) 80.dp else 0.dp) >= TWO_PANE_WIDTH_DP.dp
			if (rail) {
				Row(Modifier.fillMaxSize()) {
					NavigationRail(
						containerColor = palette.card,
						modifier = Modifier.windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Start + WindowInsetsSides.Vertical)).testTag("navigationRail"),
					) {
						AppTab.entries.forEach { tab ->
							NavigationRailItem(
								selected = navigator.tab == tab,
								onClick = { navigator.select(tab) },
								icon = { Icon(tabIcon(tab), contentDescription = null) },
								label = { Text(tab.title) },
								colors = NavigationRailItemDefaults.colors(selectedIconColor = palette.ink, selectedTextColor = palette.ink, indicatorColor = palette.accentTint, unselectedIconColor = palette.muted, unselectedTextColor = palette.muted),
								modifier = Modifier.testTag("tab_${tab.name.lowercase()}"),
							)
						}
					}
					Box(Modifier.weight(1f).fillMaxHeight().windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.End + WindowInsetsSides.Bottom))) {
						TabContent(model, account, actions, holder, twoPane, wide = true)
					}
				}
			} else {
				Scaffold(
					containerColor = palette.background,
					bottomBar = {
						NavigationBar(containerColor = palette.card, modifier = Modifier.testTag("navigationBar")) {
							AppTab.entries.forEach { tab ->
								NavigationBarItem(
									selected = navigator.tab == tab,
									onClick = { navigator.select(tab) },
									icon = { Icon(tabIcon(tab), contentDescription = null) },
									label = { Text(tab.title) },
									colors = NavigationBarItemDefaults.colors(selectedIconColor = palette.ink, selectedTextColor = palette.ink, indicatorColor = palette.accentTint, unselectedIconColor = palette.muted, unselectedTextColor = palette.muted),
									modifier = Modifier.testTag("tab_${tab.name.lowercase()}"),
								)
							}
						}
					},
				) { padding ->
					Box(Modifier.padding(padding).consumeWindowInsets(padding).fillMaxSize()) {
						TabContent(model, account, actions, holder, twoPane = false, wide = false)
					}
				}
			}
			// Full-screen tasks cover every pane, like iOS sheets.
			val overlay = navigator.overlays.lastOrNull()
			AnimatedContent(overlay, transitionSpec = { fadeIn() togetherWith fadeOut() }, label = "overlay") { route ->
				if (route != null) Surface(Modifier.fillMaxSize(), color = palette.background) {
					Box(Modifier.windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal + WindowInsetsSides.Bottom))) {
						OverlayScreen(model, account, route) { navigator.closeOverlay(route) }
					}
				}
			}
		}
	}
}

private fun tabIcon(tab: AppTab) = when (tab) {
	AppTab.BOARD -> Icons.Filled.DirectionsSubway
	AppTab.FLEET -> Icons.Filled.Train
	AppTab.SETTINGS -> Icons.Filled.Settings
}

@Composable
private fun TabContent(model: AppModel, account: AccountModel, actions: SettingsActions, holder: SaveableStateHolder, twoPane: Boolean, wide: Boolean) {
	val navigator = model.navigator
	val tab = navigator.tab
	val stack = navigator.stack(tab)
	val usesPanes = twoPane && tab != AppTab.SETTINGS
	// Choosing a row in the list pane replaces the detail column; inside details, screens push.
	val openFromList: (Route) -> Unit = { route -> if (usesPanes) navigator.show(route, tab) else navigator.push(route) }
	val openFromDetail: (Route) -> Unit = { route -> navigator.push(route) }
	val pop: () -> Unit = { navigator.pop(tab) }
	val selected = stack.firstOrNull()

	// Each tab root and pushed screen keeps its scroll position and choices while covered or hidden.
	val root: @Composable () -> Unit = {
		holder.SaveableStateProvider("root:${tab.name}") {
			when (tab) {
				AppTab.BOARD -> BoardScreen(model, openFromList, if (usesPanes) selected else null)
				AppTab.FLEET -> FleetScreen(model, "", ScreenExit.NONE, {}, openFromList, if (usesPanes) selected else null)
				AppTab.SETTINGS -> SettingsScreen(model, account, actions, openFromDetail, wide)
			}
		}
	}
	if (!usesPanes) {
		AnimatedContent(stack.lastOrNull(), transitionSpec = { fadeIn() togetherWith fadeOut() }, label = "stack") { route ->
			if (route == null) root()
			else holder.SaveableStateProvider("${tab.name}:${stack.indexOf(route)}:$route") { RouteScreen(model, account, route, ScreenExit.BACK, pop, openFromDetail) }
		}
		return
	}
	Row(Modifier.fillMaxSize()) {
		Box(Modifier.width(ListPaneWidth).fillMaxHeight().testTag("listPane")) { root() }
		VerticalDivider(color = palette.line)
		Box(Modifier.weight(1f).fillMaxHeight().testTag("detailPane")) {
			val route = stack.lastOrNull()
			if (route != null) {
				holder.SaveableStateProvider("${tab.name}:${stack.size - 1}:$route") {
					// The list pane already shows a board opened from connections; details show its station.
					if (route is Route.StationBoard) ContextScreen(model, route.stationID, ScreenExit.BACK, pop, openFromDetail)
					else RouteScreen(model, account, route, if (stack.size > 1) ScreenExit.BACK else ScreenExit.NONE, pop, openFromDetail)
				}
			} else when (tab) {
				// Side by side, station info fills the detail column until a train is chosen.
				AppTab.BOARD -> model.station?.let { ContextScreen(model, it.id, ScreenExit.NONE, {}, openFromDetail) }
				AppTab.FLEET -> Column(Modifier.fillMaxSize().padding(24.dp)) {
					EmptyState("Choose a car or consist", "Reports, roster facts and movement history appear here.")
				}
				AppTab.SETTINGS -> {}
			}
		}
	}
}

/** Every pushed screen by route. */
@Composable
fun RouteScreen(model: AppModel, account: AccountModel, route: Route, exit: ScreenExit, close: () -> Unit, open: (Route) -> Unit) {
	when (route) {
		is Route.Train -> TrainDetailScreen(model, route, exit, close, open)
		is Route.Transfers -> TransferScreen(model, route, exit, close, open)
		// A station board opened from connections pushes trains like other details, so Back returns here.
		is Route.StationBoard -> BoardScreen(model, open, null, onBack = close)
		is Route.StationInfo -> ContextScreen(model, route.stationID, exit, close, open)
		Route.SavedTrips -> SavedTripsScreen(model, exit, close, open)
		is Route.FleetDetail -> FleetDetailScreen(model, route, exit, close, open)
		is Route.FleetSearch -> FleetScreen(model, route.query, exit, close, open, null)
		Route.CombinedStations -> CombinedStationsScreen(model, exit, close, open)
		is Route.StationSelectionSettings -> StationSelectionScreen(model, route.widget, exit, close)
		Route.FavoriteTrains -> FavoriteTrainsScreen(model, exit, close, open)
		is Route.WidgetDisplay -> WidgetDisplayScreen(model, route.lockScreen, exit, close)
		is Route.WidgetFilters -> WidgetFiltersScreen(model, route.stationID, exit, close)
		Route.OfflineSettings -> OfflineSettingsScreen(model, exit, close, open)
		Route.FleetPackScope -> FleetPackScopeScreen(model, exit, close)
		Route.WidgetPreviews -> WidgetPreviewScreen(model, exit, close)
		Route.SystemStatus -> SystemStatusScreen(model, exit, close)
		Route.Lines -> LinesScreen(model, exit, close)
		else -> OverlayScreen(model, account, route, close)
	}
}

@Composable
private fun OverlayScreen(model: AppModel, account: AccountModel, route: Route, close: () -> Unit) {
	when (route) {
		is Route.StationPicker -> StationPickerScreen(model, route.mode, close)
		Route.Alerts -> AlertsScreen(model, close)
		Route.Lines -> LinesScreen(model, ScreenExit.CLOSE, close)
		is Route.CombinedEditor -> CombinedEditorScreen(model, route, close)
		Route.ImportPreview -> ImportPreviewScreen(model, account, close)
		else -> RouteScreen(model, account, route, ScreenExit.CLOSE, close, { model.navigator.push(it) })
	}
}
