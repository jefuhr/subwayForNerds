package nyc.juliet.subwaysfornerds.ui

import java.net.URI
import java.net.URLDecoder
import java.nio.charset.StandardCharsets

/** A validated app link. Anything else is ignored rather than guessed at. */
sealed interface DeepLink {
	data class Station(val id: String) : DeepLink
	data class Ride(val tripKey: String) : DeepLink
	data class AuthCallback(val uri: String) : DeepLink
}

/**
 * Strict, bounded parsing for links from widgets, notifications, browsers and other apps:
 * exact scheme and host, no user info, port, fragment or extra path, exactly one non-empty
 * query value without duplicates, and length limits matching saved identifiers.
 */
object DeepLinks {
	const val MAX_LINK_LENGTH = 2048
	private const val MAX_ID = 128
	private const val MAX_TRIP_KEY = 512

	fun parse(text: String?): DeepLink? {
		if (text == null || text.isEmpty() || text.length > MAX_LINK_LENGTH || text.any { it.code < 32 || it == '\u007f' }) return null
		val uri = try { URI(text) } catch (_: Exception) { return null }
		if (uri.rawUserInfo != null || uri.port != -1 || uri.rawFragment != null) return null
		return when (uri.scheme) {
			"subwaynerds" -> when (uri.host) {
				"board" -> single(uri, "station", MAX_ID)?.takeIf(::validStationID)?.let(DeepLink::Station)
				"ride" -> single(uri, "key", MAX_TRIP_KEY)?.let(DeepLink::Ride)
				else -> null
			}
			// Core validates the PKCE state, handoff and expiry; only the exact callback shape reaches it.
			"nyc.juliet.subwaysfornerds" -> if (uri.host == "auth" && uri.rawPath == "/android" && uri.rawQuery != null) DeepLink.AuthCallback(text) else null
			else -> null
		}
	}

	private fun single(uri: URI, name: String, maximum: Int): String? {
		if (!(uri.rawPath.isNullOrEmpty() || uri.rawPath == "/")) return null
		val query = uri.rawQuery ?: return null
		val pairs = query.split('&')
		if (pairs.size != 1) return null
		val parts = pairs[0].split('=', limit = 2)
		if (parts.size != 2 || parts[0] != name) return null
		// The charset-name overload exists on every API level; decode(String, Charset) needs API 33.
		val value = try { URLDecoder.decode(parts[1], StandardCharsets.UTF_8.name()) } catch (_: Exception) { return null }
		if (value.isEmpty() || value.length > maximum || value.any { it.code < 32 || it == '\u007f' } || value.trim() != value) return null
		return value
	}

	/** Catalog or combined station identifiers, as saved settings accept them. */
	private fun validStationID(id: String): Boolean = id.length <= MAX_ID && id.none { it.isWhitespace() }
}
