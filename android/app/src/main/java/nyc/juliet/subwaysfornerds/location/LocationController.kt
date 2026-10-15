package nyc.juliet.subwaysfornerds.location

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationManager
import android.net.Uri
import android.os.CancellationSignal
import android.provider.Settings as AndroidSettings
import java.io.File
import kotlinx.coroutines.*
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import nyc.juliet.subwaysfornerds.core.StationLocation
import nyc.juliet.subwaysfornerds.core.TransitJson
import nyc.juliet.subwaysfornerds.data.AtomicStorage
import kotlin.coroutines.resume

enum class LocationPermission { DENIED, APPROXIMATE, PRECISE }
enum class LocationFailure { DENIED, DISABLED, UNAVAILABLE, TIMEOUT, BACKGROUND_DISABLED, BACKGROUND_PERMISSION_REQUIRED }
data class LocationStatus(val permission: LocationPermission, val servicesEnabled: Boolean, val backgroundEnabled: Boolean, val backgroundPermission: Boolean) {
	val notice: String? get() = when {
		permission == LocationPermission.DENIED -> "Location permission is off · saved station"
		!servicesEnabled -> "Location services are off · saved station"
		permission == LocationPermission.APPROXIMATE -> "Approximate location"
		else -> null
	}
}
data class LocationResult(val coordinate: StationLocation?, val status: LocationStatus, val failure: LocationFailure? = null) {
	val approximate: Boolean get() = status.permission == LocationPermission.APPROXIMATE
	val notice: String? get() = when (failure) {
		LocationFailure.TIMEOUT -> "Location lookup timed out · saved station"
		LocationFailure.UNAVAILABLE -> "Location unavailable · saved station"
		LocationFailure.BACKGROUND_DISABLED -> "Background location is off · saved station"
		LocationFailure.BACKGROUND_PERMISSION_REQUIRED -> "Background location permission is off · saved station"
		else -> status.notice
	}
}
@Serializable private data class LocalLocation(val version: Int = 1, val backgroundEnabled: Boolean = false, val coordinate: StationLocation? = null, val approximate: Boolean = false)

/** Permissions are inspected only. UX owns explicit foreground and background permission prompts. */
class LocationController(context: Context, private val clock: () -> Double = { System.currentTimeMillis() / 1000.0 }) {
	private val context = context.applicationContext
	private val manager = this.context.getSystemService(LocationManager::class.java)
	private val storage = AtomicStorage(File(this.context.noBackupFilesDir, "location-v1"))

	fun status(): LocationStatus {
		val permission = when {
			has(Manifest.permission.ACCESS_FINE_LOCATION) -> LocationPermission.PRECISE
			has(Manifest.permission.ACCESS_COARSE_LOCATION) -> LocationPermission.APPROXIMATE
			else -> LocationPermission.DENIED
		}
		val enabled = try { manager?.isLocationEnabled == true } catch (_: SecurityException) { false }
		val preference = storage.locked { read() }
		return LocationStatus(permission, enabled, preference.backgroundEnabled, has(Manifest.permission.ACCESS_BACKGROUND_LOCATION))
	}
	fun foregroundPermissionNames(): Array<String> = arrayOf(Manifest.permission.ACCESS_COARSE_LOCATION, Manifest.permission.ACCESS_FINE_LOCATION)
	fun backgroundPermissionName(): String = Manifest.permission.ACCESS_BACKGROUND_LOCATION
	/** Android 12+ background access requires a separate user visit to app permission settings. */
	fun backgroundPermissionIntent(): Intent = Intent(AndroidSettings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
	fun locationServicesIntent(): Intent = Intent(AndroidSettings.ACTION_LOCATION_SOURCE_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
	suspend fun setBackgroundEnabled(enabled: Boolean) = withContext(Dispatchers.IO) {
		storage.locked { storage.write("state.json", TransitJson.encodeToString(read().copy(backgroundEnabled = enabled)).toByteArray()) }
	}
	suspend fun lastLocation(): StationLocation? = withContext(Dispatchers.IO) { lastLocationBlocking() }
	internal fun lastLocationBlocking(): StationLocation? {
		if (!has(Manifest.permission.ACCESS_COARSE_LOCATION) && !has(Manifest.permission.ACCESS_FINE_LOCATION)) return null
		return storage.locked { val saved = read(); if (!saved.approximate && !has(Manifest.permission.ACCESS_FINE_LOCATION)) null else saved.coordinate?.takeIf { usable(it, clock()) } }
	}
	suspend fun lastLocationApproximate(): Boolean = withContext(Dispatchers.IO) { storage.locked { read().approximate } }
	suspend fun publishAppLocation(location: StationLocation, approximate: Boolean = false) {
		require(usable(location, clock())) { "Only a current, source-timed location can be shared with widgets." }
		val permission = status().permission
		require(permission != LocationPermission.DENIED) { "Location permission is off." }
		publish(location, approximate || permission == LocationPermission.APPROXIMATE)
	}

	suspend fun locate(timeoutMillis: Long = 4000, foreground: Boolean = true): LocationResult {
		val status = status()
		if (status.permission == LocationPermission.DENIED) return LocationResult(null, status, LocationFailure.DENIED)
		if (!status.servicesEnabled) return LocationResult(null, status, LocationFailure.DISABLED)
		if (!foreground && !status.backgroundEnabled) return LocationResult(null, status, LocationFailure.BACKGROUND_DISABLED)
		if (!foreground && !status.backgroundPermission) return LocationResult(null, status, LocationFailure.BACKGROUND_PERMISSION_REQUIRED)
		val locationManager = manager ?: return LocationResult(null, status, LocationFailure.UNAVAILABLE)
		val providers = try {
			locationManager.getProviders(true).filter { it != LocationManager.PASSIVE_PROVIDER }
		} catch (_: SecurityException) { return LocationResult(null, status(), LocationFailure.DENIED) }
		val preferred = preferredProvider(providers, status.permission) ?: return LocationResult(null, status, LocationFailure.UNAVAILABLE)
		var timedOut = false
		var delivered = false
		val candidate = try {
			withTimeoutOrNull(timeoutMillis.coerceIn(250, 15_000)) {
				withContext(Dispatchers.Main.immediate) {
					suspendCancellableCoroutine<StationLocation?> { continuation ->
						val cancellation = CancellationSignal()
						continuation.invokeOnCancellation { cancellation.cancel() }
						try {
							locationManager.getCurrentLocation(preferred, cancellation, context.mainExecutor) { fix ->
								if (continuation.isActive) { delivered = true; continuation.resume(fix?.let(::coordinate)?.takeIf { usable(it, clock()) }) }
							}
						} catch (_: SecurityException) { if (continuation.isActive) { delivered = true; continuation.resume(null) } }
						catch (_: IllegalArgumentException) { if (continuation.isActive) { delivered = true; continuation.resume(null) } }
					}
				}
			}.also { if (it == null && !delivered) timedOut = true }
		} catch (error: CancellationException) { throw error }
		val fallback = try { providers.mapNotNull { locationManager.getLastKnownLocation(it)?.let(::coordinate) }.filter { usable(it, clock()) }.maxByOrNull { it.timestamp } } catch (_: SecurityException) { null }
		val best = listOfNotNull(candidate, fallback, lastLocation()).filter { usable(it, clock()) }.maxByOrNull { it.timestamp }
		val latest = status()
		resultFailure(status.permission, latest, foreground)?.let { return LocationResult(null, latest, it) }
		if (best != null) {
			publish(best, status.permission == LocationPermission.APPROXIMATE || latest.permission == LocationPermission.APPROXIMATE)
			return LocationResult(best, latest)
		}
		return LocationResult(null, latest, if (timedOut) LocationFailure.TIMEOUT else LocationFailure.UNAVAILABLE)
	}
	private suspend fun publish(coordinate: StationLocation, approximate: Boolean) = withContext(Dispatchers.IO) {
		storage.locked {
			val previous = read()
			if (!previous.approximate && !has(Manifest.permission.ACCESS_FINE_LOCATION) || previous.coordinate?.takeIf { usable(it, clock()) }?.timestamp?.let { it > coordinate.timestamp } != true)
				storage.write("state.json", TransitJson.encodeToString(previous.copy(coordinate = coordinate, approximate = approximate)).toByteArray())
		}
	}
	private fun coordinate(location: Location): StationLocation? {
		if (!location.hasAccuracy() || !location.accuracy.isFinite() || location.accuracy < 0) return null
		return StationLocation(location.latitude, location.longitude, location.time / 1000.0)
	}
	private fun read(): LocalLocation = storage.read("state.json", 64 * 1024)?.let { TransitJson.decodeFromString<LocalLocation>(it.decodeToString()).also { value -> require(value.version == 1) } } ?: LocalLocation()
	private fun has(permission: String) = context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
	companion object {
		internal fun preferredProvider(providers: List<String>, permission: LocationPermission): String? {
			if (permission == LocationPermission.DENIED) return null
			val eligible = providers.filter { it != LocationManager.PASSIVE_PROVIDER }
			// Android 12+ obfuscates provider results for COARSE permission, including GPS.
			return if (permission == LocationPermission.PRECISE && LocationManager.GPS_PROVIDER in eligible) LocationManager.GPS_PROVIDER
			else eligible.firstOrNull { it != LocationManager.GPS_PROVIDER } ?: eligible.firstOrNull()
		}
		internal fun resultFailure(start: LocationPermission, latest: LocationStatus, foreground: Boolean): LocationFailure? = when {
			latest.permission == LocationPermission.DENIED -> LocationFailure.DENIED
			!latest.servicesEnabled -> LocationFailure.DISABLED
			!foreground && !latest.backgroundEnabled -> LocationFailure.BACKGROUND_DISABLED
			!foreground && !latest.backgroundPermission -> LocationFailure.BACKGROUND_PERMISSION_REQUIRED
			start == LocationPermission.PRECISE && latest.permission == LocationPermission.APPROXIMATE -> LocationFailure.UNAVAILABLE
			else -> null
		}
		fun usable(coordinate: StationLocation, now: Double): Boolean = coordinate.latitude.isFinite() && coordinate.longitude.isFinite() && kotlin.math.abs(coordinate.latitude) <= 90 && kotlin.math.abs(coordinate.longitude) <= 180 && coordinate.timestamp.isFinite() && coordinate.timestamp > 0 && now.isFinite() && coordinate.timestamp <= now && now - coordinate.timestamp < 300
	}
}
