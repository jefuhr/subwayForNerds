package nyc.juliet.subwaysfornerds.ui

import android.content.Context
import android.content.Intent
import android.util.Base64
import nyc.juliet.subwaysfornerds.BuildConfig
import nyc.juliet.subwaysfornerds.core.StationLocation
import nyc.juliet.subwaysfornerds.ui.data.LocationException
import nyc.juliet.subwaysfornerds.ui.data.LocationPermission
import nyc.juliet.subwaysfornerds.ui.data.LocationSource
import java.io.File

/**
 * Debug launch settings for instrumentation, like the iOS SFN_* launch environment. They apply only
 * when a test in this process has armed the gate before launching; an ordinary external Intent can
 * never reset data or redirect the app, even in a debug build. Release builds ignore them entirely.
 */
object TestLaunchGate {
	@Volatile private var armed = false
	/** Called in-process by instrumentation before the activity starts. */
	fun arm() { armed = true }
	fun disarm() { armed = false }
	val isArmed: Boolean get() = BuildConfig.DEBUG && armed
}

data class LaunchOptions(
	val apiBase: String? = null,
	val now: Double? = null,
	val location: StationLocation? = null,
	val disableLocation: Boolean = false,
	val reset: Boolean = false,
	val settingsFile: String? = null,
) {
	companion object {
		const val API_BASE = "SFN_API_BASE_URL"
		const val NOW = "SFN_TEST_NOW"
		const val LOCATION = "SFN_TEST_LOCATION"
		const val DISABLE_LOCATION = "SFN_DISABLE_LOCATION"
		const val RESET = "SFN_RESET_STATE"
		const val SETTINGS_FILE = "SFN_TEST_SETTINGS_FILE"

		/** The options in this intent, or null when the gate is not armed. */
		fun from(intent: Intent?): LaunchOptions? {
			if (!TestLaunchGate.isArmed || intent == null) return null
			val now = intent.getStringExtra(NOW)?.toDoubleOrNull()?.takeIf { it.isFinite() && it > 0 }
			val location = intent.getStringExtra(LOCATION)?.split(',')?.mapNotNull { it.trim().toDoubleOrNull() }?.takeIf { it.size == 2 }
				?.let { (lat, lon) -> StationLocation(lat, lon, now ?: System.currentTimeMillis() / 1000.0) }?.takeIf { it.isValid }
			val settings = intent.getStringExtra(SETTINGS_FILE)?.let { encoded ->
				runCatching { Base64.decode(encoded, Base64.DEFAULT).toString(Charsets.UTF_8) }.getOrNull()
			}
			return LaunchOptions(
				apiBase = intent.getStringExtra(API_BASE)?.takeIf { it.startsWith("http://") || it.startsWith("https://") },
				now = now,
				location = location,
				disableLocation = intent.getStringExtra(DISABLE_LOCATION) == "1" || intent.getBooleanExtra(DISABLE_LOCATION, false),
				reset = intent.getStringExtra(RESET) == "1" || intent.getBooleanExtra(RESET, false),
				settingsFile = settings,
			)
		}

		/** Removes only this app's saved settings, offline boards, widget content and location; never other apps' data. */
		fun resetState(context: Context) {
			listOf(
				File(context.filesDir, "settings-v1"),
				File(context.noBackupFilesDir, "transit-v1"),
				File(context.noBackupFilesDir, "widget-v1"),
				File(context.noBackupFilesDir, "location-v1"),
			).forEach { it.deleteRecursively() }
			context.getSharedPreferences("ui-flags", Context.MODE_PRIVATE).edit().clear().apply()
		}
	}
}

/** A fixed test location, with permission granted, for armed instrumentation launches. */
class FixedLocationSource(private val location: StationLocation?) : LocationSource {
	override fun foregroundPermission() = LocationPermission.GRANTED
	override val foregroundPermissionNames: Array<String> = emptyArray()
	override fun backgroundAllowed() = false
	override suspend fun locate(timeoutMillis: Long): StationLocation = location ?: throw LocationException("Could not get your location. Search for a station or try again.")
	override suspend fun backgroundEnabled() = false
	override suspend fun setBackgroundEnabled(value: Boolean) {}
	override suspend fun publishAppLocation(location: StationLocation) {}
}
