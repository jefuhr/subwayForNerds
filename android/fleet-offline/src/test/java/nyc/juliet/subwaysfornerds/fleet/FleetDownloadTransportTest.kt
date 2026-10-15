package nyc.juliet.subwaysfornerds.fleet

import java.nio.file.Files
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.*
import nyc.juliet.subwaysfornerds.core.*
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.SocketPolicy
import org.junit.Assert.*
import org.junit.Test

class FleetDownloadTransportTest {
	private fun manifest(bytes: Long = 5) = FleetOfflineManifest(id = "fixture", generatedAt = 1000.0, historyStart = 0.0, historyEnd = 1000.0,
		counts = FleetOfflineCounts(0, 0, 0, 0), byteLength = bytes, sha256 = "0".repeat(64), downloadURL = "/first")

	@Test fun sameOriginRedirectIsFollowedThenExactChecksumIsEnforced() = runBlocking {
		val root = Files.createTempDirectory("sfn-redirect").toFile()
		MockWebServer().use { server ->
			server.enqueue(MockResponse().setResponseCode(302).addHeader("Location", "/archive"))
			server.enqueue(MockResponse().setBody("bytes"))
			server.start()
			try {
				val store = OfflineFleetStore(root, availableBytes = { Long.MAX_VALUE })
				try { store.download(manifest(), server.url("/api/").toString()); fail("Bad checksum accepted") }
				catch (error: FleetValidationException) { assertTrue(error.message!!.contains("checksum")) }
				assertEquals(2, server.requestCount)
				assertEquals("/first", server.takeRequest().path)
				assertEquals("/archive", server.takeRequest().path)
				assertFalse(root.listFiles()!!.any { it.name.endsWith(".archive") || it.name.endsWith(".sqlite") })
			} finally { root.deleteRecursively() }
		}
	}

	@Test fun foreignOriginRedirectIsRejectedBeforeContactingOtherServer() = runBlocking {
		val root = Files.createTempDirectory("sfn-foreign").toFile()
		MockWebServer().use { origin -> MockWebServer().use { foreign ->
			origin.start(); foreign.start()
			origin.enqueue(MockResponse().setResponseCode(302).addHeader("Location", foreign.url("/archive")))
			try {
				try { OfflineFleetStore(root, availableBytes = { Long.MAX_VALUE }).download(manifest(), origin.url("/api/").toString()); fail("Foreign redirect accepted") }
				catch (error: FleetValidationException) { assertTrue(error.message!!.contains("origin")) }
				assertEquals(0, foreign.requestCount)
			} finally { root.deleteRecursively() }
		} }
	}

	@Test fun expiredAndOversizedResponsesLeaveNoCandidate() = runBlocking {
		val root = Files.createTempDirectory("sfn-http-errors").toFile()
		MockWebServer().use { server ->
			server.enqueue(MockResponse().setResponseCode(404))
			server.enqueue(MockResponse().setBody("too many bytes")); server.start()
			try {
				val store = OfflineFleetStore(root, availableBytes = { Long.MAX_VALUE })
				try { store.download(manifest(), server.url("/api/").toString()); fail("Expired archive accepted") } catch (_: FleetPackExpiredException) { }
				try { store.download(manifest(), server.url("/api/").toString()); fail("Oversized archive accepted") } catch (_: FleetValidationException) { }
				assertNull(store.manifest()); assertFalse(root.listFiles()!!.any { it.name.endsWith(".archive") })
			} finally { root.deleteRecursively() }
		}
	}

	@Test fun cancelStopsAnUnresponsiveSocketAndClearsProgress() = runBlocking {
		val root = Files.createTempDirectory("sfn-http-cancel").toFile()
		MockWebServer().use { server ->
			server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE)); server.start()
			try {
				val store = OfflineFleetStore(root, availableBytes = { Long.MAX_VALUE })
				val task = launch(Dispatchers.IO) { store.download(manifest(), server.url("/api/").toString()) }
				assertNotNull(withContext(Dispatchers.IO) { server.takeRequest(5, TimeUnit.SECONDS) })
				withTimeout(2000) { task.cancelAndJoin() }
				assertNull(store.progress.value); assertNull(store.manifest())
			} finally { root.deleteRecursively() }
		}
	}
}
