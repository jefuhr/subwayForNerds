package nyc.juliet.subwaysfornerds.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ProgressTest {
	@Test fun byteCountsUseDecimalFileUnits() {
		assertEquals("512 bytes", ByteCounts.file(512))
		assertEquals("1 byte", ByteCounts.file(1))
		assertEquals("12 KB", ByteCounts.file(12_400))
		assertEquals("4.2 MB", ByteCounts.file(4_210_000))
		assertEquals("1.25 GB", ByteCounts.file(1_250_000_000))
	}

	@Test fun waitingNamesTheWorkWithoutAPercent() {
		val online = waitingLoad("departures", connected = true)
		assertNull(online.percentLabel)
		assertEquals("Waiting to request departures…", online.detail)
		assertEquals("Waiting for a connection to request train details…", waitingLoad("train details", connected = false).detail)
	}
}
