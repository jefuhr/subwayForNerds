package nyc.juliet.subwaysfornerds.ui.board

import nyc.juliet.subwaysfornerds.core.Station
import nyc.juliet.subwaysfornerds.core.StationPart
import nyc.juliet.subwaysfornerds.ui.DepartureSection
import org.junit.Assert.assertEquals
import org.junit.Test

class BoardHeadingTest {
	private val station = Station("s", "Sheepshead Bay", "Bk", listOf("B", "Q"), 40.58, -73.95, listOf(StationPart("p", "s", "Platform", "Brighton", listOf("B", "Q"), 40.58, -73.95, "1", north = "Manhattan", south = "Coney Island")))
	private fun section(track: String?, reported: Boolean) = DepartureSection("g", "NORTH", "p", track, reported, "label", null, emptyList())

	@Test fun trackGroupHeadersFollowTheProvenanceSetting() {
		assertEquals("Manhattan" to "Brighton · Track A4", BoardLogic.heading(section("A4", true), station, "track", showProvenance = false))
		assertEquals("Manhattan" to "Brighton · Track A4 · reported", BoardLogic.heading(section("A4", true), station, "track", showProvenance = true))
		assertEquals("Manhattan" to "Brighton · Track A5 · scheduled", BoardLogic.heading(section("A5", false), station, "track", showProvenance = true))
		assertEquals("Manhattan" to "Brighton · Track A5", BoardLogic.heading(section("A5", false), station, "track", showProvenance = false))
		assertEquals("Manhattan" to "Brighton · Track unknown", BoardLogic.heading(section(null, false), station, "track", showProvenance = false))
		assertEquals("Northbound" to "All platforms", BoardLogic.heading(section("A4", true), station, "direction", showProvenance = false))
	}
}
