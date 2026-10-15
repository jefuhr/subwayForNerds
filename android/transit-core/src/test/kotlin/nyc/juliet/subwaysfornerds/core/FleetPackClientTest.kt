package nyc.juliet.subwaysfornerds.core

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.*
import org.junit.Test

class FleetPackClientTest {
	private val selection = FleetPackSelection(listOf("R160"), listOf("unknown"), 30)
	private val manifest = FleetPackManifest(id = "a".repeat(64), generatedAt = 1000.0, historyStart = 0.0, historyEnd = 1000.0, selection = selection,
		counts = FleetPackCounts(1, 1, 201, 1, 201, 1, 0), archiveByteLength = 100, archiveSha256 = "a".repeat(64), uncompressedByteLength = 200, estimatedSavedByteLength = 250, downloadURL = "/api/v1/fleet/offline/v2/packs/data.jsonl.gz")
	private fun server(block: (MockWebServer) -> Unit) { val server = MockWebServer(); server.start(); try { block(server) } finally { server.shutdown() } }
	@Test fun preparesWithoutValidatorsAndPollsEncodedOpaqueJobsUntilReady() = server { s -> runBlocking {
		val api = TransitClient(s.url("/api/v1/").toString()); val id = "job /?+#%"
		s.enqueue(MockResponse().setResponseCode(202).setBody(TransitJson.encodeToString(FleetPackJob.serializer(), FleetPackJob(id, "preparing", progress = FleetPackProgress("events", "Collecting history", 2, 5, 1, 10, 0.2)))))
		val preparing = api.prepareFleetPack(selection); assertEquals("preparing", preparing.state); assertTrue(preparing.progress!!.load.estimated)
		val request = s.takeRequest(); assertEquals("POST", request.method); assertNull(request.getHeader("If-None-Match")); assertEquals(selection, TransitJson.decodeFromString(FleetPackSelection.serializer(), request.body.readUtf8()))
		s.enqueue(MockResponse().setBody(TransitJson.encodeToString(FleetPackJob.serializer(), FleetPackJob(id, "ready", manifest))))
		val ready = api.fleetPackStatus(id); assertEquals(manifest, ready.manifest); assertEquals(id, s.takeRequest().requestUrl!!.pathSegments.last())
		assertEquals(100L, api.downloadInfo(manifest).byteLength); assertEquals("gzip", api.downloadInfo(manifest).compression)
	} }
	@Test fun malformedOptionalProgressDoesNotFailAnOtherwiseValidJob() = server { s -> runBlocking {
		s.enqueue(MockResponse().setResponseCode(202).setBody("{\"jobId\":\"job\",\"state\":\"preparing\",\"progress\":{\"fraction\":\"unknown\"}}"))
		assertNull(TransitClient(s.url("/api/v1/").toString()).prepareFleetPack(selection).progress)
	} }
	@Test fun rejectsIncompatibleManifestsWrongJobsAndPartialFailures() = server { s -> runBlocking {
		val api = TransitClient(s.url("/api/v1/").toString())
		for (invalid in listOf(manifest.copy(schemaVersion = 9), manifest.copy(counts = manifest.counts.copy(linkedCars = 1)), manifest.copy(archiveSha256 = "wrong"), manifest.copy(historyEnd = 999.0))) {
			s.enqueue(MockResponse().setBody(TransitJson.encodeToString(FleetPackJob.serializer(), FleetPackJob("job", "ready", invalid))))
			assertThrows(TransitException.InvalidResponse::class.java) { runBlocking { api.fleetPackStatus("job") } }
		}
		s.enqueue(MockResponse().setBody(TransitJson.encodeToString(FleetPackJob.serializer(), FleetPackJob("other", "ready", manifest))))
		assertThrows(TransitException.InvalidResponse::class.java) { runBlocking { api.fleetPackStatus("job") } }
		for (status in listOf(404, 429, 503)) { s.enqueue(MockResponse().setResponseCode(status)); assertThrows(TransitException::class.java) { runBlocking { api.fleetPackStatus("job") } } }
		assertThrows(IllegalArgumentException::class.java) { runBlocking { api.prepareFleetPack(selection.copy(historyDays = 14)) } }
	} }
}
