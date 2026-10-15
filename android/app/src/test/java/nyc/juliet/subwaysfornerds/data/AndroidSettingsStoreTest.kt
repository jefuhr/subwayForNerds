package nyc.juliet.subwaysfornerds.data

import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.test.runTest
import nyc.juliet.subwaysfornerds.core.*
import org.junit.Assert.*
import org.junit.Test

class AndroidSettingsStoreTest {
	@Test fun settingsBaselineAndNavigationReopenWithoutDroppingUnknownIDs() = runTest {
		val root = Files.createTempDirectory("sfn-settings").toFile()
		try {
			val store = AndroidSettingsStore(root)
			val settings = Settings(theme = "future-theme", favorites = listOf("future-station"))
			store.save(settings); store.saveLastStation("future-station"); store.saveBaseline(SyncBaseline("user", 42L, settings))
			val reopened = AndroidSettingsStore(root)
			assertEquals(settings, reopened.load())
			assertEquals("future-station", reopened.lastStation())
			assertEquals(listOf("future-station"), reopened.recentStations())
			assertEquals(42L, reopened.loadBaseline()!!.revision)
			assertFalse(File(root, "state.json").readText().contains("token", ignoreCase = true))
		} finally { root.deleteRecursively() }
	}

	@Test fun unreadableSettingsArePreservedUntilExplicitImportAndBackupRecovers() = runTest {
		val root = Files.createTempDirectory("sfn-settings-recovery").toFile()
		try {
			val store = AndroidSettingsStore(root); val settings = Settings(theme = "kitty")
			store.save(settings)
			File(root, "state.json").writeText("broken primary")
			assertEquals(settings, AndroidSettingsStore(root).load())
			File(root, "state.backup").writeText("broken backup")
			try { store.saveLastStation("station"); fail("Unreadable settings were overwritten") } catch (_: java.io.IOException) { }
			assertEquals("broken primary", File(root, "state.json").readText())
			store.replaceFromImport(Settings(theme = "future-theme"), "station")
			assertEquals("future-theme", store.load().theme)
			assertEquals("station", store.lastStation())
		} finally { root.deleteRecursively() }
	}

	@Test fun groupedAcceptanceKeepsSettingsStationAndBaselineTogetherThroughInterruption() = runTest {
		val root = Files.createTempDirectory("sfn-accepted-settings").toFile()
		try {
			var interrupt = false
			val store = AndroidSettingsStore(root, beforeActivate = { if (interrupt) throw IllegalStateException("simulated activation interruption") })
			val previous = Settings(theme = "subway"); val oldBaseline = SyncBaseline("user", 1L, previous)
			store.saveAccepted(previous, "old-station", oldBaseline)
			store.saveApiBase("https://example.test/api/")
			val next = Settings(theme = "kitty"); val baseline = SyncBaseline("user", 2L, next)
			interrupt = true
			try { store.saveAccepted(next, "next-station", baseline); fail("Interrupted acceptance activated") } catch (_: IllegalStateException) { }
			val reopened = AndroidSettingsStore(root)
			assertEquals(previous, reopened.load()); assertEquals("old-station", reopened.lastStation()); assertEquals(oldBaseline, reopened.loadBaseline())
			interrupt = false; store.saveAccepted(next, "next-station", baseline)
			val accepted = AndroidSettingsStore(root)
			assertEquals(next, accepted.load()); assertEquals("next-station", accepted.lastStation()); assertEquals(baseline, accepted.loadBaseline())
			assertEquals("https://example.test/api/", accepted.apiBase())
			assertEquals(listOf("next-station", "old-station"), accepted.recentStations())
		} finally { root.deleteRecursively() }
	}
}
