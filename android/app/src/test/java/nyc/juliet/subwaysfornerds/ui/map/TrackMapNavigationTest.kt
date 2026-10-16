package nyc.juliet.subwaysfornerds.ui.map

import nyc.juliet.subwaysfornerds.ui.navigation.AppNavigator
import nyc.juliet.subwaysfornerds.ui.navigation.AppTab
import nyc.juliet.subwaysfornerds.ui.navigation.Route
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TrackMapNavigationTest {
	@Test fun mapSitsBetweenBoardAndFleetWithoutRenumberingExistingTabs() {
		assertEquals(listOf(AppTab.BOARD, AppTab.MAP, AppTab.FLEET, AppTab.SETTINGS), AppTab.ordered)
		assertEquals(listOf(0, 1, 2), listOf(AppTab.BOARD, AppTab.FLEET, AppTab.SETTINGS).map { it.ordinal })
		assertEquals(listOf("BOARD", "FLEET", "SETTINGS"), listOf(AppTab.BOARD, AppTab.FLEET, AppTab.SETTINGS).map { it.name })
		assertEquals("tab_map", "tab_${AppTab.MAP.name.lowercase()}")
		assertEquals("Map", AppTab.MAP.title)
	}

	@Test fun trainsOpenOnTheMapStackAndStationBoardsReturnToTheMap() {
		val navigator = AppNavigator()
		navigator.select(AppTab.MAP)
		navigator.push(Route.Train("gtfs-l|20260905|1|"))
		assertEquals(listOf<Route>(Route.Train("gtfs-l|20260905|1|")), navigator.stack(AppTab.MAP))
		navigator.pop()
		navigator.openStationBoard("602", AppTab.MAP)
		assertEquals(AppTab.BOARD, navigator.tab)
		assertEquals(Route.StationBoard("602", AppTab.MAP), navigator.stack(AppTab.BOARD).last())
		assertTrue(navigator.back())
		assertEquals(AppTab.MAP, navigator.tab)
		// Back from the map's root returns to the board, like the other tabs.
		assertTrue(navigator.back())
		assertEquals(AppTab.BOARD, navigator.tab)
	}
}
