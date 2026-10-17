package nyc.juliet.subwaysfornerds.ui.map

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerializationException
import nyc.juliet.subwaysfornerds.core.TrackMapContract
import nyc.juliet.subwaysfornerds.core.TrackMapTopology
import nyc.juliet.subwaysfornerds.core.TransitJson
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.security.MessageDigest

/**
 * Reads the locally prepared map from `assets/track-map/`: reviewed topology and the artwork it was drawn on.
 * The artwork is copied to the app's cache (PdfRenderer needs a seekable file and assets may be compressed),
 * hashed as it copies, and accepted only when it matches the topology's reviewed digest.
 */
class AndroidTrackMapAssets(private val context: Context) : TrackMapAssetSource {
	override suspend fun load(): TrackMapResources = withContext(Dispatchers.IO) {
		val assets = context.assets
		val text = try {
			assets.open("$DIRECTORY/topology.json").use { it.readBytes().toString(Charsets.UTF_8) }
		} catch (_: FileNotFoundException) { throw TrackMapUnavailableException(NOT_INSTALLED) }
		val topology = try { TransitJson.decodeFromString(TrackMapTopology.serializer(), text) }
			catch (_: SerializationException) { throw TrackMapUnavailableException("The installed track map data could not be read.") }
			catch (_: IllegalArgumentException) { throw TrackMapUnavailableException("The installed track map data could not be read.") }
		val directory = File(context.cacheDir, DIRECTORY).apply { mkdirs() }
		val target = File(directory, "${TrackMapContract.MAP_VERSION}.pdf")
		val partial = File(directory, "${TrackMapContract.MAP_VERSION}.pdf.partial")
		val digest = MessageDigest.getInstance("SHA-256")
		try {
			assets.open("$DIRECTORY/$PDF").use { input ->
				partial.outputStream().use { output ->
					val buffer = ByteArray(64 * 1024)
					var total = 0L
					while (true) {
						ensureActive()
						val count = input.read(buffer); if (count < 0) break
						total += count
						if (total > MAX_PDF_BYTES) throw TrackMapUnavailableException("The installed track map artwork is larger than expected.")
						digest.update(buffer, 0, count); output.write(buffer, 0, count)
					}
				}
			}
		} catch (_: FileNotFoundException) { partial.delete(); throw TrackMapUnavailableException(NOT_INSTALLED) }
		catch (error: Exception) { partial.delete(); throw error }
		val sha = digest.digest().joinToString("") { "%02x".format(it) }
		try { TrackMapContract.validateTopology(topology, sha) } catch (error: Exception) { partial.delete(); throw error }
		if (!partial.renameTo(target)) { partial.delete(); throw IOException("Could not prepare the track map artwork.") }
		TrackMapResources(topology, target)
	}

	companion object {
		const val DIRECTORY = "track-map"
		const val PDF = "NYC_full_trackmap.pdf"
		private const val MAX_PDF_BYTES = 16L * 1_048_576L
		const val NOT_INSTALLED = "This build does not include the track map artwork. It is prepared locally for development and is not distributed with the app."
	}
}
