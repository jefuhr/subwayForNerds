package nyc.juliet.subwaysfornerds

import android.app.Activity
import android.content.Context
import android.graphics.Bitmap
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.util.Log
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleCallback
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import androidx.work.WorkInfo
import androidx.work.WorkManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import nyc.juliet.subwaysfornerds.core.AccountSession
import nyc.juliet.subwaysfornerds.core.AndroidAuthPending
import nyc.juliet.subwaysfornerds.core.AuthConfig
import nyc.juliet.subwaysfornerds.core.Board
import nyc.juliet.subwaysfornerds.core.OfflineEndpoint
import nyc.juliet.subwaysfornerds.core.Settings
import nyc.juliet.subwaysfornerds.core.SettingsRevision
import nyc.juliet.subwaysfornerds.core.StationLocation
import nyc.juliet.subwaysfornerds.core.TransitClient
import nyc.juliet.subwaysfornerds.data.AndroidSettingsStore
import nyc.juliet.subwaysfornerds.data.AndroidTransitCache
import nyc.juliet.subwaysfornerds.ui.AppContainer
import nyc.juliet.subwaysfornerds.ui.AppDependencies
import nyc.juliet.subwaysfornerds.ui.AppModel
import nyc.juliet.subwaysfornerds.ui.AppViewModel
import nyc.juliet.subwaysfornerds.ui.ClientTransitService
import nyc.juliet.subwaysfornerds.ui.DeviceSettingsStorage
import nyc.juliet.subwaysfornerds.ui.LaunchOptions
import nyc.juliet.subwaysfornerds.ui.UiFlags
import nyc.juliet.subwaysfornerds.ui.account.SessionVault
import nyc.juliet.subwaysfornerds.ui.data.AccountService
import nyc.juliet.subwaysfornerds.ui.data.LocationException
import nyc.juliet.subwaysfornerds.ui.data.LocationPermission
import nyc.juliet.subwaysfornerds.ui.data.LocationSource
import nyc.juliet.subwaysfornerds.ui.data.WidgetHooks
import nyc.juliet.subwaysfornerds.widgets.runtime.TransitWidgetRefreshWorker
import nyc.juliet.subwaysfornerds.widgets.runtime.WidgetRuntime
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.Response
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.rules.TestRule
import org.junit.runner.Description
import org.junit.runners.model.Statement
import java.io.File
import java.io.IOException
import java.net.ConnectException
import java.util.concurrent.TimeUnit

/**
 * Isolation and evidence for acceptance tests that drive the real HTTP client, stores, activity
 * and widget runtime on a dedicated emulator.
 *
 * Every test first proves it runs on the named dedicated emulator, before any app data reset or shell command
 * that changes state. Recorded HTTP coverage needs the coordinator's runner arguments
 * SFN_API_BASE_URL (a local fixture server, never production) and SFN_TEST_NOW; without them
 * those tests are skipped with the missing prerequisite named, and nothing falls back to the
 * production API. Tests that need no server use a closed loopback endpoint, so no request can
 * leave the emulator. The in-process app overrides replace only accounts (disabled), the session
 * vault, location (no GPS) and the HTTP client's interceptor; settings, cache, endpoint handling,
 * TransitClient and ClientTransitService are the production classes.
 *
 * Required runner argument: SFN_DEDICATED_AVD names the coordinator-leased test AVD. Omission
 * skips before setup; naming an AVD that does not match the current device fails before setup.
 *
 * Optional runner arguments:
 * - SFN_CONNECTIVITY_MODE=airplane toggles the emulator's airplane mode for connectivity loss
 *   (restored afterwards). The default, in-process, closes the HTTP gate below and turns on the
 *   app's own debug "Simulate no connection" switch, leaving device radios untouched.
 * - SFN_E2E_STATION=<id> chooses the recorded station (default 602).
 */
class NativeNetworkAcceptanceRule : TestRule {
	/** The coordinator's recorded fixture server and the frozen clock its responses were recorded at. */
	data class RecordedServer(val endpoint: String, val now: Double, val station: String)

	enum class ConnectivityMode { IN_PROCESS, AIRPLANE }

	/**
	 * The only door from the app's HTTP client to the network: requests to any other origin are
	 * refused and recorded, and a closed gate fails requests as an unreachable network would.
	 */
	class Gate : Interceptor {
		@Volatile var origin: Pair<String, Int>? = null
		@Volatile var open = true
		private val lock = Any()
		private val passedLog = mutableListOf<String>()
		private val failedLog = mutableListOf<String>()
		private val refusedLog = mutableListOf<String>()
		private val foreignLog = mutableListOf<String>()
		/** Requests that reached the fixture server and got a response. */
		val passed: List<String> get() = synchronized(lock) { passedLog.toList() }
		/** Requests the gate let through that failed below it, as in airplane mode. */
		val failed: List<String> get() = synchronized(lock) { failedLog.toList() }
		val refused: List<String> get() = synchronized(lock) { refusedLog.toList() }
		val foreign: List<String> get() = synchronized(lock) { foreignLog.toList() }

		override fun intercept(chain: Interceptor.Chain): Response {
			val request = chain.request()
			val url = request.url
			val line = "${request.method} ${url.encodedPath}${url.encodedQuery?.let { "?$it" } ?: ""}"
			if (origin != url.host to url.port) {
				synchronized(lock) { foreignLog += "${url.scheme}://${url.host}:${url.port} $line" }
				throw IOException("Acceptance gate refused a request outside the test endpoint: ${url.host}")
			}
			if (!open) {
				synchronized(lock) { refusedLog += line }
				throw ConnectException("Network is unreachable (acceptance connectivity loss)")
			}
			val response = try { chain.proceed(request) } catch (error: IOException) {
				synchronized(lock) { failedLog += "$line (${error.javaClass.simpleName})" }
				throw error
			}
			synchronized(lock) { passedLog += "$line -> ${response.code}" }
			return response
		}
	}

	/** Step timings, request counts and file paths, written beside the screenshots for the coordinator to pull. */
	class Evidence(private val name: String) {
		private val started = SystemClock.elapsedRealtime()
		private val lines = mutableListOf<String>()
		fun note(text: String) {
			val line = "+${SystemClock.elapsedRealtime() - started}ms $text"
			synchronized(lines) { lines += line }
			Log.i(TAG, "$name: $text")
		}
		fun write(directory: File): File {
			directory.mkdirs()
			val file = File(directory, "$name.txt")
			file.writeText(synchronized(lines) { lines.joinToString("\n", postfix = "\n") })
			Log.i(TAG, "evidence ${file.absolutePath}")
			return file
		}
	}

	val instrumentation get() = InstrumentationRegistry.getInstrumentation()
	val context: Context get() = instrumentation.targetContext
	val arguments: Bundle get() = InstrumentationRegistry.getArguments()
	val gate = Gate()
	/** The app's HTTP client: the production TransitClient timeouts plus the gate. */
	val http: OkHttpClient = OkHttpClient.Builder()
		.connectTimeout(10, TimeUnit.SECONDS).readTimeout(20, TimeUnit.SECONDS).callTimeout(60, TimeUnit.SECONDS)
		.addInterceptor(gate).build()
	val connectivity: ConnectivityMode =
		if (arguments.getString("SFN_CONNECTIVITY_MODE")?.trim()?.lowercase() == "airplane") ConnectivityMode.AIRPLANE else ConnectivityMode.IN_PROCESS

	lateinit var evidence: Evidence; private set
	/** The endpoint the app, its stores and the widget runtime use in this test. */
	var endpoint: String = CLOSED_ENDPOINT; private set
	/** The app's frozen clock; null means the device clock. */
	var fixedNow: Double? = null; private set
	var recorded: RecordedServer? = null; private set
	/** True while connectivity loss is simulated or applied. */
	@Volatile var offline = false; private set

	private var emulatorVerified = false
	private var testName = "test"
	private var className = "Acceptance"
	private var airplaneRestore: String? = null
	private var refreshWorkBefore: List<WorkInfo> = emptyList()
	private val screenshots = mutableListOf<String>()
	private val lifecycle = ActivityLifecycleCallback { activity, stage ->
		// The real device stays online in-process, so each new activity gets the same simulated loss.
		if (stage == Stage.STARTED && activity is MainActivity && offline && connectivity == ConnectivityMode.IN_PROCESS) model(activity).setSimulatedOutage(true)
	}

	override fun apply(base: Statement, description: Description): Statement = object : Statement() {
		override fun evaluate() {
			className = description.testClass?.simpleName ?: "Acceptance"
			testName = description.methodName ?: "test"
			evidence = Evidence("e2e-$className-$testName")
			try {
				requireDedicatedEmulator()
				before()
				base.evaluate()
			} finally {
				after()
			}
		}
	}

	// MARK: Prerequisites

	/** Fails before anything is changed unless this is the explicitly named dedicated emulator. */
	private fun requireDedicatedEmulator() {
		val qemu = listOf("ro.boot.qemu", "ro.kernel.qemu").map { readProperty(it) }
		val avd = readProperty("ro.boot.qemu.avd_name").ifEmpty { readProperty("ro.kernel.qemu.avd_name") }
		evidence.note("device ${Build.MANUFACTURER} ${Build.MODEL} sdk=${Build.VERSION.SDK_INT} hardware=${Build.HARDWARE} qemu=$qemu avd=$avd fingerprint=${Build.FINGERPRINT}")
		assertTrue(
			"Refusing to run: this is not an Android emulator (hardware=${Build.HARDWARE}, qemu=$qemu). These tests reset this app's data and never run on a phone.",
			Build.HARDWARE in setOf("ranchu", "goldfish") && qemu.any { it == "1" },
		)
		val expected = arguments.getString("SFN_DEDICATED_AVD")?.trim().orEmpty()
		assumeTrue("Dedicated-emulator prerequisite missing: SFN_DEDICATED_AVD must name the coordinator-leased AVD. Skipped before resetting app data or changing device state.", expected.isNotEmpty())
		assertTrue("Refusing to run: AVD '$avd' is not the dedicated emulator '$expected'.", avd == expected)
		emulatorVerified = true
	}

	/** getprop only reads; it is the one shell command allowed before the emulator check. */
	private fun readProperty(name: String): String = runShell("getprop $name").trim()

	/** Skips the test, naming the missing prerequisite, unless the recorded fixture server was provided. */
	fun requireRecordedServer(): RecordedServer {
		val base = arguments.getString("SFN_API_BASE_URL")?.trim().orEmpty()
		val now = arguments.getString("SFN_TEST_NOW")?.trim()?.toDoubleOrNull()?.takeIf { it.isFinite() && it > 0 }
		if (base.isEmpty() || now == null) {
			val missing = listOfNotNull("SFN_API_BASE_URL".takeIf { base.isEmpty() }, "SFN_TEST_NOW".takeIf { now == null })
			evidence.note("SKIPPED: prerequisite runner arguments missing: $missing. No recorded-HTTP coverage was claimed and no production request was made.")
			assumeTrue("Recorded-HTTP prerequisite missing: $missing (the coordinator's fixture server, e.g. http://10.0.2.2:8093/subwaysForNerds/api/v1/). Skipped instead of using production.", false)
		}
		val url = base.toHttpUrlOrNull()
		assertTrue("SFN_API_BASE_URL is not a URL: $base", url != null)
		assertTrue("SFN_API_BASE_URL must be the recorded fixture server, never production: $base", OfflineEndpoint.key(base) != OfflineEndpoint.productionKey)
		assertTrue("SFN_API_BASE_URL must be a local fixture server (10.0.2.2, 127.0.0.1 or localhost): $base", url!!.host in setOf("10.0.2.2", "127.0.0.1", "localhost"))
		val station = arguments.getString("SFN_E2E_STATION")?.trim()?.takeIf { it.isNotEmpty() } ?: "602"
		val value = RecordedServer(url.toString().let { if (it.endsWith('/')) it else "$it/" }, now!!, station)
		recorded = value
		selectEndpoint(value.endpoint, value.now)
		evidence.note("coverage: recorded-HTTP from ${value.endpoint} with app clock SFN_TEST_NOW=${value.now}")
		return value
	}

	/**
	 * Selects this test's endpoint and saves it with the production settings store, as the debug
	 * endpoint field does; the gate admits only its origin. The default is the closed endpoint.
	 */
	fun selectEndpoint(base: String, now: Double?) {
		endpoint = base
		fixedNow = now
		val url = base.toHttpUrlOrNull()!!
		gate.origin = url.host to url.port
		io { AndroidSettingsStore(context).saveApiBase(base) }
		evidence.note("endpoint $base saved as apiBase; app clock ${now ?: "device"}")
	}

	// MARK: Setup and teardown

	private fun before() {
		evidence.note("connectivity mode $connectivity")
		AppContainer.overrides = null
		AppContainer.launchOptions = null
		// Quiesce widget refreshes first, so nothing reads the reset defaults (production endpoint) below.
		val work = WorkManager.getInstance(context)
		refreshWorkBefore = runCatching { work.getWorkInfosByTag(REFRESH_TAG).get(10, TimeUnit.SECONDS) }.getOrDefault(emptyList())
		evidence.note("widget refresh work before: ${describe(refreshWorkBefore)}")
		runCatching { work.cancelAllWorkByTag(REFRESH_TAG).result.get(10, TimeUnit.SECONDS) }
		// Fixture reset: only this app's own settings, offline cache, widget content and location.
		LaunchOptions.resetState(context)
		evidence.note("reset this app's settings, offline cache, widget content and location")
		selectEndpoint(CLOSED_ENDPOINT, null)
		ActivityLifecycleMonitorRegistry.getInstance().addLifecycleCallback(lifecycle)
	}

	private fun after() {
		AppContainer.overrides = null
		AppContainer.accountOverride = null
		AppContainer.vaultOverride = null
		AppContainer.launchOptions = null
		// Off an emulator nothing was changed, so there is nothing to restore and no file is written.
		if (!emulatorVerified) return
		runCatching { ActivityLifecycleMonitorRegistry.getInstance().removeLifecycleCallback(lifecycle) }
		runCatching { restoreConnectivity() }.onFailure { evidence.note("connectivity restore failed: $it") }
		runCatching { finishActivities() }
		runCatching { restoreWidgetWork() }.onFailure { evidence.note("widget work restore failed: $it") }
		evidence.note("gate: ${gate.passed.size} passed, ${gate.failed.size} failed below the gate, ${gate.refused.size} refused while offline, ${gate.foreign.size} foreign ${gate.foreign}")
		gate.passed.forEach { evidence.note("  passed $it") }
		evidence.note("screenshots: $screenshots")
		runCatching { evidence.write(artifactDirectory()) }
	}

	/** Cancels refresh work this test started, and re-applies the runtime's own schedule if one existed before. */
	private fun restoreWidgetWork() {
		if (!emulatorVerified) return
		val work = WorkManager.getInstance(context)
		val before = refreshWorkBefore.map { it.id }.toSet()
		val now = work.getWorkInfosByTag(REFRESH_TAG).get(10, TimeUnit.SECONDS)
		now.filter { it.id !in before && !it.state.isFinished }.forEach { work.cancelWorkById(it.id) }
		if (refreshWorkBefore.any { it.periodicityInfo != null && !it.state.isFinished }) runCatching { WidgetRuntime.schedule(context) }
		evidence.note("widget refresh work after restore: ${describe(work.getWorkInfosByTag(REFRESH_TAG).get(10, TimeUnit.SECONDS))}")
	}

	private fun finishActivities() {
		instrumentation.runOnMainSync {
			val registry = ActivityLifecycleMonitorRegistry.getInstance()
			listOf(Stage.PRE_ON_CREATE, Stage.CREATED, Stage.STARTED, Stage.RESUMED, Stage.PAUSED, Stage.STOPPED, Stage.RESTARTED)
				.flatMap { registry.getActivitiesInStage(it) }.distinct().forEach { it.finish() }
		}
	}

	// MARK: App wiring

	/** Saves settings, the station and this test's endpoint with the production stores before anything reads them. */
	fun persist(settings: Settings, lastStation: String) {
		io {
			val store = AndroidSettingsStore(context)
			store.replaceFromImport(settings, lastStation)
			store.saveApiBase(endpoint)
		}
		evidence.note("persisted settings (theme=${settings.theme}, favorites=${settings.favorites}) lastStation=$lastStation apiBase=$endpoint")
	}

	/** Production stores and HTTP client for the next activity; accounts are disabled and location never runs. */
	fun installApp(widgets: WidgetHooks = SilentWidgetHooks()) {
		val base = endpoint
		val now = fixedNow
		AppContainer.launchOptions = null
		AppContainer.overrides = { app ->
			AppDependencies(
				settingsStore = DeviceSettingsStorage(AndroidSettingsStore(app)),
				cache = { value -> AndroidTransitCache(app, value) },
				transit = { value -> ClientTransitService(TransitClient(value, http)) },
				fleet = null,
				location = NoDeviceLocation(),
				widgets = widgets,
				clock = if (now != null) ({ now }) else ({ System.currentTimeMillis() / 1000.0 }),
				fixedNow = now,
				debug = true,
				defaultEndpoint = base,
				locationDisabled = true,
				flags = UiFlags.Memory(),
				endpointOverride = base,
				// The in-process outage is controlled by this rule, not Android's external
				// internet-validation probe. Real TransitClient requests still reach the fixture.
				fixedConnectivity = if (connectivity == ConnectivityMode.IN_PROCESS) !offline else null,
			)
		}
		AppContainer.accountOverride = { NetworkAcceptanceDisabledAccounts() }
		AppContainer.vaultOverride = { NetworkAcceptanceMemoryVault() }
	}

	/** The same TransitClient class the app uses, through the gate, for preflight reads. */
	fun client(): TransitClient = TransitClient(endpoint, http)

	fun cache(): AndroidTransitCache = AndroidTransitCache(context, endpoint)

	fun model(activity: Activity): AppModel = ViewModelProvider(activity as MainActivity, AppViewModel.Factory)[AppViewModel::class.java].model

	// MARK: Connectivity

	/** Connectivity loss: the emulator's airplane mode, or the closed gate plus the app's debug outage switch. */
	fun loseConnectivity() {
		offline = true
		when (connectivity) {
			ConnectivityMode.IN_PROCESS -> {
				gate.open = false
				instrumentation.runOnMainSync { startedMainActivities().forEach { model(it).setSimulatedOutage(true) } }
			}
			ConnectivityMode.AIRPLANE -> {
				if (airplaneRestore == null) airplaneRestore = shell("cmd connectivity airplane-mode").trim()
				shell("cmd connectivity airplane-mode enable")
				waitFor(30_000, "the emulator to lose its network") { !hasInternet() }
			}
		}
		evidence.note("connectivity lost ($connectivity); ${gate.passed.size} requests had passed")
	}

	fun restoreConnectivity() {
		if (!offline && airplaneRestore == null) return
		offline = false
		gate.open = true
		airplaneRestore?.let { previous ->
			shell("cmd connectivity airplane-mode ${if (previous == "enabled") "enable" else "disable"}")
			airplaneRestore = null
			if (previous != "enabled") waitFor(60_000, "the emulator network to return") { hasInternet() }
		}
		evidence.note("connectivity restored")
	}

	private fun hasInternet(): Boolean {
		val manager = context.getSystemService(ConnectivityManager::class.java) ?: return false
		return manager.getNetworkCapabilities(manager.activeNetwork)?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true
	}

	private fun startedMainActivities(): List<Activity> {
		val registry = ActivityLifecycleMonitorRegistry.getInstance()
		return listOf(Stage.STARTED, Stage.RESUMED, Stage.PAUSED).flatMap { registry.getActivitiesInStage(it) }.filterIsInstance<MainActivity>()
	}

	// MARK: Evidence

	fun artifactDirectory(): File = File(context.getExternalFilesDir(null), "screenshots")

	/** A full-screen PNG in the app's external screenshots folder, which the coordinator pulls. */
	fun screenshot(name: String): String? {
		instrumentation.waitForIdleSync()
		val bitmap = instrumentation.uiAutomation.takeScreenshot() ?: return null.also { evidence.note("screenshot $name unavailable") }
		return saveBitmap(name, bitmap)
	}

	fun saveBitmap(name: String, bitmap: Bitmap): String {
		val directory = artifactDirectory().apply { mkdirs() }
		val file = File(directory, "e2e-$className-$name.png")
		file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
		screenshots += file.name
		evidence.note("screenshot ${file.absolutePath}")
		return file.absolutePath
	}

	// MARK: Utilities

	/** Shell commands that change device state run only after the emulator check. */
	fun shell(command: String): String {
		check(emulatorVerified) { "Shell mutation before the dedicated emulator check: $command" }
		val output = runShell(command)
		evidence.note("shell `$command` -> ${output.trim().take(200)}")
		return output
	}

	private fun runShell(command: String): String {
		val descriptor = instrumentation.uiAutomation.executeShellCommand(command)
		return ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { it.readBytes().toString(Charsets.UTF_8) }
	}

	fun <T> io(block: suspend () -> T): T = runBlocking(Dispatchers.IO) { block() }

	/** Whole seconds on the device clock, which the widget runtime always uses. */
	fun deviceNow(): Double = (System.currentTimeMillis() / 1000).toDouble()

	fun waitFor(timeoutMillis: Long, what: String, condition: () -> Boolean) {
		val deadline = SystemClock.elapsedRealtime() + timeoutMillis
		while (true) {
			if (condition()) return
			if (SystemClock.elapsedRealtime() > deadline) throw AssertionError("Timed out after ${timeoutMillis}ms waiting for $what")
			SystemClock.sleep(200)
		}
	}

	fun refreshWork(): List<WorkInfo> = WorkManager.getInstance(context).getWorkInfosByTag(REFRESH_TAG).get(10, TimeUnit.SECONDS)

	fun describe(work: List<WorkInfo>): String =
		work.joinToString(prefix = "[", postfix = "]") { "${if (it.periodicityInfo != null) "periodic" else "once"}:${it.state}:${it.id.toString().take(8)}" }

	companion object {
		const val TAG = "SfnE2E"
		/** Nothing listens on the discard port, so requests fail at connect without leaving the emulator. */
		const val CLOSED_ENDPOINT = "http://127.0.0.1:9/sfn-e2e-closed/api/v1/"
		/** WorkManager tags every request with its worker class. */
		val REFRESH_TAG: String = TransitWidgetRefreshWorker::class.java.name
	}
}

/** Widget hooks that count calls, so the HTTP flow cannot start widget refreshes behind the gate. */
class SilentWidgetHooks : WidgetHooks {
	@Volatile var settingsChanges = 0; private set
	@Volatile var boardsSaved = 0; private set
	override suspend fun settingsChanged() { settingsChanges += 1 }
	override suspend fun boardSaved(board: Board) { boardsSaved += 1 }
}

/** No GPS: the startup card, nearby search and widget location never run in these tests. */
private class NoDeviceLocation : LocationSource {
	override fun foregroundPermission() = LocationPermission.DENIED
	override val foregroundPermissionNames: Array<String> = emptyArray()
	override fun backgroundAllowed() = false
	override suspend fun locate(timeoutMillis: Long): StationLocation = throw LocationException("Location is disabled in acceptance tests.")
	override suspend fun backgroundEnabled() = false
	override suspend fun setBackgroundEnabled(value: Boolean) {}
	override suspend fun publishAppLocation(location: StationLocation) {}
}

/** Accounts stay off and never reach the production account API. */
private class NetworkAcceptanceDisabledAccounts : AccountService {
	override suspend fun config() = AuthConfig(enabled = false)
	override suspend fun startAndroid(provider: String, intent: String, token: String?): AndroidAuthPending = throw IOException("Accounts are disabled in acceptance tests.")
	override suspend fun exchangeAndroid(callback: String, pending: AndroidAuthPending, token: String?): AccountSession = throw IOException("Accounts are disabled in acceptance tests.")
	override suspend fun account(token: String): AccountSession = throw IOException("Accounts are disabled in acceptance tests.")
	override suspend fun settings(token: String): SettingsRevision = throw IOException("Accounts are disabled in acceptance tests.")
	override suspend fun putSettings(token: String, settings: Settings, revision: Long): SettingsRevision = throw IOException("Accounts are disabled in acceptance tests.")
	override suspend fun logout(token: String) {}
	override suspend fun unlink(provider: String, token: String) {}
	override suspend fun deleteAccount(token: String) {}
}

private class NetworkAcceptanceMemoryVault : SessionVault {
	private var token: String? = null
	private var pending: AndroidAuthPending? = null
	override suspend fun load() = token
	override suspend fun save(token: String) { this.token = token }
	override suspend fun clear() { token = null; pending = null }
	override suspend fun loadPending() = pending
	override suspend fun savePending(pending: AndroidAuthPending) { this.pending = pending }
	override suspend fun clearPending() { pending = null }
}
