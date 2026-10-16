package nyc.juliet.subwaysfornerds.ui.navigation

import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

enum class AppTab(val title: String) { BOARD("Board"), FLEET("Fleet"), SETTINGS("Settings") }

/** Station search starts empty in its own sort mode each time it opens. */
enum class StationPickerMode { SEARCH, NEARBY }

/** Every screen that can be pushed. Detail routes fill the right pane on wide windows. */
sealed interface Route {
	/** A train; `origin` is the board row it was opened from, which names the boarding station. */
	data class Train(val tripKey: String, val origin: String? = null, val snapshotOnly: Boolean = false) : Route
	/** Connections at a stop; `stationID` is the stop's station, known before the transfer response arrives. */
	data class Transfers(val tripKey: String, val stopID: String, val stopName: String, val sequence: Int?, val stationID: String? = null) : Route
	/** A station's normal board opened from connections. Back returns to the screen below, on `returnTab`. */
	data class StationBoard(val stationID: String, val returnTab: AppTab) : Route
	data class StationInfo(val stationID: String) : Route
	data object SavedTrips : Route
	data class FleetDetail(val id: String, val kind: String, val preferSaved: Boolean = false) : Route
	data class FleetSearch(val query: String) : Route

	// Full-screen tasks that cover both panes, like iOS sheets.
	data class StationPicker(val mode: StationPickerMode) : Route
	data object Alerts : Route
	data object Lines : Route
	data class CombinedEditor(val id: String? = null, val closePickerOnSave: Boolean = false) : Route

	// Settings screens.
	data object CombinedStations : Route
	data class StationSelectionSettings(val widget: Boolean) : Route
	data object FavoriteTrains : Route
	data class WidgetDisplay(val lockScreen: Boolean) : Route
	data class WidgetFilters(val stationID: String) : Route
	data object OfflineSettings : Route
	data object FleetPackScope : Route
	data object WidgetPreviews : Route
	data object SystemStatus : Route
	data object ImportPreview : Route

	val isOverlay: Boolean get() = this is StationPicker || this == Alerts || this == Lines || this is CombinedEditor || this == ImportPreview
}

/**
 * Back stacks for the three tabs. Detail routes stack per tab; overlays cover every pane.
 * Held by the view model so stacks survive rotation and window resizing.
 */
@Stable
class AppNavigator {
	var tab by mutableStateOf(AppTab.BOARD)
	val overlays = mutableStateListOf<Route>()
	private val stacks = AppTab.entries.associateWith { mutableStateListOf<Route>() }

	fun stack(tab: AppTab): List<Route> = stacks.getValue(tab)
	val current: List<Route> get() = stacks.getValue(tab)

	fun select(tab: AppTab) { this.tab = tab }

	/** Pushes on the current tab, or presents an overlay. */
	fun push(route: Route) {
		if (route.isOverlay) { overlays += route; return }
		stacks.getValue(tab) += route
	}

	/** Replaces the detail column, as choosing a new row in a list/detail layout does. */
	fun show(route: Route, tab: AppTab = this.tab) {
		this.tab = tab
		val stack = stacks.getValue(tab)
		stack.clear()
		stack += route
	}

	/**
	 * Shows the newly selected station's board above the screens it was opened from, so Back
	 * returns to them. From another tab, the board tab starts over and Back returns to that tab.
	 */
	fun openStationBoard(stationID: String, from: AppTab) {
		val board = stacks.getValue(AppTab.BOARD)
		if (from != AppTab.BOARD) board.clear()
		tab = AppTab.BOARD
		board += Route.StationBoard(stationID, from)
	}

	/** Leaving an opened station board goes back to the tab it was opened from. */
	private fun left(route: Route?) {
		if (route is Route.StationBoard && route.returnTab != tab) tab = route.returnTab
	}

	fun popOverlay(): Boolean = overlays.removeLastOrNull() != null
	fun closeOverlay(route: Route) { overlays.remove(route) }
	fun closeOverlays() { overlays.clear() }

	/** Back: overlays first, then the current tab's stack, then return to the Board tab. */
	fun back(): Boolean {
		if (popOverlay()) return true
		val stack = stacks.getValue(tab)
		if (stack.isNotEmpty()) { left(stack.removeAt(stack.lastIndex)); return true }
		if (tab != AppTab.BOARD) { tab = AppTab.BOARD; return true }
		return false
	}

	fun pop(tab: AppTab = this.tab) { left(stacks.getValue(tab).removeLastOrNull()) }
	fun clear(tab: AppTab) { stacks.getValue(tab).clear() }
	val canGoBack: Boolean get() = overlays.isNotEmpty() || current.isNotEmpty() || tab != AppTab.BOARD
}
