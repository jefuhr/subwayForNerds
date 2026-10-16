package nyc.juliet.subwaysfornerds.core

/** What the phone's default network is doing, from Android's connectivity callbacks. */
enum class NetworkActivityState { CONNECTED, CONNECTING, SEARCHING, OFFLINE, SIMULATED_OUTAGE }

enum class NetworkTransport(val label: String) {
	WIFI("Wi-Fi"), CELLULAR("Cellular"), ETHERNET("Ethernet"), VPN("VPN"), BLUETOOTH("Bluetooth"), OTHER("Network"),
}

/**
 * The device's network as riders see it while offline or reconnecting: the link, its capabilities,
 * and why the app is or is not online. Formatting is pure so screens and tests agree.
 */
data class DeviceNetworkStatus(
	val state: NetworkActivityState = NetworkActivityState.CONNECTED,
	val transports: List<NetworkTransport> = emptyList(),
	/** A Wi-Fi SSID or carrier label, only when the system shares one. */
	val networkName: String? = null,
	val captivePortal: Boolean = false,
	val validated: Boolean = true,
	val metered: Boolean = false,
	val roaming: Boolean = false,
	val notSuspended: Boolean = true,
	val airplaneMode: Boolean = false,
	/** The network is up but this app's traffic is blocked (Data Saver or background restrictions). */
	val blocked: Boolean = false,
	/** False when only connected/disconnected is known, so link details are not claimed. */
	val observed: Boolean = false,
	/** Received signal in dBm, only when the system reports one. */
	val signalStrengthDbm: Int? = null,
	/** The system's calibrated signal bars, 0 to 4. */
	val signalLevel: Int? = null,
	/** The system's link bandwidth estimates; not measured throughput. */
	val downstreamKbps: Int? = null,
	val upstreamKbps: Int? = null,
) {
	/** Every link capability, for the offline settings screen. */
	val linkFacts: List<String> get() {
		if (!observed) return listOf("Network type unknown")
		if (transports.isEmpty()) return listOf("No network", if (airplaneMode) "Airplane mode on" else "Airplane mode off")
		return buildList {
			add(transports.joinToString(" + ") { it.label })
			add(if (validated) "Internet verified" else "Internet not verified")
			if (captivePortal) add("Sign-in page")
			add(if (metered) "Metered" else "Unmetered")
			if (roaming) add("Roaming")
			if (!notSuspended) add("Suspended")
			if (blocked) add("Blocked for this app")
			add(if (airplaneMode) "Airplane mode on" else "Airplane mode off")
		}
	}

	/** Signal quality for the system status screen; the system's level picks the tier when it reports one. */
	val signalStrengthLabel: String get() = when (state) {
		NetworkActivityState.SIMULATED_OUTAGE -> "Simulated outage"
		NetworkActivityState.OFFLINE -> "No signal"
		NetworkActivityState.SEARCHING -> "Searching for signal…"
		NetworkActivityState.CONNECTED, NetworkActivityState.CONNECTING -> {
			val tier = signalLevel?.let(::levelTier) ?: signalStrengthDbm?.let(::dbmTier)
			when {
				tier != null -> "$tier (" + listOfNotNull(signalStrengthDbm?.let { "$it dBm" }, signalLevel?.let { "level $it/4" }).joinToString(", ") + ")"
				!observed -> "Not reported by OS"
				else -> "Connected (${transportLabel ?: "network"}) · dBm not reported by OS"
			}
		}
	}

	/** The system's link speed estimates in each direction it reports, or null when it reports neither. */
	val bandwidthLabel: String? get() = listOfNotNull(
		downstreamKbps?.takeIf { it > 0 }?.let { "${speed(it)} down" },
		upstreamKbps?.takeIf { it > 0 }?.let { "${speed(it)} up" },
	).takeIf { it.isNotEmpty() }?.joinToString(" · ")

	/** The link that carries traffic: a VPN is named only when nothing else is. */
	val transportLabel: String? get() = (transports.firstOrNull { it != NetworkTransport.VPN } ?: transports.firstOrNull())?.label

	val headline: String get() {
		val link = networkName ?: transportLabel
		return when (state) {
			NetworkActivityState.SIMULATED_OUTAGE -> "Simulated outage · network requests paused"
			NetworkActivityState.SEARCHING -> if (!notSuspended) "Network suspended · waiting for signal…" else "Searching for Wi-Fi or cellular signal…"
			NetworkActivityState.CONNECTING -> {
				val target = link ?: "network"
				when {
					captivePortal -> "Connected to $target · sign-in required (captive portal)"
					blocked -> "Connected to $target · access blocked for this app"
					!validated -> "Connecting to $target · checking internet access…"
					else -> "Connecting to $target…"
				}
			}
			NetworkActivityState.OFFLINE -> if (airplaneMode) "Offline · Airplane mode is on" else "Offline · no network available"
			NetworkActivityState.CONNECTED -> link?.let { "Connected via $it" } ?: "Connected"
		}
	}

	/** Link facts the headline does not already say, then what the app is fetching or waiting to fetch. */
	fun detailLine(waitingTargets: Int, inFlightTargets: Int, endpointHost: String?): String {
		val link = buildList {
			if (transports.isNotEmpty() && (networkName != null || transports.size > 1)) add(transports.joinToString(" + ") { it.label })
			if (metered) add("Metered")
			if (roaming) add("Roaming")
			if (airplaneMode && transports.isNotEmpty()) add("Airplane mode on")
		}
		val queued = if (waitingTargets > 0) " ($waitingTargets queued)" else ""
		val activity = when (state) {
			NetworkActivityState.SIMULATED_OUTAGE -> "Automatic refreshes paused until the simulated outage ends$queued"
			NetworkActivityState.CONNECTED -> when {
				inFlightTargets > 0 -> "Requesting live updates" + (endpointHost?.let { " from $it" } ?: "") + " ($inFlightTargets in flight)"
				waitingTargets == 1 -> "Refreshing 1 board or train automatically"
				waitingTargets > 1 -> "Refreshing $waitingTargets boards and trains automatically"
				else -> "No automatic refreshes scheduled"
			}
			NetworkActivityState.CONNECTING ->
				if (waitingTargets > 0) "Waiting for internet access to refresh departures$queued" else "Automatic refreshes paused until internet access is confirmed"
			NetworkActivityState.SEARCHING, NetworkActivityState.OFFLINE ->
				if (waitingTargets > 0) "Waiting for a connection to refresh departures$queued" else "Automatic refreshes paused until a network is available"
		}
		return (link + activity).joinToString(" · ")
	}

	/** A loading bar's detail before a request can start. */
	fun waitingDetail(subject: String): String = "$headline · Waiting to request $subject…"

	companion object {
		private const val redactedSsid = "<unknown ssid>"

		/** Classifies one reading of the default network; [hasNetwork] is false when there is none. */
		fun observe(
			hasNetwork: Boolean,
			transports: List<NetworkTransport>,
			internet: Boolean,
			validated: Boolean,
			captivePortal: Boolean,
			notMetered: Boolean,
			notRoaming: Boolean,
			notSuspended: Boolean,
			airplaneMode: Boolean,
			networkName: String? = null,
			blocked: Boolean = false,
			signalStrengthDbm: Int? = null,
			signalLevel: Int? = null,
			downstreamKbps: Int? = null,
			upstreamKbps: Int? = null,
		): DeviceNetworkStatus {
			if (!hasNetwork) return DeviceNetworkStatus(
				state = if (airplaneMode) NetworkActivityState.OFFLINE else NetworkActivityState.SEARCHING,
				validated = false, airplaneMode = airplaneMode, observed = true,
			)
			val state = when {
				!notSuspended -> NetworkActivityState.SEARCHING
				!internet || !validated || captivePortal || blocked -> NetworkActivityState.CONNECTING
				else -> NetworkActivityState.CONNECTED
			}
			return DeviceNetworkStatus(
				state, transports, cleanName(networkName), captivePortal, validated,
				metered = !notMetered, roaming = !notRoaming, notSuspended = notSuspended, airplaneMode = airplaneMode, blocked = blocked, observed = true,
				// SIGNAL_STRENGTH_UNSPECIFIED is Int.MIN_VALUE and Wi-Fi's invalid RSSI is -127.
				signalStrengthDbm = signalStrengthDbm?.takeIf { it in -126..-1 },
				signalLevel = signalLevel?.takeIf { it in 0..4 },
				downstreamKbps = downstreamKbps?.takeIf { it > 0 },
				upstreamKbps = upstreamKbps?.takeIf { it > 0 },
			)
		}

		private fun levelTier(level: Int): String = when {
			level >= 4 -> "Excellent"
			level == 3 -> "Good"
			level == 2 -> "Fair"
			else -> "Weak"
		}

		private fun dbmTier(dbm: Int): String = when {
			dbm >= -60 -> "Excellent"
			dbm >= -70 -> "Good"
			dbm >= -85 -> "Fair"
			else -> "Weak"
		}

		/** Kbps below 1 Mbps; otherwise Mbps with one decimal below 100, dropping a trailing .0. */
		private fun speed(kbps: Int): String {
			if (kbps < 1_000) return "$kbps Kbps"
			val mbps = kbps / 1_000.0
			val text = if (mbps >= 100) Math.round(mbps).toString() else String.format(java.util.Locale.US, "%.1f", mbps).removeSuffix(".0")
			return "$text Mbps"
		}

		/** Wi-Fi reports quote UTF-8 SSIDs and redact them without location access. */
		private fun cleanName(name: String?): String? =
			name?.trim()?.removeSurrounding("\"")?.trim()?.takeIf { it.isNotEmpty() && it != redactedSsid }
	}
}
