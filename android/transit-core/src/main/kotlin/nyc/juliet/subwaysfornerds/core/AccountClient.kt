@file:OptIn(kotlinx.serialization.ExperimentalSerializationApi::class)

package nyc.juliet.subwaysfornerds.core

import kotlinx.serialization.EncodeDefault
import kotlinx.serialization.EncodeDefault.Mode.NEVER
import kotlinx.serialization.Serializable
import kotlinx.serialization.DeserializationStrategy
import kotlinx.serialization.json.*
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.net.URI
import java.net.URLDecoder
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import java.io.IOException

const val ANDROID_AUTH_CALLBACK = "nyc.juliet.subwaysfornerds://auth/android"
@Serializable data class AuthConfig(val enabled: Boolean, @EncodeDefault(NEVER) val googleClientID: String? = null, @EncodeDefault(NEVER) val googleServerClientID: String? = null)
@Serializable data class AccountIdentity(val provider: String, val email: String? = null)
@Serializable data class Account(val id: String, val identities: List<AccountIdentity>, @EncodeDefault(NEVER) val authenticatedAt: Double? = null)
@Serializable data class AccountSession(val account: Account, val csrf: String, @EncodeDefault(NEVER) val token: String? = null)
@Serializable data class AndroidAuthPending(val provider: String, val intent: String, val state: String, val verifier: String, val challengeID: String, val authorizationURL: String, val createdAt: Double)
private data class AndroidCallback(val handoff: String?, val error: String?)
open class AccountException(message: String, val status: Int? = null, val remoteRevision: SettingsRevision? = null) : IOException(message)
class AuthCancelledException : AccountException("Sign-in was cancelled.")

/** Browser auth is provider-independent and uses the server's already configured web clients. */
class AccountClient(baseUrl: String = PRODUCTION_API_BASE, client: OkHttpClient = defaultHttpClient(), private val now: () -> Double = { System.currentTimeMillis() / 1000.0 }) {
	private val baseURL = apiBase(baseUrl)
	val baseUrl: String get() = baseURL.toString()
	private val transport = HttpTransport(client, baseURL)
	suspend fun config(): AuthConfig = request(listOf("auth", "config"), AuthConfig.serializer())
	suspend fun startAndroid(provider: String, intent: String = "login", token: String? = null): AndroidAuthPending {
		if (provider !in listOf("apple", "google") || intent !in listOf("login", "link", "reauth") || intent != "login" && token.isNullOrEmpty()) throw AccountException("Choose a configured login method and try again.")
		fun secret(): String = Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(32).also { SecureRandom().nextBytes(it) })
		val verifier = secret(); val state = secret()
		val payload = buildJsonObject { put("provider", provider); put("platform", "android"); put("intent", intent); put("state", state); put("codeChallenge", Base64.getUrlEncoder().withoutPadding().encodeToString(MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray()))); put("codeChallengeMethod", "S256") }
		val raw = send(listOf("auth", "challenges"), "POST", token, payload)
		val result = try { TransitJson.parseToJsonElement(raw.bytes.toString(Charsets.UTF_8)).jsonObject } catch (_: Exception) { throw AccountException("Sign-in returned an invalid challenge.") }
		val id = (result["id"] as? JsonPrimitive)?.takeIf { it.isString }?.content?.takeIf { it.isNotEmpty() && it.length <= 256 } ?: throw AccountException("Sign-in returned an invalid challenge.")
		val authorization = (result["authorizationURL"] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: throw AccountException("Browser sign-in is unavailable.")
		val url = authorization.toHttpUrlOrNull() ?: throw AccountException("Browser sign-in returned an invalid address.")
		if (!sameOrigin(url, baseURL) || url.encodedPath != requestURL(baseURL, listOf("auth", "android", "start")).encodedPath || url.queryParameterNames != setOf("challenge") || url.queryParameterValues("challenge") != listOf(id) || url.fragment != null) throw AccountException("Browser sign-in must stay on the configured server.")
		return AndroidAuthPending(provider, intent, state, verifier, id, authorization, now())
	}
	private fun callback(value: String, pending: AndroidAuthPending): AndroidCallback {
		val instant = now()
		if (!pending.createdAt.isFinite() || pending.createdAt > instant || instant - pending.createdAt > 390) throw AccountException("Sign-in expired. Please try again.")
		val uri = try { URI(value) } catch (_: Exception) { throw AccountException("This is not a valid app sign-in callback.") }
		if (uri.scheme != "nyc.juliet.subwaysfornerds" || uri.host != "auth" || uri.rawPath != "/android" || uri.userInfo != null || uri.port != -1 || uri.rawFragment != null || uri.rawQuery == null) throw AccountException("This is not a valid app sign-in callback.")
		val fields = linkedMapOf<String, String>()
		try {
			for (part in uri.rawQuery.split('&')) {
				val pair = part.split('=', limit = 2); if (pair.size != 2) throw IllegalArgumentException()
				val key = URLDecoder.decode(pair[0], StandardCharsets.UTF_8.name()); val content = URLDecoder.decode(pair[1], StandardCharsets.UTF_8.name())
				if (key !in listOf("state", "handoff", "error") || fields.put(key, content) != null || content.isEmpty() || content.length > 256) throw IllegalArgumentException()
			}
		} catch (_: Exception) { throw AccountException("This is not a valid app sign-in callback.") }
		val state = fields["state"] ?: throw AccountException("Sign-in did not match this app.")
		if (!MessageDigest.isEqual(state.toByteArray(), pending.state.toByteArray()) || (fields.containsKey("handoff") == fields.containsKey("error"))) throw AccountException("Sign-in did not match this app.")
		return AndroidCallback(fields["handoff"], fields["error"])
	}
	suspend fun exchangeAndroid(callbackUrl: String, pending: AndroidAuthPending, token: String? = null): AccountSession {
		val callback = callback(callbackUrl, pending)
		if (callback.error == "cancelled") throw AuthCancelledException()
		if (callback.error != null) throw AccountException("Sign-in could not be verified. Please try again.")
		if (pending.intent != "login" && token.isNullOrEmpty()) throw AccountException("Your account changed during sign-in. Please try again.")
		val result = request(listOf("auth", "android", "exchange"), AccountSession.serializer(), "POST", token, buildJsonObject { put("handoff", callback.handoff); put("state", pending.state); put("verifier", pending.verifier) })
		if (result.account.id.isEmpty() || result.csrf.isEmpty() || pending.intent == "login" && result.token.isNullOrEmpty()) throw AccountException("Sign-in returned incomplete account information.")
		return result
	}
	suspend fun account(token: String): AccountSession = request(listOf("account"), AccountSession.serializer(), token = token)
	suspend fun settings(token: String): SettingsRevision = revision(send(listOf("account", "settings"), "GET", token).bytes)
	suspend fun putSettings(token: String, settings: Settings, revision: Long): SettingsRevision {
		if (revision < 0) throw AccountException("Reload account settings before saving.")
		return revision(send(listOf("account", "settings"), "PUT", token, TransitJson.encodeToJsonElement(Settings.serializer(), NerdsCodec.validate(settings)), mapOf("If-Match" to "\"$revision\"")).bytes)
	}
	suspend fun logout(token: String) { send(listOf("auth", "logout"), "POST", token) }
	suspend fun unlink(provider: String, token: String) {
		if (provider !in listOf("apple", "google")) throw AccountException("Choose Apple or Google.")
		send(listOf("account", "identities", provider), "DELETE", token)
	}
	suspend fun deleteAccount(token: String) { send(listOf("account"), "DELETE", token) }
	private fun revision(bytes: ByteArray): SettingsRevision = try {
		val raw = TransitJson.parseToJsonElement(bytes.toString(Charsets.UTF_8)).jsonObject
		val revision = raw["revision"]?.jsonPrimitive?.takeIf { !it.isString }?.longOrNull ?: throw IllegalArgumentException()
		if (revision < 0 || !raw.containsKey("settings")) throw IllegalArgumentException()
		SettingsRevision(revision, raw.getValue("settings").takeIf { it != JsonNull }?.let(NerdsCodec::validate))
	} catch (_: Exception) { throw AccountException("Account settings returned an invalid revision.") }
	private suspend fun <T> request(components: List<String>, decoder: DeserializationStrategy<T>, method: String = "GET", token: String? = null, body: JsonElement? = null): T {
		val response = send(components, method, token, body)
		return try { TransitJson.decodeFromString(decoder, response.bytes.toString(Charsets.UTF_8)) } catch (_: Exception) { throw AccountException("Account service returned an invalid response.") }
	}
	private suspend fun send(components: List<String>, method: String, token: String? = null, body: JsonElement? = null, headers: Map<String, String> = emptyMap()): HttpPayload {
		if (token != null && (token.isEmpty() || token.any { it.code < 32 })) throw AccountException("Sign in to sync your settings.", 401)
		val payload = body?.toString(); if (payload != null && payload.toByteArray().size > MAX_SETTINGS_BYTES) throw SettingsException("Settings files must be smaller than 1 MiB.")
		val request = Request.Builder().url(requestURL(baseURL, components)).header("Accept", "application/json").apply {
			token?.let { header("Authorization", "Bearer $it") }; for ((name, value) in headers) header(name, value)
			method(method, if (method in listOf("POST", "PUT")) payload?.toRequestBody("application/json".toMediaType()) ?: "".toRequestBody() else null)
		}.build()
		// The portable settings object retains its 1 MiB cap; revisions add a small response envelope.
		val response = transport.send(request, MAX_SETTINGS_BYTES.toLong() + 16_384)
		if (response.status in 200..299) return response
		val remote = if (response.status == 412) try { revision(response.bytes) } catch (_: Exception) { null } else null
		val error = try { TransitJson.parseToJsonElement(response.bytes.toString(Charsets.UTF_8)).jsonObject["error"]?.jsonPrimitive?.takeIf { it.isString }?.content?.takeIf { it.length <= 1024 } } catch (_: Exception) { null }
		throw AccountException(error ?: if (response.status == 401) "Sign in to sync your settings." else "Account service unavailable. Your settings remain on this device.", response.status, remote)
	}
}
