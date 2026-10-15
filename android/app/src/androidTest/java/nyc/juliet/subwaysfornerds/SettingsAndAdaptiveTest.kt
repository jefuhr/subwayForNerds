package nyc.juliet.subwaysfornerds

import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsSelected
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
		compose.waitUntilAtLeastOneExists(hasText("Android widgets always show arrival clock times", substring = true), 5_000)
		compose.onRoot().saveScreenshot("settings-widget-display")
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
