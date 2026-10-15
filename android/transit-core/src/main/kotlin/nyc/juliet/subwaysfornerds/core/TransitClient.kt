package nyc.juliet.subwaysfornerds.core

import kotlinx.coroutines.*
import kotlinx.serialization.DeserializationStrategy
import kotlinx.serialization.SerializationException
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

const val PRODUCTION_API_BASE = "https://subwaysfornerds.juliet.nyc/api/v1/"
const val CANONICAL_PRODUCTION_API_BASE = PRODUCTION_API_BASE
const val LEGACY_PRODUCTION_API_BASE = "https://juliet.nyc/subwaysForNerds/api/v1/"
sealed class TransitException(message: String) : IOException(message) {
	class InvalidURL : TransitException("The train feed address is invalid.")
	class InvalidResponse : TransitException("The train feed returned an invalid response.")
	class NotFound : TransitException("No longer available in the current feed.")
	class HttpStatus(val status: Int) : TransitException("Could not reach the train feed (HTTP $status).")
	class UnexpectedNotModified : TransitException("The train feed cache is unavailable. Try again.")
	class BodyTooLarge : TransitException("The response exceeds the safe size limit.")
	class UnsafeDownload : TransitException("The fleet download must stay on the configured server.")
}
data class DownloadInfo(val url: String, val byteLength: Long, val sha256: String, val compression: String?)
internal fun defaultHttpClient(): OkHttpClient = OkHttpClient.Builder().connectTimeout(10, TimeUnit.SECONDS).readTimeout(20, TimeUnit.SECONDS).callTimeout(60, TimeUnit.SECONDS).build()
internal fun apiBase(value: String): HttpUrl {
	val url = value.toHttpUrlOrNull() ?: throw TransitException.InvalidURL()
	if (url.username.isNotEmpty() || url.password.isNotEmpty() || url.query != null || url.fragment != null) throw TransitException.InvalidURL()
	val normalized = url.newBuilder().encodedPath(url.encodedPath.trimEnd('/') + "/").build()
	return if (normalized.toString() == LEGACY_PRODUCTION_API_BASE) PRODUCTION_API_BASE.toHttpUrlOrNull()!! else normalized
}
internal fun requestURL(base: HttpUrl, components: List<String>, query: Map<String, String> = emptyMap()): HttpUrl {
	if (components.any { it.isEmpty() || it == "." || it == ".." }) throw TransitException.InvalidURL()
	val builder = base.newBuilder(); for (value in components) builder.addPathSegment(value)
	for ((name, value) in query.toSortedMap()) builder.addQueryParameter(name, value)
	return builder.build()
}
internal fun sameOrigin(a: HttpUrl, b: HttpUrl): Boolean = a.scheme == b.scheme && a.host == b.host && a.port == b.port && a.username.isEmpty() && a.password.isEmpty()
internal data class HttpPayload(val status: Int, val headers: Headers, val bytes: ByteArray, val url: HttpUrl)

/** OkHttp's callback owns the response until a cancellable IO reader has closed it. */
internal class HttpTransport(client: OkHttpClient, val origin: HttpUrl) {
	private val client = client.newBuilder().followRedirects(false).followSslRedirects(false).cache(null).build()
	suspend fun send(request: Request, maximum: Long, progress: TransferProgressHandler? = null, redirects: Boolean = false): HttpPayload {
		var next = request
		repeat(6) { count ->
			val payload = once(next, maximum, progress)
			if (payload.status !in listOf(301, 302, 303, 307, 308)) return payload
			if (!redirects || next.method != "GET" || count == 5) throw TransitException.InvalidResponse()
			val url = payload.headers["Location"]?.let { next.url.resolve(it) } ?: throw TransitException.InvalidResponse()
			if (!sameOrigin(url, origin)) throw TransitException.UnsafeDownload()
			next = next.newBuilder().url(url).build()
		}
		throw TransitException.InvalidResponse()
	}
	private suspend fun once(request: Request, maximum: Long, progress: TransferProgressHandler?): HttpPayload = suspendCancellableCoroutine { continuation ->
		val call = client.newCall(request); val reader = AtomicReference<Job?>()
		continuation.invokeOnCancellation { call.cancel(); reader.get()?.cancel() }
		call.enqueue(object : Callback {
			override fun onFailure(call: Call, e: IOException) { if (continuation.isActive) continuation.resumeWithException(e) }
			override fun onResponse(call: Call, response: Response) {
				if (!continuation.isActive) { response.close(); return }
				val job = CoroutineScope(continuation.context).launch(Dispatchers.IO) {
					try {
						val payload = response.use {
							val body = response.body ?: throw TransitException.InvalidResponse()
							if (body.contentLength() > maximum) throw TransitException.BodyTooLarge()
							val expected = response.header("X-Uncompressed-Length")?.toLongOrNull()?.takeIf { it > 0 } ?: body.contentLength().takeIf { it > 0 }
							val output = ByteArrayOutputStream(); val buffer = ByteArray(8192); val input = body.byteStream()
							while (true) {
								ensureActive(); val count = input.read(buffer); if (count < 0) break
								if (output.size().toLong() + count > maximum) throw TransitException.BodyTooLarge()
								output.write(buffer, 0, count)
								if (response.code in 200..299) progress?.invoke(TransferProgress(TransferPhase.RECEIVING, output.size().toLong(), expected, request.url.host))
							}
							ensureActive(); HttpPayload(response.code, response.headers, output.toByteArray(), response.request.url)
						}
						if (continuation.isActive) continuation.resume(payload)
					} catch (error: Exception) { if (continuation.isActive) continuation.resumeWithException(error) }
				}
				reader.set(job); job.invokeOnCompletion { response.close() }
				if (!continuation.isActive) { call.cancel(); job.cancel() }
			}
		})
	}
}

class TransitClient(baseUrl: String = PRODUCTION_API_BASE, client: OkHttpClient = defaultHttpClient(), private val maxBodyBytes: Long = 8 * 1_048_576L) {
	val baseURL: HttpUrl = apiBase(baseUrl)
	val baseUrl: String get() = baseURL.toString()
	private val transport = HttpTransport(client, baseURL)
	private data class Cached(val bytes: ByteArray, val etag: String, val order: Long)
	private class Flight(var count: Int = 0, var acceptedOrder: Long = -1)
	private data class Snapshot(val cached: Cached?, val order: Long, val generation: Long, val flight: Flight)
	private val responses = LinkedHashMap<HttpUrl, Cached>(16, 0.75f, true)
	private val flights = mutableMapOf<HttpUrl, Flight>()
	private val lock = Any(); private var serial = 0L; private var generation = 0L
	init { require(maxBodyBytes in 1..64 * 1_048_576L) }
	fun requestURL(components: List<String>, query: Map<String, String> = emptyMap()): HttpUrl = requestURL(baseURL, components, query)
	fun clearResponseCache() { synchronized(lock) { responses.clear(); generation++ } }
	suspend fun stations(progress: TransferProgressHandler? = null): List<Station> = get(listOf("stations"), decoder = ListSerializer(Station.serializer()), progress = progress)
	suspend fun board(stationID: String, progress: TransferProgressHandler? = null): Board = get(listOf("stations", stationID, "board"), decoder = Board.serializer(), progress = progress)
	suspend fun trip(key: String, progress: TransferProgressHandler? = null): TripDetail = get(listOf("trips"), mapOf("key" to key), TripDetail.serializer(), progress)
	suspend fun transfers(key: String, stopID: String, sequence: Int? = null, progress: TransferProgressHandler? = null): TransferResult = get(listOf("trips", "transfers"), mapOf("key" to key, "stopId" to stopID) + (sequence?.let { mapOf("sequence" to it.toString()) } ?: emptyMap()), TransferResult.serializer(), progress)
	suspend fun context(stationID: String, progress: TransferProgressHandler? = null): StationContext = get(listOf("stations", stationID, "context"), decoder = StationContext.serializer(), progress = progress)
	suspend fun fleet(query: Map<String, String> = emptyMap(), progress: TransferProgressHandler? = null): FleetPage = get(listOf("fleet"), query, FleetPage.serializer(), progress)
	suspend fun fleetDetail(kind: String, id: String, progress: TransferProgressHandler? = null): FleetDetail = get(listOf("fleet", kind, id), decoder = FleetDetail.serializer(), progress = progress)
	suspend fun offlineManifest(): FleetOfflineManifest = get(listOf("fleet", "offline", "manifest"), decoder = FleetOfflineManifest.serializer())
	private suspend fun <T> get(components: List<String>, query: Map<String, String> = emptyMap(), decoder: DeserializationStrategy<T>, progress: TransferProgressHandler? = null): T {
		val url = requestURL(components, query)
		val snapshot = synchronized(lock) { val cached = responses[url]; val flight = flights.getOrPut(url) { Flight(acceptedOrder = cached?.order ?: -1) }; flight.count++; Snapshot(cached, ++serial, generation, flight) }
		val cached = snapshot.cached; val version = snapshot.order; val startedGeneration = snapshot.generation
		try {
		val request = Request.Builder().url(url).header("Accept", "application/json").apply { cached?.let { header("If-None-Match", it.etag) } }.build()
		progress?.invoke(TransferProgress(TransferPhase.REQUESTING, host = url.host))
		val response = transport.send(request, maxBodyBytes, progress, redirects = true)
		val bytes = when (response.status) {
			304 -> (cached ?: throw TransitException.UnexpectedNotModified()).bytes.also { progress?.invoke(TransferProgress(TransferPhase.VALIDATED, it.size.toLong(), it.size.toLong(), url.host)) }
			in 200..299 -> response.bytes.also { progress?.invoke(TransferProgress(TransferPhase.DECODING, it.size.toLong(), it.size.toLong(), url.host)) }
			404 -> throw TransitException.NotFound()
			else -> throw TransitException.HttpStatus(response.status)
		}
		currentCoroutineContext().ensureActive()
		val decoded = withContext(Dispatchers.Default) { try { TransitJson.decodeFromString(decoder, bytes.toString(Charsets.UTF_8)) } catch (_: SerializationException) { throw TransitException.InvalidResponse() } catch (_: IllegalArgumentException) { throw TransitException.InvalidResponse() } }
		currentCoroutineContext().ensureActive()
		synchronized(lock) {
			if (generation == startedGeneration && snapshot.flight.acceptedOrder <= version) {
				snapshot.flight.acceptedOrder = version
				val etag = response.headers["ETag"] ?: if (response.status == 304) cached?.etag else null
				if (etag != null) responses[url] = Cached(bytes, etag, version) else responses.remove(url)
				while (responses.size > 128 || responses.values.sumOf { it.bytes.size.toLong() } > 32 * 1_048_576L) responses.remove(responses.keys.first())
			}
		}
		progress?.invoke(TransferProgress(TransferPhase.FINISHED, bytes.size.toLong(), bytes.size.toLong(), url.host))
		return decoded
		} finally { synchronized(lock) { snapshot.flight.count--; if (snapshot.flight.count == 0 && flights[url] === snapshot.flight) flights.remove(url) } }
	}
	suspend fun prepareFleetPack(selection: FleetPackSelection): FleetPackJob {
		if (!selection.isValid) throw IllegalArgumentException("Choose exact car types and yards, with 7 or 30 days of history.")
		return pack(null, selection)
	}
	suspend fun fleetPackStatus(jobID: String): FleetPackJob {
		if (jobID.isEmpty() || jobID.toByteArray().size > 256) throw TransitException.InvalidResponse()
		return pack(jobID, null)
	}
	private suspend fun pack(jobID: String?, selection: FleetPackSelection?): FleetPackJob {
		val request = Request.Builder().url(requestURL(listOf("fleet", "offline", "v2", "packs") + listOfNotNull(jobID))).header("Accept", "application/json").apply { selection?.let { post(TransitJson.encodeToString(FleetPackSelection.serializer(), it).toRequestBody("application/json".toMediaType())) } }.build()
		val response = transport.send(request, minOf(maxBodyBytes, 1_048_576L))
		if (response.status !in listOf(200, 202)) { if (response.status == 404) throw TransitException.NotFound(); throw TransitException.HttpStatus(response.status) }
		val job = withContext(Dispatchers.Default) { try {
			val raw = TransitJson.parseToJsonElement(response.bytes.toString(Charsets.UTF_8)).jsonObject
			// Build progress is optional presentation metadata, not the pack's integrity contract.
			val progress = raw["progress"]?.takeIf { it != JsonNull }?.let { try { TransitJson.decodeFromJsonElement(FleetPackProgress.serializer(), it) } catch (_: Exception) { null } }
			TransitJson.decodeFromJsonElement(FleetPackJob.serializer(), JsonObject(raw - "progress")).copy(progress = progress)
		} catch (_: Exception) { throw TransitException.InvalidResponse() } }
		currentCoroutineContext().ensureActive()
		if (job.jobId.isEmpty() || job.jobId.toByteArray().size > 256 || jobID != null && job.jobId != jobID ||
			!(response.status == 202 && job.state == "preparing" && job.manifest == null || response.status == 200 && job.state == "ready" && job.manifest?.isValid == true)) throw TransitException.InvalidResponse()
		return job
	}
	private fun downloadURL(relative: String): String {
		if (!relative.startsWith('/') || relative.startsWith("//") || relative.contains('\\')) throw TransitException.UnsafeDownload()
		val url = baseURL.resolve(relative) ?: throw TransitException.UnsafeDownload()
		if (!sameOrigin(url, baseURL) || url.fragment != null) throw TransitException.UnsafeDownload()
		return url.toString()
	}
	fun downloadInfo(manifest: FleetOfflineManifest): DownloadInfo {
		manifest.pack?.let { return downloadInfo(it) }
		if (manifest.schemaVersion != 1 || manifest.byteLength <= 0 || !Regex("[0-9a-fA-F]{64}").matches(manifest.sha256) || manifest.compression !in listOf(null, "gzip")) throw TransitException.InvalidResponse()
		val compressed = manifest.compression == "gzip"
		val length = if (compressed) manifest.compressedByteLength ?: throw TransitException.InvalidResponse() else manifest.byteLength
		val sha = if (compressed) manifest.compressedSha256 ?: throw TransitException.InvalidResponse() else manifest.sha256
		if (length <= 0 || !Regex("[0-9a-fA-F]{64}").matches(sha)) throw TransitException.InvalidResponse()
		return DownloadInfo(downloadURL(manifest.downloadURL), length, sha, manifest.compression)
	}
	fun downloadInfo(manifest: FleetPackManifest): DownloadInfo {
		if (!manifest.isValid) throw TransitException.InvalidResponse()
		return DownloadInfo(downloadURL(manifest.downloadURL), manifest.archiveByteLength, manifest.archiveSha256, manifest.compression)
	}
}
