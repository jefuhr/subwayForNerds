package nyc.juliet.subwaysfornerds.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DeviceNetworkStatusTest {
	private fun observe(
		hasNetwork: Boolean = true,
		transports: List<NetworkTransport> = listOf(NetworkTransport.WIFI),
		internet: Boolean = true,
		validated: Boolean = true,
		captivePortal: Boolean = false,
		notMetered: Boolean = true,
		notRoaming: Boolean = true,
		notSuspended: Boolean = true,
		airplaneMode: Boolean = false,
		networkName: String? = null,
		blocked: Boolean = false,
	) = DeviceNetworkStatus.observe(hasNetwork, transports, internet, validated, captivePortal, notMetered, notRoaming, notSuspended, airplaneMode, networkName, blocked)

	@Test fun validatedInternetIsConnectedAndNamesTheTransport() {
		val wifi = observe()
		assertEquals(NetworkActivityState.CONNECTED, wifi.state)
		assertEquals("Connected via Wi-Fi", wifi.headline)
		assertEquals("Connected via Cellular", observe(transports = listOf(NetworkTransport.CELLULAR)).headline)
		assertEquals("Connected via Home", observe(networkName = "Home").headline)
		// A VPN rides on another link; the underlying link names the connection.
		assertEquals("Connected via Cellular", observe(transports = listOf(NetworkTransport.VPN, NetworkTransport.CELLULAR)).headline)
		assertEquals("Connected", DeviceNetworkStatus().headline)
	}

	@Test fun unvalidatedOrCaptiveLinksAreConnectingNotOnline() {
		val checking = observe(validated = false)
		assertEquals(NetworkActivityState.CONNECTING, checking.state)
		assertEquals("Connecting to Wi-Fi · checking internet access…", checking.headline)
		val portal = observe(validated = false, captivePortal = true, networkName = "Station Wi-Fi")
		assertEquals(NetworkActivityState.CONNECTING, portal.state)
		assertEquals("Connected to Station Wi-Fi · sign-in required (captive portal)", portal.headline)
		val noInternet = observe(internet = false)
		assertEquals(NetworkActivityState.CONNECTING, noInternet.state)
		assertEquals("Connecting to Wi-Fi…", noInternet.headline)
		val blocked = observe(blocked = true)
		assertEquals(NetworkActivityState.CONNECTING, blocked.state)
		assertEquals("Connected to Wi-Fi · access blocked for this app", blocked.headline)
	}

	@Test fun noNetworkIsSearchingUnlessAirplaneModeIsOn() {
		val searching = observe(hasNetwork = false, transports = emptyList())
		assertEquals(NetworkActivityState.SEARCHING, searching.state)
		assertEquals("Searching for Wi-Fi or cellular signal…", searching.headline)
		val airplane = observe(hasNetwork = false, transports = emptyList(), airplaneMode = true)
		assertEquals(NetworkActivityState.OFFLINE, airplane.state)
		assertEquals("Offline · Airplane mode is on", airplane.headline)
		assertEquals("Offline · no network available", DeviceNetworkStatus(state = NetworkActivityState.OFFLINE).headline)
		val suspended = observe(transports = listOf(NetworkTransport.CELLULAR), notSuspended = false)
		assertEquals(NetworkActivityState.SEARCHING, suspended.state)
		assertEquals("Network suspended · waiting for signal…", suspended.headline)
		// Wi-Fi turned back on in airplane mode is a normal connection.
		assertEquals(NetworkActivityState.CONNECTED, observe(airplaneMode = true).state)
	}

	@Test fun linkCapabilitiesAreCarriedAndBlankOrRedactedNamesAreDropped() {
		val roaming = observe(transports = listOf(NetworkTransport.CELLULAR, NetworkTransport.VPN), notMetered = false, notRoaming = false, networkName = "Carrier")
		assertTrue(roaming.metered); assertTrue(roaming.roaming); assertTrue(roaming.notSuspended)
		assertEquals("Cellular + VPN · Metered · Roaming · Requesting live updates (1 in flight)", roaming.detailLine(4, 1, null))
		assertNull(observe(networkName = "<unknown ssid>").networkName)
		assertNull(observe(networkName = "  ").networkName)
		assertEquals("Home", observe(networkName = "\"Home\"").networkName)
		assertFalse(observe(validated = false).validated)
	}

	@Test fun detailSaysWhatTheAppIsWaitingFor() {
		val searching = DeviceNetworkStatus(state = NetworkActivityState.SEARCHING)
		assertEquals("Waiting for a connection to refresh departures (3 queued)", searching.detailLine(3, 0, null))
		assertEquals("Automatic refreshes paused until a network is available", searching.detailLine(0, 0, null))
		val airplane = DeviceNetworkStatus(state = NetworkActivityState.OFFLINE, airplaneMode = true)
		assertEquals("Waiting for a connection to refresh departures (1 queued)", airplane.detailLine(1, 0, "juliet.nyc"))
		val outage = DeviceNetworkStatus(state = NetworkActivityState.SIMULATED_OUTAGE)
		assertEquals("Simulated outage · network requests paused", outage.headline)
		assertEquals("Automatic refreshes paused until the simulated outage ends (2 queued)", outage.detailLine(2, 0, null))
		val connected = observe()
		assertEquals("Requesting live updates from juliet.nyc (2 in flight)", connected.detailLine(5, 2, "juliet.nyc"))
		assertEquals("Refreshing 5 boards and trains automatically", connected.detailLine(5, 0, "juliet.nyc"))
		assertEquals("No automatic refreshes scheduled", connected.detailLine(0, 0, null))
		val captive = observe(validated = false, captivePortal = true, notMetered = false)
		assertEquals("Metered · Waiting for internet access to refresh departures (1 queued)", captive.detailLine(1, 0, null))
	}

	@Test fun linkFactsListEveryCapabilityForSettings() {
		val portal = observe(validated = false, captivePortal = true, notMetered = false, networkName = "Station")
		assertEquals(listOf("Wi-Fi", "Internet not verified", "Sign-in page", "Metered", "Airplane mode off"), portal.linkFacts)
		val roaming = observe(transports = listOf(NetworkTransport.CELLULAR), notRoaming = false, notSuspended = false, airplaneMode = true, blocked = true)
		assertEquals(listOf("Cellular", "Internet verified", "Unmetered", "Roaming", "Suspended", "Blocked for this app", "Airplane mode on"), roaming.linkFacts)
		assertEquals(listOf("No network", "Airplane mode on"), observe(hasNetwork = false, transports = emptyList(), airplaneMode = true).linkFacts)
		// Without a reading from the system, nothing is claimed about the link.
		assertEquals(listOf("Network type unknown"), DeviceNetworkStatus().linkFacts)
	}

	@Test fun signalReadingsAreNormalizedAndDroppedWithoutANetwork() {
		val wifi = DeviceNetworkStatus.observe(true, listOf(NetworkTransport.WIFI), true, true, false, true, true, true, false, signalStrengthDbm = -58, signalLevel = 4, downstreamKbps = 48_000, upstreamKbps = 12_500)
		assertEquals(-58, wifi.signalStrengthDbm); assertEquals(4, wifi.signalLevel)
		assertEquals(48_000, wifi.downstreamKbps); assertEquals(12_500, wifi.upstreamKbps)
		// SIGNAL_STRENGTH_UNSPECIFIED is Int.MIN_VALUE; Wi-Fi's invalid RSSI is -127; zero bandwidth is unknown.
		val unspecified = DeviceNetworkStatus.observe(true, listOf(NetworkTransport.CELLULAR), true, true, false, true, true, true, false, signalStrengthDbm = Int.MIN_VALUE, signalLevel = 7, downstreamKbps = 0, upstreamKbps = -1)
		assertNull(unspecified.signalStrengthDbm); assertNull(unspecified.signalLevel)
		assertNull(unspecified.downstreamKbps); assertNull(unspecified.upstreamKbps)
		assertNull(DeviceNetworkStatus.observe(true, listOf(NetworkTransport.WIFI), true, true, false, true, true, true, false, signalStrengthDbm = -127).signalStrengthDbm)
		val gone = DeviceNetworkStatus.observe(false, emptyList(), false, false, false, true, true, true, false, signalStrengthDbm = -60, signalLevel = 3, downstreamKbps = 1_000)
		assertNull(gone.signalStrengthDbm); assertNull(gone.signalLevel); assertNull(gone.downstreamKbps)
	}

	@Test fun signalLabelNamesATierFromDbmOrTheSystemLevel() {
		fun dbm(value: Int) = observe().copy(signalStrengthDbm = value).signalStrengthLabel
		assertEquals("Excellent (-60 dBm)", dbm(-60))
		assertEquals("Good (-61 dBm)", dbm(-61))
		assertEquals("Good (-70 dBm)", dbm(-70))
		assertEquals("Fair (-71 dBm)", dbm(-71))
		assertEquals("Fair (-85 dBm)", dbm(-85))
		assertEquals("Weak (-86 dBm)", dbm(-86))
		fun level(value: Int) = observe(transports = listOf(NetworkTransport.CELLULAR)).copy(signalLevel = value).signalStrengthLabel
		assertEquals("Excellent (level 4/4)", level(4))
		assertEquals("Good (level 3/4)", level(3))
		assertEquals("Fair (level 2/4)", level(2))
		assertEquals("Weak (level 1/4)", level(1))
		assertEquals("Weak (level 0/4)", level(0))
		// The system's calibrated level picks the tier when both are known.
		assertEquals("Good (-55 dBm, level 3/4)", observe().copy(signalStrengthDbm = -55, signalLevel = 3).signalStrengthLabel)
	}

	@Test fun signalLabelExplainsStatesWithoutAReading() {
		assertEquals("Connected (Wi-Fi) · dBm not reported by OS", observe().signalStrengthLabel)
		assertEquals("Connected (Cellular) · dBm not reported by OS", observe(transports = listOf(NetworkTransport.CELLULAR), validated = false).signalStrengthLabel)
		assertEquals("Connected (network) · dBm not reported by OS", observe(transports = emptyList()).signalStrengthLabel)
		assertEquals("Not reported by OS", DeviceNetworkStatus().signalStrengthLabel)
		assertEquals("Searching for signal…", observe(hasNetwork = false, transports = emptyList()).signalStrengthLabel)
		assertEquals("No signal", observe(hasNetwork = false, transports = emptyList(), airplaneMode = true).signalStrengthLabel)
		assertEquals("Simulated outage", observe().copy(state = NetworkActivityState.SIMULATED_OUTAGE, signalStrengthDbm = -50).signalStrengthLabel)
	}

	@Test fun bandwidthLabelFormatsEachKnownDirection() {
		assertNull(observe().bandwidthLabel)
		assertEquals("48 Mbps down · 12.5 Mbps up", observe().copy(downstreamKbps = 48_000, upstreamKbps = 12_500).bandwidthLabel)
		assertEquals("1.5 Mbps down", observe().copy(downstreamKbps = 1_500).bandwidthLabel)
		assertEquals("640 Kbps up", observe().copy(upstreamKbps = 640).bandwidthLabel)
		assertEquals("10 Mbps down · 1 Mbps up", observe().copy(downstreamKbps = 10_000, upstreamKbps = 1_000).bandwidthLabel)
	}

	@Test fun waitingDetailNamesWhatThePhoneIsDoing() {
		val searching = DeviceNetworkStatus(state = NetworkActivityState.SEARCHING)
		assertEquals("Searching for Wi-Fi or cellular signal… · Waiting to request departures…", searching.waitingDetail("departures"))
	}
}
