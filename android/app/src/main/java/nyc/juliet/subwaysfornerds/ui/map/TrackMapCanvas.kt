package nyc.juliet.subwaysfornerds.ui.map

import android.graphics.Bitmap
import android.graphics.Paint
import android.graphics.RectF
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.runtime.Composable
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.SemanticsPropertyKey
import androidx.compose.ui.semantics.SemanticsPropertyReceiver
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import nyc.juliet.subwaysfornerds.core.Display
import nyc.juliet.subwaysfornerds.core.TrackMapCamera
import nyc.juliet.subwaysfornerds.core.TrackMapFreshness
import nyc.juliet.subwaysfornerds.core.TrackMapPage
import nyc.juliet.subwaysfornerds.core.TrackMapPlacement
import nyc.juliet.subwaysfornerds.core.TrackMapPoint
import nyc.juliet.subwaysfornerds.core.TrackMapTiles
import nyc.juliet.subwaysfornerds.core.TrackMapViewport
import nyc.juliet.subwaysfornerds.core.TrackMapViewportSummary
import nyc.juliet.subwaysfornerds.ui.components.routeColor
import nyc.juliet.subwaysfornerds.ui.components.routeInk
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.roundToInt
import kotlin.math.sin

/** Length of the drawn train body at close zoom, in PDF points. A symbol size; its shape follows real rail points. */
private const val TRAIN_BODY_POINTS = 22.0
private val OutsidePage = Color(0xFFE6E6E6)

/** The canvas's rounded camera for acceptance tests; it is also spoken as the canvas's state description. */
val TrackMapViewportKey = SemanticsPropertyKey<TrackMapViewportSummary>("TrackMapViewport")
var SemanticsPropertyReceiver.trackMapViewport by TrackMapViewportKey

/**
 * The artwork with trains over it. The PDF keeps its original colours in every app theme. Markers are a fixed
 * screen size; at close zoom each train's body is drawn along the rail behind it.
 */
@Composable
internal fun TrackMapCanvas(
	map: TrackMapModel,
	renderer: TrackMapRenderer,
	page: TrackMapPage,
	time: () -> Double,
	reducedMotion: Boolean,
	description: String,
	onTap: (Offset, Float) -> Unit,
	onFit: () -> Unit,
	modifier: Modifier = Modifier,
) {
	val measurer = rememberTextMeasurer()
	val bitmapPaint = remember { Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG) }
	val currentOnTap by rememberUpdatedState(onTap)
	// Rounded, so gestures recompose only when the exposed values change.
	val viewport by remember(map) { derivedStateOf { map.camera?.summary() } }
	Canvas(
		modifier
			.testTag("track-map-canvas")
			.semantics {
				contentDescription = description
				viewport?.let { trackMapViewport = it; stateDescription = it.description }
				customActions = listOf(
					CustomAccessibilityAction("Zoom in") { zoomBy(map, page, 2.0); true },
					CustomAccessibilityAction("Zoom out") { zoomBy(map, page, 0.5); true },
					CustomAccessibilityAction("Fit map") { onFit(); true },
				)
			}
			.pointerInput(map, page) {
				detectTransformGestures { centroid, pan, zoom, _ ->
					val camera = map.camera ?: return@detectTransformGestures
					val w = size.width.toDouble(); val h = size.height.toDouble()
					map.camera = camera.panned(pan.x.toDouble(), pan.y.toDouble(), page).zoomed(zoom.toDouble(), centroid.x.toDouble(), centroid.y.toDouble(), w, h, page)
				}
			}
			.pointerInput(map, page) {
				detectTapGestures(
					onDoubleTap = { at ->
						val camera = map.camera ?: return@detectTapGestures
						map.camera = camera.zoomed(2.0, at.x.toDouble(), at.y.toDouble(), size.width.toDouble(), size.height.toDouble(), page)
					},
					onTap = { at -> currentOnTap(at, 24.dp.toPx()) },
				)
			},
	) {
		val camera = map.camera ?: return@Canvas
		// Read so a newly rendered tile redraws.
		renderer.revision
		val view = camera.viewport(size.width.toDouble(), size.height.toDouble())
		drawRect(OutsidePage)
		drawArtwork(renderer, view, camera, page, bitmapPaint)
		val markers = map.markers(time(), reducedMotion)
		for (marker in markers) drawTrain(marker, view, camera, measurer)
	}
}

private fun zoomBy(map: TrackMapModel, page: TrackMapPage, factor: Double) {
	val camera = map.camera ?: return
	val (w, h) = map.viewSize ?: return
	map.camera = camera.zoomed(factor, w / 2, h / 2, w, h, page)
}

private fun DrawScope.drawArtwork(renderer: TrackMapRenderer, view: TrackMapViewport, camera: TrackMapCamera, page: TrackMapPage, paint: Paint) {
	val w = size.width.toDouble(); val h = size.height.toDouble()
	drawIntoCanvas { canvas ->
		val native = canvas.nativeCanvas
		val pageTopLeft = view.toScreen(TrackMapPoint(0.0, 0.0)); val pageBottomRight = view.toScreen(TrackMapPoint(page.width, page.height))
		native.drawRect(pageTopLeft.x.toFloat(), pageTopLeft.y.toFloat(), pageBottomRight.x.toFloat(), pageBottomRight.y.toFloat(), Paint().apply { color = android.graphics.Color.WHITE })
		renderer.overview?.let { native.drawBitmap(it, null, RectF(pageTopLeft.x.toFloat(), pageTopLeft.y.toFloat(), pageBottomRight.x.toFloat(), pageBottomRight.y.toFloat()), paint) }
		val level = TrackMapTiles.levelWithin(camera, w, h, page, renderer.maxTiles - 2)
		// Tiles sharper than the overview only; at overview scale the overview is the artwork.
		if (camera.scale <= TrackMapTiles.OVERVIEW_PIXELS / page.width) { renderer.request(emptyList()); return@drawIntoCanvas }
		val tiles = TrackMapTiles.visible(camera, w, h, page, level)
		renderer.request(tiles)
		val span = TrackMapTiles.tilePoints(level)
		for (tile in tiles) {
			val bitmap: Bitmap = renderer.tile(tile) ?: continue
			// Shared edges round identically, so neighbouring tiles never leave a seam.
			val left = view.toScreen(TrackMapPoint(tile.col * span, tile.row * span)); val right = view.toScreen(TrackMapPoint((tile.col + 1) * span, (tile.row + 1) * span))
			native.drawBitmap(bitmap, null, RectF(left.x.roundToInt().toFloat(), left.y.roundToInt().toFloat(), right.x.roundToInt().toFloat(), right.y.roundToInt().toFloat()), paint)
		}
	}
}

private fun DrawScope.drawTrain(marker: TrackMapMarker, view: TrackMapViewport, camera: TrackMapCamera, measurer: TextMeasurer) {
	val shown = marker.display
	val at = view.toScreen(shown.point)
	val margin = 64.dp.toPx()
	if (at.x < -margin || at.y < -margin || at.x > size.width + margin || at.y > size.height + margin) return
	val center = Offset(at.x.toFloat(), at.y.toFloat())
	val train = marker.train
	val color = routeColor(train.route)
	val stale = marker.evidence.freshness != TrackMapFreshness.LIVE
	val alpha = if (stale) 0.55f else 1f
	val path = shown.path; val distance = shown.distance
	if (camera.scale >= TrackMapCamera.DETAIL_SCALE && path != null && distance != null) {
		val body = path.trail(distance, TRAIN_BODY_POINTS)
		if (body.size >= 2) {
			val line = Path().apply {
				body.forEachIndexed { i, p -> val s = view.toScreen(p); if (i == 0) moveTo(s.x.toFloat(), s.y.toFloat()) else lineTo(s.x.toFloat(), s.y.toFloat()) }
			}
			val width = max(5.dp.toPx(), (2.5 * camera.scale).toFloat())
			drawPath(line, Color.White, alpha = alpha, style = Stroke(width + 3.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round))
			drawPath(line, color, alpha = alpha, style = Stroke(width, cap = StrokeCap.Round, join = StrokeJoin.Round))
		}
	}
	val label = measurer.measure(Display.displayRoute(train.route), TextStyle(fontSize = 11.sp, fontWeight = FontWeight.Black, color = routeInk(train.route)))
	val radius = max(10.dp.toPx(), max(label.size.width, label.size.height) / 2f + 3.dp.toPx())
	shown.heading?.let { heading ->
		val dx = cos(heading).toFloat(); val dy = sin(heading).toFloat()
		val tip = center + Offset(dx, dy) * (radius + 7.dp.toPx())
		val base = center + Offset(dx, dy) * (radius - 1.dp.toPx())
		val side = Offset(-dy, dx) * 6.dp.toPx()
		val arrow = Path().apply { moveTo(tip.x, tip.y); lineTo(base.x + side.x, base.y + side.y); lineTo(base.x - side.x, base.y - side.y); close() }
		drawPath(arrow, color, alpha = alpha)
		drawPath(arrow, Color.White, alpha = alpha, style = Stroke(1.dp.toPx()))
	}
	val dashed = PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 3.dp.toPx()))
	if (train.placement == TrackMapPlacement.NEAR_STOP) {
		// Position is only near a station: a hollow, dashed ring.
		drawCircle(Color.White, radius, center, alpha = 0.85f)
		drawCircle(color, radius, center, alpha = alpha, style = Stroke(2.5.dp.toPx(), pathEffect = dashed))
		val ink = measurer.measure(Display.displayRoute(train.route), TextStyle(fontSize = 11.sp, fontWeight = FontWeight.Black, color = Color.Black))
		drawText(ink, topLeft = center - Offset(ink.size.width / 2f, ink.size.height / 2f), alpha = alpha)
	} else {
		drawCircle(color, radius, center, alpha = alpha)
		drawCircle(Color.White, radius, center, alpha = alpha, style = Stroke(1.5.dp.toPx(), pathEffect = if (stale) dashed else null))
		drawText(label, topLeft = center - Offset(label.size.width / 2f, label.size.height / 2f), alpha = alpha)
	}
}
