package nyc.juliet.subwaysfornerds

import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.assertTextContains
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.test.ext.junit.runners.AndroidJUnit4
import nyc.juliet.subwaysfornerds.core.NerdsCodec
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.runner.RunWith

@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class SettingsFlowTest {
	private val compose = createAndroidComposeRule<MainActivity>()
	@get:Rule val rules: RuleChain = RuleChain.outerRule(FixtureRule()).around(compose).around(FailureArtifacts(compose))

	private fun openSettings() {
		compose.waitUntilAtLeastOneExists(hasTestTag("boardScreen"), 10_000)
		compose.onNodeWithTag("tab_settings").performClick()
		compose.onNodeWithTag("settingsScreen").assertIsDisplayed()
	}

	@Test fun everyThemeIsADirectChoiceAndPersists() {
		openSettings()
		compose.onNodeWithTag("settingsScreen").performScrollToNode(hasTestTag("theme_kuromi"))
		compose.onNodeWithTag("theme_kuromi").performClick()
		compose.onNodeWithTag("theme_kuromi").assertIsSelected()
		compose.onRoot().saveScreenshot("settings-theme-kuromi")
		compose.waitUntil(5_000) { kotlinx.coroutines.runBlocking { nyc.juliet.subwaysfornerds.data.AndroidSettingsStore(compose.activity).load().theme } == "kuromi" }
	}

	@Test fun offlineSettingsUseDirectControls() {
		openSettings()
		compose.onNodeWithTag("settingsScreen").performScrollToNode(hasTestTag("offlineSettings"))
		compose.onNodeWithTag("offlineSettings").performClick()
		compose.waitUntilAtLeastOneExists(hasTestTag("offlineSettingsScreen"), 5_000)
		compose.onNodeWithTag("offlineDepartures_increment").performClick()
		compose.onNodeWithText("Departures per line and direction: 6").assertExists()
		compose.onNodeWithTag("offlineSettingsScreen").performScrollToNode(hasTestTag("offlineEstimateLimit_60"))
		compose.onNodeWithTag("offlineEstimateLimit_60").performClick()
		compose.onNodeWithTag("offlineEstimateLimit_60").assertIsSelected()
		compose.onRoot().saveScreenshot("settings-offline")
	}

	@Test fun systemStatusMeasuresThisDevice() {
		openSettings()
		compose.onNodeWithTag("settingsScreen").performScrollToNode(hasTestTag("systemStatusSettings"))
		compose.onNodeWithTag("systemStatusSettings").assertTextContains("Online")
		compose.onNodeWithTag("systemStatusSettings").performClick()
		compose.waitUntilAtLeastOneExists(hasTestTag("systemStatusScreen"), 5_000)
		// The installed APK is never empty, so a nonzero total proves the collector ran on the device.
		compose.waitUntilAtLeastOneExists(hasTestTag("systemStatusAppApkStorage") and !hasText("0 bytes", substring = true), 10_000)
		compose.onNodeWithTag("systemStatusTotalStorage").assertIsDisplayed()
		compose.onNodeWithTag("systemStatusFleetStorage").assertTextContains("Not downloaded", substring = true)
		compose.onNodeWithTag("systemStatusScreen").performScrollToNode(hasTestTag("systemStatusRamUsed"))
		compose.onNodeWithTag("systemStatusRamUsed").assertIsDisplayed()
		compose.onNodeWithTag("systemStatusScreen").performScrollToNode(hasTestTag("refreshSystemStatus"))
		compose.onNodeWithTag("systemStatusAppVersion").assertTextContains(BuildConfig.VERSION_NAME, substring = true)
		compose.onNodeWithTag("systemStatusThermalState").assertExists()
		compose.onNodeWithTag("refreshSystemStatus").performClick()
		compose.waitUntil(10_000) { compose.onAllNodes(hasTestTag("refreshSystemStatus") and hasText("Refresh status")).fetchSemanticsNodes().isNotEmpty() }
		compose.onRoot().saveScreenshot("settings-system-status")
	}

	@Test fun accountsShowTheServerConfigurationHonestly() {
		openSettings()
		compose.onNodeWithTag("settingsScreen").performScrollToNode(hasTestTag("accountsUnavailable"))
		compose.onNodeWithTag("accountsUnavailable").assertIsDisplayed()
	}

	@Test fun widgetPreviewsRenderTheActualWidget() {
		openSettings()
		compose.onNodeWithTag("settingsScreen").performScrollToNode(hasTestTag("widgetPreviews"))
		compose.onNodeWithTag("widgetPreviews").performClick()
		compose.waitUntilAtLeastOneExists(hasTestTag("widgetPreview_Small · Example · live"), 15_000)
		compose.onRoot().saveScreenshot("widget-previews")
	}

	@Test fun widgetDisplayKeepsPortableArrivalStyle() {
		openSettings()
		compose.onNodeWithTag("settingsScreen").performScrollToNode(hasTestTag("widgetDisplaySettings"))
		compose.onNodeWithTag("widgetDisplaySettings").performClick()
		compose.waitUntilAtLeastOneExists(hasTestTag("widgetDisplayScreen"), 5_000)
		// The stored iPhone and iPad style stays visible and labeled; the grey caption explaining Android's own style is gone.
		compose.onNodeWithTag("widgetDisplayScreen").performScrollToNode(hasTestTag("widgetTimeStyle"))
		compose.onNodeWithText("Arrival display on iPhone and iPad").assertExists()
		assertNoText("Android widgets always show arrival clock times")
		compose.onRoot().saveScreenshot("settings-widget-display")
	}

	@Test fun settingsDropTheTaglineAndExplanatoryFooters() {
		openSettings()
		compose.onNodeWithText("subways for nerds.").assertExists()
		// Every section still has its rows; only the prose that explains how they work is gone.
		for (anchor in listOf("combinedStationsSettings", "widgetStationSelectionSettings", "widgetBackgroundLocation", "offlineSettings", "fleetPackScope", "exportSettings", "systemStatusSettings", "createGithubIssue")) {
			compose.onNodeWithTag("settingsScreen").performScrollToNode(hasTestTag(anchor))
			compose.onNodeWithTag(anchor).assertExists()
			assertNoText(*SETTINGS_PROSE)
		}
		compose.onNodeWithTag("settingsScreen").performScrollToNode(hasTestTag("distanceUnits_auto"))
		assertNoText(*SETTINGS_PROSE)
		compose.onRoot().saveScreenshot("settings-without-footers")
	}

	@Test fun offlineSettingsAndSystemStatusDropExplanatoryFooters() {
		openSettings()
		compose.onNodeWithTag("settingsScreen").performScrollToNode(hasTestTag("offlineSettings"))
		compose.onNodeWithTag("offlineSettings").performClick()
		compose.waitUntilAtLeastOneExists(hasTestTag("offlineSettingsScreen"), 5_000)
		for (anchor in listOf("offlineDepartures_increment", "offlineEstimateLimit_60", "offlineSavedTrains")) {
			compose.onNodeWithTag("offlineSettingsScreen").performScrollToNode(hasTestTag(anchor))
			assertNoText(*OFFLINE_PROSE)
		}
		compose.onRoot().saveScreenshot("settings-offline-without-footers")
		compose.onNodeWithTag("navigateBack").performClick()
		compose.onNodeWithTag("settingsScreen").performScrollToNode(hasTestTag("systemStatusSettings"))
		compose.onNodeWithTag("systemStatusSettings").performClick()
		compose.waitUntilAtLeastOneExists(hasTestTag("systemStatusScreen"), 5_000)
		for (anchor in listOf("systemStatusTotalStorage", "deviceNetworkStatus", "systemStatusRamUsed", "refreshSystemStatus")) {
			compose.onNodeWithTag("systemStatusScreen").performScrollToNode(hasTestTag(anchor))
			assertNoText(*SYSTEM_STATUS_PROSE)
		}
		// Sizes, counts and status stay: they are data, not explanation.
		compose.onNodeWithTag("systemStatusScreen").performScrollToNode(hasTestTag("systemStatusFleetStorage"))
		compose.onNodeWithTag("systemStatusFleetStorage").assertTextContains("Not downloaded", substring = true)
	}

	private fun assertNoText(vararg phrases: String) {
		for (phrase in phrases) assertTrue("'$phrase' should be gone", compose.onAllNodes(hasText(phrase, substring = true)).fetchSemanticsNodes().isEmpty())
	}

	private companion object {
		val SETTINGS_PROSE = arrayOf(
			"Know the system. Make your next move.", "Applies to the app and widgets.", "Widgets use your station selection", "Off by default. When on",
			"Boards you view, nearby boards", "Prepare to see the archive size", "Move combined stations, hidden lines", "App storage breakdown, network signal",
			"Use a reachable API base address", "Times are predictions, not promises. Location finds",
		)
		val OFFLINE_PROSE = arrayOf(
			"Each board you view keeps", "Favorite boards, and boards within", "Without a connection, countdowns use saved", "Automatic boards and trips expire",
			"While you are on a train, Home screen", "Offline boards, trips and your ride stay on this device",
		)
		val SYSTEM_STATUS_PROSE = arrayOf("Settings include your account session", "Signal and link speed are the system's own estimates", "App RAM is the process's total footprint")
	}
}

@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class OfflineLaunchTest {
	private val compose = createAndroidComposeRule<MainActivity>()
	@get:Rule val rules: RuleChain = RuleChain.outerRule(FixtureRule(online = false)).around(compose).around(FailureArtifacts(compose))

	@Test fun noConnectionAndNoSavedBoardSaysSoWithoutInventingTimes() {
		compose.waitUntilAtLeastOneExists(hasTestTag("boardError"), 15_000)
		compose.onNodeWithTag("boardScreen").assertIsDisplayed()
		compose.onRoot().saveScreenshot("board-offline-no-saved-board")
		assertTrue(FixtureEnvironment.transit.requests.isNotEmpty())
	}
}

@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class CombinedImportTest {
	private val combined = {
		val text = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().context.assets.open("fixtures/combined-stations.nerds").use { it.readBytes().toString(Charsets.UTF_8) }
		NerdsCodec.decode(text).settings
	}
	private val compose = createAndroidComposeRule<MainActivity>()
	@get:Rule val rules: RuleChain = RuleChain.outerRule(FixtureRule(combined)).around(compose).around(FailureArtifacts(compose))

	@Test fun aCombinedFavoriteIsAPageThatReportsEachMember() {
		compose.waitUntilAtLeastOneExists(hasTestTag("stationPager"), 10_000)
		compose.onNodeWithTag("nextStation").performClick()
		compose.waitUntilAtLeastOneExists(hasText("Downtown"), 10_000)
		// No member of this combined station has a recorded board, so each one is reported rather than invented.
		compose.waitUntilAtLeastOneExists(hasTestTag("boardError"), 15_000)
		compose.onNodeWithTag("findStation").performClick()
		compose.waitUntilAtLeastOneExists(hasTestTag("addCombinedStation"), 5_000)
		compose.onNodeWithTag("closeScreen").performClick()
		compose.onRoot().saveScreenshot("board-combined-favorite-unavailable")
		val members = listOf("328", "624", "628", "path-wtc").map { "board:$it" }
		assertTrue(FixtureEnvironment.transit.requests.any { it in members })
		assertTrue(FixtureEnvironment.transit.requests.none { it.startsWith("board:combined:") })
	}
}
