package nyc.juliet.subwaysfornerds.ui.components

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChatBubble
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.outlined.StarOutline
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import nyc.juliet.subwaysfornerds.core.Display
import nyc.juliet.subwaysfornerds.core.Freshness
import nyc.juliet.subwaysfornerds.core.SourceState
import nyc.juliet.subwaysfornerds.core.TripChange
import nyc.juliet.subwaysfornerds.ui.theme.TextRoles
import nyc.juliet.subwaysfornerds.ui.theme.palette

/** Official MTA line colors. Regional colors come from core's route table. */
fun routeColor(route: String): Color = when (route) {
	"1", "2", "3" -> Color(0xFFEE352E)
	"4", "5", "6", "6X" -> Color(0xFF00933C)
	"7", "7X" -> Color(0xFFB933AD)
	"A", "C", "E" -> Color(0xFF0039A6)
	"B", "D", "F", "FX", "M" -> Color(0xFFFF6319)
	"N", "Q", "R", "W" -> Color(0xFFFCCC0A)
	"G" -> Color(0xFF6CBE45)
	"J", "Z" -> Color(0xFF996633)
	else -> Color(0xFF62666B)
}

/** Yellow, orange and light green bullets carry black letters, as on station signs. */
fun routeInk(route: String): Color = if (route in setOf("N", "Q", "R", "W", "G", "B", "D", "F", "FX", "M")) Color.Black else Color.White
fun regionalInk(route: String): Color = if (route.startsWith("PATH-") && route != "PATH-NWK-WTC") Color.Black else Color.White

/** A subway bullet, or a PATH/light rail name badge. Text scales with the rider's font size. */
@Composable
fun RouteBullet(route: String, modifier: Modifier = Modifier, small: Boolean = false) {
	val regional = Display.regionalRoute(route)
	if (regional != null) {
		val colors = regional.colors.map { Color(0xFF000000 or it) }
		val fill = if (colors.size == 2) Brush.linearGradient(0f to colors[0], 0.5f to colors[0], 0.5f to colors[1], 1f to colors[1]) else Brush.linearGradient(listOf(colors[0], colors[0]))
		Text(
			regional.label,
			style = (if (small) TextRoles.caption2 else TextRoles.caption).copy(fontWeight = FontWeight.Black),
			color = regionalInk(route),
			textAlign = TextAlign.Center,
			modifier = modifier
				.clip(RoundedCornerShape(7.dp))
				.background(fill)
				.padding(horizontal = 8.dp, vertical = if (small) 5.dp else 8.dp)
				.clearAndSetSemantics { contentDescription = regional.name },
		)
	} else {
		val label = Display.displayRoute(route)
		val size = if (small) 26.dp else 34.dp
		Box(
			modifier
				.defaultMinSize(minWidth = size, minHeight = size)
				.background(routeColor(route), CircleShape)
				.clearAndSetSemantics { contentDescription = "Line $label" },
			contentAlignment = Alignment.Center,
		) {
			Text(
				label,
				color = routeInk(route),
				style = (if (small) TextRoles.caption else TextRoles.subheadline).copy(fontWeight = FontWeight.Black, fontSize = if (label.length > 1) (if (small) 10.sp else 13.sp) else (if (small) 13.sp else 17.sp)),
				maxLines = 1,
				modifier = Modifier.padding(horizontal = 3.dp),
			)
		}
	}
}

/** Wraps bullets onto further lines instead of truncating them. */
@Composable
fun RouteStrip(routes: List<String>, modifier: Modifier = Modifier) {
	FlowRow(modifier, horizontalArrangement = Arrangement.spacedBy(4.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
		routes.forEach { RouteBullet(it, small = true) }
	}
}

private fun changeText(change: TripChange, stale: Boolean): String =
	(if (stale) "Last known · " else "") + change.label + (if (change.advisory == true) " · advisory" else "")

/** Amber for planned or scheduled changes, red for unplanned, as on the web board. */
@Composable
private fun ChangeGlyph(change: TripChange, stale: Boolean, size: Dp = 13.dp) {
	val tint = when (change.classification) {
		"unplanned" -> palette.unplanned
		"planned", "scheduled" -> palette.planned
		else -> palette.warning
	}
	Icon(if (stale || change.classification == "scheduled") Icons.Filled.Schedule else Icons.Filled.Warning, contentDescription = null, tint = tint, modifier = Modifier.size(size))
}

/** Rows show service changes and alerts as icons; train details list them in full. */
@Composable
fun ChangeIcons(changes: List<TripChange>, now: Double, modifier: Modifier = Modifier, alerts: List<String> = emptyList(), cached: Boolean = false) {
	if (changes.isEmpty() && alerts.isEmpty()) return
	val description = (changes.map { "${it.classification} · ${changeText(it, Display.changeStale(it, now, cached))}" } +
		(if (alerts.isEmpty()) emptyList() else listOf("Alert · " + alerts.joinToString(" · ")))).joinToString(". ")
	Row(modifier.semantics { contentDescription = description }, horizontalArrangement = Arrangement.spacedBy(3.dp), verticalAlignment = Alignment.CenterVertically) {
		changes.take(4).forEach { ChangeGlyph(it, Display.changeStale(it, now, cached)) }
		if (changes.size > 4) Text("+${changes.size - 4}", style = TextRoles.caption2, color = palette.muted)
		if (alerts.isNotEmpty()) Icon(Icons.Filled.ChatBubble, contentDescription = null, tint = palette.warning, modifier = Modifier.size(13.dp))
	}
}

/** One service change with its evidence, expandable like an iOS disclosure group. */
@Composable
fun ChangeRow(change: TripChange, now: Double, cached: Boolean, timeFormat: String) {
	var expanded by rememberSaveable(change.id) { mutableStateOf(false) }
	val stale = Display.changeStale(change, now, cached)
	Column(Modifier.fillMaxWidth()) {
		Row(
			Modifier.fillMaxWidth().heightIn(min = 48.dp)
				.clickable(role = Role.Button, onClickLabel = if (expanded) "Hide details" else "Show details") { expanded = !expanded }
				.padding(horizontal = 16.dp, vertical = 8.dp)
				.semantics(mergeDescendants = true) { stateDescription = if (expanded) "Expanded" else "Collapsed" },
			verticalAlignment = Alignment.CenterVertically,
			horizontalArrangement = Arrangement.spacedBy(6.dp),
		) {
			ChangeGlyph(change, stale, 15.dp)
			Text(changeText(change, stale), style = TextRoles.footnote, modifier = Modifier.weight(1f))
			Icon(if (expanded) Icons.Filled.KeyboardArrowUp else Icons.Filled.KeyboardArrowDown, contentDescription = null, tint = palette.muted)
		}
		AnimatedVisibility(expanded) {
			Column(Modifier.padding(start = 37.dp, end = 16.dp, bottom = 10.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
				change.description?.let { Text(it, style = TextRoles.footnote) }
				Text(change.classification.replaceFirstChar { it.uppercase() } + " · " + change.kind, style = TextRoles.caption)
				if (change.before != null && change.after != null) Text("${change.before} → ${change.after}", style = TextRoles.caption)
				if (change.affectedStops.isNotEmpty()) Text("Affected stops: " + change.affectedStops.joinToString(", "), style = TextRoles.caption)
				change.evidence.forEach { evidence ->
					Text("${evidence.source} · ${Display.ageLabel(evidence.timestamp, now)}${if (evidence.unavailable == true) " · unavailable" else ""}", style = TextRoles.caption, color = palette.muted)
				}
				if (change.alertIds.isNotEmpty()) SelectionContainer { Text("Alert IDs: " + change.alertIds.joinToString(", "), style = TextRoles.caption) }
			}
		}
	}
}

/** One aligned row per feed instead of a two-line row per feed. */
@Composable
fun SourcesTable(sources: List<SourceState>, now: Double, modifier: Modifier = Modifier) {
	Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
		sources.forEach { source ->
			val live = source.error == null && Display.freshness(source, now) == Freshness.LIVE
			Row(
				Modifier.fillMaxWidth().semantics(mergeDescendants = true) {},
				verticalAlignment = Alignment.CenterVertically,
				horizontalArrangement = Arrangement.spacedBy(8.dp),
			) {
				Box(Modifier.size(6.dp).background(if (live) palette.accent else palette.warning, CircleShape))
				Text(source.id, style = TextRoles.caption2.copy(fontWeight = FontWeight.SemiBold, fontFamily = FontFamily.Monospace), modifier = Modifier.weight(1f))
				Text(Display.ageLabel(source.timestamp, now), style = TextRoles.caption2.copy(fontFamily = FontFamily.Monospace), textAlign = TextAlign.End, modifier = Modifier.width(64.dp))
				Text("fetched ${Display.ageLabel(source.fetchedAt, now)}", style = TextRoles.caption2.copy(fontFamily = FontFamily.Monospace), color = palette.muted, modifier = Modifier.width(104.dp))
			}
			source.error?.let { Text(it, style = TextRoles.caption2, color = palette.muted, modifier = Modifier.padding(start = 14.dp)) }
		}
	}
}

private val prettyJson = Json { prettyPrint = true }

/** Decoded feed data and identifiers, hidden until asked for. */
@Composable
fun RawJsonDisclosure(title: String, value: JsonElement?, modifier: Modifier = Modifier) {
	var expanded by rememberSaveable(title) { mutableStateOf(false) }
	val text = remember(value) { value?.let { runCatching { prettyJson.encodeToString(JsonElement.serializer(), it) }.getOrNull() } ?: "Unavailable" }
	Column(modifier.fillMaxWidth()) {
		Row(
			Modifier.fillMaxWidth().heightIn(min = 48.dp).clickable(role = Role.Button) { expanded = !expanded }
				.padding(horizontal = 16.dp, vertical = 8.dp)
				.semantics(mergeDescendants = true) { stateDescription = if (expanded) "Expanded" else "Collapsed" },
			verticalAlignment = Alignment.CenterVertically,
		) {
			Text(title, style = TextRoles.subheadline, color = palette.action, modifier = Modifier.weight(1f))
			Icon(if (expanded) Icons.Filled.KeyboardArrowUp else Icons.Filled.KeyboardArrowDown, contentDescription = null, tint = palette.muted)
		}
		if (expanded) {
			SelectionContainer {
				Text(
					text,
					style = TextRoles.caption.copy(fontFamily = FontFamily.Monospace),
					softWrap = false,
					modifier = Modifier.horizontalScroll(rememberScrollState()).padding(start = 16.dp, end = 16.dp, bottom = 12.dp).testTag("rawJson"),
				)
			}
		}
	}
}

/** A star that saves or removes a favorite, with a 48 dp target. */
@Composable
fun FavoriteStar(saved: Boolean, label: String, onClick: () -> Unit, modifier: Modifier = Modifier) {
	IconButton(onClick = onClick, modifier = modifier.semantics { contentDescription = label; selected = saved }) {
		Icon(if (saved) Icons.Filled.Star else Icons.Outlined.StarOutline, contentDescription = null, tint = palette.action)
	}
}

/** Disclosure header for long rows, like "Show 4 more trains". */
@Composable
fun ExpandRow(label: String, expanded: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier) {
	Row(
		modifier.fillMaxWidth().heightIn(min = 48.dp).clickable(role = Role.Button, onClick = onClick).padding(horizontal = 16.dp),
		verticalAlignment = Alignment.CenterVertically,
		horizontalArrangement = Arrangement.spacedBy(4.dp),
	) {
		Text(label, style = TextRoles.caption.copy(fontWeight = FontWeight.SemiBold), color = palette.action)
		Icon(if (expanded) Icons.Filled.KeyboardArrowUp else Icons.Filled.KeyboardArrowDown, contentDescription = null, tint = palette.action, modifier = Modifier.size(16.dp))
	}
}
