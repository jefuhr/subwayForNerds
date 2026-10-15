package nyc.juliet.subwaysfornerds.ui.account

import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonElement
import nyc.juliet.subwaysfornerds.core.Account
import nyc.juliet.subwaysfornerds.core.AccountException
import nyc.juliet.subwaysfornerds.core.AccountSync
import nyc.juliet.subwaysfornerds.core.AccountSyncBaseline
import nyc.juliet.subwaysfornerds.core.AndroidAuthPending
import nyc.juliet.subwaysfornerds.core.AuthCancelledException
import nyc.juliet.subwaysfornerds.core.Settings
import nyc.juliet.subwaysfornerds.core.SettingsConflict
import nyc.juliet.subwaysfornerds.core.SettingsConflictDraft
import nyc.juliet.subwaysfornerds.core.SettingsRevision
import nyc.juliet.subwaysfornerds.core.SyncDraftChangedException
import nyc.juliet.subwaysfornerds.data.SyncBaseline
import nyc.juliet.subwaysfornerds.ui.AppModel
import nyc.juliet.subwaysfornerds.ui.data.AccountService

/** A selection belongs to the exact pair of values presented to the rider. */
data class ConflictChoices(private val selections: Map<String, Selection> = emptyMap()) {
	data class Selection(val value: String, val local: JsonElement?, val remote: JsonElement?)

	fun selection(conflict: SettingsConflict): String {
		val saved = selections[conflict.path] ?: return ""
		return if (saved.local == conflict.local && saved.remote == conflict.remote) saved.value else ""
	}

	fun select(value: String, conflict: SettingsConflict): ConflictChoices =
		if (!isExplicit(value)) ConflictChoices(selections - conflict.path)
		else ConflictChoices(selections + (conflict.path to Selection(value, conflict.local, conflict.remote)))

	fun resolved(conflicts: List<SettingsConflict>): Map<String, String>? {
		val result = mutableMapOf<String, String>()
		for (conflict in conflicts) {
			val value = selection(conflict)
			if (!isExplicit(value)) return null
			result[conflict.path] = value
		}
		return result
	}

	companion object {
		fun isExplicit(value: String?): Boolean = value == "local" || value == "remote"
	}
}

/** The saved session and pending browser sign-in, encrypted on this device and never part of settings or exports. */
interface SessionVault {
	suspend fun load(): String?
	suspend fun save(token: String)
	/** Removes the session and any pending sign-in. */
	suspend fun clear()
	suspend fun loadPending(): AndroidAuthPending?
	suspend fun savePending(pending: AndroidAuthPending)
	suspend fun clearPending()
}

/** A pending browser sign-in is valid for 390 seconds, matching the server's single-use handoff. */
const val PENDING_SIGN_IN_SECONDS = 390.0

/**
 * Optional accounts, ported from the iOS AccountModel with core's AccountSync decisions.
 * Settings save locally first; edits sync after one second, on reconnect, and every
 * 30 seconds while the app is open. Three-way conflicts wait for the rider's explicit choice.
 * Nothing syncs until this device's saved settings are restored, and never from unreadable settings.
 */
@Stable
class AccountModel(
	private val scope: CoroutineScope,
	private val service: AccountService,
	private val vault: SessionVault,
	/** How long after the app resumes a sign-in with no callback counts as abandoned in the browser. */
	private val abandonAfterMillis: Long = 1500,
	private val clock: () -> Double = { System.currentTimeMillis() / 1000.0 },
) {
	var enabled by mutableStateOf(false); private set
	var ready by mutableStateOf(false); private set
	var account by mutableStateOf<Account?>(null); private set
	var status by mutableStateOf("Not signed in"); private set
	var error by mutableStateOf<String?>(null); private set
	/** Joining an account whose settings differ from this device's: the rider chooses first. */
	var first by mutableStateOf<SettingsRevision?>(null); private set
	var conflicts by mutableStateOf<List<SettingsConflict>>(emptyList()); private set
	var choices by mutableStateOf(ConflictChoices())
	var signingIn by mutableStateOf(false); private set
	/** The encrypted proof stays on disk until it can be read or the rider explicitly replaces it. */
	var pendingUnreadable by mutableStateOf(false); private set
	/** A Custom Tab page waiting to be opened by the activity. */
	var pendingSignInPage by mutableStateOf<String?>(null); private set
	val providers: List<String> = listOf("apple", "google")

	private var app: AppModel? = null
	private var token: String? = null
	/** The saved session could not be unlocked; a new sign-in replaces it explicitly. */
	private var tokenUnreadable = false
	private var pending: AndroidAuthPending? = null
	private var callbackAwaitingUnlock: String? = null
	/** The browser page was shown, or the sign-in was restored after Android recreated the app. */
	private var awaitingCallback = false
	private var callbacksInFlight = 0
	private var abandonCheck: Job? = null
	private val restored = CompletableDeferred<Unit>()
	private var generation = 0
	private var syncing = false
	private var debounce: Job? = null
	private var lastObserved: Settings? = null
	private var draft: SettingsConflictDraft? = null
	/** The actual account snapshot, when a later conflict draft also includes already-chosen local values. */
	private var draftBaseline: SettingsRevision? = null

	init { scope.launch { restore() } }

	/** Restores the session and any pending sign-in, so a callback after process death can finish. */
	private suspend fun restore() {
		try {
			token = try { vault.load() } catch (failure: CancellationException) { throw failure } catch (_: Exception) {
				tokenUnreadable = true
				status = "Sign in again to sync. Your saved session could not be unlocked."
				null
			}
			restorePending()
		} finally { restored.complete(Unit) }
	}

	private suspend fun restorePending() {
		try {
			val saved = vault.loadPending()
			if (saved != null && expired(saved)) vault.clearPending()
			pending = saved?.takeUnless(::expired)
			pendingUnreadable = false
			signingIn = pending != null
			awaitingCallback = pending != null
			if (error == PENDING_PROOF_UNAVAILABLE) error = null
		} catch (failure: CancellationException) { throw failure }
		catch (_: Exception) {
			pendingUnreadable = true
			signingIn = false
			error = PENDING_PROOF_UNAVAILABLE
		}
	}

	/** Retrying only reads the preserved proof. A callback received while locked resumes after unlock. */
	fun retryPendingSignIn() = scope.launch {
		restored.await()
		restorePending()
		if (pendingUnreadable) return@launch
		val callback = callbackAwaitingUnlock
		callbackAwaitingUnlock = null
		if (callback != null) completeSignIn(callback)
		else pending?.let { pendingSignInPage = it.authorizationURL }
	}

	/** Called only after the replacement confirmation. The session and settings are not removed. */
	fun replacePendingSignIn() = scope.launch {
		restored.await()
		try {
			vault.clearPending()
			pending = null; callbackAwaitingUnlock = null; pendingSignInPage = null
			pendingUnreadable = false; signingIn = false; awaitingCallback = false
			error = null
		} catch (failure: CancellationException) { throw failure }
		catch (_: Exception) { error = "The pending sign-in could not be replaced. It has been preserved. Try again after unlocking your device." }
	}

	private fun expired(value: AndroidAuthPending): Boolean {
		val now = clock()
		return !value.createdAt.isFinite() || value.createdAt > now || now - value.createdAt > PENDING_SIGN_IN_SECONDS
	}

	suspend fun run(app: AppModel) {
		this.app = app
		restored.await()
		// Local settings, station and baseline must be restored before any preview, upload or baseline decision.
		app.awaitLoaded()
		lastObserved = app.settings
		app.settingsDidChange = { changed() }
		refreshAccount()
		while (true) {
			sync()
			delay(30_000)
		}
	}

	suspend fun reconnect() { refreshAccount(); sync() }

	private suspend fun refreshAccount() {
		val runGeneration = generation
		restored.await()
		try {
			val config = service.config()
			if (runGeneration != generation) return
			enabled = config.enabled
			ready = true
			if (!enabled) return
			val current = token ?: return
			val value = service.account(current).account
			if (runGeneration == generation) account = value
		} catch (failure: CancellationException) { throw failure }
		catch (failure: Exception) {
			if (runGeneration != generation) return
			ready = true
			if ((failure as? AccountException)?.status == 401) invalidateSession()
			else error = "Account service unavailable. Settings are saved on this device."
		}
	}

	fun changed() {
		val app = app ?: return
		if (account == null || lastObserved == app.settings) return
		lastObserved = app.settings
		status = "Changes waiting to sync"
		debounce?.cancel()
		debounce = scope.launch { delay(1000); sync() }
	}

	/**
	 * Starts a sign-in, link or re-verification. The PKCE state is saved, encrypted, before the
	 * activity opens the page, so the callback can complete even if Android recreates the app.
	 */
	fun login(provider: String, intent: String = "login") {
		if (!enabled || signingIn || pendingUnreadable) return
		signingIn = true
		awaitingCallback = false
		generation += 1
		scope.launch {
			try {
				restored.await()
				if (intent != "login" && token == null) throw AccountException("Sign in again to verify this account.", 401)
				val started = service.startAndroid(provider, intent, if (intent == "login") null else token)
				vault.savePending(started)
				pending = started
				pendingSignInPage = started.authorizationURL
				error = null
			} catch (failure: CancellationException) { throw failure }
			catch (failure: Exception) { error = failure.message ?: "Sign-in could not start. Please try again."; signingIn = false }
		}
	}

	fun signInPageOpened() { pendingSignInPage = null; awaitingCallback = true }

	/**
	 * The activity resumed. If a sign-in is still waiting for its browser callback shortly afterwards,
	 * with no callback being exchanged, the rider gets the sign-in buttons back. Resume is not proof
	 * of cancellation: Android may deliver a warm callback later, so its valid proof stays preserved.
	 */
	fun activityResumed() {
		abandonCheck?.cancel()
		abandonCheck = scope.launch {
			restored.await()
			delay(abandonAfterMillis)
			if (!signingIn || !awaitingCallback || callbacksInFlight > 0) return@launch
			signingIn = false
			awaitingCallback = false
		}
	}

	/**
	 * The callback `nyc.juliet.subwaysfornerds://auth/android?...` arrived. A callback that arrives
	 * before restoration finishes waits for it. Links and re-verification keep the current session.
	 */
	fun completeSignIn(callback: String) {
		// Counted before launching, so a resume right after the callback never abandons it.
		callbacksInFlight += 1
		scope.launch {
			try { exchange(callback) } finally { callbacksInFlight -= 1 }
		}
	}

	private suspend fun exchange(callback: String) {
		restored.await()
		if (pendingUnreadable) {
			callbackAwaitingUnlock = callback
			error = PENDING_PROOF_UNAVAILABLE
			return
		}
		val started = pending
		if (started == null || expired(started)) {
			pending = null
			runCatching { vault.clearPending() }
			error = "Sign-in expired. Please try again."
			signingIn = false
			awaitingCallback = false
			return
		}
		signingIn = true
		try {
			val session = service.exchangeAndroid(callback, started, if (started.intent == "login") null else token)
			if (pending != started) return
			if (started.intent == "login") {
				val newToken = session.token?.takeIf { it.isNotEmpty() } ?: throw AccountException("Sign-in returned incomplete account information.")
				if (tokenUnreadable) { vault.clear(); tokenUnreadable = false }
				vault.save(newToken)
				token = newToken
			} else {
				val current = account
				if (current != null && current.id != session.account.id) throw AccountException("Your account changed during sign-in. Please try again.")
			}
			runCatching { vault.clearPending() }
			pending = null
			generation += 1
			account = session.account
			error = null; first = null; conflicts = emptyList(); draft = null; draftBaseline = null
			signingIn = false
			awaitingCallback = false
			sync()
		} catch (failure: CancellationException) { throw failure }
		catch (_: AuthCancelledException) { finishFailedSignIn(started, null, cancelled = true) }
		catch (failure: Exception) { finishFailedSignIn(started, failure.message ?: "Sign-in did not complete. Please try again.") }
	}

	private suspend fun finishFailedSignIn(started: AndroidAuthPending, message: String?, cancelled: Boolean = false) {
		if (pending != started) return
		// Only a state-validated cancellation consumes proof. A stale or malformed callback (or
		// a transient exchange error) must not destroy the current sign-in's still-valid proof.
		if (cancelled) {
			try { vault.clearPending(); pending = null }
			catch (failure: CancellationException) { throw failure }
			catch (_: Exception) { error = "The cancelled sign-in could not be removed. Its proof has been preserved."; signingIn = false; awaitingCallback = false; return }
		}
		error = message
		signingIn = false
		awaitingCallback = false
	}

	fun logout() = scope.launch {
		val current = token
		try { if (current != null) service.logout(current); disconnect() }
		catch (failure: CancellationException) { throw failure }
		catch (failure: Exception) {
			if ((failure as? AccountException)?.status == 401) runCatching { disconnect() }.onFailure { error = it.message }
			else error = failure.message
		}
	}

	/** Deletes the account, or unlinks one provider when `provider` is given. */
	fun remove(provider: String? = null) = scope.launch {
		val current = token ?: return@launch
		try {
			if (provider == null) service.deleteAccount(current) else service.unlink(provider, current)
			disconnect()
		} catch (failure: CancellationException) { throw failure }
		catch (failure: Exception) { error = failure.message }
	}

	private suspend fun disconnect() {
		vault.clear(); token = null; tokenUnreadable = false; pending = null; generation += 1; debounce?.cancel()
		account = null; first = null; conflicts = emptyList(); draft = null; draftBaseline = null
		status = "Not signed in"; error = null
		app?.let { model -> model.acceptSettings(sync = null) { it } }
	}

	private suspend fun invalidateSession() {
		if (!pendingUnreadable) runCatching { vault.clear() }
		token = null; account = null; generation += 1
		status = "Sign in again to sync. Changes are saved on this device."
	}

	fun chooseInitial(remote: Boolean) = scope.launch {
		val start = first ?: return@launch
		val settings = start.settings ?: return@launch
		val account = account ?: return@launch
		val app = app ?: return@launch
		var before = app.settings
		var chosen = app.settings
		val priorBaseline = app.syncBaseline
		try {
			app.acceptSettings(sync = priorBaseline) { local ->
				before = local
				(if (remote) settings else local).also { chosen = it }
			}
			first = null; error = null
			if (showLateConflicts(before, chosen, start)) return@launch
			advanceBaseline(account.id, start)
			sync()
		} catch (failure: CancellationException) { throw failure }
		catch (failure: Exception) { error = failure.message }
	}

	/** Applies the rider's explicit choices against the exact account revision they were made for. */
	fun resolve() = scope.launch {
		val resolved = choices.resolved(conflicts) ?: return@launch
		val pendingDraft = draft ?: return@launch
		val account = account ?: return@launch
		val app = app ?: return@launch
		val actualRemote = draftBaseline ?: pendingDraft.remote
		if (actualRemote.settings == null) return@launch
		var remaining = emptyList<SettingsConflict>()
		var before = app.settings
		var chosen = app.settings
		val priorBaseline = app.syncBaseline
		try {
			app.acceptSettings(sync = priorBaseline) { local ->
				before = local
				val merged = AccountSync.resolve(pendingDraft, local, pendingDraft.remote, resolved)
				remaining = merged.conflicts
				if (merged.conflicts.isNotEmpty()) throw UnresolvedConflicts()
				merged.settings.also { chosen = it }
			}
			choices = ConflictChoices()
			error = null
			if (showLateConflicts(before, chosen, actualRemote)) return@launch
			advanceBaseline(account.id, actualRemote)
			conflicts = emptyList(); draft = null; draftBaseline = null
			sync()
		} catch (failure: CancellationException) { throw failure }
		catch (_: UnresolvedConflicts) { conflicts = remaining }
		catch (failure: SyncDraftChangedException) {
			choices = ConflictChoices()
			// Keep unresolved conflicts when another local field changed while the choices were open.
			// The accepted remote baseline alone cannot reconstruct a late storage-time conflict.
			val refreshed = AccountSync.rebase(pendingDraft.base, app.settings, pendingDraft.remote)
			draft = pendingDraft.copy(local = app.settings)
			conflicts = refreshed.conflicts; error = failure.message
			if (conflicts.isEmpty()) { draft = null; draftBaseline = null; sync() }
			else status = "Choose which changes to keep"
		}
		catch (failure: Exception) { error = failure.message }
	}

	private class UnresolvedConflicts : Exception()

	/** A second edit while choices are saved needs fresh choices, without losing earlier decisions. */
	private fun showLateConflicts(before: Settings, chosen: Settings, actualRemote: SettingsRevision): Boolean {
		val app = app ?: return false
		val local = app.settings
		val accepted = actualRemote.copy(settings = chosen)
		val late = AccountSync.rebase(before, local, accepted).conflicts
		if (late.isEmpty()) return false
		draft = SettingsConflictDraft(before, local, accepted)
		draftBaseline = actualRemote
		conflicts = late; choices = ConflictChoices()
		status = "Choose which changes to keep"
		// The first acceptance retained the previous baseline. No rollback is needed: even if
		// the process ends here, a new owner rediscovers this conflict from the durable snapshot.
		lastObserved = app.settings
		return true
	}

	/**
	 * Advance only after the accepted values are published and late edits have been checked.
	 * A failure here leaves the previous baseline intact and safely repeats that check next time.
	 * Edits during this second write follow the already-published acceptance and remain local edits.
	 */
	private suspend fun advanceBaseline(userID: String, revision: SettingsRevision) {
		val app = app ?: return
		val settings = revision.settings ?: return
		val next = SyncBaseline(userID, revision.revision, settings)
		if (app.syncBaseline != next) app.acceptSettings(sync = next) { it }
	}

	suspend fun sync() {
		val account = account ?: return
		val app = app ?: return
		val current = token ?: return
		if (!app.loaded || app.settingsUnreadable) return
		if (syncing || signingIn || first != null || conflicts.isNotEmpty()) return
		if (!app.connected) { status = "Offline — changes saved on this device"; return }
		syncing = true
		val requestGeneration = generation
		try {
			status = "Syncing…"; error = null
			// The local settings this sync starts from. Edits made while it runs are rebased onto the result.
			val local = app.settings
			val priorBaseline = app.syncBaseline
			val baseline = app.syncBaseline?.let { AccountSyncBaseline(it.userID, it.revision, it.settings) }
			val remote = service.settings(current)
			if (requestGeneration != generation) return
			val preview = AccountSync.preview(account.id, local, baseline, remote)
			if (preview.requiresInitialChoice) { first = remote; status = "Choose settings to start syncing"; return }
			if (preview.conflicts.isNotEmpty()) {
				draft = SettingsConflictDraft(baseline?.settings ?: local, local, remote)
				draftBaseline = null
				conflicts = preview.conflicts; status = "Choose which changes to keep"; return
			}
			val accepted = if (preview.needsUpload) service.putSettings(current, preview.settings, remote.revision) else remote
			if (requestGeneration != generation) return
			val acceptedRevision = accepted.copy(settings = accepted.settings ?: preview.settings)
			val acceptedSettings = acceptedRevision.settings!!
			// Keep the prior common baseline through the first durable write. Advancing it before
			// detecting storage-time conflicts would make a failed rollback or process exit unsafe.
			app.acceptSettings(sync = priorBaseline) { now ->
				AccountSync.rebase(local, now, acceptedRevision).settings
			}
			// Acceptance itself suspends for storage. Include edits made in that window before
			// another sync can upload the retained local value over the account's conflicting choice.
			lastObserved = app.settings
			if (!showLateConflicts(local, acceptedSettings, acceptedRevision)) {
				advanceBaseline(account.id, acceptedRevision)
				lastObserved = app.settings
				status = if (app.settings == acceptedSettings) "Settings synced" else "Changes waiting to sync"
			}
		} catch (failure: CancellationException) { throw failure }
		catch (failure: Exception) {
			if (requestGeneration != generation) return
			when ((failure as? AccountException)?.status) {
				401 -> invalidateSession()
				412 -> {
					status = "New account changes — retrying…"
					debounce?.cancel(); debounce = scope.launch { delay(1000); sync() }
				}
				409 -> { status = "Changes saved on this device"; error = failure.message ?: "Update this app before syncing. Your account settings are unchanged." }
				else -> { status = "Changes saved on this device"; error = failure.message }
			}
		} finally { syncing = false }
	}

	private companion object {
		const val PENDING_PROOF_UNAVAILABLE = "Pending sign-in could not be unlocked. It has been preserved. Unlock your device and retry, or explicitly replace the pending sign-in."
	}
}
