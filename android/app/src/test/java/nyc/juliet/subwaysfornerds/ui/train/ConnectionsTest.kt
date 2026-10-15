package nyc.juliet.subwaysfornerds.ui.train

import nyc.juliet.subwaysfornerds.core.TransferFilter
import nyc.juliet.subwaysfornerds.core.TransferResult
import nyc.juliet.subwaysfornerds.core.TransitJson
import nyc.juliet.subwaysfornerds.ui.fixture
import nyc.juliet.subwaysfornerds.ui.navigation.Route
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Transfer filtering keeps the arrival-relative grouping and 30-minute window, and only narrows it. */
class ConnectionsTest {
	private val data = TransitJson.decodeFromString(TransferResult.serializer(), fixture("transfers.json"))
	private val now = 1_788_656_340.0
	private val route = Route.Transfers("gtfs-l|20260905|122300_L..N|", "L02N", "6 Av", 22, stationID = "601")

	@Test fun unfilteredGroupsAreUnchanged() {
		assertEquals(Connections.groups(data, emptyList(), now), Connections.groups(data, emptyList(), now, TransferFilter()))
		assertTrue(Connections.groups(data, emptyList(), now).isNotEmpty())
	}

	@Test fun directionAndLinesNarrowTheGroups() {
		val south = Connections.groups(data, emptyList(), now, TransferFilter("SOUTH"))
		assertTrue(south.isNotEmpty())
		assertTrue(south.all { it.direction == "SOUTH" })
		val lines = Connections.groups(data, emptyList(), now, TransferFilter(routes = listOf("1", "F")))
		assertTrue(lines.isNotEmpty())
		assertEquals(setOf("1", "F"), lines.map { it.route }.toSet() intersect setOf("1", "F"))
		assertTrue(lines.all { it.route in setOf("1", "F") })
	}

	@Test fun routeAliasesMatchTheirDisplayedLine() {
		val shuttle = data.copy(connections = data.connections.take(1).map { it.copy(route = "GS") })
		assertEquals(1, Connections.groups(shuttle, emptyList(), now, TransferFilter(routes = listOf("S"))).size)
		// An imported alias selection matches the same line.
		assertEquals(1, Connections.groups(shuttle, emptyList(), now, TransferFilter(routes = listOf("GS"))).size)
		assertEquals(listOf("S"), Connections.lineChoices(null, shuttle, emptyList()))
	}

	@Test fun hiddenLinesStayHiddenWhileStoredSelectionsRemain() {
		val filter = TransferFilter(routes = listOf("L", "2"))
		val groups = Connections.groups(data, listOf("L"), now, filter)
		assertTrue(groups.isNotEmpty())
		assertTrue(groups.none { it.route == "L" })
		assertFalse("L" in Connections.lineChoices(data.station, data, listOf("L")))
		assertEquals(listOf("L", "2"), filter.routes)
	}

	@Test fun lineChoicesComeFromTheTargetStationAndConnections() {
		val choices = Connections.lineChoices(data.station, data, emptyList())
		assertEquals(listOf("1", "2", "3", "F", "L", "M"), choices)
		// Choices stay stable when the current response has no rows for a line.
		assertEquals(choices, Connections.lineChoices(data.station, data.copy(connections = emptyList()), emptyList()))
	}

	@Test fun emptyStatesDistinguishFiltersFromNoService() {
		assertNull(Connections.empty(data, emptyList(), now, TransferFilter()))
		assertEquals(Connections.Empty.FILTERED, Connections.empty(data, emptyList(), now, TransferFilter(routes = listOf("M"))))
		assertEquals(Connections.Empty.NONE, Connections.empty(data.copy(connections = emptyList()), emptyList(), now, TransferFilter(routes = listOf("M"))))
	}

	@Test fun theTargetStationComesFromTheResponseOrTheStop() {
		assertEquals("601", Connections.targetStationID(route, data))
		assertEquals("601", Connections.targetStationID(route, null))
		assertNull(Connections.targetStationID(route.copy(stationID = null), null))
		assertEquals("601", Connections.targetStationID(route.copy(stationID = "999"), data))
	}

	@Test fun expiredOrStaleResultsAreNeverCurrent() {
		assertTrue(Connections.stale(data, connected = true, now = data.arrival!! + 1))
		assertTrue(Connections.stale(data, connected = false, now = now))
		assertTrue(Connections.stale(data, connected = true, now = data.originTimestamp!! + 3_600))
		assertFalse(Connections.stale(data, connected = true, now = now))
		// Rows that already left are dropped even when the result itself is fresh.
		assertTrue(Connections.groups(data, emptyList(), now + 1_800).flatMap { it.departures }.all { (it.time ?: 0.0) >= now + 1_800 })
	}
}
