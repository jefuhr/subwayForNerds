package nyc.juliet.subwaysfornerds.widgets.ui

import nyc.juliet.subwaysfornerds.core.Departure
import nyc.juliet.subwaysfornerds.core.LockScreenSettings
import nyc.juliet.subwaysfornerds.core.WidgetDisplay
import nyc.juliet.subwaysfornerds.widgets.runtime.WidgetColumn
import nyc.juliet.subwaysfornerds.widgets.runtime.WidgetDeparture
import nyc.juliet.subwaysfornerds.widgets.runtime.WidgetSnapshot
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class WidgetLayoutTest {
	private val now = 1_800_000_000.0
	private fun row(direction: String, minutes: Int, cached: Boolean = false) = WidgetDeparture(
		Departure(key = "$direction$minutes", tripKey = "t$direction$minutes", route = "Q", destination = if (direction == "NORTH") "96 St" else "Coney Island", direction = direction,
			stopId = "D28", partId = "D28", area = "Brighton", time = now + minutes * 60, pattern = "Local", patternSource = "reported", location = "", feed = "gtfs-nqrw", timestamp = now - 20),
		cached = cached,
	)
	private fun snapshot(vararg columns: WidgetColumn) = WidgetSnapshot(stationID = "44", stationName = "Church Av", columns = columns.toList(), sourceTime = now - 20, generatedAt = now, estimated = false)

	@Test fun bothDirectionsAreAlwaysRepresented() {
		val value = snapshot(WidgetColumn("NORTH", "Northbound", listOf(row("NORTH", 3))), WidgetColumn("SOUTH", "Southbound", emptyList()))
		val columns = WidgetLayout.columns(value, lockScreen = false)
		assertEquals(listOf("NORTH", "SOUTH"), columns.map { it.direction })
		assertTrue(columns[1].rows.isEmpty())
		val only = snapshot(WidgetColumn("NORTH", "Northbound", listOf(row("NORTH", 3))))
		assertEquals(listOf("NORTH", "SOUTH"), WidgetLayout.columns(only, lockScreen = false).map { it.direction })
	}

	@Test fun lockScreenOrderPutsDowntownLeftByDefault() {
		val value = snapshot(WidgetColumn("NORTH", "Northbound", emptyList()), WidgetColumn("SOUTH", "Southbound", emptyList()))
		assertEquals(listOf("SOUTH", "NORTH"), WidgetLayout.columns(value, lockScreen = true).map { it.direction })
		val reversed = value.copy(lockScreen = LockScreenSettings(directionOrder = "uptownLeft"))
		assertEquals(listOf("NORTH", "SOUTH"), WidgetLayout.columns(reversed, lockScreen = true).map { it.direction })
		val path = snapshot(WidgetColumn("TO_NY", "To New York", emptyList()), WidgetColumn("TO_NJ", "To New Jersey", emptyList()))
		assertEquals(listOf("TO_NJ", "TO_NY"), WidgetLayout.columns(path, lockScreen = true).map { it.direction })
		assertEquals(listOf("TO_NY", "TO_NJ"), WidgetLayout.columns(path, lockScreen = false).map { it.direction })
	}

	@Test fun rowsFitTheHeightAndRespectTheChosenLimit() {
		assertEquals(3, WidgetLayout.rowsThatFit(heightDp = 150f, headerDp = 24f, footerDp = 0f, rowDp = 34f, limit = 0, maximum = 14))
		assertEquals(2, WidgetLayout.rowsThatFit(heightDp = 400f, headerDp = 24f, footerDp = 14f, rowDp = 34f, limit = 2, maximum = 14))
		// Both directions keep at least one row, even when text is very large.
		assertEquals(1, WidgetLayout.rowsThatFit(heightDp = 60f, headerDp = 24f, footerDp = 14f, rowDp = 60f, limit = 0, maximum = 14))
	}

	@Test fun clocksDropAmPmAndTheReportTimeCarriesIt() {
		assertEquals("3:00", WidgetLayout.shortClock(now, "12h"))
		assertEquals("03:00", WidgetLayout.shortClock(now, "24h"))
		assertEquals("As of 3:00 AM", WidgetLayout.reportLabel(snapshot().copy(sourceTime = now), now))
	}

	@Test fun estimatesAreAlwaysLabeledWithTheirSourceAge() {
		val saved = snapshot().copy(estimated = true, estimateUsable = true, sourceTime = now - 180)
		assertEquals("Offline estimate · 3m ago", WidgetLayout.reportLabel(saved, now))
		val old = saved.copy(estimateUsable = false, sourceTime = now - 7200)
		assertEquals("Last known times · 2h ago", WidgetLayout.reportLabel(old, now))
	}

	@Test fun passedRowsSayPassedInsteadOfAClock() {
		assertEquals("Passed", WidgetLayout.arrival(row("NORTH", -2, cached = true), now, "12h"))
		assertEquals("3:05", WidgetLayout.arrival(row("NORTH", 5), now, "12h"))
	}

	@Test fun fieldsControlOptionalLines() {
		val display = WidgetDisplay(fields = listOf("destination"))
		assertTrue(WidgetLayout.shows(display, "destination"))
		assertTrue(!WidgetLayout.shows(display, "stationName"))
	}
}
