package nyc.juliet.subwaysfornerds.fleet

import android.content.Context
import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import nyc.juliet.subwaysfornerds.core.*
import okhttp3.*
import okhttp3.HttpUrl.Companion.toHttpUrl

enum class FleetDownloadStage(val label: String) {
	PREPARING("Preparing fleet pack"), DOWNLOADING("Downloading fleet archive"), VERIFYING("Verifying download"),
	IMPORTING("Importing saved fleet"), CHECKING("Checking saved fleet"), ACTIVATING("Saving fleet download"),
}
data class FleetDownloadProgress(
	val stage: FleetDownloadStage,
	val completedBytes: Long = 0,
	val totalBytes: Long? = null,
	val detail: String? = null,
	val completedRecords: Long? = null,
	val totalRecords: Long? = null,
) {
	val label: String get() = detail ?: stage.label
	/** The percentage describes this measured stage only. Unknown totals stay unknown. */
	val fraction: Double? get() = totalBytes?.takeIf { it > 0 }?.let { (completedBytes.toDouble() / it).coerceIn(0.0, 1.0) }
		?: totalRecords?.takeIf { it > 0 }?.let { total -> completedRecords?.let { (it.toDouble() / total).coerceIn(0.0, 1.0) } }
}
data class FleetStoreStatus(val manifest: FleetOfflineManifest?, val downloadInProgress: Boolean, val progress: FleetDownloadProgress?, val storageBytes: Long)
@Serializable private data class SavedFleet(val version: Int = 1, val manifest: FleetOfflineManifest, val fileName: String)

/** Explicit coroutine-bound updates. Nothing starts a service or background download. */
class OfflineFleetStore internal constructor(private val directory: File, private val availableBytes: () -> Long = { directory.usableSpace }) {
	constructor(context: Context) : this(File(context.applicationContext.noBackupFilesDir, "fleet-v1"))
	private class Shared {
		val update = Mutex(); val state = ReentrantLock(); var initialized = false; var generation = 0L
		var foreground = true; var updateJob: Job? = null
		val progress = MutableStateFlow<FleetDownloadProgress?>(null)
	}
	private val shared = stores.computeIfAbsent(directory.canonicalPath) { Shared() }
	val progress: StateFlow<FleetDownloadProgress?> = shared.progress
	init { shared.state.withLock { if (!shared.update.isLocked) shared.initialized = false } }
	/** UX calls this on app lifecycle changes; downloads have no background execution grant. */
	fun setForeground(value: Boolean) = shared.state.withLock {
		shared.foreground = value
		if (!value) shared.updateJob?.cancel(CancellationException("Keep the app open while saving the fleet."))
	}

	suspend fun manifest(): FleetOfflineManifest? = withContext(Dispatchers.IO) { shared.state.withLock { initialize(); saved()?.manifest } }
	suspend fun status(): FleetStoreStatus = withContext(Dispatchers.IO) {
		shared.state.withLock { initialize(); val active = saved(); FleetStoreStatus(active?.manifest, shared.update.isLocked, shared.progress.value, active?.let { File(directory, it.fileName).length() } ?: 0) }
	}

	suspend fun download(manifest: FleetOfflineManifest, apiBase: String = PRODUCTION_API_BASE, progress: (FleetDownloadProgress) -> Unit = {}) {
		validate(manifest)
		performUpdate(progress) { token, check, emit ->
			val bytes = manifest.downloadByteLength
			requireSpace(safeAdd(bytes, manifest.byteLength))
			val archive = downloadArchive(downloadURL(manifest.downloadURL, apiBase), bytes, check, emit)
			try { installLegacy(archive, manifest, token, check, emit) } finally { archive.delete() }
		}
	}
	suspend fun download(pack: FleetPackManifest, apiBase: String = PRODUCTION_API_BASE, progress: (FleetDownloadProgress) -> Unit = {}) {
		validate(pack)
		performUpdate(progress) { token, check, emit ->
			requireSpace(safeAdd(pack.archiveByteLength, safeAdd(pack.estimatedSavedByteLength, pack.estimatedSavedByteLength)))
			val archive = downloadArchive(downloadURL(pack.downloadURL, apiBase), pack.archiveByteLength, check, emit)
			try { installPack(archive, pack, token, check, emit) } finally { archive.delete() }
		}
	}
	suspend fun prepareAndDownload(selection: FleetPackSelection, client: TransitClient, apiBase: String = client.baseUrl, progress: (FleetDownloadProgress) -> Unit = {}) {
		if (!selection.isValid) throw FleetValidationException("Choose a supported fleet scope and 7 or 30 days of history.")
		performUpdate(progress) { token, check, emit ->
			// Preparation is also bound to the caller, never scheduled in WorkManager.
			val pack = try { withTimeout(15 * 60 * 1000L) {
				var job = client.prepareFleetPack(selection)
				while (job.state != "ready") {
					check()
					val measured = job.progress
					val done = measured?.done?.takeIf { it >= 0 }
					val total = measured?.total?.takeIf { it > 0 && done != null && done <= it }
					val label = measured?.label ?: FleetDownloadStage.PREPARING.label
					emit(FleetDownloadProgress(FleetDownloadStage.PREPARING, detail = if (total != null) "$label · $done of $total records" else label, completedRecords = done, totalRecords = total))
					delay(1000); job = client.fleetPackStatus(job.jobId)
				}
				job.manifest ?: throw FleetValidationException("The prepared fleet pack has no download information.")
			} } catch (_: TransitException.NotFound) { throw FleetPackExpiredException() }
			if (pack.selection != selection) throw FleetValidationException("The prepared fleet pack has a different scope.")
			validate(pack)
			requireSpace(safeAdd(pack.archiveByteLength, safeAdd(pack.estimatedSavedByteLength, pack.estimatedSavedByteLength)))
			val archive = downloadArchive(downloadURL(pack.downloadURL, apiBase), pack.archiveByteLength, check, emit)
			try { installPack(archive, pack, token, check, emit) } finally { archive.delete() }
			}
	}
	suspend fun install(file: File, manifest: FleetOfflineManifest, progress: (FleetDownloadProgress) -> Unit = {}) {
		validate(manifest); performUpdate(progress) { token, check, emit -> installLegacy(file, manifest, token, check, emit) }
	}
	suspend fun install(file: File, pack: FleetPackManifest, progress: (FleetDownloadProgress) -> Unit = {}) {
		validate(pack); performUpdate(progress) { token, check, emit -> installPack(file, pack, token, check, emit) }
	}
	private suspend fun performUpdate(progress: (FleetDownloadProgress) -> Unit, body: suspend (Long, () -> Unit, (FleetDownloadProgress) -> Unit) -> Unit) = withContext(Dispatchers.IO) {
		if (!shared.update.tryLock()) throw FleetValidationException("A fleet download is already running.")
		try {
			val job = currentCoroutineContext()[Job]
			val token = shared.state.withLock {
				initialize()
				if (!shared.foreground) throw FleetValidationException("Keep the app open while saving the fleet.")
				shared.updateJob = job; shared.generation
			}
			val check = { job?.ensureActive(); if (shared.state.withLock { shared.generation } != token) throw CancellationException("Fleet update cancelled."); Unit }
			body(token, check) { value -> check(); shared.progress.value = value; progress(value) }
		} finally { shared.state.withLock { shared.updateJob = null }; shared.progress.value = null; shared.update.unlock() }
	}
	private fun installLegacy(file: File, manifest: FleetOfflineManifest, token: Long, check: () -> Unit, emit: (FleetDownloadProgress) -> Unit) {
		requireSpace(manifest.byteLength)
		val candidate = File(directory, "${manifest.id.take(64)}-${UUID.randomUUID()}.sqlite")
		var activated = false
		try {
			val transportBytes = manifest.downloadByteLength
			emit(FleetDownloadProgress(FleetDownloadStage.VERIFYING, totalBytes = transportBytes))
			FleetArchive.verify(file, transportBytes, if (manifest.compression == "gzip") manifest.compressedSha256!! else manifest.sha256, check) { emit(FleetDownloadProgress(FleetDownloadStage.VERIFYING, it, transportBytes)) }
			FileOutputStream(candidate).use { output ->
				var total = 0L
				emit(FleetDownloadProgress(FleetDownloadStage.IMPORTING, totalBytes = manifest.byteLength))
				if (manifest.compression == "gzip") file.inputStream().buffered().use { source ->
					FleetArchive.expand(source, manifest.byteLength, check) { block -> check(); requireSpace(0); output.write(block); total += block.size; emit(FleetDownloadProgress(FleetDownloadStage.IMPORTING, total, manifest.byteLength)) }
				} else file.inputStream().buffered().use { source ->
					val buffer = ByteArray(64 * 1024)
					while (true) { check(); val count = source.read(buffer); if (count < 0) break; requireSpace(0); output.write(buffer, 0, count); total += count; emit(FleetDownloadProgress(FleetDownloadStage.IMPORTING, total, manifest.byteLength)) }
				}
				output.fd.sync()
			}
			emit(FleetDownloadProgress(FleetDownloadStage.CHECKING, totalBytes = manifest.byteLength))
			FleetArchive.verify(candidate, manifest.byteLength, manifest.sha256, check) { emit(FleetDownloadProgress(FleetDownloadStage.CHECKING, it, manifest.byteLength)) }
			FleetDatabase(candidate, check).use { it.validate(manifest) }
			emit(FleetDownloadProgress(FleetDownloadStage.ACTIVATING))
			activate(SavedFleet(manifest = manifest, fileName = candidate.name), token, check); activated = true
		} finally { if (!activated) removeDatabase(candidate) }
	}
	private fun installPack(file: File, pack: FleetPackManifest, token: Long, check: () -> Unit, emit: (FleetDownloadProgress) -> Unit) {
		requireSpace(safeAdd(pack.estimatedSavedByteLength, pack.estimatedSavedByteLength))
		val candidate = File(directory, "${pack.id.take(64)}-${UUID.randomUUID()}.sqlite")
		var activated = false
		try {
			emit(FleetDownloadProgress(FleetDownloadStage.VERIFYING, totalBytes = pack.archiveByteLength))
			FleetArchive.verify(file, pack.archiveByteLength, pack.archiveSha256, check) { emit(FleetDownloadProgress(FleetDownloadStage.VERIFYING, it, pack.archiveByteLength)) }
			FleetPackImporter(candidate, pack, check, { requireSpace(16L * 1024 * 1024) }).use { importer ->
				var total = 0L
				emit(FleetDownloadProgress(FleetDownloadStage.IMPORTING, totalBytes = pack.uncompressedByteLength))
				file.inputStream().buffered().use { source -> FleetArchive.expand(source, pack.uncompressedByteLength, check) { block -> importer.consume(block); total += block.size; emit(FleetDownloadProgress(FleetDownloadStage.IMPORTING, total, pack.uncompressedByteLength)) } }
				// Index construction has no measured byte denominator.
				emit(FleetDownloadProgress(FleetDownloadStage.CHECKING)); importer.finish()
			}
			FleetDatabase(candidate, check).use { it.validate(pack) }
			val size = candidate.length()
			val hash = FleetArchive.digest(candidate, check) { emit(FleetDownloadProgress(FleetDownloadStage.CHECKING, it, size)) }
			val manifest = FleetOfflineManifest(schemaVersion = 2, id = pack.id, generatedAt = pack.generatedAt, historyStart = pack.historyStart, historyEnd = pack.historyEnd,
				counts = FleetOfflineCounts(pack.counts.cars, pack.counts.consists, pack.counts.events, pack.counts.assertions), byteLength = size, sha256 = hash,
				downloadURL = pack.downloadURL, observedAt = pack.observedAt, pack = pack)
			emit(FleetDownloadProgress(FleetDownloadStage.ACTIVATING)); activate(SavedFleet(manifest = manifest, fileName = candidate.name), token, check); activated = true
		} finally { if (!activated) removeDatabase(candidate) }
	}
	private fun activate(next: SavedFleet, token: Long, check: () -> Unit) = shared.state.withLock {
		check(); if (token != shared.generation) throw CancellationException()
		val previous = saved()
		atomicWrite("active.json", TransitJson.encodeToString(next).toByteArray(), check)
		previous?.takeIf { it.fileName != next.fileName }?.let { removeDatabase(File(directory, it.fileName)) }
	}

	suspend fun clear() = withContext(Dispatchers.IO) {
		shared.state.withLock {
			initialize(); shared.generation++
			shared.updateJob?.cancel(CancellationException("Fleet download removed."))
			val previous = saved()
			val pointer = File(directory, "active.json")
			if (pointer.exists() && !pointer.delete()) throw FleetValidationException("The saved fleet could not be removed.")
			previous?.let { removeDatabase(File(directory, it.fileName)) }
		}
	}
	/** History remains paged in SQLite beyond 200 events. Each page is capped at 200. */
	suspend fun fleetDetail(kind: String, id: String, offset: Int = 0, limit: Int = 200): FleetDetail = query { db, manifest ->
		val membership = if (kind == "car") null else db.rows("SELECT data FROM consists WHERE id=?", listOf(id)).firstOrNull()?.firstOrNull()
		val members = membership?.let { TransitJson.decodeFromString<List<String>>(it) }.orEmpty()
		val cars = if (members.isNotEmpty()) members.flatMap { member -> db.rows("SELECT data FROM cars WHERE id=?", listOf(member)).map { car(it[0]) } }
			else db.rows("SELECT data FROM cars WHERE id=? OR json_extract(data,'$.fixedSet')=? ORDER BY id", listOf(id, id)).map { car(it[0]) }
		if (cars.isEmpty()) throw FleetValidationException("This car or consist is not in the saved fleet.")
		val arguments = cars.map { it.id } + (if (members.isEmpty()) emptyList() else listOf(id)) + listOf(limit.coerceIn(1, 200).toString(), offset.coerceAtLeast(0).toString())
		val restriction = if (members.isEmpty()) "" else " AND json_extract(e.data,'$.consistId')=?"
		val history = db.rows("SELECT e.data FROM events e WHERE e.id IN (SELECT ec.event_id FROM event_cars ec WHERE ec.car_id IN (${cars.joinToString(",") { "?" }}))$restriction ORDER BY e.timestamp DESC,e.id DESC LIMIT ? OFFSET ?", arguments).map { TransitJson.decodeFromString<FleetObservation>(it[0]) }
		FleetDetail(cars, history, manifest.generatedAt)
	}
	suspend fun fleet(query: Map<String, String> = emptyMap()): FleetPage = query { db, manifest ->
		val grouping = if (query["view"] == "cars") "id" else "COALESCE(json_extract(data,'$.fixedSet'),id)"
		val (condition, values) = selection(query)
		val keys = db.rows("SELECT $grouping,json_extract(data,'$.number') FROM cars WHERE $grouping IN (SELECT $grouping FROM cars WHERE $condition)", values)
		val numbers = mutableMapOf<String, String>()
		keys.forEach { row -> if (numbers[row[0]]?.let { naturalCompare(row[1], it) < 0 } != false) numbers[row[0]] = row[1] }
		val ordered = numbers.keys.sortedWith { a, b -> naturalCompare(numbers[a]!!, numbers[b]!!).takeIf { it != 0 } ?: a.compareTo(b) }
		val pages = maxOf(1, (ordered.size + 99) / 100); val page = (query["page"]?.toIntOrNull() ?: 1).coerceIn(1, pages)
		val pageIDs = ordered.drop((page - 1) * 100).take(100)
		val groups = if (pageIDs.isEmpty()) emptyMap() else db.rows("SELECT $grouping,data FROM cars WHERE $grouping IN (${pageIDs.joinToString(",") { "?" }})", pageIDs).groupBy({ it[0] }, { car(it[1]) })
		val rows = pageIDs.map { id -> FleetRow(id, if (id.startsWith("set:")) "consist" else "car", groups[id].orEmpty().sortedWith { a, b -> naturalCompare(a.number, b.number) }, false) }
		fun facet(path: String) = db.rows("SELECT DISTINCT json_extract(data,'$path') AS value FROM cars WHERE value IS NOT NULL AND value != '' ORDER BY value").map { it[0] }
		val counts = db.rows("SELECT json_extract(data,'$.category'),COUNT(*) FROM cars GROUP BY json_extract(data,'$.category')").associate { it[0] to it[1].toInt() }
		val coverage = listOf("passenger", "sir", "work", "museum").map { category -> FleetCoverage(category, counts[category] ?: 0, if (category == "passenger") "Saved NYCT roster and observed cars; source records can conflict." else "Partial documented inventory; saved reports are historical.") }
		val sources = buildList<Evidence> {
			db.rows("SELECT data FROM meta WHERE key='roster'").firstOrNull()?.firstOrNull()?.let { raw -> add(TransitJson.decodeFromString<Evidence>(raw)) }
			db.rows("SELECT data FROM meta WHERE key='supplement'").firstOrNull()?.firstOrNull()?.let { raw -> addAll(TransitJson.decodeFromString<List<Evidence>>(raw)) }
		}
		FleetPage(rows, ordered.size, page, pages, manifest.generatedAt, coverage, FleetFacets(facet("$.equipment"), facet("$.last.route"), facet("$.estimatedYard.name")), sources)
	}
	private suspend fun <T> query(block: (FleetDatabase, FleetOfflineManifest) -> T): T = withContext(Dispatchers.IO) {
		val job = currentCoroutineContext()[Job]
		// Holding state through the read prevents an activation/clear deleting this database mid-query.
		shared.state.withLock { initialize(); val active = saved() ?: throw FleetUnavailableException(); FleetDatabase(File(directory, active.fileName), { job?.ensureActive() }).use { block(it, active.manifest) } }
	}
	private fun car(raw: String): FleetCar = TransitJson.decodeFromString<FleetCar>(raw).copy(reporting = false)
	private fun selection(query: Map<String, String>): Pair<String, List<String>> {
		val clauses = mutableListOf("1=1"); val values = mutableListOf<String>()
		if (query["status"] == "reporting") clauses += "0=1"
		query["category"]?.takeIf { it.isNotEmpty() }?.let { clauses += "json_extract(data,'$.category')=?"; values += it }
		for ((key, path) in listOf("equipment" to "$.equipment", "yard" to "$.estimatedYard.name", "route" to "$.last.route")) query[key]?.takeIf { it.isNotEmpty() }?.let { value ->
			val expression = "COALESCE(json_extract(data,'$path'),'')"
			when { value == "unknown" -> clauses += "$expression=''"; key == "route" -> { clauses += "$expression=?"; values += value }; else -> { clauses += "instr(lower($expression),?)>0"; values += value.lowercase() } }
		}
		if (query["retired"] != "true") {
			val lifecycle = "lower(COALESCE(json_extract(data,'$.lifecycle'),''))"
			clauses += "instr($lifecycle,'retired')=0 AND instr($lifecycle,'scrapped')=0 AND $lifecycle NOT GLOB '[0-9][0-9]/[0-9][0-9]/[0-9][0-9][0-9][0-9]'"
		}
		val searchable = listOf("$.number", "$.aliases", "$.equipment", "$.last.location", "$.estimatedYard.name").joinToString(" || ' ' || ") { "COALESCE(json_extract(data,'$it'),'')" }
		query["q"].orEmpty().lowercase().split(Regex("\\s+")).filter { it.isNotEmpty() }.forEach { term -> clauses += "instr(lower($searchable),?)>0"; values += term }
		return clauses.joinToString(" AND ") to values
	}
	private fun initialize() {
		if (shared.initialized) return
		if (!directory.isDirectory && !directory.mkdirs() && !directory.isDirectory) throw FleetValidationException("The fleet storage could not be opened.")
		val active = saved()
		directory.listFiles().orEmpty().forEach { file ->
			val database = databaseName(file.name)
			if (database != null && database != active?.fileName) removeDatabase(File(directory, database))
			if (file.name.endsWith(".archive") || file.name.endsWith(".staging")) file.delete()
		}
		shared.initialized = true
	}
	private fun saved(): SavedFleet? {
		val pointer = File(directory, "active.json")
		if (!pointer.exists()) return null
		if (pointer.length() > 1_048_576) throw FleetValidationException("Saved fleet information exceeds its supported size.")
		val value = try { TransitJson.decodeFromString<SavedFleet>(pointer.readText()) } catch (error: Exception) { throw FleetValidationException("Saved fleet information could not be read. It has been preserved.", error) }
		if (value.version != 1 || value.fileName != File(value.fileName).name || !value.fileName.endsWith(".sqlite") || !File(directory, value.fileName).isFile) throw FleetValidationException("The saved fleet could not be opened. It has been preserved.")
		return value
	}
	private fun atomicWrite(name: String, bytes: ByteArray, check: () -> Unit) {
		val temp = File(directory, ".${UUID.randomUUID()}.staging")
		try { FileOutputStream(temp).use { it.write(bytes); it.fd.sync() }; check(); Files.move(temp.toPath(), File(directory, name).toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING) }
		finally { temp.delete() }
	}
	private fun requireSpace(bytes: Long) { FleetArchive.requireSpace(availableBytes(), bytes) }

	private suspend fun downloadArchive(url: HttpUrl, bytes: Long, check: () -> Unit, emit: (FleetDownloadProgress) -> Unit): File {
		val client = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).connectTimeout(30, TimeUnit.SECONDS).readTimeout(60, TimeUnit.SECONDS).callTimeout(1, TimeUnit.HOURS).build()
		val file = File(directory, "${UUID.randomUUID()}.archive")
		var success = false
		try {
			var current = url
			for (redirect in 0..5) {
				check()
				val call = client.newCall(Request.Builder().url(current).header("Accept-Encoding", "identity").build())
				try {
					val response = suspendCancellableCoroutine<Response> { continuation ->
						continuation.invokeOnCancellation { call.cancel() }
						call.enqueue(object : Callback {
							override fun onFailure(call: Call, error: java.io.IOException) { if (continuation.isActive) continuation.resumeWithException(error) }
							override fun onResponse(call: Call, response: Response) {
								continuation.resume(response, onCancellation = { _, value, _ -> value.close() })
							}
						})
					}
					// A child watcher is cancellable with the parent while the body is streamed.
					coroutineScope {
						val cancellation = launch(start = CoroutineStart.UNDISPATCHED) { try { awaitCancellation() } finally { call.cancel() } }
						try { response.use { response ->
						check()
						if (response.code in setOf(301, 302, 303, 307, 308)) {
							if (redirect == 5) throw FleetValidationException("The fleet download redirected too many times.")
							val next = response.header("Location")?.let { current.resolve(it) } ?: throw FleetValidationException("The fleet download address is unavailable.")
							if (!sameOrigin(url, next) || next.fragment != null) throw FleetValidationException("The fleet download redirected to an unsupported origin.")
							current = next
						} else {
							if (response.code == 404) throw FleetPackExpiredException()
							if (response.code != 200 || !sameOrigin(url, response.request.url)) throw FleetValidationException("The fleet download is unavailable. Prepare it again.")
							val body = response.body ?: throw FleetValidationException("Fleet download is empty.")
							if (body.contentLength() >= 0 && body.contentLength() != bytes) throw FleetValidationException("The fleet download has an unexpected size.")
							emit(FleetDownloadProgress(FleetDownloadStage.DOWNLOADING, totalBytes = bytes))
							body.byteStream().use { input -> FileOutputStream(file).use { output ->
								val buffer = ByteArray(64 * 1024); var total = 0L
								while (true) { check(); val count = input.read(buffer); if (count < 0) break; if (count.toLong() > bytes - total) throw FleetValidationException("The fleet download exceeds its announced size."); requireSpace(0); output.write(buffer, 0, count); total += count; emit(FleetDownloadProgress(FleetDownloadStage.DOWNLOADING, total, bytes)) }
								if (total != bytes) throw FleetValidationException("Fleet download is incomplete."); output.fd.sync()
							} }
							success = true
						}
					} } finally { cancellation.cancel() }
					}
					if (success) return file
				} catch (error: java.io.IOException) { check(); throw error }
				finally { call.cancel() }
			}
			throw FleetValidationException("The fleet download address is unavailable.")
		} finally { if (!success) file.delete(); client.connectionPool.evictAll(); client.dispatcher.executorService.shutdown() }
	}
	companion object {
		private val stores = ConcurrentHashMap<String, Shared>()
		internal fun sameOrigin(a: HttpUrl, b: HttpUrl) = a.scheme == b.scheme && a.host == b.host && a.port == b.port && b.username.isEmpty() && b.password.isEmpty()
		internal fun downloadURL(address: String, apiBase: String): HttpUrl {
			val initial = apiBase.toHttpUrl().toString().trimEnd('/') + "/"
			val base = (if (initial == "https://juliet.nyc/subwaysForNerds/api/v1/") "https://subwaysfornerds.juliet.nyc/api/v1/" else initial).toHttpUrl()
			val url = base.resolve(address) ?: throw FleetValidationException("This fleet download address is unsupported.")
			if (!sameOrigin(base, url) || url.fragment != null || !(url.isHttps || url.host in setOf("localhost", "127.0.0.1", "::1"))) throw FleetValidationException("This fleet download address is unsupported.")
			return url
		}
		internal fun validate(pack: FleetPackManifest) { if (!pack.isValid) throw FleetValidationException("The fleet pack information is incomplete or incompatible. Prepare it again.") }
		internal fun validate(manifest: FleetOfflineManifest) {
			if (manifest.schemaVersion != 1 || manifest.byteLength <= 0 || manifest.byteLength >= Long.MAX_VALUE / 3 || !manifest.sha256.matches(Regex("[0-9a-fA-F]{64}")) || !manifest.id.matches(Regex("[A-Za-z0-9-]{1,128}")) ||
				!listOf(manifest.generatedAt, manifest.historyStart, manifest.historyEnd).all { it.isFinite() && it >= 0 } || manifest.historyStart > manifest.historyEnd || manifest.historyEnd < manifest.generatedAt ||
				listOf(manifest.counts.cars, manifest.counts.consists, manifest.counts.events, manifest.counts.assertions).any { it < 0 } || manifest.observedAt?.isFinite() == false) throw FleetValidationException("The fleet snapshot information is incompatible or incomplete.")
			if (manifest.compression == "gzip") {
				if (manifest.compressedByteLength == null || manifest.compressedByteLength!! <= 0 || manifest.compressedByteLength!! >= Long.MAX_VALUE / 3 || manifest.compressedSha256?.matches(Regex("[0-9a-fA-F]{64}")) != true) throw FleetValidationException("The fleet download information is incomplete.")
			} else if (manifest.compression != null || manifest.compressedByteLength != null || manifest.compressedSha256 != null) throw FleetValidationException("The fleet compression format is unsupported.")
		}
		private fun safeAdd(a: Long, b: Long): Long { if (a < 0 || b < 0 || a > Long.MAX_VALUE - b) throw FleetValidationException("The fleet download size is unsupported."); return a + b }
		private fun databaseName(name: String): String? = listOf("", "-journal", "-wal", "-shm").firstOrNull { name.endsWith(".sqlite$it") }?.let { if (it.isEmpty()) name else name.removeSuffix(it) }
		private fun removeDatabase(file: File) { listOf("", "-journal", "-wal", "-shm").forEach { File(file.path + it).delete() } }
		private fun naturalCompare(a: String, b: String): Int {
			val left = Regex("[0-9]+|[^0-9]+").findAll(a).map { it.value }.toList(); val right = Regex("[0-9]+|[^0-9]+").findAll(b).map { it.value }.toList()
			for (index in 0 until minOf(left.size, right.size)) {
				val x = left[index]; val y = right[index]
				val numeric = x.first().isDigit() && y.first().isDigit()
				val xx = if (numeric) x.trimStart('0').ifEmpty { "0" } else x; val yy = if (numeric) y.trimStart('0').ifEmpty { "0" } else y
				val result = if (numeric) xx.length.compareTo(yy.length).takeIf { it != 0 } ?: xx.compareTo(yy) else xx.compareTo(yy)
				if (result != 0) return result
			}
			return left.size.compareTo(right.size)
		}
	}
}
