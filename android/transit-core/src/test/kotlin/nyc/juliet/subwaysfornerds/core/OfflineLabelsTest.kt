package nyc.juliet.subwaysfornerds.core

import org.junit.Assert.assertEquals
import org.junit.Test

class OfflineLabelsTest {
	@Test fun theEstimatedNextStopLabelDoesNotRepeatThatItIsUnobserved() {
		// Offline times are already labeled as estimates with their source age.
		assertEquals("Estimated next stop", OfflineDisplay.estimatedNextStopLabel)
	}
}
