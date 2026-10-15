package nyc.juliet.subwaysfornerds

import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Bundle
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
		viewModel.model.setNetworkConnected(current?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true)
		val callback = object : ConnectivityManager.NetworkCallback() {
			override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
				val connected = capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) && capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
				runOnUiThread { viewModel.model.setNetworkConnected(connected) }
			}
			override fun onLost(network: Network) { runOnUiThread { viewModel.model.setNetworkConnected(false) } }
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
