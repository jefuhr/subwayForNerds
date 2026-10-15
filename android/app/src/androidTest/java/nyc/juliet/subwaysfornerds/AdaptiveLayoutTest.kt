package nyc.juliet.subwaysfornerds

import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.test.DeviceConfigurationOverride
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.FontScale
import androidx.compose.ui.test.ForcedSize
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel
import nyc.juliet.subwaysfornerds.ui.AppContainer
import nyc.juliet.subwaysfornerds.ui.AppModel
import nyc.juliet.subwaysfornerds.ui.AppRoot
import nyc.juliet.subwaysfornerds.ui.account.AccountModel
import nyc.juliet.subwaysfornerds.ui.settings.SettingsActions
import org.junit.After
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** The same app at tablet width and at very large text, without changing the device. */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class AdaptiveLayoutTest {
	@get:Rule(order = 0) val compose = createComposeRule()
	@get:Rule(order = 1) val failures = FailureArtifacts(compose)
	private val scope = MainScope()
	private lateinit var model: AppModel
	private lateinit var account: AccountModel
	private val actions = object : SettingsActions {
		override fun exportSettings() {}
		override fun importSettings() {}
		override fun enableWidgetLocation() {}
		override fun openLocationSettings() {}
	}

	@Before fun setUp() {
		FixtureEnvironment.install()
		val context = InstrumentationRegistry.getInstrumentation().targetContext
		InstrumentationRegistry.getInstrumentation().runOnMainSync {
			model = AppModel(scope, AppContainer.overrides!!.invoke(context))
			account = AccountModel(scope, DisabledAccounts(), MemoryVault())
		}
	}

	@After fun tearDown() { scope.cancel() }

	@Test fun tabletWidthKeepsTheBoardBesideStationInfoThenTrainDetails() {
		compose.setContent {
			DeviceConfigurationOverride(DeviceConfigurationOverride.ForcedSize(DpSize(1100.dp, 800.dp))) {
				LaunchedEffect(Unit) { model.runWhileActive() }
				AppRoot(model, account, actions)
			}
		}
		compose.waitUntilAtLeastOneExists(hasTestTag("detailPane"), 10_000)
		compose.onNodeWithTag("navigationRail").assertIsDisplayed()
		compose.onNodeWithTag("listPane").assertIsDisplayed()
		compose.waitUntilAtLeastOneExists(hasTestTag("stationContext"), 10_000)
		compose.waitForDepartures()
		compose.onRoot().saveScreenshot("tablet-board-station-info")
		compose.scrollToDeparture(FIRST_NORTH_L).performClick()
		compose.waitUntilAtLeastOneExists(hasTestTag("trainDetails"), 10_000)
		compose.onNodeWithTag("listPane").assertIsDisplayed()
		compose.onRoot().saveScreenshot("tablet-board-train-details")
	}

	@Test fun largestTextKeepsTheBoardUsable() {
		compose.setContent {
			DeviceConfigurationOverride(DeviceConfigurationOverride.FontScale(2f)) {
				LaunchedEffect(Unit) { model.runWhileActive() }
				AppRoot(model, account, actions)
			}
		}
		compose.waitUntilAtLeastOneExists(hasTestTag("boardList"), 10_000)
		compose.onNodeWithTag("selectedStation").assertIsDisplayed()
		compose.onNodeWithTag("navigationBar").assertIsDisplayed()
		compose.onRoot().saveScreenshot("phone-board-font-200")
	}

	@Test fun everyThemeRendersTheBoard() {
		compose.setContent {
			LaunchedEffect(Unit) { model.runWhileActive() }
			AppRoot(model, account, actions)
		}
		compose.waitForDepartures()
		nyc.juliet.subwaysfornerds.ui.theme.AppTheme.all.forEach { theme ->
			compose.runOnIdle { model.setTheme(theme.id) }
			compose.waitForIdle()
			compose.onRoot().saveScreenshot("theme-${theme.id}")
		}
	}
}
