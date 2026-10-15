package nyc.juliet.subwaysfornerds.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import nyc.juliet.subwaysfornerds.ui.theme.TextRoles
import nyc.juliet.subwaysfornerds.ui.theme.palette

/** Outer margin of grouped cards; matches iOS inset-grouped lists. */
val SectionInset = 12.dp
private val CardRadius = 12.dp

/** Rows collected for one grouped card. Each row becomes its own lazy item. */
class SectionRows {
	internal val rows = mutableListOf<Pair<Any?, @Composable () -> Unit>>()

	fun row(key: Any? = null, content: @Composable () -> Unit) { rows += key to content }
}

/**
 * A grouped card of rows with an optional header and footer, emitted as separate lazy
 * items so long sections still scroll lazily. Rows draw their part of the rounded card.
 */
fun LazyListScope.section(
	id: String,
	header: String? = null,
	footer: String? = null,
	headerContent: (@Composable () -> Unit)? = null,
	rows: SectionRows.() -> Unit,
) {
	val built = SectionRows().apply(rows).rows
	if (built.isEmpty() && header == null && headerContent == null) return
	if (header != null || headerContent != null) {
		item(key = "$id#header", contentType = "header") {
			Box(Modifier.fillMaxWidth().padding(start = SectionInset + 14.dp, end = SectionInset + 8.dp, top = 10.dp, bottom = 4.dp)) {
				if (headerContent != null) headerContent() else ListHeader(header.orEmpty())
			}
		}
	} else {
		item(key = "$id#gap", contentType = "gap") { Spacer(Modifier.padding(top = 10.dp)) }
	}
	built.forEachIndexed { index, (key, content) ->
		item(key = "$id#${key ?: index}", contentType = "row") {
			SectionRow(first = index == 0, last = index == built.lastIndex, content = content)
		}
	}
	if (footer != null) {
		item(key = "$id#footer", contentType = "footer") {
			Text(
				footer,
				style = TextRoles.caption,
				color = palette.muted,
				modifier = Modifier.fillMaxWidth().padding(start = SectionInset + 14.dp, end = SectionInset + 14.dp, top = 6.dp, bottom = 2.dp),
			)
		}
	}
}

@Composable
private fun SectionRow(first: Boolean, last: Boolean, content: @Composable () -> Unit) {
	val shape: Shape = RoundedCornerShape(
		topStart = if (first) CardRadius else 0.dp, topEnd = if (first) CardRadius else 0.dp,
		bottomStart = if (last) CardRadius else 0.dp, bottomEnd = if (last) CardRadius else 0.dp,
	)
	Column(
		Modifier
			.fillMaxWidth()
			.padding(horizontal = SectionInset)
			.clip(shape)
			.background(palette.card),
	) {
		CompositionLocalProvider(LocalContentColor provides palette.ink) { content() }
		if (!last) HorizontalDivider(Modifier.padding(start = 16.dp), color = palette.line.copy(alpha = 0.6f))
	}
}

/** Section titles sized for dense lists. */
@Composable
fun ListHeader(title: String, modifier: Modifier = Modifier) {
	Text(
		title,
		style = TextRoles.footnote,
		color = palette.muted,
		modifier = modifier.semantics { heading() },
	)
}

/** Padding inside a card row. Interactive rows also reach the 48 dp minimum height. */
val RowPadding = PaddingValues(horizontal = 16.dp, vertical = 10.dp)

@Composable
fun RowContainer(
	modifier: Modifier = Modifier,
	padding: PaddingValues = RowPadding,
	minHeight: Dp = 44.dp,
	content: @Composable () -> Unit,
) {
	Box(modifier.fillMaxWidth().heightIn(min = minHeight).padding(padding), contentAlignment = Alignment.CenterStart) { content() }
}

/** A tappable row that pushes another screen, with the platform's trailing chevron. */
@Composable
fun NavigationRow(
	title: String,
	onClick: () -> Unit,
	modifier: Modifier = Modifier,
	value: String? = null,
	subtitle: String? = null,
	enabled: Boolean = true,
	leading: (@Composable RowScope.() -> Unit)? = null,
) {
	Row(
		modifier
			.fillMaxWidth()
			.heightIn(min = 48.dp)
			.clickable(enabled = enabled, role = Role.Button, onClick = onClick)
			.padding(start = 16.dp, end = 8.dp, top = 8.dp, bottom = 8.dp),
		verticalAlignment = Alignment.CenterVertically,
		horizontalArrangement = Arrangement.spacedBy(8.dp),
	) {
		leading?.invoke(this)
		Column(Modifier.weight(1f)) {
			Text(title, style = TextRoles.subheadline, color = if (enabled) palette.ink else palette.muted)
			if (subtitle != null) Text(subtitle, style = TextRoles.caption, color = palette.muted)
		}
		if (value != null) Text(value, style = TextRoles.subheadline, color = palette.muted)
		Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = palette.muted, modifier = Modifier.width(24.dp))
	}
}
