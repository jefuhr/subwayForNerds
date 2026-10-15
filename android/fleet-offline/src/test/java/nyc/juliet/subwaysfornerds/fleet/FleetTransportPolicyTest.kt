package nyc.juliet.subwaysfornerds.fleet

import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.*
import org.junit.Test

class FleetTransportPolicyTest {
	@Test fun sameOriginIncludesSchemeHostPortAndCredentialExclusion() {
		val origin = "https://example.test/api/".toHttpUrl()
		assertTrue(OfflineFleetStore.sameOrigin(origin, "https://example.test/pack.gz".toHttpUrl()))
		for (other in listOf("https://evil.test/pack.gz", "http://example.test/pack.gz", "https://example.test:444/pack.gz", "https://user:password@example.test/pack.gz"))
			assertFalse(OfflineFleetStore.sameOrigin(origin, other.toHttpUrl()))
	}
	@Test fun downloadResolutionRejectsForeignOriginFragmentAndRemoteHTTP() {
		val origin = "https://example.test/api/"
		assertEquals("https://example.test/pack.gz", OfflineFleetStore.downloadURL("/pack.gz", origin).toString())
		for (address in listOf("//evil.test/pack.gz", "https://evil.test/pack.gz", "/pack.gz#part", "http://example.test/pack.gz"))
			assertThrows(FleetValidationException::class.java) { OfflineFleetStore.downloadURL(address, origin) }
		assertThrows(FleetValidationException::class.java) { OfflineFleetStore.downloadURL("/pack.gz", "http://example.test/api/") }
		assertEquals("http://127.0.0.1:8080/pack.gz", OfflineFleetStore.downloadURL("/pack.gz", "http://127.0.0.1:8080/api/").toString())
	}
	@Test fun onlyKnownProductionAliasNormalizesAndOtherOriginsStayIsolated() {
		assertEquals("https://subwaysfornerds.juliet.nyc/pack.gz", OfflineFleetStore.downloadURL("/pack.gz", "https://juliet.nyc/subwaysForNerds/api/v1/").toString())
		assertEquals("https://juliet.nyc/pack.gz", OfflineFleetStore.downloadURL("/pack.gz", "https://juliet.nyc/other/api/").toString())
	}
}
