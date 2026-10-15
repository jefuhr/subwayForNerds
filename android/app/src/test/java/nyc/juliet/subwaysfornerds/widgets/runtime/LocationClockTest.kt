package nyc.juliet.subwaysfornerds.widgets.runtime

import nyc.juliet.subwaysfornerds.core.StationLocation
import nyc.juliet.subwaysfornerds.location.*
import org.junit.Assert.*
import org.junit.Test

class LocationClockTest {
	@Test fun sourceClockRejectsFutureExpiredAndInvalidCoordinates() {
		assertTrue(LocationController.usable(StationLocation(40.7, -74.0, 100.0), 200.0))
		assertFalse(LocationController.usable(StationLocation(40.7, -74.0, 201.0), 200.0))
		assertFalse(LocationController.usable(StationLocation(40.7, -74.0, 100.0), 400.0))
		assertFalse(LocationController.usable(StationLocation(Double.NaN, -74.0, 100.0), 200.0))
	}
	@Test fun deniedAndApproximateAreSeparateAndUnavailableHasHonestFallbackNotice() {
		val denied = LocationStatus(LocationPermission.DENIED, true, false, false)
		assertTrue(denied.notice!!.contains("permission"))
		val approximate = LocationStatus(LocationPermission.APPROXIMATE, true, false, false)
		assertEquals("Approximate location", approximate.notice)
		assertTrue(LocationResult(null, approximate, LocationFailure.UNAVAILABLE).notice!!.contains("saved station"))
		assertFalse(approximate.backgroundEnabled)
	}
	@Test fun permissionAndBackgroundChangesDuringLookupDiscardIneligibleResults() {
		val precise = LocationStatus(LocationPermission.PRECISE, true, true, true)
		assertNull(LocationController.resultFailure(LocationPermission.PRECISE, precise, true))
		assertNull(LocationController.resultFailure(LocationPermission.APPROXIMATE, precise, true))
		assertEquals(LocationFailure.DENIED, LocationController.resultFailure(LocationPermission.PRECISE, precise.copy(permission = LocationPermission.DENIED), true))
		assertEquals(LocationFailure.UNAVAILABLE, LocationController.resultFailure(LocationPermission.PRECISE, precise.copy(permission = LocationPermission.APPROXIMATE), true))
		assertNull(LocationController.resultFailure(LocationPermission.APPROXIMATE, precise.copy(permission = LocationPermission.APPROXIMATE), true))
		assertEquals(LocationFailure.DISABLED, LocationController.resultFailure(LocationPermission.PRECISE, precise.copy(servicesEnabled = false), true))
		assertEquals(LocationFailure.BACKGROUND_DISABLED, LocationController.resultFailure(LocationPermission.PRECISE, precise.copy(backgroundEnabled = false), false))
		assertEquals(LocationFailure.BACKGROUND_PERMISSION_REQUIRED, LocationController.resultFailure(LocationPermission.PRECISE, precise.copy(backgroundPermission = false), false))
		assertNull(LocationController.resultFailure(LocationPermission.PRECISE, precise.copy(backgroundEnabled = false, backgroundPermission = false), true))
	}
	@Test fun approximatePermissionStillUsesGPSOnlyDevicesAndNeverStartsPassiveOrDeniedLookups() {
		assertEquals("gps", LocationController.preferredProvider(listOf("passive", "gps"), LocationPermission.APPROXIMATE))
		assertEquals("network", LocationController.preferredProvider(listOf("network", "gps"), LocationPermission.APPROXIMATE))
		assertEquals("gps", LocationController.preferredProvider(listOf("network", "gps"), LocationPermission.PRECISE))
		assertNull(LocationController.preferredProvider(listOf("passive"), LocationPermission.APPROXIMATE))
		assertNull(LocationController.preferredProvider(listOf("network", "gps"), LocationPermission.DENIED))
	}
}
