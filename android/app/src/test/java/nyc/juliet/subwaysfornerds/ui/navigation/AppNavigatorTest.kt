package nyc.juliet.subwaysfornerds.ui.navigation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AppNavigatorTest {
	@Test fun backClosesOverlaysBeforeDetailsThenReturnsToBoard() {
		val navigator = AppNavigator()
		navigator.select(AppTab.FLEET)
		navigator.push(Route.FleetDetail("nyct:R211A:4149", "cars"))
		navigator.push(Route.Lines)
		assertEquals(listOf(Route.Lines), navigator.overlays)

		assertTrue(navigator.back())
		assertTrue(navigator.overlays.isEmpty())
		assertEquals(1, navigator.current.size)

		assertTrue(navigator.back())
		assertTrue(navigator.current.isEmpty())
		assertEquals(AppTab.FLEET, navigator.tab)

		assertTrue(navigator.back())
		assertEquals(AppTab.BOARD, navigator.tab)
		assertFalse(navigator.back())
	}

	@Test fun tabsKeepIndependentStacks() {
		val navigator = AppNavigator()
		navigator.push(Route.Train("gtfs|1"))
		navigator.select(AppTab.SETTINGS)
		navigator.push(Route.OfflineSettings)
		navigator.select(AppTab.BOARD)
		assertEquals(listOf<Route>(Route.Train("gtfs|1")), navigator.current)
		assertEquals(listOf<Route>(Route.OfflineSettings), navigator.stack(AppTab.SETTINGS))
	}

	@Test fun showReplacesTheDetailColumn() {
		val navigator = AppNavigator()
		navigator.push(Route.Train("a"))
		navigator.push(Route.Transfers("a", "A01N", "Times Sq", 3))
		navigator.show(Route.StationInfo("602"))
		assertEquals(listOf<Route>(Route.StationInfo("602")), navigator.current)
	}

	@Test fun showingSystemStatusFromTheBoardSelectsSettingsAndBackReturnsToSettings() {
		val navigator = AppNavigator()
		navigator.push(Route.Train("a"))
		navigator.show(Route.SystemStatus, AppTab.SETTINGS)
		assertEquals(AppTab.SETTINGS, navigator.tab)
		assertEquals(listOf<Route>(Route.SystemStatus), navigator.current)
		assertEquals("The board's own stack must not be disturbed", listOf<Route>(Route.Train("a")), navigator.stack(AppTab.BOARD))

		assertTrue(navigator.back())
		assertEquals("Back from System status returns to Settings, not the board", AppTab.SETTINGS, navigator.tab)
		assertTrue(navigator.current.isEmpty())
	}

	@Test fun showingSystemStatusReplacesWhateverSettingsAlreadyHad() {
		val navigator = AppNavigator()
		navigator.select(AppTab.SETTINGS)
		navigator.push(Route.OfflineSettings)
		navigator.select(AppTab.BOARD)
		navigator.show(Route.SystemStatus, AppTab.SETTINGS)
		assertEquals(listOf<Route>(Route.SystemStatus), navigator.stack(AppTab.SETTINGS))
	}

	@Test fun anOpenedStationBoardReturnsToTheTransferThenTheTrain() {
		val navigator = AppNavigator()
		val transfers = Route.Transfers("a", "A01N", "Times Sq", 3, stationID = "611")
		navigator.push(Route.Train("a", origin = "row"))
		navigator.push(transfers)
		navigator.openStationBoard("611", from = AppTab.BOARD)
		assertEquals(Route.StationBoard("611", AppTab.BOARD), navigator.current.last())
		assertTrue(navigator.back())
		assertEquals(transfers, navigator.current.last())
		navigator.pop()
		assertEquals(listOf<Route>(Route.Train("a", origin = "row")), navigator.current)
	}

	@Test fun anOpenedStationBoardReturnsToItsOriginalTab() {
		val navigator = AppNavigator()
		navigator.push(Route.Train("board-train"))
		navigator.select(AppTab.FLEET)
		navigator.push(Route.Train("a"))
		navigator.push(Route.Transfers("a", "A01N", "Times Sq", 3))
		navigator.openStationBoard("611", from = AppTab.FLEET)
		assertEquals(AppTab.BOARD, navigator.tab)
		assertEquals(listOf<Route>(Route.StationBoard("611", AppTab.FLEET)), navigator.current)
		// The in-app back arrow pops like the system back.
		navigator.pop()
		assertEquals(AppTab.FLEET, navigator.tab)
		assertEquals(2, navigator.current.size)
	}
}
