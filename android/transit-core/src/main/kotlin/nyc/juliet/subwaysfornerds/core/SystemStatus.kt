package nyc.juliet.subwaysfornerds.core

import java.io.File

/** Bytes the app occupies on the device, by what a rider would recognize. */
data class AppStorageBreakdown(
	/** The installed APK and its splits. */
	val appApkBytes: Long = 0,
	/** Settings, the account session, location preference and interface flags. */
	val settingsBytes: Long = 0,
	/** Offline boards, trips, saved trains, the active ride and the station catalog. */
	val transitCacheBytes: Long = 0,
	val widgetCacheBytes: Long = 0,
	/** The system-managed cache directory, which Android may clear. */
	val httpCacheBytes: Long = 0,
	val fleetBytes: Long = 0,
	val deviceFreeBytes: Long? = null,
	val deviceTotalBytes: Long? = null,
) {
	val cacheBytes: Long get() = transitCacheBytes + widgetCacheBytes + httpCacheBytes
	val userDataBytes: Long get() = settingsBytes + cacheBytes + fleetBytes
	val totalAppBytes: Long get() = appApkBytes + userDataBytes

	val appFraction: Double get() = fraction(appApkBytes)
	val settingsFraction: Double get() = fraction(settingsBytes)
	val cacheFraction: Double get() = fraction(cacheBytes)
	val fleetFraction: Double get() = fraction(fleetBytes)

	/** One category's share of the app's total, 0 when nothing was measured. */
	fun fraction(bytes: Long): Double = if (totalAppBytes > 0) (bytes.toDouble() / totalAppBytes).coerceIn(0.0, 1.0) else 0.0
}

/** The app's memory use and the device's, from the platform's memory APIs. */
data class AppMemoryStatus(
	/** Total proportional set size of this process, including code and graphics; 0 when unavailable. */
	val processPssBytes: Long = 0,
	val jvmUsedBytes: Long = 0,
	val jvmMaxBytes: Long = 0,
	val nativeAllocatedBytes: Long = 0,
	val deviceAvailableBytes: Long? = null,
	val deviceTotalBytes: Long? = null,
	val lowMemory: Boolean = false,
) {
	/** The process footprint when the system reports it, otherwise the two heaps the app can see. */
	val appRamBytes: Long get() = if (processPssBytes > 0) processPssBytes else jvmUsedBytes + nativeAllocatedBytes
	val heapFraction: Double get() = if (jvmMaxBytes > 0) (jvmUsedBytes.toDouble() / jvmMaxBytes).coerceIn(0.0, 1.0) else 0.0
}

/** One reading of the device for the system status screen. */
data class SystemRuntimeStatus(
	val storage: AppStorageBreakdown = AppStorageBreakdown(),
	val memory: AppMemoryStatus = AppMemoryStatus(),
	val thermalStatus: String = "Nominal",
	val powerSaveMode: Boolean = false,
	val appVersion: String = "",
	val androidVersion: String = "",
	/** The last successful API request's time to a complete response, including download. */
	val lastApiLatencyMs: Long? = null,
) {
	companion object {
		/** Android's PowerManager.THERMAL_STATUS_* codes, 0 (none) through 6 (shutdown). */
		fun thermalLabel(code: Int): String = when (code) {
			0 -> "Nominal"
			1 -> "Light"
			2 -> "Moderate"
			3 -> "Severe"
			4 -> "Critical"
			5 -> "Emergency"
			6 -> "Shutdown"
			else -> "Unknown"
		}
	}
}

/** Bytes of files on disk; directories count every file beneath them and missing paths count 0. */
object DiskUsage {
	fun bytes(vararg paths: File): Long = paths.sumOf { path ->
		runCatching { if (path.isFile) path.length() else path.walkTopDown().filter { it.isFile }.sumOf { it.length() } }.getOrDefault(0L)
	}
}
