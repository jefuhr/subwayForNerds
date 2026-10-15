package nyc.juliet.subwaysfornerds.core

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.*
import org.junit.Test
import java.security.MessageDigest
import java.util.Base64

class AccountClientTest {
	private fun server(block: (MockWebServer) -> Unit) { val server = MockWebServer(); server.start(); try { block(server) } finally { server.shutdown() } }
	@Test fun browserStartUsesAppPkceAndKeepsAllSessionTokensOutOfUrls() = server { s -> runBlocking {
		s.enqueue(MockResponse().setBody(buildJsonObject { put("id", "challenge"); put("nonce", "nonce"); put("authorizationURL", s.url("/api/v1/auth/android/start?challenge=challenge").toString()) }.toString()))
		val api = AccountClient(s.url("/api/v1/").toString()); val pending = api.startAndroid("apple", "link", "session-secret")
		val request = s.takeRequest(); val body = TransitJson.parseToJsonElement(request.body.readUtf8()).jsonObject
		assertEquals("Bearer session-secret", request.getHeader("Authorization")); assertEquals("android", body.getValue("platform").jsonPrimitive.content)
		assertEquals("S256", body.getValue("codeChallengeMethod").jsonPrimitive.content)
		assertEquals(Base64.getUrlEncoder().withoutPadding().encodeToString(MessageDigest.getInstance("SHA-256").digest(pending.verifier.toByteArray())), body.getValue("codeChallenge").jsonPrimitive.content)
		assertEquals(pending.state, body.getValue("state").jsonPrimitive.content)
		assertFalse(pending.authorizationURL.contains("session-secret")); assertFalse(pending.authorizationURL.contains(pending.verifier))
	} }
	@Test fun untrustedCallbacksAndBrowserStartOriginsAreRejectedBeforeExchange() = server { s -> runBlocking {
		val api = AccountClient(s.url("/api/v1/").toString(), now = { 1000.0 })
		val pending = AndroidAuthPending("apple", "login", "s".repeat(43), "a".repeat(43), "challenge", "https://example.test", 1000.0)
		for (url in listOf("evil://auth/android?handoff=x&state=${pending.state}", "$ANDROID_AUTH_CALLBACK?handoff=x&state=wrong", "$ANDROID_AUTH_CALLBACK?handoff=x&state=${pending.state}&state=${pending.state}", "$ANDROID_AUTH_CALLBACK?handoff=x&state=${pending.state}#secret")) {
			assertThrows(AccountException::class.java) { runBlocking { api.exchangeAndroid(url, pending) } }
		}
		assertEquals(0, s.requestCount)
		s.enqueue(MockResponse().setBody("{\"id\":\"challenge\",\"nonce\":\"nonce\",\"authorizationURL\":\"https://evil.test/start\"}"))
		assertThrows(AccountException::class.java) { runBlocking { api.startAndroid("google") } }
	} }
	@Test fun cancellationExpiredCallbacksAndPreconditionsHaveTypedResults() = server { s -> runBlocking {
		val api = AccountClient(s.url("/api/v1/").toString(), now = { 1000.0 })
		val pending = AndroidAuthPending("apple", "login", "s".repeat(43), "a".repeat(43), "challenge", "https://example.test", 1000.0)
		assertThrows(AuthCancelledException::class.java) { runBlocking { api.exchangeAndroid("$ANDROID_AUTH_CALLBACK?error=cancelled&state=${pending.state}", pending) } }
		assertThrows(AccountException::class.java) { runBlocking { api.exchangeAndroid("$ANDROID_AUTH_CALLBACK?handoff=x&state=${pending.state}", pending.copy(createdAt = 0.0)) } }
		val remote = SettingsRevision(2, Settings(theme = "night")); s.enqueue(MockResponse().setResponseCode(412).setBody(TransitJson.encodeToString(SettingsRevision.serializer(), remote)))
		val error = assertThrows(AccountException::class.java) { runBlocking { api.putSettings("token", Settings(), 1) } }
		assertEquals(412, error.status); assertEquals(remote, error.remoteRevision)
		val request = s.takeRequest(); assertEquals("\"1\"", request.getHeader("If-Match")); assertTrue(TransitJson.parseToJsonElement(request.body.readUtf8()).jsonObject.containsKey("offline"))
	} }
	@Test fun syncRequiresAnInitialChoiceAndRebasesConcurrentLocalChanges() {
		val local = Settings(theme = "local"); val remote = SettingsRevision(2, Settings(theme = "remote"))
		assertTrue(AccountSync.preview("one", local, null, remote).requiresInitialChoice)
		val baseline = AccountSyncBaseline("one", 1, Settings())
		val preview = AccountSync.preview("one", local, baseline, remote)
		assertEquals(listOf("/theme"), preview.conflicts.map { it.path })
		val draft = SettingsConflictDraft(baseline.settings, local, remote)
		assertThrows(SyncDraftChangedException::class.java) { AccountSync.resolve(draft, local.copy(favorites = listOf("a")), remote, mapOf("/theme" to "remote")) }
		val resolved = AccountSync.resolve(draft, local, remote, mapOf("/theme" to "remote")); assertEquals("remote", resolved.settings.theme)
		val accepted = SettingsRevision(3, local.copy(hiddenRoutes = listOf("A")))
		val rebased = AccountSync.rebase(local, local.copy(favorites = listOf("a")), accepted)
		assertEquals(listOf("a"), rebased.settings.favorites); assertEquals(listOf("A"), rebased.settings.hiddenRoutes)
	}
	@Test fun callbackExchangesProofInTheBodyAndLogoutDoesNotSendEmptyJson() = server { s -> runBlocking {
		val api = AccountClient(s.url("/api/v1/").toString(), now = { 1000.0 })
		val pending = AndroidAuthPending("apple", "login", "s".repeat(43), "a".repeat(43), "challenge", "https://example.test", 1000.0)
		s.enqueue(MockResponse().setBody("{\"account\":{\"id\":\"one\",\"identities\":[{\"provider\":\"apple\",\"email\":null}]},\"csrf\":\"csrf\",\"token\":\"session-secret\"}"))
		val session = api.exchangeAndroid("$ANDROID_AUTH_CALLBACK?handoff=${"h".repeat(43)}&state=${pending.state}", pending)
		assertEquals("session-secret", session.token); val request = s.takeRequest()
		assertEquals("/api/v1/auth/android/exchange", request.path); assertTrue(request.body.readUtf8().contains(pending.verifier))
		s.enqueue(MockResponse().setResponseCode(204)); api.logout(session.token!!)
		val logout = s.takeRequest(); assertEquals("Bearer session-secret", logout.getHeader("Authorization")); assertNull(logout.getHeader("Content-Type")); assertEquals(0L, logout.bodySize)
	} }
	@Test fun productionAliasesShareIdentityAndDebugOriginsDoNot() {
		assertEquals(PRODUCTION_API_BASE, TransitClient(LEGACY_PRODUCTION_API_BASE).baseUrl)
		assertEquals(PRODUCTION_API_BASE, AccountClient(LEGACY_PRODUCTION_API_BASE).baseUrl)
		assertEquals(OfflineEndpoint.productionKey, OfflineEndpoint.key(PRODUCTION_API_BASE))
		assertEquals(OfflineEndpoint.productionKey, OfflineEndpoint.key(LEGACY_PRODUCTION_API_BASE))
		assertNotEquals(OfflineEndpoint.key("http://example.test/api/v1/"), OfflineEndpoint.key("http://example.test:8080/api/v1/"))
		assertEquals("http://example.test/prefix/api/v1/", TransitClient("http://example.test/prefix/api/v1/").baseUrl)
	}
	@Test fun boundedAccountResponsesAllowRevisionEnvelopeOverhead() = server { s -> runBlocking {
		val api = AccountClient(s.url("/api/v1/").toString())
		val revision = TransitJson.encodeToString(SettingsRevision.serializer(), SettingsRevision(1, Settings()))
		s.enqueue(MockResponse().setBody(" ".repeat(MAX_SETTINGS_BYTES - revision.length + 1) + revision))
		assertEquals(1L, api.settings("token").revision)
		s.enqueue(MockResponse().setBody(" ".repeat(MAX_SETTINGS_BYTES + 16_385) + revision))
		assertThrows(TransitException.BodyTooLarge::class.java) { runBlocking { api.settings("token") } }
	} }
}
