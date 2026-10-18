package nyc.juliet.subwaysfornerds

import android.content.Intent
import android.util.Base64
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onRoot
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import nyc.juliet.subwaysfornerds.core.Settings
import nyc.juliet.subwaysfornerds.data.AndroidSettingsStore
import nyc.juliet.subwaysfornerds.ui.AppContainer
import nyc.juliet.subwaysfornerds.ui.LaunchOptions
import nyc.juliet.subwaysfornerds.ui.TestLaunchGate
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * MainActivity is exported, so any app can send it SFN_* extras. They may reset data, redirect the API
 * or open a settings file only when instrumentation in this process armed the gate first.
 */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class LaunchGateTest {
	@get:Rule(order = 0) val activities = LaunchedActivities()
	@get:Rule(order = 1) val compose = createEmptyComposeRule()
	@get:Rule(order = 2) val failures = FailureArtifacts(compose)
	private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
	private val redirect = "https://redirect.invalid/api/v1/"

	@Before fun setUp() {
		// A rider's saved theme and an offline board for the selected station, with the fixture network down.
		FixtureEnvironment.install(Settings(theme = "kuromi"), online = false)
		runBlocking { FixtureEnvironment.cache(context).saveBoardMerged(FixtureEnvironment.recordedBoard()) }
	}

	@After fun tearDown() {
		TestLaunchGate.disarm()
		AppContainer.launchOptions = null
	}

	private fun testExtras() = Intent(context, MainActivity::class.java).apply {
		putExtra(LaunchOptions.RESET, "1")
		putExtra(LaunchOptions.API_BASE, redirect)
		putExtra(LaunchOptions.SETTINGS_FILE, Base64.encodeToString(asset("settings.nerds").toByteArray(), Base64.NO_WRAP))
	}

	@Test fun anUnarmedLaunchIgnoresResetRedirectAndSettingsExtras() {
		activities.launch(testExtras())
		// The saved board is on screen with its offline estimate card; there is no separate notice for it.
		compose.waitUntilAtLeastOneExists(hasTestTag("boardOfflineEstimate"), 15_000)
		compose.onNodeWithTag("importPreview").assertDoesNotExist()
		compose.onRoot().saveScreenshot("launch-unarmed-extras-ignored")
		assertNull(AppContainer.launchOptions)
		assertEquals("kuromi", runBlocking { AndroidSettingsStore(context).load().theme })
		assertNotNull(runBlocking { FixtureEnvironment.cache(context).boardSnapshot(FIXTURE_STATION) })
	}

	@Test fun anArmedLaunchResetsThisAppsStateAndPreviewsTheFile() {
		TestLaunchGate.arm()
		activities.launch(testExtras())
		// The settings file opens as a preview; nothing is replaced until the rider accepts it.
		compose.waitUntilAtLeastOneExists(hasTestTag("importPreview"), 15_000)
		compose.onRoot().saveScreenshot("launch-armed-reset-import-preview")
		assertEquals(redirect, AppContainer.launchOptions?.apiBase)
		assertEquals(Settings().theme, runBlocking { AndroidSettingsStore(context).load().theme })
		assertNull(runBlocking { FixtureEnvironment.cache(context).boardSnapshot(FIXTURE_STATION) })
	}
}
