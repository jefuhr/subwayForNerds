package nyc.juliet.subwaysfornerds.ui.data

import nyc.juliet.subwaysfornerds.core.Board
import nyc.juliet.subwaysfornerds.core.FleetDetail
import nyc.juliet.subwaysfornerds.core.FleetOfflineManifest
import nyc.juliet.subwaysfornerds.core.FleetPackJob
import nyc.juliet.subwaysfornerds.core.FleetPackManifest
import nyc.juliet.subwaysfornerds.core.FleetPackSelection
import nyc.juliet.subwaysfornerds.core.FleetPage
import nyc.juliet.subwaysfornerds.core.Settings
import nyc.juliet.subwaysfornerds.core.SettingsRevision
import nyc.juliet.subwaysfornerds.core.Station
import nyc.juliet.subwaysfornerds.core.StationContext
import nyc.juliet.subwaysfornerds.core.StationLocation
import nyc.juliet.subwaysfornerds.core.TransferResult
import nyc.juliet.subwaysfornerds.core.TripDetail
import nyc.juliet.subwaysfornerds.core.LoadProgress
import nyc.juliet.subwaysfornerds.core.TransferProgressHandler
import nyc.juliet.subwaysfornerds.core.AuthConfig
import nyc.juliet.subwaysfornerds.core.AndroidAuthPending
import nyc.juliet.subwaysfornerds.core.AccountSession
import nyc.juliet.subwaysfornerds.data.LocalSettingsSnapshot
import nyc.juliet.subwaysfornerds.data.SyncBaseline

typealias TransferSink = TransferProgressHandler

/** Network requests the screens make. Production wraps core's TransitClient; tests use fixtures. */
interface TransitService {
	val baseUrl: String
	val host: String
	suspend fun stations(progress: TransferSink? = null): List<Station>
	suspend fun board(stationID: String, progress: TransferSink? = null): Board
	suspend fun trip(key: String, progress: TransferSink? = null): TripDetail
	suspend fun transfers(key: String, stopID: String, sequence: Int?, progress: TransferSink? = null): TransferResult
	suspend fun context(stationID: String, progress: TransferSink? = null): StationContext
	suspend fun fleet(query: Map<String, String>, progress: TransferSink? = null): FleetPage
	suspend fun fleetDetail(kind: String, id: String, progress: TransferSink? = null): FleetDetail
	suspend fun prepareFleetPack(selection: FleetPackSelection): FleetPackJob
	suspend fun fleetPackStatus(jobID: String): FleetPackJob
}

/**
 * Download progress of a fleet pack, by stage. Fractions describe the measured stage only, in bytes
 * or, while the server prepares records, in records; records are never shown as bytes.
 */
data class FleetTransfer(val stageLabel: String, val completed: Long, val total: Long?, val detail: String?, val records: Boolean = false) {
	val fraction: Double? get() = total?.takeIf { it > 0 }?.let { (completed.toDouble() / it).coerceIn(0.0, 1.0) }
	val load: LoadProgress get() {
		val label = detail ?: stageLabel
		val measured = total?.takeIf { it > 0 }
		val text = when {
			measured == null -> "$label…"
			records -> label
			else -> "$label · ${nyc.juliet.subwaysfornerds.ui.ByteCounts.file(completed)} of ${nyc.juliet.subwaysfornerds.ui.ByteCounts.file(measured)}"
		}
		return LoadProgress(fraction, text, false)
	}
}

/** The saved fleet download on this device. */
interface FleetStorage {
	suspend fun manifest(): FleetOfflineManifest?
	suspend fun download(pack: FleetPackManifest, apiBase: String, progress: (FleetTransfer) -> Unit)
	suspend fun delete()
	suspend fun page(query: Map<String, String>): FleetPage
	/** Saved history pages beyond the online endpoint's 200-event limit. */
	suspend fun detail(kind: String, id: String, offset: Int, limit: Int): FleetDetail
	/** Downloads are foreground-bound: leaving the app cancels one and keeps the previous fleet. */
	fun setForeground(value: Boolean)
}

/** The download expired on the server; prepare a fresh pack. */
class FleetDownloadExpiredException : Exception("The previous archive expired.")

enum class LocationPermission { GRANTED, DENIED, NOT_REQUESTED }

/** Device location for nearby stations, the startup board and widgets. Never requests permission itself. */
interface LocationSource {
	fun foregroundPermission(): LocationPermission
	/** Permissions to request with the system dialog for foreground use. */
	val foregroundPermissionNames: Array<String>
	fun backgroundAllowed(): Boolean
	suspend fun locate(timeoutMillis: Long = 12_000): StationLocation
	/** The optional background widget location, which starts disabled. */
	suspend fun backgroundEnabled(): Boolean
	suspend fun setBackgroundEnabled(value: Boolean)
	/** Shares the latest foreground fix with widgets. Coordinates stay on the device. */
	suspend fun publishAppLocation(location: StationLocation)
}

class LocationException(message: String) : Exception(message)

/** Optional accounts, mirroring core's AccountClient so tests can replace the server. */
interface AccountService {
	suspend fun config(): AuthConfig
	/** Starts a PKCE browser sign-in; the pending state stays in memory until the callback. */
	suspend fun startAndroid(provider: String, intent: String, token: String?): AndroidAuthPending
	suspend fun exchangeAndroid(callback: String, pending: AndroidAuthPending, token: String?): AccountSession
	suspend fun account(token: String): AccountSession
	suspend fun settings(token: String): SettingsRevision
	suspend fun putSettings(token: String, settings: Settings, revision: Long): SettingsRevision
	suspend fun logout(token: String)
	suspend fun unlink(provider: String, token: String)
	suspend fun deleteAccount(token: String)
}

/** Widget refresh and rendering, after settings or rides change. */
interface WidgetHooks {
	/** Settings or rides changed: reload widgets now from saved data. */
	suspend fun settingsChanged()
	/** A fetched board was saved; widgets keep its merged, untrimmed rows without another request. */
	suspend fun boardSaved(board: Board)
}

/** Settings, station, endpoint and sync baseline on this device. */
interface SettingsStorage {
	/** One consistent read of everything saved; throws when the saved record cannot be read. */
	suspend fun snapshot(): LocalSettingsSnapshot
	suspend fun save(settings: Settings)
	suspend fun saveLastStation(id: String)
	suspend fun saveApiBase(base: String)
	/** Saves settings, station and baseline in one activation. Only an explicit import may replace an unreadable record. */
	suspend fun saveAccepted(settings: Settings, lastStation: String, baseline: SyncBaseline?, replaceUnreadable: Boolean)
}
