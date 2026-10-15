package nyc.juliet.subwaysfornerds.data

import android.content.Context
import java.io.File
import java.io.IOException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import nyc.juliet.subwaysfornerds.core.NerdsCodec
import nyc.juliet.subwaysfornerds.core.AccountSyncBaseline
import nyc.juliet.subwaysfornerds.core.PRODUCTION_API_BASE
import nyc.juliet.subwaysfornerds.core.Settings
import nyc.juliet.subwaysfornerds.core.TransitJson
import okhttp3.HttpUrl.Companion.toHttpUrl

typealias SyncBaseline = AccountSyncBaseline
data class LocalSettingsSnapshot(val settings: Settings, val lastStation: String, val apiBase: String, val recent: List<String>, val baseline: SyncBaseline?)

@Serializable
private data class SettingsDocument(
	val version: Int = 1,
	val settings: Settings = Settings(),
	val lastStation: String = "602",
	val recent: List<String> = emptyList(),
	val apiBase: String = PRODUCTION_API_BASE,
	val baseline: SyncBaseline? = null,
)

/** Portable settings may be backed up; credentials, rides and location never live here. */
class AndroidSettingsStore internal constructor(directory: File, private val beforeActivate: () -> Unit = {}) {
	constructor(context: Context) : this(File(context.applicationContext.filesDir, "settings-v1"))
	private val storage = AtomicStorage(directory)

	suspend fun load(): Settings = read { it.settings }
	suspend fun lastStation(): String = read { it.lastStation }
	suspend fun recentStations(): List<String> = read { it.recent }
	suspend fun apiBase(): String = read { it.apiBase }
	suspend fun loadBaseline(): SyncBaseline? = read { it.baseline }
	suspend fun snapshot(): LocalSettingsSnapshot = withContext(Dispatchers.IO) { snapshotBlocking() }
	/** Runtime activation guards use this only on Dispatchers.IO without awaiting other work. */
	internal fun snapshotBlocking(): LocalSettingsSnapshot = storage.locked { loadDocument().let { LocalSettingsSnapshot(it.settings, it.lastStation, it.apiBase, it.recent, it.baseline) } }

	suspend fun save(settings: Settings) { val valid = NerdsCodec.validate(settings); update { it.copy(settings = valid) } }
	suspend fun saveLastStation(id: String) {
		requireIdentifier(id)
		update { it.copy(lastStation = id, recent = (listOf(id) + it.recent).distinct().take(32)) }
	}
	suspend fun saveApiBase(base: String) {
		val url = base.toHttpUrl()
		require(url.username.isEmpty() && url.password.isEmpty() && url.fragment == null)
		require(url.isHttps || url.host in setOf("localhost", "127.0.0.1", "::1", "10.0.2.2"))
		update { it.copy(apiBase = url.toString().let { value -> if (value.endsWith('/')) value else "$value/" }) }
	}
	suspend fun saveBaseline(value: SyncBaseline) {
		requireIdentifier(value.userID); require(value.revision >= 0)
		update { it.copy(baseline = value.copy(settings = NerdsCodec.validate(value.settings))) }
	}
	suspend fun clearBaseline() { update { it.copy(baseline = null) } }
	/** Account acceptance/import publishes settings, station and baseline in one activation. */
	suspend fun saveAccepted(settings: Settings, lastStation: String, baseline: SyncBaseline?, replaceUnreadable: Boolean = false) = withContext(Dispatchers.IO) {
		val valid = NerdsCodec.validate(settings); requireIdentifier(lastStation)
		val validBaseline = baseline?.let { value -> requireIdentifier(value.userID); require(value.revision >= 0); value.copy(settings = NerdsCodec.validate(value.settings)) }
		storage.locked {
			val current = try { loadDocument() } catch (error: IOException) { if (!replaceUnreadable) throw error else SettingsDocument() }
			persist(current.copy(settings = valid, lastStation = lastStation, baseline = validBaseline, recent = (listOf(lastStation) + current.recent).distinct().take(32)))
		}
	}
	/** Explicit user import is the only path that may replace an unreadable settings record. */
	suspend fun replaceFromImport(settings: Settings, lastStation: String) = withContext(Dispatchers.IO) {
		val valid = NerdsCodec.validate(settings); requireIdentifier(lastStation)
		storage.locked {
			val current = try { loadDocument() } catch (_: IOException) { SettingsDocument() }
			val next = current.copy(settings = valid, lastStation = lastStation)
			persist(next)
		}
	}

	private suspend fun <T> read(block: (SettingsDocument) -> T): T = withContext(Dispatchers.IO) {
		storage.locked { block(loadDocument()) }
	}
	private suspend fun update(block: (SettingsDocument) -> SettingsDocument) = withContext(Dispatchers.IO) {
		storage.locked {
			val next = block(loadDocument())
			persist(next)
		}
	}
	private fun persist(next: SettingsDocument) {
		val bytes = TransitJson.encodeToString(next).toByteArray()
		if (bytes.size > 4 * 1_048_576) throw IOException("Saved settings exceed their supported size.")
		storage.write("state.json", bytes, beforeActivate)
		// Primary activation is authoritative. A redundant copy is recovery only.
		try { storage.write("state.backup", bytes) } catch (_: IOException) { }
	}
	private fun loadDocument(): SettingsDocument {
		fun decode(name: String): SettingsDocument? = storage.read(name, 4L * 1_048_576)?.let { bytes ->
			val value = TransitJson.decodeFromString<SettingsDocument>(bytes.decodeToString(throwOnInvalidSequence = true))
			if (value.version != 1) throw IOException("Saved settings need a newer app version.")
			NerdsCodec.validate(value.settings)
			value.baseline?.let { requireIdentifier(it.userID); require(it.revision >= 0); NerdsCodec.validate(it.settings) }
			value
		}
		return try { decode("state.json") ?: decode("state.backup") ?: SettingsDocument() }
		catch (error: Exception) {
			try { decode("state.backup") ?: throw error } catch (_: Exception) { throw IOException("Saved settings could not be read. They have been preserved.", error) }
		}
	}
	private fun requireIdentifier(value: String) { require(value.isNotBlank() && value.length <= 128 && value.none { it.code < 32 }) }
}
