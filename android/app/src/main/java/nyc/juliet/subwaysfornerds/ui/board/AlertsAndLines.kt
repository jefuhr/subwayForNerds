package nyc.juliet.subwaysfornerds.ui.board

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.serialization.json.JsonElement
import nyc.juliet.subwaysfornerds.core.Display
import nyc.juliet.subwaysfornerds.core.Freshness
import nyc.juliet.subwaysfornerds.core.ServiceAlert
import nyc.juliet.subwaysfornerds.core.TransitJson
import nyc.juliet.subwaysfornerds.ui.AppModel
import nyc.juliet.subwaysfornerds.ui.CoreBridge
import nyc.juliet.subwaysfornerds.ui.components.ActionButton
import nyc.juliet.subwaysfornerds.ui.components.EmptyState
import nyc.juliet.subwaysfornerds.ui.components.ListScreen
import nyc.juliet.subwaysfornerds.ui.components.Notice
import nyc.juliet.subwaysfornerds.ui.components.RawJsonDisclosure
import nyc.juliet.subwaysfornerds.ui.components.RouteBullet
import nyc.juliet.subwaysfornerds.ui.components.RouteStrip
import nyc.juliet.subwaysfornerds.ui.components.RowContainer
import nyc.juliet.subwaysfornerds.ui.components.ScreenExit
import nyc.juliet.subwaysfornerds.ui.components.SourcesTable
import nyc.juliet.subwaysfornerds.ui.components.section
import nyc.juliet.subwaysfornerds.ui.easternDate
import nyc.juliet.subwaysfornerds.ui.theme.TextRoles
import nyc.juliet.subwaysfornerds.ui.theme.palette

@Composable
fun AlertsScreen(model: AppModel, close: () -> Unit) {
	val alerts = model.displayBoard?.alerts.orEmpty()
	val sources = model.board?.sources.orEmpty().filter { it.id == "subway-alerts" }
	val now = model.now
	val stale = model.boardIsCached || !model.connected || sources.firstOrNull()?.let { it.error != null || Display.freshness(it.timestamp, now) != Freshness.LIVE } != false
	ListScreen("Service alerts", exit = ScreenExit.CLOSE, onExit = close, tag = "alertsScreen") {
		section("status") {
			if (stale) row { RowContainer { Notice("Alert information is cached, stale, or unavailable. Check source ages before relying on these reports.") } }
			row { RowContainer { SourcesTable(sources, now) } }
		}
		if (alerts.isEmpty()) section("empty") {
			row { EmptyState("No matching alerts", null, Modifier.fillMaxWidth().padding(16.dp)) }
		}
		alerts.forEach { alert ->
			section("alert:${alert.id}") {
				row { AlertBody(alert, model.timeFormat) }
				row { RawJsonDisclosure("Alert scope, selectors & source", TransitJson.encodeToJsonElement(ServiceAlert.serializer(), alert)) }
			}
		}
	}
}

@Composable
private fun AlertBody(alert: ServiceAlert, timeFormat: String) {
	RowContainer {
		Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
			if (alert.routes.isNotEmpty()) RouteStrip(alert.routes)
			Text(alert.title, style = TextRoles.subheadlineBold)
			Text(alert.description, style = TextRoles.footnote)
			alertMeta(alert)?.let { Text(it, style = TextRoles.caption.copy(fontWeight = FontWeight.SemiBold)) }
			alert.periods.forEach { period ->
				Text(
					(period.start?.let { easternDate(it, timeFormat) } ?: "Start not specified") + " → " + (period.end?.let { easternDate(it, timeFormat) } ?: "Until further notice"),
					style = TextRoles.caption2, color = palette.muted,
				)
			}
		}
	}
}

private fun alertMeta(alert: ServiceAlert): String? {
	val parts = buildList {
		alert.effect?.takeIf { it.isNotEmpty() }?.let { add("Effect: $it") }
		alert.alertType?.takeIf { it.isNotEmpty() }?.let { add("Type: $it") }
		alert.activePeriodLabel?.takeIf { it.isNotEmpty() }?.let { add(it) }
		alert.planNumbers?.takeIf { it.isNotEmpty() }?.let { add("Plans " + it.joinToString(", ")) }
	}
	return parts.takeIf { it.isNotEmpty() }?.joinToString(" · ")
}

private fun lineSystem(route: String): String = when {
	route.startsWith("PATH") -> "PATH"
	route.startsWith("NJT-") -> "NJ Transit"
	else -> "Subway & SIR"
}

/** Global line visibility: applies to stations, departures, connections, alerts and widgets. */
@Composable
fun LinesScreen(model: AppModel, exit: ScreenExit, close: () -> Unit) {
	val keys = model.allLineKeys
	ListScreen("Lines", exit = exit, onExit = close, tag = "linesScreen") {
		section("all") {
			row { ActionButton("Enable all lines", { model.setHiddenLines(emptyList()) }, Modifier.padding(start = 4.dp).testTag("enableAllLines")) }
			row { ActionButton("Hide all lines", { model.setHiddenLines(keys) }, Modifier.padding(start = 4.dp).testTag("hideAllLines")) }
		}
		model.settingsError?.let { error -> section("error") { row { RowContainer { Notice(error) } } } }
		listOf("Subway & SIR", "PATH", "NJ Transit").forEach { group ->
			val routes = keys.filter { lineSystem(it) == group }
			if (routes.isNotEmpty()) section("lines:$group", header = group) {
				routes.forEach { route ->
					row(route) {
						val enabled = CoreBridge.lineEnabled(route, model.hiddenRoutes)
						Row(
							Modifier.fillMaxWidth().heightIn(min = 52.dp)
								.toggleable(value = enabled, role = Role.Switch) { model.setLine(route, it) }
								.padding(horizontal = 16.dp, vertical = 6.dp)
								.testTag("globalLine_$route"),
							verticalAlignment = Alignment.CenterVertically,
							horizontalArrangement = Arrangement.spacedBy(10.dp),
						) {
							RouteBullet(route, small = true)
							Text(Display.regionalRoute(route)?.name ?: "Line $route", style = TextRoles.subheadline, modifier = Modifier.weight(1f))
							Switch(checked = enabled, onCheckedChange = null, colors = SwitchDefaults.colors(checkedTrackColor = palette.selection, checkedThumbColor = androidx.compose.ui.graphics.Color.White))
						}
					}
				}
				row("toggles") {
					Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp)) {
						ActionButton("Enable $group", { model.setHiddenLines(model.hiddenRoutes.filter { CoreBridge.lineKey(it) !in routes }) })
						androidx.compose.foundation.layout.Spacer(Modifier.weight(1f))
						ActionButton("Hide $group", { model.setHiddenLines((model.hiddenRoutes + routes).distinct()) })
					}
				}
			}
		}
		if (keys.isEmpty()) section("none") { row { RowContainer { Text("Connect to load the station catalog and line controls.", style = TextRoles.footnote, color = palette.muted) } } }
	}
}
