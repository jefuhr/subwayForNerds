package nyc.juliet.subwaysfornerds

import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.runBlocking
import nyc.juliet.subwaysfornerds.core.Account
import nyc.juliet.subwaysfornerds.core.AccountIdentity
import nyc.juliet.subwaysfornerds.core.AccountSession
import nyc.juliet.subwaysfornerds.core.AndroidAuthPending
import nyc.juliet.subwaysfornerds.core.AuthConfig
import nyc.juliet.subwaysfornerds.core.Settings
import nyc.juliet.subwaysfornerds.core.SettingsRevision
import nyc.juliet.subwaysfornerds.ui.AppContainer
import nyc.juliet.subwaysfornerds.ui.AppViewModel
import nyc.juliet.subwaysfornerds.ui.account.SessionVault
import nyc.juliet.subwaysfornerds.ui.data.AccountService
import nyc.juliet.subwaysfornerds.ui.data.SettingsStorage
import nyc.juliet.subwaysfornerds.data.AndroidSettingsStore
import nyc.juliet.subwaysfornerds.data.SyncBaseline
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.IOException
import java.util.Collections

/** An enabled account server that records each callback exchange; nothing leaves the device. */
private class RecordingAccounts : AccountService {
	val user = Account("user-1", listOf(AccountIdentity("google", "rider@example.com")))
	/** Each exchanged callback with the state of the pending sign-in it completed. */
	val exchanges: MutableList<Pair<String, String>> = Collections.synchronizedList(mutableListOf())
	@Volatile var remote = SettingsRevision(1, null)
	val uploads: MutableList<Settings> = Collections.synchronizedList(mutableListOf())
	override suspend fun config() = AuthConfig(enabled = true)
	override suspend fun startAndroid(provider: String, intent: String, token: String?): AndroidAuthPending = throw IOException("Sign-in pages are not opened in tests.")
	override suspend fun exchangeAndroid(callback: String, pending: AndroidAuthPending, token: String?): AccountSession {
		exchanges += callback to pending.state
		return AccountSession(user, "csrf", "session-token")
	}
	override suspend fun account(token: String) = AccountSession(user, "csrf")
	override suspend fun settings(token: String) = remote
	override suspend fun putSettings(token: String, settings: Settings, revision: Long): SettingsRevision {
		uploads += settings
		remote = SettingsRevision(revision + 1, settings)
		return remote
	}
	override suspend fun logout(token: String) {}
	override suspend fun unlink(provider: String, token: String) {}
	override suspend fun deleteAccount(token: String) {}
}

/**
 * The browser finishes sign-in with an ACTION_VIEW callback that any app could also send. These tests
 * send it from the shell with `am start`, so it is routed by the real manifest filter, both to the
 * running activity (singleTask, onNewIntent) and to a newly started activity reading its launch intent.
 * The instrumentation shares the app's process and uses a test vault. Model recreation is covered
 * by unit tests; neither those tests nor this class claim native killed-process or Keystore coverage.
 */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class AuthCallbackTest {
	@get:Rule(order = 0) val activities = LaunchedActivities()
	@get:Rule(order = 1) val compose = createEmptyComposeRule()
	@get:Rule(order = 2) val failures = FailureArtifacts(compose)
	private val accounts = RecordingAccounts()
	private val vault = MemoryVault()

	@Before fun setUp() {
		FixtureEnvironment.install()
		AppContainer.accountOverride = { accounts }
		AppContainer.vaultOverride = { vault }
	}

	private fun callback(state: String) = "nyc.juliet.subwaysfornerds://auth/android?state=$state&handoff=handoff-$state"
	private fun pending(state: String) = AndroidAuthPending("google", "login", state, "verifier-$state", "challenge", "https://fixture.invalid/auth", System.currentTimeMillis() / 1000.0 - 5)

	private fun waitForSession() = compose.waitUntil(15_000) { runBlocking { vault.load() } != null }

	private fun showAccount() {
		compose.onNodeWithTag("tab_settings").performClick()
		compose.onNodeWithTag("settingsScreen").performScrollToNode(hasTestTag("signOut"))
		compose.onNodeWithText("Google · rider@example.com").assertExists()
	}

	@Test fun aCallbackToTheRunningAppFinishesSignInInPlace() {
		runBlocking { vault.savePending(pending("warm")) }
		val scenario = activities.launch()
		compose.waitUntilAtLeastOneExists(hasTestTag("boardScreen"), 15_000)
		var before: MainActivity? = null
		scenario.onActivity { before = it }
		sendViewIntentFromShell(callback("warm"))
		waitForSession()
		var after: MainActivity? = null
		scenario.onActivity { after = it }
		assertSame("The running activity receives the callback", before, after)
		assertEquals(listOf(callback("warm") to "warm"), accounts.exchanges.toList())
		assertEquals("session-token", runBlocking { vault.load() })
		assertNull(runBlocking { vault.loadPending() })
		showAccount()
		compose.onRoot().saveScreenshot("auth-callback-warm-signed-in")
	}

	@Test fun aCallbackThatStartsTheActivityFinishesSignIn() {
		runBlocking { vault.savePending(pending("cold")) }
		sendViewIntentFromShell(callback("cold"))
		compose.waitUntilAtLeastOneExists(hasTestTag("boardScreen"), 15_000)
		waitForSession()
		assertEquals(listOf(callback("cold") to "cold"), accounts.exchanges.toList())
		assertNull(runBlocking { vault.loadPending() })
		showAccount()
		compose.onRoot().saveScreenshot("auth-callback-cold-signed-in")
	}

	@Test fun unexpectedCallbacksNeverReachTheServer() {
		activities.launch()
		compose.waitUntilAtLeastOneExists(hasTestTag("boardScreen"), 15_000)
		// Wrong path: not an auth callback at all, so it is ignored.
		sendViewIntentFromShell("nyc.juliet.subwaysfornerds://auth/other?state=x&handoff=y")
		// The right shape with no sign-in in progress: rejected as expired, never exchanged.
		sendViewIntentFromShell(callback("unsolicited"))
		compose.onNodeWithTag("tab_settings").performClick()
		val notice = hasText("Sign-in expired. Please try again.")
		compose.waitUntil(10_000) { runCatching { compose.onNodeWithTag("settingsScreen").performScrollToNode(notice) }.isSuccess }
		compose.onRoot().saveScreenshot("auth-callback-unsolicited-rejected")
		assertTrue(accounts.exchanges.isEmpty())
		assertNull(runBlocking { vault.load() })
	}

	@Test fun unreadableProofCanBeRetriedFromSettingsWithoutDiscardingTheCallback() {
		var locked = true
		runBlocking { vault.savePending(pending("locked")) }
		AppContainer.vaultOverride = {
			object : SessionVault by vault {
				override suspend fun loadPending(): AndroidAuthPending? {
					if (locked) throw IOException("Injected locked proof")
					return vault.loadPending()
				}
			}
		}
		activities.launch()
		compose.waitUntilAtLeastOneExists(hasTestTag("boardScreen"), 15_000)
		sendViewIntentFromShell(callback("locked"))
		compose.onNodeWithTag("tab_settings").performClick()
		compose.onNodeWithTag("settingsScreen").performScrollToNode(hasTestTag("retryPendingSignIn"))
		assertEquals("locked", runBlocking { vault.loadPending() }?.state)
		assertTrue(accounts.exchanges.isEmpty())
		compose.onRoot().saveScreenshot("auth-pending-proof-preserved")
		locked = false
		compose.onNodeWithTag("retryPendingSignIn").performClick()
		waitForSession()
		assertEquals(listOf(callback("locked") to "locked"), accounts.exchanges.toList())
		compose.onRoot().saveScreenshot("auth-pending-proof-recovered")
	}

	@Test fun replacingUnreadableProofNeedsConfirmationAndKeepsTheSession() {
		runBlocking { vault.save("existing-session"); vault.savePending(pending("locked")) }
		AppContainer.vaultOverride = { object : SessionVault by vault { override suspend fun loadPending(): AndroidAuthPending? = throw IOException("Injected locked proof") } }
		activities.launch()
		compose.waitUntilAtLeastOneExists(hasTestTag("boardScreen"), 15_000)
		compose.onNodeWithTag("tab_settings").performClick()
		compose.onNodeWithTag("settingsScreen").performScrollToNode(hasTestTag("replacePendingSignIn"))
		compose.onNodeWithTag("replacePendingSignIn").performClick()
		compose.onNodeWithTag("cancelReplacePendingSignIn").performClick()
		assertEquals("locked", runBlocking { vault.loadPending() }?.state)
		compose.onNodeWithTag("replacePendingSignIn").performClick()
		compose.onRoot().saveScreenshot("auth-pending-replacement-confirmation")
		compose.onNodeWithTag("confirmReplacePendingSignIn").performClick()
		compose.waitUntil(5_000) { runBlocking { vault.loadPending() } == null }
		assertEquals("existing-session", runBlocking { vault.load() })
		assertTrue(accounts.exchanges.isEmpty())
	}

	@Test fun aThemeChangedDuringAccountStorageShowsExplicitConflictChoices() {
		val writing = CompletableDeferred<Unit>()
		val release = CompletableDeferred<Unit>()
		val hold = java.util.concurrent.atomic.AtomicBoolean(false)
		FixtureEnvironment.install(settingsStorage = { storage ->
			object : SettingsStorage by storage {
				override suspend fun saveAccepted(settings: Settings, lastStation: String, baseline: SyncBaseline?, replaceUnreadable: Boolean) {
					if (hold.get()) { writing.complete(Unit); release.await() }
					storage.saveAccepted(settings, lastStation, baseline, replaceUnreadable)
				}
			}
		})
		val context = InstrumentationRegistry.getInstrumentation().targetContext
		runBlocking {
			AndroidSettingsStore(context).saveAccepted(Settings(), FIXTURE_STATION, SyncBaseline(accounts.user.id, 1, Settings()))
			vault.save("session-token")
		}
		accounts.remote = SettingsRevision(1, Settings())
		AppContainer.accountOverride = { accounts }
		AppContainer.vaultOverride = { vault }
		val scenario = activities.launch()
		lateinit var viewModel: AppViewModel
		scenario.onActivity { viewModel = ViewModelProvider(it)[AppViewModel::class.java] }
		compose.waitUntil(10_000) { viewModel.account.status == "Settings synced" }
		compose.onNodeWithTag("tab_settings").performClick()
		compose.onNodeWithTag("settingsScreen").performScrollToNode(hasTestTag("syncNow"))
		hold.set(true)
		accounts.remote = SettingsRevision(2, Settings(theme = "kuromi"))
		try {
			compose.onNodeWithTag("syncNow").performClick()
			compose.waitUntil(5_000) { writing.isCompleted }
			compose.onNodeWithTag("settingsScreen").performScrollToNode(hasTestTag("theme_night"))
			compose.onNodeWithTag("theme_night").performClick()
			release.complete(Unit)
			compose.waitUntil(10_000) { viewModel.account.conflicts.isNotEmpty() }
			compose.onNodeWithTag("settingsScreen").performScrollToNode(hasTestTag("saveConflictChoices"))
			compose.onNodeWithText("This device: Night").assertExists()
			compose.onNodeWithText("Account: Kuromi").assertExists()
			compose.onRoot().saveScreenshot("account-storage-conflict-choices")
			assertTrue("The unresolved local theme must not be uploaded", accounts.uploads.isEmpty())
			compose.onNodeWithText("Account: Kuromi").performClick()
			compose.onNodeWithTag("saveConflictChoices").performClick()
			compose.waitUntil(10_000) { viewModel.account.conflicts.isEmpty() && viewModel.model.settings.theme == "kuromi" }
			compose.onRoot().saveScreenshot("account-storage-conflict-resolved")
		} finally { release.complete(Unit) }
	}
}
