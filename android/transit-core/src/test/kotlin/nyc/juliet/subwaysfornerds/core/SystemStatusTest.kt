package nyc.juliet.subwaysfornerds.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

class SystemStatusTest {
	@Test fun storageTotalsAddEveryCategory() {
		val storage = AppStorageBreakdown(
			appApkBytes = 40_000_000, settingsBytes = 20_000, transitCacheBytes = 3_000_000, widgetCacheBytes = 80_000,
			httpCacheBytes = 900_000, fleetBytes = 56_000_000, deviceFreeBytes = 10_000_000_000, deviceTotalBytes = 128_000_000_000,
		)
		assertEquals(3_980_000L, storage.cacheBytes)
		assertEquals(60_000_000L, storage.userDataBytes)
		assertEquals(100_000_000L, storage.totalAppBytes)
		assertEquals(0.4, storage.appFraction, 1e-9)
		assertEquals(0.0002, storage.settingsFraction, 1e-9)
		assertEquals(0.0398, storage.cacheFraction, 1e-9)
		assertEquals(0.56, storage.fleetFraction, 1e-9)
		assertEquals(1.0, storage.appFraction + storage.settingsFraction + storage.cacheFraction + storage.fleetFraction, 1e-9)
	}

	@Test fun emptyStorageHasNoFractionsInsteadOfDividingByZero() {
		val empty = AppStorageBreakdown()
		assertEquals(0L, empty.totalAppBytes)
		assertEquals(0.0, empty.appFraction, 0.0)
		assertEquals(0.0, empty.fleetFraction, 0.0)
	}

	@Test fun appRamPrefersTheProcessFootprint() {
		val measured = AppMemoryStatus(processPssBytes = 180_000_000, jvmUsedBytes = 30_000_000, jvmMaxBytes = 256_000_000, nativeAllocatedBytes = 40_000_000)
		assertEquals(180_000_000L, measured.appRamBytes)
		assertEquals(30_000_000.0 / 256_000_000.0, measured.heapFraction, 1e-9)
		// Without a PSS reading, the two heaps the app can see are the estimate.
		assertEquals(70_000_000L, measured.copy(processPssBytes = 0).appRamBytes)
		assertEquals(0.0, AppMemoryStatus().heapFraction, 0.0)
	}

	@Test fun thermalCodesUsePlainNames() {
		assertEquals(listOf("Nominal", "Light", "Moderate", "Severe", "Critical", "Emergency", "Shutdown"), (0..6).map(SystemRuntimeStatus::thermalLabel))
		assertEquals("Unknown", SystemRuntimeStatus.thermalLabel(-1))
		assertEquals("Unknown", SystemRuntimeStatus.thermalLabel(7))
		assertEquals("Nominal", SystemRuntimeStatus().thermalStatus)
	}

	@Test fun diskUsageCountsNestedFilesAndIgnoresMissingPaths() {
		val root = Files.createTempDirectory("system-status").toFile()
		try {
			File(root, "a.bin").writeBytes(ByteArray(100))
			File(root, "nested/deeper").mkdirs()
			File(root, "nested/b.bin").writeBytes(ByteArray(250))
			File(root, "nested/deeper/c.bin").writeBytes(ByteArray(5))
			val single = File(root, "single.bin").apply { writeBytes(ByteArray(7)) }
			assertEquals(362L, DiskUsage.bytes(root))
			assertEquals(255L, DiskUsage.bytes(File(root, "nested")))
			assertEquals(7L, DiskUsage.bytes(single))
			assertEquals(355L, DiskUsage.bytes(File(root, "a.bin"), File(root, "nested/deeper"), File(root, "nested/b.bin"), File(root, "missing")))
			assertEquals(0L, DiskUsage.bytes(File(root, "missing")))
			assertTrue(DiskUsage.bytes() == 0L)
		} finally {
			root.deleteRecursively()
		}
	}
}
