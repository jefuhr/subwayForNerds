package nyc.juliet.subwaysfornerds.ui.account

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import nyc.juliet.subwaysfornerds.core.Account
import nyc.juliet.subwaysfornerds.core.AccountException
import nyc.juliet.subwaysfornerds.core.AccountIdentity
import nyc.juliet.subwaysfornerds.core.AccountSession
import nyc.juliet.subwaysfornerds.core.AndroidAuthPending
import nyc.juliet.subwaysfornerds.core.AuthCancelledException
import nyc.juliet.subwaysfornerds.core.AuthConfig
import nyc.juliet.subwaysfornerds.core.Settings
import nyc.juliet.subwaysfornerds.core.SettingsRevision
import nyc.juliet.subwaysfornerds.data.SyncBaseline
import nyc.juliet.subwaysfornerds.ui.AppModel
import nyc.juliet.subwaysfornerds.ui.ModelHarness
import nyc.juliet.subwaysfornerds.ui.NOW
import nyc.juliet.subwaysfornerds.ui.data.AccountService
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException

private val USER = Account("user-1", listOf(AccountIdentity("google", "rider@example.com")))

/** A scripted account server. Hooks run while a request is in flight, as a rider's edit would. */
private class ScriptedAccounts : AccountService {
	var enabled = true
	var remote = SettingsRevision(1, null)
	var duringFetch: (suspend () -> Unit)? = null
	var duringPut: (suspend () -> Unit)? = null
	var preconditionFailures = 0
	val puts = mutableListOf<Settings>()
	var exchange: (suspend (String, AndroidAuthPending, String?) -> AccountSession)? = null
	val exchanged = mutableListOf<AndroidAuthPending>()
	val started = mutableListOf<Pair<String, String?>>()
	override suspend fun config() = AuthConfig(enabled)
	override suspend fun startAndroid(provider: String, intent: String, token: String?): AndroidAuthPending {
		started += intent to token
		return AndroidAuthPending(provider, intent, "state", "verifier", "challenge", "https://subwaysfornerds.juliet.nyc/api/v1/auth/android/start?challenge=challenge", NOW)
	}
	override suspend fun exchangeAndroid(callback: String, pending: AndroidAuthPending, token: String?): AccountSession {
		exchanged += pending
		return exchange?.invoke(callback, pending, token) ?: AccountSession(USER, "csrf", "token-1")
	}
	override suspend fun account(token: String) = AccountSession(USER, "csrf", null)
	override suspend fun settings(token: String): SettingsRevision { duringFetch?.invoke(); return remote }
	override suspend fun putSettings(token: String, settings: Settings, revision: Long): SettingsRevision {
		if (preconditionFailures > 0) { preconditionFailures -= 1; throw AccountException("Settings changed elsewhere.", 412) }
		if (revision != remote.revision) throw AccountException("Settings changed elsewhere.", 412)
		duringPut?.invoke()
		puts += settings
		remote = SettingsRevision(revision + 1, settings)
		return remote
	}
	override suspend fun logout(token: String) {}
	override suspend fun unlink(provider: String, token: String) {}
	override suspend fun deleteAccount(token: String) {}
}

private class TestVault(var token: String? = null, var pending: AndroidAuthPending? = null) : SessionVault {
	var pendingFailure: Exception? = null
	var clearPendingCalls = 0
	var pendingReads = 0
	override suspend fun load() = token
	override suspend fun save(token: String) { this.token = token }
	override suspend fun clear() { token = null; pending = null }
	override suspend fun loadPending(): AndroidAuthPending? {
		pendingReads += 1
		pendingFailure?.let { throw it }
		return pending
	}
	override suspend fun savePending(pending: AndroidAuthPending) { this.pending = pending }
	override suspend fun clearPending() { clearPendingCalls += 1; pending = null }
}

class AccountModelTest {
	private val harness = ModelHarness()
	private val server = ScriptedAccounts()
	private lateinit var model: AppModel
	private lateinit var accounts: AccountModel

	@After fun tearDown() = harness.close()

	private fun <T> onModel(block: suspend () -> T): T = harness.onModel(block)
	private fun waitFor(message: String, condition: () -> Boolean) = harness.waitFor(message, condition = condition)

	/** A signed-in device whose local settings and baseline are `local` at revision 1. */
	private fun signedIn(local: Settings, remote: Settings = local, baseline: Settings? = local, vault: TestVault = TestVault("token-1")) {
		runBlocking { harness.storage.store.saveAccepted(local, "602", baseline?.let { SyncBaseline(USER.id, 1, it) }) }
		server.remote = SettingsRevision(1, remote)
		model = harness.create()
		accounts = onModel { AccountModel(harness.scope, server, vault) { NOW } }
		harness.scope.launch { accounts.run(model) }
		waitFor("the account") { accounts.account != null }
	}

	private fun sync() = onModel { accounts.sync() }

	@Test fun remoteOnlyChangesAreAdoptedAndNeverUploadedBack() {
		val local = Settings(theme = "subway")
		signedIn(local, remote = local.copy(theme = "kuromi"))
		waitFor("the remote theme") { model.settings.theme == "kuromi" }
		sync()
		assertEquals("kuromi", model.settings.theme)
		assertTrue("A remote-only change must not be overwritten by the old local value", server.puts.none { it.theme == "subway" })
		assertEquals("kuromi", runBlocking { harness.storage.store.loadBaseline() }!!.settings.theme)
	}

	@Test fun independentLocalAndRemoteEditsBothSurvive() {
		val base = Settings()
		signedIn(base.copy(units = base.units.copy(time = "24h")), remote = base.copy(theme = "night"), baseline = base)
		waitFor("the merged result") { model.settings.theme == "night" && server.puts.isNotEmpty() }
		assertEquals("24h", model.settings.units.time)
		assertEquals("night", server.puts.last().theme)
		assertEquals("24h", server.puts.last().units.time)
	}

	@Test fun anEditDuringTheFetchIsKeptAndUploadedNext() {
		signedIn(Settings())
		waitFor("the first sync") { accounts.status == "Settings synced" }
		server.duringFetch = { model.setTimeFormat("24h"); server.duringFetch = null }
		sync()
		assertEquals("24h", model.settings.units.time)
		sync()
		assertEquals("24h", server.puts.last().units.time)
	}

	@Test fun anEditDuringTheUploadIsKept() {
		signedIn(Settings())
		waitFor("the first sync") { accounts.status == "Settings synced" }
		onModel { model.setTheme("night") }
		server.duringPut = { model.setTimeFormat("24h"); server.duringPut = null }
		sync()
		assertEquals("night", model.settings.theme)
		assertEquals("24h", model.settings.units.time)
		assertEquals("Changes waiting to sync", accounts.status)
	}

	@Test fun sameFieldEditsWaitForAnExplicitChoice() {
		val base = Settings()
		signedIn(base.copy(theme = "night"), remote = base.copy(theme = "kuromi"), baseline = base)
		waitFor("the conflict") { accounts.conflicts.isNotEmpty() }
		assertEquals(listOf("/theme"), accounts.conflicts.map { it.path })
		assertEquals("night", model.settings.theme)
		assertTrue(server.puts.isEmpty())
		onModel { accounts.choices = accounts.choices.select("remote", accounts.conflicts.single()) }
		onModel { accounts.resolve().join() }
		waitFor("the resolution") { accounts.conflicts.isEmpty() && model.settings.theme == "kuromi" }
	}

	@Test fun aSameFieldEditDuringAcceptedStorageWaitsForAChoice() {
		signedIn(Settings())
		waitFor("the first sync") { accounts.status == "Settings synced" }
		server.remote = SettingsRevision(2, Settings(theme = "kuromi"))
		val writing = CompletableDeferred<Unit>()
		val written = CompletableDeferred<Unit>()
		harness.storage.beforeAccepted = { writing.complete(Unit); written.await() }
		val syncing = harness.scope.launch { accounts.sync() }
		runBlocking { writing.await() }
		onModel { model.setTheme("night") }
		written.complete(Unit)
		runBlocking { syncing.join() }
		assertEquals("night", model.settings.theme)
		assertEquals(listOf("/theme"), accounts.conflicts.map { it.path })
		assertEquals("Choose which changes to keep", accounts.status)
		assertEquals("The common baseline stays durable until choices are made", "subway", runBlocking { harness.storage.store.loadBaseline() }!!.settings.theme)
		sync()
		assertTrue("No upload before the rider chooses", server.puts.isEmpty())
		onModel { accounts.choices = accounts.choices.select("remote", accounts.conflicts.single()) }
		onModel { accounts.resolve().join() }
		assertEquals("kuromi", model.settings.theme)
		assertTrue(accounts.conflicts.isEmpty())
	}

	@Test fun aLateConflictStillRequiresAChoiceAfterTheAccountOwnerIsRecreated() {
		signedIn(Settings())
		waitFor("the first sync") { accounts.status == "Settings synced" }
		server.remote = SettingsRevision(2, Settings(theme = "kuromi"))
		val writing = CompletableDeferred<Unit>()
		val written = CompletableDeferred<Unit>()
		harness.storage.beforeAccepted = { writing.complete(Unit); written.await() }
		val syncing = harness.scope.launch { accounts.sync() }
		runBlocking { writing.await() }
		onModel { model.setTheme("night") }
		written.complete(Unit)
		runBlocking { syncing.join() }
		val recreated = onModel { AccountModel(harness.scope, server, TestVault("token-1")) { NOW } }
		harness.scope.launch { recreated.run(model) }
		waitFor("the recreated account") { recreated.account != null && recreated.status != "Syncing…" }
		assertEquals(listOf("/theme"), recreated.conflicts.map { it.path })
		assertTrue("Recreation cannot upload an unresolved choice", server.puts.isEmpty())
	}

	@Test fun aFailedBaselineFollowUpCannotHideALateConflictFromARecreatedApp() {
		signedIn(Settings())
		waitFor("the first sync") { accounts.status == "Settings synced" }
		server.remote = SettingsRevision(2, Settings(theme = "kuromi"))
		val writing = CompletableDeferred<Unit>()
		val written = CompletableDeferred<Unit>()
		var accepts = 0
		harness.storage.beforeAccepted = {
			accepts += 1
			if (accepts == 1) { writing.complete(Unit); written.await() }
			else throw IOException("Injected failure after the first durable acceptance")
		}
		val syncing = harness.scope.launch { accounts.sync() }
		runBlocking { writing.await() }
		onModel { model.setTheme("night") }
		written.complete(Unit)
		runBlocking { syncing.join() }
		waitFor("the local edit to reach disk") { runBlocking { harness.storage.store.load() }.theme == "night" }
		harness.storage.beforeAccepted = null
		// Both owners are recreated from disk. Reusing the previous AppModel would hide a
		// durable-baseline bug behind its in-memory conflict draft.
		val recreatedApp = harness.create()
		val recreated = onModel { AccountModel(harness.scope, server, TestVault("token-1")) { NOW } }
		harness.scope.launch { recreated.run(recreatedApp) }
		waitFor("the recreated sync decision") { recreated.status in setOf("Settings synced", "Choose which changes to keep") }
		assertEquals("The disk snapshot must still require a choice", listOf("/theme"), recreated.conflicts.map { it.path })
		assertTrue("A failed follow-up must not turn an unresolved value into an upload", server.puts.isEmpty())
		assertEquals("subway", runBlocking { harness.storage.store.loadBaseline() }!!.settings.theme)
	}

	@Test fun unreadablePendingProofIsPreservedDuringRestoreAndCallbacks() {
		val proof = AndroidAuthPending("google", "login", "state", "verifier", "challenge", "https://example.invalid", NOW - 30)
		val vault = TestVault(pending = proof).apply { pendingFailure = IOException("temporarily locked") }
		accounts = onModel { AccountModel(harness.scope, server, vault) { NOW } }
		waitFor("the pending read") { vault.pendingReads > 0 }
		onModel { accounts.completeSignIn("nyc.juliet.subwaysfornerds://auth/android?state=state&handoff=h") }
		onModel { kotlinx.coroutines.yield() }
		assertEquals("Unreadable proof must not be cleared by restore or a callback", 0, vault.clearPendingCalls)
		assertEquals(proof, vault.pending)
		assertTrue(server.exchanged.isEmpty())
		assertTrue(accounts.error?.contains("preserved", ignoreCase = true) == true)
	}

	@Test fun aWarmCallbackAfterTheResumeGracePeriodStillUsesSavedProof() {
		val vault = TestVault(pending = AndroidAuthPending("google", "login", "state", "verifier", "challenge", "https://example.invalid", NOW - 30))
		accounts = onModel { AccountModel(harness.scope, server, vault, abandonAfterMillis = 50) { NOW } }
		waitFor("restored sign-in") { accounts.signingIn }
		onModel { accounts.activityResumed() }
		waitFor("buttons after resume") { !accounts.signingIn }
		onModel { accounts.completeSignIn("nyc.juliet.subwaysfornerds://auth/android?state=state&handoff=h") }
		onModel { kotlinx.coroutines.yield() }
		assertEquals("The delayed callback must still exchange the saved proof", 1, server.exchanged.size)
		assertEquals("token-1", vault.token)
	}

	@Test fun retryUnlockResumesTheCallbackWithoutDeletingItsProof() {
		val proof = AndroidAuthPending("google", "login", "state", "verifier", "challenge", "https://example.invalid", NOW - 30)
		val vault = TestVault(pending = proof).apply { pendingFailure = IOException("temporarily locked") }
		accounts = onModel { AccountModel(harness.scope, server, vault) { NOW } }
		waitFor("the preserved proof notice") { accounts.pendingUnreadable }
		onModel { accounts.completeSignIn("nyc.juliet.subwaysfornerds://auth/android?state=state&handoff=h") }
		onModel { accounts.retryPendingSignIn().join() }
		assertEquals(0, vault.clearPendingCalls)
		assertTrue(accounts.pendingUnreadable)
		vault.pendingFailure = null
		onModel { accounts.retryPendingSignIn().join() }
		waitFor("the recovered session") { accounts.account != null }
		assertEquals(proof, server.exchanged.single())
		assertEquals("token-1", vault.token)
		assertFalse(accounts.pendingUnreadable)
	}

	@Test fun onlyExplicitReplacementClearsUnreadableProofAndKeepsTheSession() {
		val proof = AndroidAuthPending("google", "login", "state", "verifier", "challenge", "https://example.invalid", NOW - 30)
		val vault = TestVault("token-1", proof).apply { pendingFailure = IOException("locked") }
		signedIn(Settings(), vault = vault)
		waitFor("the preserved proof notice") { accounts.pendingUnreadable }
		onModel { accounts.login("google") }
		assertTrue(server.started.isEmpty())
		assertEquals(proof, vault.pending)
		onModel { accounts.replacePendingSignIn().join() }
		assertEquals(1, vault.clearPendingCalls)
		assertNull(vault.pending)
		assertEquals("token-1", vault.token)
		assertFalse(accounts.pendingUnreadable)
	}

	@Test fun aStaleCallbackCannotDeleteTheExplicitlyReplacedSignIn() {
		val vault = TestVault(pending = AndroidAuthPending("google", "login", "old", "old-verifier", "challenge", "https://example.invalid", NOW - 30)).apply { pendingFailure = IOException("locked") }
		model = harness.create()
		accounts = onModel { AccountModel(harness.scope, server, vault) { NOW } }
		harness.scope.launch { accounts.run(model) }
		waitFor("configuration and preserved proof") { accounts.enabled && accounts.pendingUnreadable }
		onModel { accounts.replacePendingSignIn().join() }
		vault.pendingFailure = null
		onModel { accounts.login("google") }
		waitFor("replacement proof") { accounts.pendingSignInPage != null }
		val replacement = vault.pending
		server.exchange = { callback, _, _ ->
			if (callback.contains("state=old")) throw AccountException("Sign-in did not match this app.")
			AccountSession(USER, "csrf", "token-1")
		}
		onModel { accounts.completeSignIn("nyc.juliet.subwaysfornerds://auth/android?state=old&handoff=stale") }
		waitFor("the rejected stale callback") { accounts.error == "Sign-in did not match this app." }
		assertEquals("The current proof must survive a stale callback", replacement, vault.pending)
		onModel { accounts.completeSignIn("nyc.juliet.subwaysfornerds://auth/android?state=state&handoff=current") }
		waitFor("the current callback") { accounts.account != null }
		assertEquals("token-1", vault.token)
	}

	@Test fun anotherEditWhileSavingConflictChoicesRequiresAnotherChoice() {
		val base = Settings()
		signedIn(base.copy(theme = "night"), remote = base.copy(theme = "kuromi"), baseline = base)
		waitFor("the initial conflict") { accounts.conflicts.isNotEmpty() }
		onModel { accounts.choices = accounts.choices.select("remote", accounts.conflicts.single()) }
		val writing = CompletableDeferred<Unit>()
		val written = CompletableDeferred<Unit>()
		harness.storage.beforeAccepted = { writing.complete(Unit); written.await() }
		val resolving = onModel { accounts.resolve() }
		runBlocking { writing.await() }
		onModel { model.setTheme("hacker") }
		written.complete(Unit)
		runBlocking { resolving.join() }
		assertEquals(listOf("/theme"), accounts.conflicts.map { it.path })
		assertEquals("hacker", model.settings.theme)
		assertTrue(server.puts.isEmpty())
		onModel { accounts.choices = accounts.choices.select("remote", accounts.conflicts.single()) }
		onModel { accounts.resolve().join() }
		assertEquals("kuromi", model.settings.theme)
		assertTrue(accounts.conflicts.isEmpty())
	}

	@Test fun staleRevisionsRetry() {
		signedIn(Settings())
		waitFor("the first sync") { accounts.status == "Settings synced" }
		server.preconditionFailures = 1
		onModel { model.setTheme("hacker") }
		waitFor("the retried upload") { server.puts.any { it.theme == "hacker" } }
	}

	@Test fun syncWaitsForRestoredLocalSettings() {
		val saved = Settings(theme = "kuromi")
		runBlocking { harness.storage.store.saveAccepted(saved, "602", null) }
		server.remote = SettingsRevision(0, null)
		harness.storage.readDelayMillis = 400
		model = harness.create(waitForLoad = false)
		accounts = onModel { AccountModel(harness.scope, server, TestVault("token-1")) { NOW } }
		harness.scope.launch { accounts.run(model) }
		waitFor("the first upload") { server.puts.isNotEmpty() }
		assertEquals("kuromi", server.puts.first().theme)
	}

	@Test fun unreadableSettingsNeverSync() {
		harness.storage.failRead = IOException("damaged")
		server.remote = SettingsRevision(3, Settings(theme = "night"))
		model = harness.create()
		accounts = onModel { AccountModel(harness.scope, server, TestVault("token-1")) { NOW } }
		harness.scope.launch { accounts.run(model) }
		waitFor("the account") { accounts.account != null }
		sync()
		assertTrue(server.puts.isEmpty())
		assertNull(accounts.first)
		assertEquals("subway", model.settings.theme)
	}

	@Test fun signInSavesItsPendingStateBeforeOpeningTheBrowser() {
		val vault = TestVault()
		model = harness.create()
		accounts = onModel { AccountModel(harness.scope, server, vault) { NOW } }
		harness.scope.launch { accounts.run(model) }
		waitFor("configuration") { accounts.enabled }
		onModel { accounts.login("google") }
		waitFor("the browser page") { accounts.pendingSignInPage != null }
		assertEquals("state", vault.pending?.state)
		onModel { accounts.signInPageOpened() }
		onModel { accounts.completeSignIn("nyc.juliet.subwaysfornerds://auth/android?state=state&handoff=h") }
		waitFor("the session") { accounts.account != null }
		assertEquals("token-1", vault.token)
		assertNull(vault.pending)
		assertFalse(accounts.signingIn)
	}

	@Test fun aCallbackAfterProcessDeathFinishesFromTheSavedState() {
		val vault = TestVault(pending = AndroidAuthPending("google", "login", "state", "verifier", "challenge", "https://example.invalid", NOW - 30))
		model = harness.create()
		// A recreated owner receives the callback before restoration has finished.
		accounts = onModel { AccountModel(harness.scope, server, vault) { NOW }.also { it.completeSignIn("nyc.juliet.subwaysfornerds://auth/android?state=state&handoff=h") } }
		waitFor("the session") { accounts.account != null }
		assertEquals("verifier", server.exchanged.single().verifier)
		assertEquals("token-1", vault.token)
		assertNull(vault.pending)
	}

	@Test fun expiredPendingSignInsAreRejectedAndCleared() {
		val vault = TestVault(pending = AndroidAuthPending("google", "login", "state", "verifier", "challenge", "https://example.invalid", NOW - 400))
		model = harness.create()
		accounts = onModel { AccountModel(harness.scope, server, vault) { NOW } }
		onModel { accounts.completeSignIn("nyc.juliet.subwaysfornerds://auth/android?state=state&handoff=h") }
		waitFor("the expiry notice") { accounts.error == "Sign-in expired. Please try again." }
		assertTrue(server.exchanged.isEmpty())
		assertNull(vault.pending)
		assertNull(vault.token)
	}

	@Test fun onlyMatchingCancellationClearsProofWhileMismatchedCallbacksPreserveIt() {
		val vault = TestVault(pending = AndroidAuthPending("google", "login", "state", "verifier", "challenge", "https://example.invalid", NOW - 5))
		server.exchange = { _, _, _ -> throw AuthCancelledException() }
		model = harness.create()
		accounts = onModel { AccountModel(harness.scope, server, vault) { NOW } }
		onModel { accounts.completeSignIn("nyc.juliet.subwaysfornerds://auth/android?state=state&error=cancelled") }
		waitFor("the cancellation") { server.exchanged.isNotEmpty() && vault.pending == null }
		assertNull(accounts.error)
		assertNull(vault.token)

		vault.pending = AndroidAuthPending("google", "login", "other", "verifier", "challenge", "https://example.invalid", NOW - 5)
		server.exchange = { _, _, _ -> throw AccountException("Sign-in did not match this app.") }
		val second = onModel { AccountModel(harness.scope, server, vault) { NOW } }
		onModel { second.completeSignIn("nyc.juliet.subwaysfornerds://auth/android?state=state&handoff=h") }
		waitFor("the mismatch") { second.error == "Sign-in did not match this app." }
		assertEquals("other", vault.pending?.state)
		assertNull(vault.token)
	}

	/** A model whose abandoned-sign-in check runs quickly, started and waiting for its browser page. */
	private fun signingIn(vault: TestVault = TestVault()): AccountModel {
		model = harness.create()
		accounts = onModel { AccountModel(harness.scope, server, vault, abandonAfterMillis = 100) { NOW } }
		harness.scope.launch { accounts.run(model) }
		waitFor("configuration") { accounts.enabled }
		onModel { accounts.login("google") }
		waitFor("the browser page") { accounts.pendingSignInPage != null }
		return accounts
	}

	@Test fun closingTheSignInPageWithoutFinishingBringsTheButtonsBack() {
		val vault = TestVault()
		signingIn(vault)
		onModel { accounts.signInPageOpened() }
		// The rider closes the Custom Tab, and the activity resumes without a callback.
		onModel { accounts.activityResumed() }
		waitFor("the abandoned sign-in") { !accounts.signingIn }
		assertEquals("A return without a callback is not cancellation", "state", vault.pending?.state)
		assertTrue(server.exchanged.isEmpty())
	}

	@Test fun aResumeBeforeThePageOpensKeepsTheSignInGoing() {
		val vault = TestVault()
		signingIn(vault)
		onModel { accounts.activityResumed() }
		Thread.sleep(400)
		assertTrue(accounts.signingIn)
		assertEquals("state", vault.pending?.state)
		onModel { accounts.signInPageOpened(); accounts.completeSignIn("nyc.juliet.subwaysfornerds://auth/android?state=state&handoff=h") }
		waitFor("the session") { accounts.account != null }
		assertEquals("token-1", vault.token)
	}

	@Test fun aSlowCallbackIsNotAbandonedWhenTheAppResumes() {
		val vault = TestVault()
		val release = CompletableDeferred<Unit>()
		server.exchange = { _, _, _ -> release.await(); AccountSession(USER, "csrf", "token-1") }
		signingIn(vault)
		onModel { accounts.signInPageOpened() }
		// The callback arrives just before the activity resumes, and the exchange is still in flight.
		onModel { accounts.completeSignIn("nyc.juliet.subwaysfornerds://auth/android?state=state&handoff=h"); accounts.activityResumed() }
		Thread.sleep(400)
		assertTrue(accounts.signingIn)
		assertEquals("state", vault.pending?.state)
		release.complete(Unit)
		waitFor("the session") { accounts.account != null }
		assertEquals("token-1", vault.token)
		assertNull(vault.pending)
		assertFalse(accounts.signingIn)
	}

	@Test fun aRestoredSignInWithoutACallbackReleasesButtonsButKeepsItsProof() {
		val vault = TestVault(pending = AndroidAuthPending("google", "login", "state", "verifier", "challenge", "https://example.invalid", NOW - 30))
		model = harness.create()
		accounts = onModel { AccountModel(harness.scope, server, vault, abandonAfterMillis = 100) { NOW } }
		waitFor("the restored sign-in") { accounts.signingIn }
		// The app was reopened from the launcher instead of by the browser's callback.
		onModel { accounts.activityResumed() }
		waitFor("the abandoned sign-in") { !accounts.signingIn }
		assertEquals("state", vault.pending?.state)
		assertTrue(server.exchanged.isEmpty())
	}

	@Test fun linkingKeepsTheCurrentSession() {
		val vault = TestVault("token-1")
		signedIn(Settings(), vault = vault)
		server.exchange = { _, _, _ -> AccountSession(USER, "csrf", "token-2") }
		onModel { accounts.login("apple", "link") }
		waitFor("the browser page") { accounts.pendingSignInPage != null }
		assertEquals("link" to "token-1", server.started.last())
		onModel { accounts.signInPageOpened(); accounts.completeSignIn("nyc.juliet.subwaysfornerds://auth/android?state=state&handoff=h") }
		waitFor("the link") { !accounts.signingIn }
		assertEquals("token-1", vault.token)
	}
}
