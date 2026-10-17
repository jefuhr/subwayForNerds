package nyc.juliet.subwaysfornerds.core

import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.*
import org.junit.Test

class TrackMapClientTest {
	private val body = TransitJson.encodeToString(TrackMapSnapshot.serializer(), TrackMapTestData.snapshot())
	private fun server(block: (MockWebServer) -> Unit) { val server = MockWebServer(); server.start(); try { block(server) } finally { server.shutdown() } }

	@Test fun snapshotUsesTheVersionedPathEtagCacheAndProgress() = server { s -> runBlocking {
		val api = TransitClient(s.url("/prefix/api/v1/").toString())
		s.enqueue(MockResponse().setBody(body).setHeader("ETag", "\"m1\""))
		val phases = mutableListOf<TransferPhase>()
		val first = api.trackMapSnapshot(TrackMapContract.MAP_VERSION) { phases += it.phase }
		assertEquals("/prefix/api/v1/track-map/nyc-2.6.8-v1/snapshot", s.takeRequest().path)
		assertEquals(TransferPhase.REQUESTING, phases.first()); assertEquals(TransferPhase.FINISHED, phases.last())
		s.enqueue(MockResponse().setResponseCode(304))
		assertEquals(first, api.trackMapSnapshot(TrackMapContract.MAP_VERSION))
		assertEquals("\"m1\"", s.takeRequest().getHeader("If-None-Match"))
	} }

	@Test fun unsupportedVersionsAndMalformedSnapshotsFail() = server { s -> runBlocking {
		val api = TransitClient(s.url("/api/v1/").toString())
		s.enqueue(MockResponse().setResponseCode(404))
		assertThrows(TransitException.NotFound::class.java) { runBlocking { api.trackMapSnapshot("nyc-0-v0") } }
		s.enqueue(MockResponse().setResponseCode(503))
		assertThrows(TransitException.HttpStatus::class.java) { runBlocking { api.trackMapSnapshot(TrackMapContract.MAP_VERSION) } }
		s.enqueue(MockResponse().setBody(body.replace("\"live\"", "\"bright\"")))
		assertThrows(TransitException.InvalidResponse::class.java) { runBlocking { api.trackMapSnapshot(TrackMapContract.MAP_VERSION) } }
		assertThrows(TransitException.InvalidURL::class.java) { runBlocking { api.trackMapSnapshot("..") } }
	} }
}
