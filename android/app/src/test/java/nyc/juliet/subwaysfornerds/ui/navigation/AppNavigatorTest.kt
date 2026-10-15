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
}
