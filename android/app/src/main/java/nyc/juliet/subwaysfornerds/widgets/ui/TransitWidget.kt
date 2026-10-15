package nyc.juliet.subwaysfornerds.widgets.ui

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProviderInfo
import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.datastore.preferences.core.longPreferencesKey
import androidx.glance.ColorFilter
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.LocalContext
import androidx.glance.LocalSize
import androidx.glance.action.ActionParameters
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetManager
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.LocalAppWidgetOptions
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.action.ActionCallback
import androidx.glance.appwidget.action.actionRunCallback
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.appwidget.state.getAppWidgetState
import androidx.glance.appwidget.state.updateAppWidgetState
import androidx.glance.background
import androidx.glance.currentState
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.ColumnScope
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxHeight
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.semantics.contentDescription
import androidx.glance.semantics.semantics
import androidx.glance.state.PreferencesGlanceStateDefinition
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextAlign
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import kotlin.concurrent.thread
import kotlinx.coroutines.runBlocking
import nyc.juliet.subwaysfornerds.R
import nyc.juliet.subwaysfornerds.core.Display
import nyc.juliet.subwaysfornerds.core.WidgetDisplay
import nyc.juliet.subwaysfornerds.ui.components.regionalInk
import nyc.juliet.subwaysfornerds.ui.components.routeColor
import nyc.juliet.subwaysfornerds.ui.components.routeInk
import nyc.juliet.subwaysfornerds.ui.theme.AppPalette
import nyc.juliet.subwaysfornerds.ui.theme.AppTheme
import nyc.juliet.subwaysfornerds.widgets.runtime.WidgetDeparture
import nyc.juliet.subwaysfornerds.widgets.runtime.WidgetRuntime
import nyc.juliet.subwaysfornerds.widgets.runtime.WidgetSnapshot

/** Renders the runtime's snapshot. Runtime owns refresh work; this class owns presentation. */
class TransitWidget : GlanceAppWidget() {
	/** A revision bumped on every runtime refresh; the composition reloads the snapshot when it changes. */
	override val stateDefinition = PreferencesGlanceStateDefinition

	override val sizeMode: SizeMode = SizeMode.Responsive(
		setOf(
			DpSize(110.dp, 110.dp), DpSize(180.dp, 110.dp), DpSize(250.dp, 110.dp),
			DpSize(180.dp, 180.dp), DpSize(250.dp, 180.dp), DpSize(250.dp, 280.dp), DpSize(320.dp, 380.dp),
		),
	)

	override suspend fun provideGlance(context: Context, id: GlanceId) {
		// Glance owns a durable CoroutineWorker here. Await scheduling inside that owner rather
		// than blocking the receiver's main thread or taking its PendingResult a second time.
		runCatching { WidgetRuntime.scheduleAndAwait(context) }
		// The revision is read before the snapshot, so a refresh that lands in between still triggers a reload.
		val startRevision = getAppWidgetState(context, PreferencesGlanceStateDefinition, id)[SNAPSHOT_REVISION] ?: 0L
		val initial = WidgetRuntime.readAsync(context)
		provideContent {
			// A live session only recomposes on update, so the snapshot is reloaded whenever the revision moves.
			val revision = currentState(SNAPSHOT_REVISION) ?: 0L
			var snapshot by remember { mutableStateOf(initial) }
			var loadedRevision by remember { mutableStateOf(startRevision) }
			LaunchedEffect(revision) {
				if (revision != loadedRevision) {
					snapshot = WidgetRuntime.readAsync(context)
					loadedRevision = revision
				}
			}
			WidgetBody(snapshot, System.currentTimeMillis() / 1000.0, null)
		}
	}

	override suspend fun onDelete(context: Context, glanceId: GlanceId) {
		// Glance awaits this callback before completing its receiver (or OEM fallback worker).
		runCatching { WidgetRuntime.scheduleAndAwait(context) }
		super.onDelete(context, glanceId)
	}

	companion object {
		val SNAPSHOT_REVISION = longPreferencesKey("snapshotRevision")
	}
}

/**
 * Widget placement starts periodic refresh and removing the last widget stops it; the runtime decides
 * the schedule from saved settings and the real widget count.
 *
 * Enable and disable hold their sole PendingResult while awaiting local WorkManager operations off
 * the main thread. Updates and deletions use Glance's existing asynchronous owner and the widget's
 * suspend hooks, so there is no second goAsync capture and no blocking main-thread wait.
 */
open class TransitWidgetReceiver : GlanceAppWidgetReceiver() {
	override val glanceAppWidget: GlanceAppWidget = TransitWidget()

	override fun onEnabled(context: Context) {
		super.onEnabled(context)
		whileBroadcastIsOpen(context) { app ->
			runCatching { WidgetRuntime.scheduleAndAwait(app) }
			runCatching { WidgetRuntime.requestRefreshAndAwait(app) }
		}
	}

	override fun onDisabled(context: Context) {
		super.onDisabled(context)
		whileBroadcastIsOpen(context) { app -> runCatching { WidgetRuntime.cancelScheduledRefreshAndAwait(app) } }
	}

	/** Runs off the main thread and finishes after every submitted operation completes, even on failure. */
	private fun whileBroadcastIsOpen(context: Context, work: suspend (Context) -> Unit) {
		val app = context.applicationContext
		val pending = goAsync()
		thread(name = "widget-schedule") {
			try { runBlocking { work(app) } } finally { pending?.finish() }
		}
	}
}

/** The hook runtime calls after every refresh or saved board: bump each widget's revision, then update it. */
object TransitWidgetUi {
	suspend fun updateAll(context: Context) {
		val manager = GlanceAppWidgetManager(context)
		val widget = TransitWidget()
		for (id in manager.getGlanceIds(TransitWidget::class.java)) {
			updateAppWidgetState(context, id) { preferences -> preferences[TransitWidget.SNAPSHOT_REVISION] = (preferences[TransitWidget.SNAPSHOT_REVISION] ?: 0L) + 1 }
			widget.update(context, id)
		}
	}
}

/** The refresh button: the runtime's one-shot refresh, which redraws widgets when it finishes. */
class RefreshWidgetAction : ActionCallback {
	override suspend fun onAction(context: Context, glanceId: GlanceId, parameters: ActionParameters) {
		WidgetRuntime.requestRefreshAndAwait(context)
	}
}

/** Colors for one theme; widgets keep the app theme rather than system dynamic colors. */
private class WidgetColors(theme: AppTheme) {
	private val palette = AppPalette.from(theme)
	val background = ColorProvider(theme.background)
	val card = ColorProvider(palette.card)
	val ink = ColorProvider(theme.ink)
	val muted = ColorProvider(palette.muted)
	val accent = ColorProvider(palette.action)
	val accentTint = ColorProvider(palette.accentTint)
	val warning = ColorProvider(palette.warning)
}

/** Text sizes for one widget size; small widgets keep their size, larger ones follow large text up to 135%. */
private class Metrics(val small: Boolean, val compact: Boolean, scale: Float) {
	val s = if (small) 1f else minOf(scale, 1.35f)
	val title = ((if (small) 13 else if (compact) 14 else 15) * s).sp
	val bullet = ((if (small) 16 else if (compact) 18 else 20) * s).dp
	val time = ((if (small) 12 else if (compact) 14 else 15) * s).sp
	val destination = ((if (small) 10f else if (compact) 11.5f else 12.5f) * s).sp
	val detail = ((if (small) 9 else if (compact) 9 else 10) * s).sp
	val footer = ((if (small) 9 else 10) * s).sp
	/** Approximate height of one train row, used to choose how many fit. */
	fun rowHeight(withDestination: Boolean, withDetail: Boolean): Float =
		(bullet.value + (if (withDestination && small) destination.value * 1.3f else 0f) + (if (withDetail) detail.value * 1.35f else 0f) + (if (compact) 4f else 7f))
}

/** The same body for debug previews and screenshot tests, with a fixed clock and host category. */
@Composable
internal fun WidgetPreviewBody(snapshot: WidgetSnapshot, now: Double, lockScreen: Boolean) = WidgetBody(snapshot, now, lockScreen)

@Composable
private fun WidgetBody(snapshot: WidgetSnapshot, now: Double, forcedLockScreen: Boolean?) {
	val context = LocalContext.current
	val options = LocalAppWidgetOptions.current
	val lockScreen = forcedLockScreen ?: (options.getInt(AppWidgetManager.OPTION_APPWIDGET_HOST_CATEGORY, -1) == AppWidgetProviderInfo.WIDGET_CATEGORY_KEYGUARD)
	val colors = WidgetColors(AppTheme.forId(snapshot.themeID))
	val size = LocalSize.current
	val small = size.width < 170.dp || size.height < 120.dp
	val display = if (lockScreen) snapshot.lockScreen.display else snapshot.display
	val fontScale = context.resources.configuration.fontScale
	val metrics = Metrics(small, display.compact, fontScale)
	val open = actionStartActivity(WidgetRuntime.navigationIntent(context, snapshot))
	Box(
		GlanceModifier.fillMaxSize().background(colors.background).cornerRadius(16.dp).padding(horizontal = 12.dp, vertical = 10.dp).clickable(open),
	) {
		Column(GlanceModifier.fillMaxSize()) {
			Header(snapshot, colors, metrics, display, small, lockScreen, now)
			val hasRows = snapshot.columns.any { it.rows.isNotEmpty() }
			val message = snapshot.message
			if (message != null && !hasRows) {
				Spacer(GlanceModifier.height(6.dp))
				Row(verticalAlignment = Alignment.Top) {
					Image(ImageProvider(R.drawable.kitty), contentDescription = null, modifier = GlanceModifier.size(18.dp))
					Spacer(GlanceModifier.width(6.dp))
					Text(message, style = TextStyle(color = colors.ink, fontSize = metrics.destination), maxLines = 4)
				}
			} else if (snapshot.rideKey != null) {
				RideBody(snapshot, colors, metrics, display, lockScreen, now, size.height.value)
			} else if (WidgetLayout.mixed(snapshot)) {
				MixedBody(snapshot, colors, metrics, display, lockScreen, now, size.height.value)
			} else {
				Columns(snapshot, colors, metrics, display, lockScreen, small, now, size.height.value)
			}
			if (small || lockScreen) Footer(snapshot, colors, metrics, now)
			else snapshot.notice?.takeIf { size.height >= 250.dp }?.let {
				Text(it, style = TextStyle(color = colors.muted, fontSize = metrics.footer), maxLines = 1)
			}
		}
	}
}

@Composable
private fun Header(snapshot: WidgetSnapshot, colors: WidgetColors, metrics: Metrics, display: WidgetDisplay, small: Boolean, lockScreen: Boolean, now: Double) {
	Row(GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
		if (WidgetLayout.shows(display, "stationName") || snapshot.stationID == null || snapshot.rideKey != null) {
			Text(
				if (snapshot.rideKey != null) "Your ride" else snapshot.stationName,
				style = TextStyle(color = colors.ink, fontSize = metrics.title, fontWeight = FontWeight.Medium),
				maxLines = 1,
				modifier = GlanceModifier.defaultWeight(),
			)
		} else Spacer(GlanceModifier.defaultWeight())
		if (snapshot.notice != null) {
			Image(
				ImageProvider(R.drawable.ic_widget_location_off), contentDescription = snapshot.notice,
				colorFilter = ColorFilter.tint(colors.muted), modifier = GlanceModifier.size(12.dp),
			)
		}
		if (!small && !lockScreen) {
			val showReport = WidgetLayout.shows(display, "updatedAt") || snapshot.estimated
			WidgetLayout.reportLabel(snapshot, now)?.takeIf { showReport }?.let { label ->
				Spacer(GlanceModifier.width(6.dp))
				Text("● ", style = TextStyle(color = if (snapshot.estimated) colors.warning else colors.accent, fontSize = 7.sp))
				Text(label, style = TextStyle(color = colors.muted, fontSize = metrics.footer), maxLines = 1)
			}
		}
		if (WidgetLayout.shows(display, "refreshButton") && !lockScreen) {
			Spacer(GlanceModifier.width(6.dp))
			Box(
				GlanceModifier.size(if (small) 26.dp else 30.dp).background(colors.accentTint).cornerRadius(15.dp).clickable(actionRunCallback<RefreshWidgetAction>())
					.semantics { contentDescription = "Refresh departures" },
				contentAlignment = Alignment.Center,
			) {
				Image(ImageProvider(R.drawable.ic_widget_refresh), contentDescription = null, colorFilter = ColorFilter.tint(colors.accent), modifier = GlanceModifier.size(if (small) 14.dp else 16.dp))
			}
		}
	}
}

/** Small and lock screen widgets put the report time below the trains; estimates always keep their label. */
@Composable
private fun Footer(snapshot: WidgetSnapshot, colors: WidgetColors, metrics: Metrics, now: Double) {
	val show = snapshot.estimated || WidgetLayout.shows(snapshot.display, "updatedAt")
	val label = WidgetLayout.reportLabel(snapshot, now)?.takeIf { show } ?: return
	Row(verticalAlignment = Alignment.CenterVertically) {
		Text("● ", style = TextStyle(color = if (snapshot.estimated) colors.warning else colors.accent, fontSize = 7.sp))
		Text(label, style = TextStyle(color = colors.muted, fontSize = metrics.footer), maxLines = 1)
	}
}

@Composable
private fun ColumnScope.Columns(snapshot: WidgetSnapshot, colors: WidgetColors, metrics: Metrics, display: WidgetDisplay, lockScreen: Boolean, small: Boolean, now: Double, heightDp: Float) {
	val columns = WidgetLayout.columns(snapshot, lockScreen)
	val withDestination = WidgetLayout.shows(display, "destination")
	val withDetail = columns.any { column -> column.rows.any { (if (lockScreen) it.lockDetail else it.homeDetail).isNotEmpty() || it.originLabel != null } }
	val headers = WidgetLayout.shows(display, "groupHeaders") && snapshot.groupedBy != "direction" && !small
	val footer = if (small || lockScreen) metrics.footer.value * 1.4f else 0f
	val rows = WidgetLayout.rowsThatFit(heightDp - 20f, metrics.title.value * 1.6f + 6f, footer + (if (headers) metrics.detail.value * 1.5f else 0f), metrics.rowHeight(withDestination, withDetail), display.trainsPerDirection, if (lockScreen) 6 else 14)
	Spacer(GlanceModifier.height(if (small) 4.dp else 6.dp))
	Row(GlanceModifier.fillMaxWidth().defaultWeight()) {
		columns.forEachIndexed { index, column ->
			if (index > 0) Spacer(GlanceModifier.width(if (small) 8.dp else 12.dp))
			Row(GlanceModifier.defaultWeight().fillMaxHeight(), verticalAlignment = Alignment.Top) {
				Text(
					WidgetLayout.arrow(column.direction),
					style = TextStyle(color = colors.accent, fontSize = metrics.time, fontWeight = FontWeight.Bold),
					modifier = GlanceModifier.semantics { contentDescription = column.label },
				)
				Spacer(GlanceModifier.width(3.dp))
				Column(GlanceModifier.defaultWeight()) {
					if (column.rows.isEmpty()) Text(if (small) "No matches" else "No matching trains", style = TextStyle(color = colors.muted, fontSize = metrics.detail), maxLines = 1)
					var lastGroup: String? = null
					column.rows.take(rows).forEach { row ->
						if (headers && row.groupLabel != lastGroup) {
							lastGroup = row.groupLabel
							Text(row.groupLabel.uppercase(), style = TextStyle(color = colors.muted, fontSize = 8.sp, fontWeight = FontWeight.Medium), maxLines = 1)
						}
						TrainRow(row, colors, metrics, display, lockScreen, small, snapshot.timeFormat, now, !lockScreen || snapshot.lockScreen.showService)
					}
				}
			}
		}
	}
}

@Composable
private fun TrainRow(row: WidgetDeparture, colors: WidgetColors, metrics: Metrics, display: WidgetDisplay, lockScreen: Boolean, small: Boolean, format: String, now: Double, showBullet: Boolean) {
	val detail = listOfNotNull(row.originLabel, (if (lockScreen) row.lockDetail else row.homeDetail).takeIf { it.isNotEmpty() }).joinToString(" · ")
	val arrival = WidgetLayout.arrival(row, now, format)
	val description = WidgetLayout.rowDescription(row, now, format, detail)
	Column(GlanceModifier.fillMaxWidth().padding(bottom = if (metrics.compact) 3.dp else 5.dp).semantics { contentDescription = description }) {
		Row(GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
			if (showBullet) { Bullet(row.route, metrics.bullet); Spacer(GlanceModifier.width(4.dp)) }
			if (!small && WidgetLayout.shows(display, "destination")) {
				Text(row.destination, style = TextStyle(color = colors.ink, fontSize = metrics.destination, fontWeight = FontWeight.Medium), maxLines = 1, modifier = GlanceModifier.defaultWeight())
			} else Spacer(GlanceModifier.defaultWeight())
			Text(
				arrival,
				style = TextStyle(color = if (row.cached) colors.muted else colors.ink, fontSize = if (arrival == "Passed") metrics.detail else metrics.time, fontWeight = FontWeight.Bold, textAlign = TextAlign.End),
				maxLines = 1,
			)
		}
		if (small && WidgetLayout.shows(display, "destination")) Text(row.destination, style = TextStyle(color = colors.ink, fontSize = metrics.destination), maxLines = 1)
		if (detail.isNotEmpty()) Text(detail, style = TextStyle(color = colors.muted, fontSize = metrics.detail), maxLines = 1)
	}
}

/** Merged rows for boards with both subway and PATH directions; each row keeps its direction. */
@Composable
private fun ColumnScope.MixedBody(snapshot: WidgetSnapshot, colors: WidgetColors, metrics: Metrics, display: WidgetDisplay, lockScreen: Boolean, now: Double, heightDp: Float) {
	val rows = WidgetLayout.mergedRows(snapshot)
	val count = WidgetLayout.rowsThatFit(heightDp - 20f, metrics.title.value * 1.6f, metrics.footer.value * 1.4f, metrics.rowHeight(true, true), display.trainsPerDirection, 10)
	Spacer(GlanceModifier.height(6.dp))
	Column(GlanceModifier.fillMaxWidth().defaultWeight()) {
		if (rows.isEmpty()) Text("No matching departures", style = TextStyle(color = colors.muted, fontSize = metrics.detail))
		rows.take(count).forEach { row ->
			val detail = listOfNotNull(WidgetLayout.shortDirection(row.departure.direction), row.originLabel).joinToString(" · ")
			Column(GlanceModifier.fillMaxWidth().padding(bottom = 4.dp).semantics { contentDescription = WidgetLayout.rowDescription(row, now, snapshot.timeFormat, detail) }) {
				Row(GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
					Bullet(row.route, metrics.bullet)
					Spacer(GlanceModifier.width(4.dp))
					Text(if (WidgetLayout.shows(display, "destination")) row.destination else Display.routeLabel(row.route), style = TextStyle(color = colors.ink, fontSize = metrics.destination), maxLines = 1, modifier = GlanceModifier.defaultWeight())
					Text(WidgetLayout.arrival(row, now, snapshot.timeFormat), style = TextStyle(color = if (row.cached) colors.muted else colors.ink, fontSize = metrics.time, fontWeight = FontWeight.Bold))
				}
				Text(detail, style = TextStyle(color = colors.muted, fontSize = metrics.detail), maxLines = 1)
			}
		}
		if (snapshot.message != null) Text("Partial board · tap for station status", style = TextStyle(color = colors.muted, fontSize = metrics.detail), maxLines = 1)
	}
}

/** A followed ride: the estimated next stop and the stops after it, never an observed position. */
@Composable
private fun ColumnScope.RideBody(snapshot: WidgetSnapshot, colors: WidgetColors, metrics: Metrics, display: WidgetDisplay, lockScreen: Boolean, now: Double, heightDp: Float) {
	val train = snapshot.ride?.train
	val rows = snapshot.columns.flatMap { it.rows }.sortedBy { it.arrival ?: Double.POSITIVE_INFINITY }
	val next = rows.firstOrNull()
	Spacer(GlanceModifier.height(4.dp))
	Row(verticalAlignment = Alignment.CenterVertically) {
		train?.route?.let { Bullet(it, metrics.bullet); Spacer(GlanceModifier.width(6.dp)) }
		Text(train?.destination ?: "Saved ride", style = TextStyle(color = colors.ink, fontSize = metrics.destination, fontWeight = FontWeight.Medium), maxLines = 1)
	}
	if (next == null) {
		Text(snapshot.message ?: "No future saved estimates. Reconnect for an update.", style = TextStyle(color = colors.ink, fontSize = metrics.destination), maxLines = 3)
		return
	}
	Text("Estimated next stop", style = TextStyle(color = colors.muted, fontSize = metrics.detail))
	Row(GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
		Text(next.destination, style = TextStyle(color = colors.ink, fontSize = metrics.title, fontWeight = FontWeight.Bold), maxLines = 1, modifier = GlanceModifier.defaultWeight())
		Text(WidgetLayout.arrival(next, now, snapshot.timeFormat), style = TextStyle(color = colors.ink, fontSize = metrics.time, fontWeight = FontWeight.Bold))
	}
	val remaining = WidgetLayout.rowsThatFit(heightDp - 20f, metrics.title.value * 4f + 20f, metrics.footer.value * 2.6f, metrics.detail.value * 1.8f, 0, 5)
	if (heightDp >= 220f) rows.drop(1).take(remaining).forEach { stop ->
		Row(GlanceModifier.fillMaxWidth()) {
			Text(stop.destination, style = TextStyle(color = colors.ink, fontSize = metrics.detail), maxLines = 1, modifier = GlanceModifier.defaultWeight())
			Text(WidgetLayout.arrival(stop, now, snapshot.timeFormat), style = TextStyle(color = colors.muted, fontSize = metrics.detail))
		}
	}
	Spacer(GlanceModifier.defaultWeight())
	if (snapshot.ride?.isComplete == false) Text("Partial saved trip", style = TextStyle(color = colors.muted, fontSize = metrics.detail))
	if (!lockScreen) WidgetLayout.reportLabel(snapshot, now)?.let { Text(it, style = TextStyle(color = colors.muted, fontSize = metrics.footer), maxLines = 2) }
}

/** A line bullet: subway letters in their color, PATH and light rail names in a rounded badge. */
@Composable
private fun Bullet(route: String, diameter: androidx.compose.ui.unit.Dp) {
	val regional = Display.regionalRoute(route)
	if (regional != null) {
		Box(
			GlanceModifier.height(diameter).background(ColorProvider(Color(0xFF000000 or regional.colors.first()))).cornerRadius(diameter * 0.3f).padding(horizontal = 4.dp),
			contentAlignment = Alignment.Center,
		) {
			Text(regional.label, style = TextStyle(color = ColorProvider(regionalInk(route)), fontSize = (diameter.value * 0.5f).sp, fontWeight = FontWeight.Bold), maxLines = 1)
		}
	} else {
		val label = Display.displayRoute(route)
		Box(
			GlanceModifier.size(diameter).background(ColorProvider(routeColor(route))).cornerRadius(diameter / 2),
			contentAlignment = Alignment.Center,
		) {
			Text(label, style = TextStyle(color = ColorProvider(routeInk(route)), fontSize = (diameter.value * if (label.length > 1) 0.42f else 0.6f).sp, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center), maxLines = 1)
		}
	}
}
