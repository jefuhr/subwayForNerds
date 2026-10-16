package nyc.juliet.subwaysfornerds.ui.map

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import android.util.LruCache
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.withContext
import nyc.juliet.subwaysfornerds.core.TrackMapPage
import nyc.juliet.subwaysfornerds.core.TrackMapTile
import nyc.juliet.subwaysfornerds.core.TrackMapTiles
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlin.math.abs
import kotlin.math.ceil

/**
 * Native tiled rendering of the map artwork with [PdfRenderer]. Every renderer call runs on one background
 * thread (PdfRenderer is not thread-safe), never on the main thread. Memory is bounded: one ~6.6 MB overview
 * plus a tile LRU of [TrackMapTiles.cacheBytes] (16–48 MB of 1 MB tiles). The 7344 × 11540 point page is never
 * rendered into a single full-resolution bitmap.
 */
class TrackMapRenderer private constructor(
	private val executor: ExecutorService,
	private val descriptor: ParcelFileDescriptor,
	private val renderer: PdfRenderer,
	private val page: PdfRenderer.Page,
	val pageSize: TrackMapPage,
	val cacheBytes: Long,
) {
	private val dispatcher = executor.asCoroutineDispatcher()
	private val cache = object : LruCache<TrackMapTile, Bitmap>(cacheBytes.toInt()) {
		override fun sizeOf(key: TrackMapTile, value: Bitmap): Int = value.allocationByteCount
	}
	private val wanted = MutableStateFlow<List<TrackMapTile>>(emptyList())
	@Volatile private var closed = false

	var overview by mutableStateOf<Bitmap?>(null); private set
	/** Bumps when a tile lands, so the canvas redraws. */
	var revision by mutableIntStateOf(0); private set
	val maxTiles: Int get() = TrackMapTiles.maxTiles(cacheBytes)

	fun tile(tile: TrackMapTile): Bitmap? = cache.get(tile)

	/** Replaces the wanted set; tiles no longer wanted are skipped without rendering. */
	fun request(tiles: List<TrackMapTile>) { wanted.value = tiles.take(maxTiles) }

	/** Renders the overview, then wanted tiles nearest the centre first, until cancelled. */
	suspend fun run() {
		if (overview == null) overview = withContext(dispatcher) { renderOverview() } ?: return
		wanted.collectLatest { tiles ->
			for (tile in tiles) {
				currentCoroutineContext().ensureActive()
				if (cache.get(tile) != null) continue
				val bitmap = withContext(dispatcher) { renderTile(tile) } ?: return@collectLatest
				cache.put(tile, bitmap)
				revision += 1
			}
		}
	}

	private fun renderOverview(): Bitmap? {
		if (closed) return null
		val scale = TrackMapTiles.OVERVIEW_PIXELS / pageSize.width
		val bitmap = Bitmap.createBitmap(TrackMapTiles.OVERVIEW_PIXELS, ceil(pageSize.height * scale).toInt(), Bitmap.Config.ARGB_8888)
		bitmap.eraseColor(Color.WHITE)
		page.render(bitmap, null, Matrix().apply { setScale(scale.toFloat(), scale.toFloat()) }, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
		return bitmap
	}

	private fun renderTile(tile: TrackMapTile): Bitmap? {
		if (closed) return null
		val scale = TrackMapTiles.levelScale(tile.level).toFloat()
		val size = TrackMapTiles.TILE_PIXELS
		val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
		bitmap.eraseColor(Color.WHITE)
		// Page coordinates are points from the crop box's top left, the same origin as the topology.
		val matrix = Matrix().apply { setScale(scale, scale); postTranslate(-tile.col * size.toFloat(), -tile.row * size.toFloat()) }
		page.render(bitmap, null, matrix, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
		return bitmap
	}

	/** Closes the document on its own thread after any render in progress. */
	fun close() {
		closed = true
		cache.evictAll()
		executor.execute {
			runCatching { page.close() }; runCatching { renderer.close() }; runCatching { descriptor.close() }
		}
		executor.shutdown()
	}

	companion object {
		/** Opens the verified artwork off the main thread; fails when its page is not the topology's page. */
		suspend fun open(pdf: File, expected: TrackMapPage, maxHeapBytes: Long): TrackMapRenderer {
			val executor = Executors.newSingleThreadExecutor { runnable -> Thread(runnable, "track-map-render").apply { isDaemon = true } }
			try {
				return withContext(executor.asCoroutineDispatcher()) {
					val descriptor = ParcelFileDescriptor.open(pdf, ParcelFileDescriptor.MODE_READ_ONLY)
					try {
						val renderer = PdfRenderer(descriptor)
						if (renderer.pageCount < 1) { renderer.close(); throw TrackMapUnavailableException("The installed track map artwork has no pages.") }
						val page = renderer.openPage(0)
						// Page sizes are whole points here; the reviewed crop box is 7344 × 11540.6.
						if (abs(page.width - expected.width) > 1 || abs(page.height - expected.height) > 1) {
							page.close(); renderer.close()
							throw TrackMapUnavailableException("The installed track map artwork is not the reviewed page size.")
						}
						TrackMapRenderer(executor, descriptor, renderer, page, expected, TrackMapTiles.cacheBytes(maxHeapBytes))
					} catch (error: Exception) { runCatching { descriptor.close() }; throw error }
				}
			} catch (error: Exception) {
				executor.shutdown()
				throw error
			}
		}
	}
}
