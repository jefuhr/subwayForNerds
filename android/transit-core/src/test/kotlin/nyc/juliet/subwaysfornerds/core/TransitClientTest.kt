package nyc.juliet.subwaysfornerds.core

import kotlinx.coroutines.*
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.*
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.SocketPolicy
import okhttp3.HttpUrl.Companion.toHttpUrl
import okio.Buffer
import okio.GzipSink
import okio.buffer
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.TimeUnit

class TransitClientTest {
	private fun fixture(name: String): String = javaClass.getResourceAsStream("/fixtures/$name")!!.bufferedReader().use { it.readText() }
	private fun server(block: (MockWebServer) -> Unit) { val server = MockWebServer(); server.start(); try { block(server) } finally { server.shutdown() } }
	private fun client(server: MockWebServer, maximum: Long = 8 * 1_048_576L) = TransitClient(server.url("/prefix/api/v1/").toString(), maxBodyBytes = maximum)
	@Test fun etagsReuseTheValidatedSnapshotWithoutRenewingAnyClock() = server { s -> runBlocking {
		s.enqueue(MockResponse().setBody(fixture("board.json")).setHeader("ETag", "\"one\""))
		s.enqueue(MockResponse().setResponseCode(304))
		val api = client(s); val first = api.board("328"); val second = api.board("328")
		assertEquals(first, second); assertEquals(first.sources, second.sources)
		assertNull(s.takeRequest().getHeader("If-None-Match")); assertEquals("\"one\"", s.takeRequest().getHeader("If-None-Match"))
		val phases = mutableListOf<TransferPhase>(); s.enqueue(MockResponse().setResponseCode(304)); api.board("328") { phases += it.phase }
		assertEquals(listOf(TransferPhase.REQUESTING, TransferPhase.VALIDATED, TransferPhase.FINISHED), phases)
	} }
	@Test fun validatorsAreUrlSpecificAndIdentifiersRemainOpaque() = server { s -> runBlocking {
		s.enqueue(MockResponse().setBody(fixture("board.json")).setHeader("ETag", "a")); s.enqueue(MockResponse().setBody(fixture("board.json")))
		val api = client(s); api.board("id/a?b#c%+"); api.board("other")
		assertEquals("/prefix/api/v1/stations/id%2Fa%3Fb%23c%25+/board", s.takeRequest().path)
		assertNull(s.takeRequest().getHeader("If-None-Match"))
		val url = api.requestURL(listOf("trips"), mapOf("key" to "a+b /%?#", "sequence" to "0"))
		assertEquals("a+b /%?#", url.queryParameter("key")); assertTrue(url.encodedQuery!!.contains("%2B"))
		assertThrows(TransitException.InvalidURL::class.java) { api.requestURL(listOf("..")) }
	} }
	@Test fun malformedReplacementCannotPoisonValidatedCacheAndErrorsNeverMasqueradeAsSuccess() = server { s -> runBlocking {
		val api = client(s); s.enqueue(MockResponse().setBody(fixture("board.json")).setHeader("ETag", "good")); val good = api.board("328")
		s.enqueue(MockResponse().setBody("{broken").setHeader("ETag", "bad")); assertThrows(TransitException.InvalidResponse::class.java) { runBlocking { api.board("328") } }
		s.enqueue(MockResponse().setResponseCode(304)); assertEquals(good, api.board("328"))
		for (status in listOf(401, 404, 429, 500, 503)) { s.enqueue(MockResponse().setResponseCode(status)); assertThrows(TransitException::class.java) { runBlocking { api.board("328") } } }
	} }
	@Test fun orphan304AndClearedCacheAreRejected() = server { s -> runBlocking {
		val api = client(s); s.enqueue(MockResponse().setResponseCode(304)); assertThrows(TransitException.UnexpectedNotModified::class.java) { runBlocking { api.stations() } }
		s.enqueue(MockResponse().setBody(fixture("catalog.json")).setHeader("ETag", "good")); api.stations(); api.clearResponseCache()
		s.enqueue(MockResponse().setResponseCode(304)); assertThrows(TransitException.UnexpectedNotModified::class.java) { runBlocking { api.stations() } }
	} }
	@Test fun nullFalseZeroAndPartialFailuresSurviveDtoRoundTrip() {
		val row = TransitJson.decodeFromString(Board.serializer(), fixture("edge-board.json")).departures.first().copy(time = null, stopsAway = 0)
		assertEquals(false, row.assigned); assertEquals(0, row.stopsAway); assertNull(row.time)
		val raw = TransitJson.encodeToJsonElement(Departure.serializer(), row).jsonObject
		assertEquals(JsonNull, raw["time"]); assertEquals(JsonPrimitive(false), raw["assigned"]); assertEquals(JsonPrimitive(0), raw["stopsAway"])
		val trip = TransitJson.decodeFromString(TripDetail.serializer(), fixture("edge-trip.json")); assertNotNull(trip.raw)
		val minimal = row.copy(assigned = null, stopsAway = null)
		val encoded = TransitJson.encodeToJsonElement(Departure.serializer(), minimal).jsonObject
		assertFalse(encoded.containsKey("assigned")); assertEquals(JsonNull, encoded["stopsAway"])
		val absent = TransitJson.decodeFromJsonElement(Departure.serializer(), JsonObject(encoded - "departure"))
		val explicitNull = TransitJson.decodeFromJsonElement(Departure.serializer(), JsonObject(encoded + ("departure" to JsonNull)))
		assertFalse(TransitJson.encodeToJsonElement(Departure.serializer(), absent).jsonObject.containsKey("departure"))
		assertEquals(JsonNull, TransitJson.encodeToJsonElement(Departure.serializer(), explicitNull).jsonObject["departure"])
	}
	@Test fun decodedBodiesAreBoundedEvenWhenGzippedAndCancellationStopsTheCall() = server { s -> runBlocking {
		val buffer = Buffer(); GzipSink(buffer).buffer().use { it.writeUtf8("x".repeat(100_000)) }
		s.enqueue(MockResponse().setHeader("Content-Encoding", "gzip").setBody(buffer))
		assertThrows(TransitException.BodyTooLarge::class.java) { runBlocking { client(s, 1024).stations() } }
		// Leave teardown margin below MockWebServer's five-second shutdown deadline.
		s.enqueue(MockResponse().setBody(fixture("catalog.json")).setBodyDelay(1, TimeUnit.SECONDS))
		val pending = launch { client(s).stations() }
		withContext(Dispatchers.IO) { assertNotNull(s.takeRequest(5, TimeUnit.SECONDS)); assertNotNull(s.takeRequest(5, TimeUnit.SECONDS)) }
		pending.cancelAndJoin(); assertTrue(pending.isCancelled)
	} }
	@Test fun concurrentCompletionCannotReplaceANewerResponseValidator() = server { s -> runBlocking {
		s.enqueue(MockResponse().setBody(fixture("board.json")).setHeader("ETag", "old").setBodyDelay(250, TimeUnit.MILLISECONDS))
		s.enqueue(MockResponse().setBody(fixture("board.json")).setHeader("ETag", "new"))
		val api = client(s); val old = async { api.board("328") }; withContext(Dispatchers.IO) { s.takeRequest() }
		val newer = async { api.board("328") }; newer.await(); old.await()
		s.enqueue(MockResponse().setResponseCode(304)); api.board("328")
		s.takeRequest(); assertEquals("new", s.takeRequest().getHeader("If-None-Match"))
	} }
	@Test fun concurrentUntaggedReplacementAndExplicitClearCannotReviveAnOldValidator() = server { s -> runBlocking {
		val api = client(s)
		s.enqueue(MockResponse().setBody(fixture("board.json")).setHeader("ETag", "old").setBodyDelay(250, TimeUnit.MILLISECONDS))
		s.enqueue(MockResponse().setBody(fixture("board.json")))
		val old = async { api.board("328") }; withContext(Dispatchers.IO) { s.takeRequest() }; api.board("328"); old.await(); s.takeRequest()
		s.enqueue(MockResponse().setBody(fixture("board.json"))); api.board("328"); assertNull(s.takeRequest().getHeader("If-None-Match"))
		s.enqueue(MockResponse().setBody(fixture("board.json")).setHeader("ETag", "late").setBodyDelay(250, TimeUnit.MILLISECONDS))
		val pending = async { api.board("328") }; withContext(Dispatchers.IO) { s.takeRequest() }; api.clearResponseCache(); pending.await()
		s.enqueue(MockResponse().setBody(fixture("board.json"))); api.board("328"); assertNull(s.takeRequest().getHeader("If-None-Match"))
	} }
	@Test fun manifestsRequireSameOriginAndEveryPublicEndpointDecodesFixtures() = server { s -> runBlocking {
		val api = client(s)
		fun body(name: String) { s.enqueue(MockResponse().setBody(fixture(name))) }
		body("catalog.json"); assertTrue(api.stations().isNotEmpty())
		body("trip.json"); api.trip("key+opaque")
		body("transfers.json"); api.transfers("key", "stop/opaque", 0)
		body("context.json"); api.context("328")
		body("fleet-page.json"); api.fleet(mapOf("page" to "1"))
		body("fleet-detail.json"); api.fleetDetail("car", "nyct:R160:001")
		body("offline-manifest.json"); val manifest = api.offlineManifest()
		assertEquals(s.hostName, api.downloadInfo(manifest).url.toHttpUrl().host)
		for (url in listOf("https://evil.test/db", "//evil.test/db", "\\\\evil.test/db")) assertThrows(TransitException.UnsafeDownload::class.java) { api.downloadInfo(manifest.copy(downloadURL = url)) }
	} }
	@Test fun receivingUnknownLengthDoesNotInventPercentages() = server { s -> runBlocking {
		s.enqueue(MockResponse().setChunkedBody(fixture("catalog.json"), 32_768))
		val progress = mutableListOf<TransferProgress>(); client(s).stations { progress += it }
		val receiving = progress.filter { it.phase == TransferPhase.RECEIVING }
		assertTrue(receiving.isNotEmpty()); assertTrue(receiving.all { it.expectedBytes == null && it.load("stations").percentLabel == null })
		assertEquals(TransferPhase.FINISHED, progress.last().phase)
	} }
}
