package nyc.juliet.subwaysfornerds

import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.wifi.WifiInfo
import android.net.wifi.WifiManager
import android.os.Bundle
import android.provider.Settings
import android.telephony.TelephonyManager
import android.view.View
import android.view.ViewTreeObserver
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.launch
import nyc.juliet.subwaysfornerds.core.DeviceNetworkStatus
import nyc.juliet.subwaysfornerds.core.NetworkTransport
import nyc.juliet.subwaysfornerds.ui.AppContainer
import nyc.juliet.subwaysfornerds.ui.AppRoot
import nyc.juliet.subwaysfornerds.ui.DeepLink
import nyc.juliet.subwaysfornerds.ui.DeepLinks
import nyc.juliet.subwaysfornerds.ui.LaunchOptions
import nyc.juliet.subwaysfornerds.ui.AppViewModel
import nyc.juliet.subwaysfornerds.ui.readNerds
import nyc.juliet.subwaysfornerds.ui.rememberSettingsActions

/**
 * The single activity. It is never shown over the lock screen, so a widget tap on the lock
 * screen asks for the normal unlock before any app navigation.
 */
class MainActivity : ComponentActivity() {
	private val viewModel: AppViewModel by viewModels { AppViewModel.Factory }
	private var networkCallback: ConnectivityManager.NetworkCallback? = null

	override fun onCreate(savedInstanceState: Bundle?) {
		enableEdgeToEdge()
		super.onCreate(savedInstanceState)
		// SFN_* test options apply only to an instrumentation launch that armed the in-process gate.
		val options = if (savedInstanceState == null) LaunchOptions.from(intent) else null
		if (options != null) {
			if (options.reset) LaunchOptions.resetState(this)
			AppContainer.launchOptions = options
		}
		// Keep the system splash until saved settings, and so the rider's theme, are loaded.
		val content = findViewById<View>(android.R.id.content)
		content.viewTreeObserver.addOnPreDrawListener(object : ViewTreeObserver.OnPreDrawListener {
			override fun onPreDraw(): Boolean {
				if (!viewModel.model.loaded) return false
				content.viewTreeObserver.removeOnPreDrawListener(this)
				return true
			}
		})
		if (savedInstanceState == null) handle(intent)
		options?.settingsFile?.let { text -> viewModel.model.previewSettingsFile(text) }
		lifecycleScope.launch { repeatOnLifecycle(Lifecycle.State.STARTED) { viewModel.model.runWhileActive() } }
		lifecycleScope.launch { repeatOnLifecycle(Lifecycle.State.STARTED) { viewModel.account.run(viewModel.model) } }
		setContent {
			val actions = rememberSettingsActions(viewModel.model, viewModel.account)
			AppRoot(viewModel.model, viewModel.account, actions)
		}
	}

	override fun onNewIntent(intent: Intent) {
		super.onNewIntent(intent)
		setIntent(intent)
		handle(intent)
	}

	override fun onStart() {
		super.onStart()
		viewModel.model.fixedConnectivity?.let { fixed -> viewModel.model.setNetworkConnected(fixed); return }
		val manager = getSystemService(ConnectivityManager::class.java) ?: return
		val current = manager.getNetworkCapabilities(manager.activeNetwork)
		viewModel.model.setNetworkConnected(current?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true, networkStatus(current))
		val callback = object : ConnectivityManager.NetworkCallback() {
			private var capabilities: NetworkCapabilities? = null
			private var blocked = false
			override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
				this.capabilities = capabilities
				report(capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) && capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED))
			}
			override fun onBlockedStatusChanged(network: Network, blocked: Boolean) {
				this.blocked = blocked
				val connected = capabilities?.let { it.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) && it.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) } == true
				report(connected)
			}
			override fun onLost(network: Network) {
				capabilities = null
				blocked = false
				report(false)
			}
			private fun report(connected: Boolean) {
				val status = networkStatus(capabilities, blocked)
				runOnUiThread { viewModel.model.setNetworkConnected(connected && !blocked, status) }
			}
		}
		manager.registerDefaultNetworkCallback(callback)
		networkCallback = callback
	}

	override fun onResume() {
		super.onResume()
		// A rider who closes the sign-in tab without finishing gets the buttons back. A callback
		// delivered with this resume (onNewIntent runs first) is never treated as abandoned.
		viewModel.account.activityResumed()
	}

	override fun onStop() {
		networkCallback?.let { callback -> runCatching { getSystemService(ConnectivityManager::class.java)?.unregisterNetworkCallback(callback) } }
		networkCallback = null
		viewModel.model.suspend()
		super.onStop()
	}

	/**
	 * Reads the default network for the offline status. Wi-Fi names appear only when the system shares
	 * them; this callback does not request location info, so Android usually redacts the SSID.
	 * Signal and link speed are what the system reports; nothing is measured here.
	 */
	private fun networkStatus(capabilities: NetworkCapabilities?, blocked: Boolean = false): DeviceNetworkStatus {
		val airplaneMode = Settings.Global.getInt(contentResolver, Settings.Global.AIRPLANE_MODE_ON, 0) != 0
		fun has(capability: Int) = capabilities?.hasCapability(capability) == true
		val transports = capabilities?.let { value ->
			listOf(
				NetworkCapabilities.TRANSPORT_WIFI to NetworkTransport.WIFI,
				NetworkCapabilities.TRANSPORT_CELLULAR to NetworkTransport.CELLULAR,
				NetworkCapabilities.TRANSPORT_ETHERNET to NetworkTransport.ETHERNET,
				NetworkCapabilities.TRANSPORT_BLUETOOTH to NetworkTransport.BLUETOOTH,
				NetworkCapabilities.TRANSPORT_VPN to NetworkTransport.VPN,
			).filter { (transport, _) -> value.hasTransport(transport) }.map { it.second }.ifEmpty { listOf(NetworkTransport.OTHER) }
		}.orEmpty()
		val wifi = capabilities?.transportInfo as? WifiInfo
		// SIGNAL_STRENGTH_UNSPECIFIED and Wi-Fi's invalid RSSI are dropped by observe().
		val dbm = capabilities?.signalStrength?.takeIf { it != NetworkCapabilities.SIGNAL_STRENGTH_UNSPECIFIED } ?: wifi?.rssi
		return DeviceNetworkStatus.observe(
			hasNetwork = capabilities != null,
			transports = transports,
			internet = has(NetworkCapabilities.NET_CAPABILITY_INTERNET),
			validated = has(NetworkCapabilities.NET_CAPABILITY_VALIDATED),
			captivePortal = has(NetworkCapabilities.NET_CAPABILITY_CAPTIVE_PORTAL),
			notMetered = has(NetworkCapabilities.NET_CAPABILITY_NOT_METERED),
			notRoaming = has(NetworkCapabilities.NET_CAPABILITY_NOT_ROAMING),
			notSuspended = has(NetworkCapabilities.NET_CAPABILITY_NOT_SUSPENDED),
			airplaneMode = airplaneMode,
			networkName = wifi?.ssid,
			blocked = blocked,
			signalStrengthDbm = dbm,
			signalLevel = signalLevel(capabilities, wifi),
			downstreamKbps = capabilities?.linkDownstreamBandwidthKbps,
			upstreamKbps = capabilities?.linkUpstreamBandwidthKbps,
		)
	}

	/** The system's 0–4 bars: Wi-Fi from its RSSI, cellular from the phone's signal strength. */
	private fun signalLevel(capabilities: NetworkCapabilities?, wifi: WifiInfo?): Int? {
		val rssi = wifi?.rssi?.takeIf { it in -126..-1 }
		if (rssi != null) {
			val manager = getSystemService(WifiManager::class.java) ?: return null
			val max = manager.maxSignalLevel.takeIf { it > 0 } ?: return null
			return Math.round(manager.calculateSignalLevel(rssi) * 4.0 / max).toInt()
		}
		if (capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) != true) return null
		return runCatching { getSystemService(TelephonyManager::class.java)?.signalStrength?.level }.getOrNull()
	}

	/** Links are validated strictly; a file only ever opens the import preview, never replaces settings. */
	private fun handle(intent: Intent?) {
		if (intent?.action != Intent.ACTION_VIEW) return
		val data = intent.data ?: return
		if (data.scheme == "content") {
			lifecycleScope.launch {
				val (text, error) = readNerds(this@MainActivity, data, requireExtension = false)
				viewModel.model.previewSettingsFile(text, error)
			}
			return
		}
		when (val link = DeepLinks.parse(data.toString())) {
			is DeepLink.Station -> viewModel.model.openStationLink(link.id)
			is DeepLink.Ride -> viewModel.model.openRideLink(link.tripKey)
			is DeepLink.AuthCallback -> viewModel.account.completeSignIn(link.uri)
			null -> {}
		}
	}
}
