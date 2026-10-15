package nyc.juliet.subwaysfornerds.core

import kotlinx.serialization.Serializable

@Serializable data class AccountSyncBaseline(val userID: String, val revision: Long, val settings: Settings)
data class AccountSyncPreview(val settings: Settings, val conflicts: List<SettingsConflict>, val expectedRevision: Long, val requiresInitialChoice: Boolean, val needsUpload: Boolean)
data class SettingsConflictDraft(val base: Settings, val local: Settings, val remote: SettingsRevision)
class SyncDraftChangedException : IllegalStateException("Settings changed while choosing conflicts. Review the current changes before syncing.")

/** Produces decisions only; callers own atomic device storage and conditional account writes. */
object AccountSync {
	fun preview(userID: String, local: Settings, baseline: AccountSyncBaseline?, remote: SettingsRevision, choices: Map<String, String> = emptyMap()): AccountSyncPreview {
		if (remote.revision < 0) throw IllegalArgumentException("Invalid account revision")
		val device = NerdsCodec.validate(local); val server = remote.settings?.let(NerdsCodec::validate)
		val prior = baseline?.takeIf { it.userID == userID }
		if (prior != null && prior.revision > remote.revision) throw IllegalStateException("Account revision moved backwards. Reload before syncing.")
		if (prior == null && server != null && device != server) return AccountSyncPreview(device, emptyList(), remote.revision, true, false)
		val merged = if (prior != null && server != null) SettingsMerge.merge(prior.settings, device, server, choices) else SettingsMergeResult(device, emptyList())
		return AccountSyncPreview(merged.settings, merged.conflicts, remote.revision, false, merged.conflicts.isEmpty() && merged.settings != server)
	}
	fun resolve(draft: SettingsConflictDraft, currentLocal: Settings, currentRemote: SettingsRevision, choices: Map<String, String>): SettingsMergeResult {
		if (NerdsCodec.validate(draft.local) != NerdsCodec.validate(currentLocal) || draft.remote.revision != currentRemote.revision || draft.remote.settings?.let(NerdsCodec::validate) != currentRemote.settings?.let(NerdsCodec::validate)) throw SyncDraftChangedException()
		return SettingsMerge.merge(draft.base, currentLocal, currentRemote.settings ?: throw SyncDraftChangedException(), choices)
	}
	fun rebase(sent: Settings, currentLocal: Settings, accepted: SettingsRevision): SettingsMergeResult = SettingsMerge.merge(sent, currentLocal, accepted.settings ?: throw IllegalArgumentException("Accepted account settings are missing"))
}
