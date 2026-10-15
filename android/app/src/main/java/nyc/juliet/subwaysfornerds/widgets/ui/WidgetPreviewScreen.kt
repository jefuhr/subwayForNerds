package nyc.juliet.subwaysfornerds.widgets.ui

import android.widget.FrameLayout
import android.widget.RemoteViews
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.glance.appwidget.ExperimentalGlanceRemoteViewsApi
import androidx.glance.appwidget.GlanceRemoteViews
import nyc.juliet.subwaysfornerds.core.Board
import nyc.juliet.subwaysfornerds.core.Consist
import nyc.juliet.subwaysfornerds.core.ConsistCar
import nyc.juliet.subwaysfornerds.core.Departure
import nyc.juliet.subwaysfornerds.core.Settings
import nyc.juliet.subwaysfornerds.core.SourceState
import nyc.juliet.subwaysfornerds.core.Station
import nyc.juliet.subwaysfornerds.ui.AppModel
import nyc.juliet.subwaysfornerds.ui.components.ListScreen
import nyc.juliet.subwaysfornerds.ui.components.RowContainer
import nyc.juliet.subwaysfornerds.ui.components.ScreenExit
import nyc.juliet.subwaysfornerds.ui.components.section
import nyc.juliet.subwaysfornerds.ui.theme.TextRoles
import nyc.juliet.subwaysfornerds.ui.theme.palette
import nyc.juliet.subwaysfornerds.widgets.runtime.WidgetSnapshot
import nyc.juliet.subwaysfornerds.widgets.runtime.WidgetSnapshotFactory

/** Example boards for the debug preview gallery. They are labeled examples, never shown as live data. */
object WidgetExamples {
	fun station(name: String = "Church Av", routes: List<String> = listOf("B", "Q")) = Station("44", name, "Bk", routes, 40.65, -73.96)

	fun board(now: Double, station: Station = station(), regional: Boolean = false, sourceAge: Double = 15.0): Board {
		val rows = (0 until 16).map { index ->
			val north = index % 2 == 0
			val route = if (regional) (if (index % 3 == 0) "PATH-JSQ-33-HOB" else "PATH-NWK-WTC") else if (index % 3 == 0) "B" else "Q"
			Departure(
				key = "example-$index", tripKey = "example-$index", route = route,
				destination = if (regional) (if (north) "33 St" else "Newark") else if (north) "96 St" else "Coney Island",
				direction = if (regional) (if (north) "TO_NY" else "TO_NJ") else if (north) "NORTH" else "SOUTH",
				stopId = "D28", partId = "D28", area = "Brighton", time = now + (index + 2) * 60.0,
				pattern = "Local", patternSource = "reported", location = "", feed = if (regional) "path" else "gtfs-nqrw", timestamp = now - sourceAge,
				scheduledTrack = if (north) "A2" else "A1",
				consist = Consist(listOf(ConsistCar("4149", "R211A"), ConsistCar("4148", "R211A")), now - sourceAge, now - sourceAge),
			)
		}
		return Board(station, now, listOf(SourceState(if (regional) "path" else "gtfs-nqrw", now - sourceAge, now)), rows)
	}

	fun scenarios(settings: Settings, now: Double): List<Pair<String, WidgetSnapshot>> = listOf(
		"Example · live" to WidgetSnapshotFactory.board(board(now), settings, now, cached = false),
		"Example · saved" to WidgetSnapshotFactory.board(board(now, sourceAge = 600.0), settings, now, cached = true),
		"Example · old saved" to WidgetSnapshotFactory.board(board(now, sourceAge = 9000.0), settings, now, cached = true),
		"Example · PATH" to WidgetSnapshotFactory.board(board(now, station("Journal Square", listOf("PATH-JSQ-33-HOB", "PATH-NWK-WTC")), regional = true), settings, now, cached = false),
		"Example · long name" to WidgetSnapshotFactory.board(board(now, station("Court Sq–23 St (E M G 7) Long Island City")), settings, now, cached = false),
		"Example · location unavailable" to WidgetSnapshotFactory.board(board(now), settings, now, cached = false, notice = "Location unavailable · saved station"),
		"Example · empty" to WidgetSnapshotFactory.board(Board(station(), now), settings, now, cached = false),
		"No favorites" to WidgetSnapshot(themeID = settings.theme, message = "Add a favorite or choose Closest station in Settings.", generatedAt = now),
	)
}

/** Debug gallery rendering the widget's actual RemoteViews in each size and on the lock screen. */
@OptIn(ExperimentalGlanceRemoteViewsApi::class)
@Composable
fun WidgetPreviewScreen(model: AppModel, exit: ScreenExit, close: () -> Unit) {
	val now = model.now
	val scenarios = remember(model.settings, (now / 60).toLong()) { WidgetExamples.scenarios(model.settings, now) }
	val sizes = listOf("Small" to DpSize(150.dp, 150.dp), "Medium" to DpSize(300.dp, 150.dp), "Large" to DpSize(300.dp, 320.dp))
	ListScreen("Widget previews", exit = exit, onExit = close, tag = "widgetPreviewScreen") {
		section("about", footer = "Examples use made-up trains to check layout only. Home screen previews use the selected app theme; actual widgets also depend on the launcher.") {
			row { RowContainer { Text("Every size reserves both directions. Times are arrival clocks with the report time.", style = TextRoles.footnote, color = palette.muted) } }
		}
		scenarios.forEach { (name, snapshot) ->
			section("scenario:$name", header = name) {
				sizes.forEach { (label, size) -> row(label) { WidgetPreview(snapshot, now, size, lockScreen = false, label = "$label · $name") } }
				row("lock") { WidgetPreview(snapshot, now, DpSize(250.dp, 110.dp), lockScreen = true, label = "Lock screen · $name") }
			}
		}
	}
}

@OptIn(ExperimentalGlanceRemoteViewsApi::class)
@Composable
private fun WidgetPreview(snapshot: WidgetSnapshot, now: Double, size: DpSize, lockScreen: Boolean, label: String) {
	val context = LocalContext.current
	var views by remember(snapshot, size, lockScreen) { mutableStateOf<RemoteViews?>(null) }
	LaunchedEffect(snapshot, size, lockScreen) {
		views = runCatching { GlanceRemoteViews().compose(context, size) { WidgetPreviewBody(snapshot, now, lockScreen) }.remoteViews }.getOrNull()
	}
	Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
		Text(label, style = TextRoles.caption, color = palette.muted)
		val current = views
		if (current == null) Text("Rendering…", style = TextRoles.caption, color = palette.muted)
		else AndroidView(
			factory = { FrameLayout(it) },
			update = { frame -> frame.removeAllViews(); frame.addView(current.apply(context, frame)) },
			modifier = Modifier.size(size.width, size.height).testTag("widgetPreview_$label"),
		)
	}
}
