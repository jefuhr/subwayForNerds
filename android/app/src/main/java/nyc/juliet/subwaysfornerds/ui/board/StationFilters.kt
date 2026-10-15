package nyc.juliet.subwaysfornerds.ui.board

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.SwapVert
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import nyc.juliet.subwaysfornerds.core.Display
import nyc.juliet.subwaysfornerds.ui.components.ChipRow
import nyc.juliet.subwaysfornerds.ui.components.ChoiceChip
import nyc.juliet.subwaysfornerds.ui.components.RouteBullet
import nyc.juliet.subwaysfornerds.ui.theme.TextRoles
import nyc.juliet.subwaysfornerds.ui.theme.palette

/**
 * Direction chips, then "All" and one bullet per line, as the board and transfer connections
 * show them. Several lines can be chosen at once. `tagPrefix` keeps test tags distinct when
 * both are on screen side by side.
 */
@Composable
fun StationFilterRow(
	directions: List<DirectionOption>,
	direction: String,
	onDirection: (String) -> Unit,
	routes: List<String>,
	selectedRoutes: List<String>,
	onToggleRoute: (String) -> Unit,
	onAllRoutes: () -> Unit,
	tagPrefix: String = "",
) {
	Row(verticalAlignment = Alignment.CenterVertically) {
		Row(horizontalArrangement = Arrangement.spacedBy(4.dp), modifier = Modifier.testTag("${tagPrefix}directionFilter")) {
			directions.forEach { option -> DirectionChip(option, direction == option.id, "${tagPrefix}direction_${option.id}") { onDirection(option.id) } }
		}
		VerticalDivider(Modifier.height(24.dp).padding(horizontal = 6.dp), color = palette.line)
		ChipRow {
			ChoiceChip("All", selectedRoutes.isEmpty(), onAllRoutes, Modifier.testTag("${tagPrefix}allLines"), contentDescription = "All lines")
			routes.forEach { route ->
				val on = route in selectedRoutes
				Box(
					Modifier.size(48.dp)
						.clickable(role = Role.Checkbox) { onToggleRoute(route) }
						.semantics { contentDescription = "Filter line ${Display.routeLabel(route)}"; selected = on }
						.testTag("${tagPrefix}routeFilter_$route"),
					contentAlignment = Alignment.Center,
				) {
					Box(
						Modifier.then(if (on) Modifier.border(2.dp, palette.accent, CircleShape) else Modifier).padding(3.dp),
						contentAlignment = Alignment.Center,
					) {
						// Unselected lines fade while another line filter is active.
						RouteBullet(route, small = true, modifier = if (selectedRoutes.isEmpty() || on) Modifier else Modifier.alpha(0.4f))
					}
				}
			}
		}
	}
}

@Composable
private fun DirectionChip(option: DirectionOption, isSelected: Boolean, tag: String, onClick: () -> Unit) {
	val icon = when (option.id) {
		"NORTH" -> Icons.Filled.ArrowUpward
		"SOUTH" -> Icons.Filled.ArrowDownward
		"ALL" -> Icons.Filled.SwapVert
		else -> null
	}
	Box(
		Modifier
			.size(48.dp)
			.clickable(role = Role.RadioButton, onClick = onClick)
			.semantics { contentDescription = option.name; selected = isSelected }
			.testTag(tag),
		contentAlignment = Alignment.Center,
	) {
		Box(
			Modifier.size(width = 40.dp, height = 32.dp)
				.background(if (isSelected) palette.accentTint else Color.Transparent, CircleShape)
				.border(if (isSelected) 1.5.dp else 1.dp, if (isSelected) palette.accent else palette.line, CircleShape),
			contentAlignment = Alignment.Center,
		) {
			if (icon != null) Icon(icon, contentDescription = null, tint = if (isSelected) palette.action else palette.ink, modifier = Modifier.size(18.dp))
			else Text(option.text.orEmpty(), style = TextRoles.caption.copy(fontWeight = FontWeight.SemiBold), color = if (isSelected) palette.action else palette.ink)
		}
	}
}
