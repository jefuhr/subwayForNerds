package nyc.juliet.subwaysfornerds.core

import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.hypot
import kotlin.math.log2
import kotlin.math.pow
import kotlin.math.roundToInt

/** Screen = page point × scale + offset. Page and screen y both grow downward, so no flip is applied. */
data class TrackMapViewport(val scale: Double, val offsetX: Double, val offsetY: Double) {
	fun toScreen(point: TrackMapPoint): TrackMapPoint = TrackMapPoint(point.x * scale + offsetX, point.y * scale + offsetY)
	fun toPage(x: Double, y: Double): TrackMapPoint = TrackMapPoint((x - offsetX) / scale, (y - offsetY) / scale)
}

/**
 * What the map shows: a page point at the view's centre and pixels per PDF point. Stored independently
 * of view size, so rotation and window resizing keep the same place and zoom.
 */
data class TrackMapCamera(val centerX: Double, val centerY: Double, val scale: Double) {
	fun viewport(width: Double, height: Double): TrackMapViewport = TrackMapViewport(scale, width / 2 - centerX * scale, height / 2 - centerY * scale)

	/** Zooms by [factor] keeping the page point under the focus fixed on screen. */
	fun zoomed(factor: Double, focusX: Double, focusY: Double, width: Double, height: Double, page: TrackMapPage): TrackMapCamera {
		if (!factor.isFinite() || factor <= 0) return this
		val next = (scale * factor).coerceIn(minScale(page, width, height), MAX_SCALE)
		val focus = viewport(width, height).toPage(focusX, focusY)
		return TrackMapCamera(focus.x - (focusX - width / 2) / next, focus.y - (focusY - height / 2) / next, next).clamped(page)
	}

	/** Moves the artwork with a drag of (dx, dy) pixels; the centre never leaves the page. */
	fun panned(dx: Double, dy: Double, page: TrackMapPage): TrackMapCamera = copy(centerX = centerX - dx / scale, centerY = centerY - dy / scale).clamped(page)

	/** Whole PDF points and whole zoom percent, stable across redraws, for accessibility and acceptance tests. */
	fun summary(): TrackMapViewportSummary = TrackMapViewportSummary(centerX.roundToInt(), centerY.roundToInt(), (scale * 100).roundToInt())

	fun clamped(page: TrackMapPage): TrackMapCamera = copy(
		centerX = centerX.takeIf { it.isFinite() }?.coerceIn(0.0, page.width) ?: (page.width / 2),
		centerY = centerY.takeIf { it.isFinite() }?.coerceIn(0.0, page.height) ?: (page.height / 2),
	)

	companion object {
		/** Close zoom where train bodies are drawn along the rail. */
		const val MAX_SCALE = 8.0
		const val DETAIL_SCALE = 1.5
		/** A station is focused at this zoom. */
		const val STATION_SCALE = 1.0

		fun fitScale(page: TrackMapPage, width: Double, height: Double, padding: Double = 0.0): Double =
			minOf((width - 2 * padding) / page.width, (height - 2 * padding) / page.height).takeIf { it.isFinite() && it > 0 } ?: 0.01

		fun minScale(page: TrackMapPage, width: Double, height: Double): Double = minOf(fitScale(page, width, height) * 0.75, MAX_SCALE)

		fun fit(page: TrackMapPage, width: Double, height: Double, padding: Double = 0.0): TrackMapCamera =
			TrackMapCamera(page.width / 2, page.height / 2, fitScale(page, width, height, padding))

		fun centered(point: TrackMapPoint, scale: Double, page: TrackMapPage): TrackMapCamera = TrackMapCamera(point.x, point.y, scale.coerceAtMost(MAX_SCALE)).clamped(page)
	}
}

/** The rounded camera the map exposes; the centre is in top-left PDF points. */
data class TrackMapViewportSummary(val centerX: Int, val centerY: Int, val zoomPercent: Int) {
	val description: String get() = "Centre $centerX, $centerY · zoom $zoomPercent%"
}

data class TrackMapTile(val level: Int, val col: Int, val row: Int)

/**
 * Tiles of the artwork rendered at power-of-two scales, so the full 7344 × 11540 point page is never one
 * bitmap. A coarse overview underlays tiles while they render.
 */
object TrackMapTiles {
	const val TILE_PIXELS = 512
	const val MAX_LEVEL = 7
	const val TILE_BYTES = TILE_PIXELS.toLong() * TILE_PIXELS * 4
	/** Overview bitmap width in pixels (about 6.6 MB in ARGB_8888). */
	const val OVERVIEW_PIXELS = 1024
	private const val MEGABYTE = 1_048_576L

	/** Pixels per PDF point at a level: level 0 is 1/16, level 7 is 8. */
	fun levelScale(level: Int): Double = 2.0.pow(level) / 16.0

	/** The coarsest level at least as sharp as the display scale. */
	fun level(scale: Double): Int = ceil(log2(scale * 16)).takeIf { it.isFinite() }?.toInt()?.coerceIn(0, MAX_LEVEL) ?: 0

	/** The sharpest level whose visible tiles fit [maxTiles]; coarser tiles upscale instead of overflowing the cache. */
	fun levelWithin(camera: TrackMapCamera, width: Double, height: Double, page: TrackMapPage, maxTiles: Int): Int {
		var level = level(camera.scale)
		while (level > 0 && visible(camera, width, height, page, level).size > maxTiles) level--
		return level
	}

	fun tilePoints(level: Int): Double = TILE_PIXELS / levelScale(level)

	/** Tiles intersecting the view, nearest the centre first. */
	fun visible(camera: TrackMapCamera, width: Double, height: Double, page: TrackMapPage, level: Int): List<TrackMapTile> {
		val view = camera.viewport(width, height)
		val topLeft = view.toPage(0.0, 0.0); val bottomRight = view.toPage(width, height)
		val x0 = topLeft.x.coerceIn(0.0, page.width); val x1 = bottomRight.x.coerceIn(0.0, page.width)
		val y0 = topLeft.y.coerceIn(0.0, page.height); val y1 = bottomRight.y.coerceIn(0.0, page.height)
		if (x1 <= x0 || y1 <= y0) return emptyList()
		val size = tilePoints(level)
		val lastCol = ceil(page.width / size).toInt() - 1; val lastRow = ceil(page.height / size).toInt() - 1
		val cols = floor(x0 / size).toInt().coerceIn(0, lastCol)..ceil(x1 / size).toInt().minus(1).coerceIn(0, lastCol)
		val rows = floor(y0 / size).toInt().coerceIn(0, lastRow)..ceil(y1 / size).toInt().minus(1).coerceIn(0, lastRow)
		return cols.flatMap { col -> rows.map { row -> TrackMapTile(level, col, row) } }
			.sortedBy { hypot((it.col + 0.5) * size - camera.centerX, (it.row + 0.5) * size - camera.centerY) }
	}

	/** Tile cache size from the app's heap limit: an eighth, between 16 and 48 MB. */
	fun cacheBytes(maxHeapBytes: Long): Long = (maxHeapBytes / 8).coerceIn(16 * MEGABYTE, 48 * MEGABYTE)
	fun maxTiles(cacheBytes: Long): Int = (cacheBytes / TILE_BYTES).toInt().coerceAtLeast(1)
}

object TrackMapHitTest {
	/** Keys whose screen points are within [radius] of a tap, nearest first. */
	fun <K> within(points: List<Pair<K, TrackMapPoint>>, x: Double, y: Double, radius: Double): List<K> =
		points.map { (key, point) -> key to hypot(point.x - x, point.y - y) }.filter { it.second <= radius }.sortedBy { it.second }.map { it.first }
}
