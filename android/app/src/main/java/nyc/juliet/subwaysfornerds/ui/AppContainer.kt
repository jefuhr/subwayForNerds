package nyc.juliet.subwaysfornerds.ui

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import android.os.Debug
import android.os.PowerManager
import android.os.Process
import android.os.StatFs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import nyc.juliet.subwaysfornerds.BuildConfig
import nyc.juliet.subwaysfornerds.core.AccountClient
import nyc.juliet.subwaysfornerds.core.AppMemoryStatus
import nyc.juliet.subwaysfornerds.core.AppStorageBreakdown
import nyc.juliet.subwaysfornerds.core.DiskUsage
import nyc.juliet.subwaysfornerds.core.AccountSession
import nyc.juliet.subwaysfornerds.core.AndroidAuthPending
import nyc.juliet.subwaysfornerds.core.AuthConfig
import nyc.juliet.subwaysfornerds.core.FleetDetail
import nyc.juliet.subwaysfornerds.core.FleetOfflineManifest
import nyc.juliet.subwaysfornerds.core.FleetPackJob
import nyc.juliet.subwaysfornerds.core.FleetPackManifest
import nyc.juliet.subwaysfornerds.core.FleetPackSelection
import nyc.juliet.subwaysfornerds.core.FleetPage
import nyc.juliet.subwaysfornerds.core.PRODUCTION_API_BASE
import nyc.juliet.subwaysfornerds.core.Settings
import nyc.juliet.subwaysfornerds.core.SettingsRevision
import nyc.juliet.subwaysfornerds.core.Station
import nyc.juliet.subwaysfornerds.core.StationContext
import nyc.juliet.subwaysfornerds.core.StationLocation
import nyc.juliet.subwaysfornerds.core.SystemRuntimeStatus
import nyc.juliet.subwaysfornerds.core.TransferResult
import nyc.juliet.subwaysfornerds.core.TransitClient
import nyc.juliet.subwaysfornerds.core.TripDetail
import nyc.juliet.subwaysfornerds.core.Board
import nyc.juliet.subwaysfornerds.data.AndroidSessionStore
import nyc.juliet.subwaysfornerds.data.AndroidSettingsStore
import nyc.juliet.subwaysfornerds.data.LocalSettingsSnapshot
import nyc.juliet.subwaysfornerds.data.SyncBaseline
import nyc.juliet.subwaysfornerds.ui.data.SettingsStorage
import nyc.juliet.subwaysfornerds.data.AndroidTransitCache
import nyc.juliet.subwaysfornerds.fleet.FleetPackExpiredException
import nyc.juliet.subwaysfornerds.fleet.OfflineFleetStore
import nyc.juliet.subwaysfornerds.location.LocationController
import nyc.juliet.subwaysfornerds.location.LocationFailure
import nyc.juliet.subwaysfornerds.ui.account.SessionVault
import nyc.juliet.subwaysfornerds.ui.data.AccountService
import nyc.juliet.subwaysfornerds.ui.data.FleetDownloadExpiredException
import nyc.juliet.subwaysfornerds.ui.data.FleetStorage
import nyc.juliet.subwaysfornerds.ui.data.FleetTransfer
import nyc.juliet.subwaysfornerds.ui.data.LocationException
import nyc.juliet.subwaysfornerds.ui.data.LocationPermission
import nyc.juliet.subwaysfornerds.ui.data.LocationSource
import nyc.juliet.subwaysfornerds.ui.data.TransferSink
import nyc.juliet.subwaysfornerds.ui.data.TransitService
import nyc.juliet.subwaysfornerds.ui.data.WidgetHooks
import nyc.juliet.subwaysfornerds.widgets.runtime.WidgetRuntime
import nyc.juliet.subwaysfornerds.widgets.ui.TransitWidgetUi
import java.io.File
import java.net.URI

/** The app's long-lived stores and clients. Tests may replace the model's dependencies. */
class AppContainer(private val context: Context) {
	val settingsStore by lazy { AndroidSettingsStore(context) }
	val sessionStore by lazy { AndroidSessionStore(context) }
	val location by lazy { LocationController(context) }
	val fleetStore by lazy { OfflineFleetStore(context) }
	val flags: UiFlags by lazy { PreferenceFlags(context) }

	fun dependencies(): AppDependencies {
		overrides?.let { return it(context) }
		// Armed instrumentation launches only; see TestLaunchGate.
		val options = launchOptions?.takeIf { TestLaunchGate.isArmed }
		val now = options?.now
		return AppDependencies(
			settingsStore = DeviceSettingsStorage(settingsStore),
			cache = { endpoint -> AndroidTransitCache(context, endpoint) },
			transit = { endpoint -> ClientTransitService(TransitClient(endpoint)) },
			fleet = OfflineFleetStorage(fleetStore),
			location = if (options?.location != null) FixedLocationSource(options.location) else DeviceLocationSource(location, flags),
			widgets = AppWidgetHooks(context),
			clock = if (now != null) ({ now }) else ({ System.currentTimeMillis() / 1000.0 }),
			fixedNow = now,
			debug = BuildConfig.DEBUG,
			locationDisabled = options?.disableLocation == true,
			flags = flags,
			endpointOverride = options?.apiBase,
			systemStatus = DeviceSystemStatus(context)::read,
		)
	}

	fun accountService(): AccountService = accountOverride?.invoke() ?: ClientAccountService(AccountClient(PRODUCTION_API_BASE))
	fun sessionVault(): SessionVault = vaultOverride?.invoke() ?: StoreSessionVault(sessionStore)

	companion object {
		/** Instrumentation tests install fixture-backed dependencies before the activity starts. */
		@Volatile var overrides: ((Context) -> AppDependencies)? = null
		@Volatile var accountOverride: (() -> AccountService)? = null
		@Volatile var vaultOverride: (() -> SessionVault)? = null
		/** SFN_* options from an armed instrumentation launch. */
		@Volatile var launchOptions: LaunchOptions? = null
	}
}

class ClientTransitService(private val client: TransitClient) : TransitService {
	override val baseUrl: String get() = client.baseUrl
	override val host: String get() = runCatching { URI(client.baseUrl).host }.getOrNull() ?: "the server"
	override suspend fun stations(progress: TransferSink?): List<Station> = client.stations(progress)
	override suspend fun board(stationID: String, progress: TransferSink?): Board = client.board(stationID, progress)
	override suspend fun trip(key: String, progress: TransferSink?): TripDetail = client.trip(key, progress)
	override suspend fun transfers(key: String, stopID: String, sequence: Int?, progress: TransferSink?): TransferResult = client.transfers(key, stopID, sequence, progress)
	override suspend fun context(stationID: String, progress: TransferSink?): StationContext = client.context(stationID, progress)
	override suspend fun fleet(query: Map<String, String>, progress: TransferSink?): FleetPage = client.fleet(query.filterValues { it.isNotEmpty() }, progress)
	override suspend fun fleetDetail(kind: String, id: String, progress: TransferSink?): FleetDetail = client.fleetDetail(kind, id, progress)
	override suspend fun prepareFleetPack(selection: FleetPackSelection): FleetPackJob = client.prepareFleetPack(selection)
	override suspend fun fleetPackStatus(jobID: String): FleetPackJob = client.fleetPackStatus(jobID)
}

class DeviceSettingsStorage(private val store: AndroidSettingsStore) : SettingsStorage {
	override suspend fun snapshot(): LocalSettingsSnapshot = store.snapshot()
	override suspend fun save(settings: Settings) = store.save(settings)
	override suspend fun saveLastStation(id: String) = store.saveLastStation(id)
	override suspend fun saveApiBase(base: String) = store.saveApiBase(base)
	override suspend fun saveAccepted(settings: Settings, lastStation: String, baseline: SyncBaseline?, replaceUnreadable: Boolean) {
		store.saveAccepted(settings, lastStation, baseline, replaceUnreadable)
	}
}

class OfflineFleetStorage(private val store: OfflineFleetStore) : FleetStorage {
	override suspend fun manifest(): FleetOfflineManifest? = store.manifest()
	override suspend fun download(pack: FleetPackManifest, apiBase: String, progress: (FleetTransfer) -> Unit) {
		try {
			store.download(pack, apiBase) { value ->
				val records = value.totalBytes == null && value.totalRecords != null
				progress(FleetTransfer(value.stage.label, if (records) value.completedRecords ?: 0 else value.completedBytes, if (records) value.totalRecords else value.totalBytes, value.detail, records))
			}
		} catch (_: FleetPackExpiredException) { throw FleetDownloadExpiredException() }
	}
	override fun setForeground(value: Boolean) { store.setForeground(value) }
	override suspend fun delete() { store.clear() }
	override suspend fun page(query: Map<String, String>): FleetPage = store.fleet(query)
	override suspend fun detail(kind: String, id: String, offset: Int, limit: Int): FleetDetail =
		store.fleetDetail(if (kind == "cars") "car" else kind, id, offset, limit)
}

class DeviceLocationSource(private val controller: LocationController, private val flags: UiFlags) : LocationSource {
	override fun foregroundPermission(): LocationPermission = when {
		controller.status().permission != nyc.juliet.subwaysfornerds.location.LocationPermission.DENIED -> LocationPermission.GRANTED
		flags.get(UiFlags.LOCATION_REQUESTED) -> LocationPermission.DENIED
		else -> LocationPermission.NOT_REQUESTED
	}
	override val foregroundPermissionNames: Array<String> get() = controller.foregroundPermissionNames()
	override fun backgroundAllowed(): Boolean = controller.status().backgroundPermission
	override suspend fun locate(timeoutMillis: Long): StationLocation {
		val result = controller.locate(timeoutMillis.coerceAtMost(12_000), foreground = true)
		return result.coordinate ?: throw LocationException(when (result.failure) {
			LocationFailure.DENIED -> "Location permission is off. You can still search for any station, or allow location in Settings."
			LocationFailure.DISABLED -> "Location services are off. Turn them on in system settings, or search for any station."
			else -> "Could not get your location. Search for a station or try again."
		})
	}
	override suspend fun backgroundEnabled(): Boolean = withContext(Dispatchers.IO) { controller.status().backgroundEnabled }
	override suspend fun setBackgroundEnabled(value: Boolean) = controller.setBackgroundEnabled(value)
	override suspend fun publishAppLocation(location: StationLocation) { runCatching { controller.publishAppLocation(location) } }
}

class AppWidgetHooks(private val context: Context) : WidgetHooks {
	override suspend fun settingsChanged() {
		withContext(Dispatchers.IO) { runCatching { WidgetRuntime.schedule(context) } }
		runCatching { TransitWidgetUi.updateAll(context) }
	}
	override suspend fun boardSaved(board: Board) { runCatching { WidgetRuntime.boardSaved(context, board) } }
}

class ClientAccountService(private val client: AccountClient) : AccountService {
	override suspend fun config(): AuthConfig = client.config()
	override suspend fun startAndroid(provider: String, intent: String, token: String?): AndroidAuthPending = client.startAndroid(provider, intent, token)
	override suspend fun exchangeAndroid(callback: String, pending: AndroidAuthPending, token: String?): AccountSession = client.exchangeAndroid(callback, pending, token)
	override suspend fun account(token: String): AccountSession = client.account(token)
	override suspend fun settings(token: String): SettingsRevision = client.settings(token)
	override suspend fun putSettings(token: String, settings: Settings, revision: Long): SettingsRevision = client.putSettings(token, settings, revision)
	override suspend fun logout(token: String) = client.logout(token)
	override suspend fun unlink(provider: String, token: String) = client.unlink(provider, token)
	override suspend fun deleteAccount(token: String) = client.deleteAccount(token)
}

class StoreSessionVault(private val store: AndroidSessionStore) : SessionVault {
	override suspend fun load(): String? = store.loadToken()
	override suspend fun save(token: String) { store.saveToken(token) }
	override suspend fun clear() { store.clear() }
	override suspend fun loadPending(): AndroidAuthPending? = store.loadPendingAuth()
	override suspend fun savePending(pending: AndroidAuthPending) { store.savePendingAuth(pending) }
	override suspend fun clearPending() { store.clearPendingAuth() }
}

/** One-time answers stored in plain preferences; they are interface state, not portable settings. */
class PreferenceFlags(context: Context) : UiFlags {
	private val preferences = context.applicationContext.getSharedPreferences("ui-flags", Context.MODE_PRIVATE)
	override fun get(key: String): Boolean = preferences.getBoolean(key, false)
	override fun set(key: String, value: Boolean) { preferences.edit().putBoolean(key, value).apply() }
}

/**
 * Measures the app's files, memory and device health for the system status screen. Paths match
 * the stores that own them; reads block, so the model calls this off the main thread.
 */
class DeviceSystemStatus(context: Context) {
	private val context = context.applicationContext

	fun read(): SystemRuntimeStatus {
		val info = context.applicationInfo
		val files = context.filesDir
		val noBackup = context.noBackupFilesDir
		val disk = runCatching { StatFs(files.absolutePath) }.getOrNull()
		val storage = AppStorageBreakdown(
			appApkBytes = DiskUsage.bytes(File(info.sourceDir), *info.splitSourceDirs.orEmpty().map(::File).toTypedArray()),
			settingsBytes = DiskUsage.bytes(File(files, "settings-v1"), File(noBackup, "session-v1"), File(noBackup, "location-v1"), File(info.dataDir, "shared_prefs")),
			transitCacheBytes = DiskUsage.bytes(File(noBackup, "transit-v1")),
			widgetCacheBytes = DiskUsage.bytes(File(noBackup, "widget-v1")),
			httpCacheBytes = DiskUsage.bytes(context.cacheDir),
			fleetBytes = DiskUsage.bytes(File(noBackup, "fleet-v1")),
			deviceFreeBytes = disk?.availableBytes,
			deviceTotalBytes = disk?.totalBytes,
		)
		val activity = context.getSystemService(ActivityManager::class.java)
		val device = activity?.let { manager -> ActivityManager.MemoryInfo().also(manager::getMemoryInfo) }
		val runtime = Runtime.getRuntime()
		// Android rate-limits this for apps, so repeated reads within a few minutes may repeat a sample.
		val pss = runCatching { activity?.getProcessMemoryInfo(intArrayOf(Process.myPid()))?.firstOrNull()?.totalPss?.toLong() }.getOrNull() ?: 0L
		val memory = AppMemoryStatus(
			processPssBytes = pss * 1024L,
			jvmUsedBytes = runtime.totalMemory() - runtime.freeMemory(),
			jvmMaxBytes = runtime.maxMemory(),
			nativeAllocatedBytes = Debug.getNativeHeapAllocatedSize(),
			deviceAvailableBytes = device?.availMem,
			deviceTotalBytes = device?.totalMem,
			lowMemory = device?.lowMemory == true,
		)
		val power = context.getSystemService(PowerManager::class.java)
		return SystemRuntimeStatus(
			storage = storage,
			memory = memory,
			thermalStatus = power?.let { SystemRuntimeStatus.thermalLabel(it.currentThermalStatus) } ?: "Unknown",
			powerSaveMode = power?.isPowerSaveMode == true,
			appVersion = "${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})",
			androidVersion = "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})",
		)
	}
}
