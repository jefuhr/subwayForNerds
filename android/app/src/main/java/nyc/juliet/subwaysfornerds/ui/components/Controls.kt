package nyc.juliet.subwaysfornerds.ui.components

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.browser.customtabs.CustomTabsIntent
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AssistChip
import androidx.compose.material3.AssistChipDefaults
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import android.provider.Settings as AndroidSettings
import nyc.juliet.subwaysfornerds.ui.theme.TextRoles
import nyc.juliet.subwaysfornerds.ui.theme.palette

/**
 * A selectable chip: a 32 dp capsule inside the 48 dp touch target Material reserves.
 * Direct chips replace menus so the current value always stays visible.
 */
@Composable
fun ChoiceChip(
	label: String,
	selected: Boolean,
	onClick: () -> Unit,
	modifier: Modifier = Modifier,
	icon: ImageVector? = null,
	iconTint: Color? = null,
	contentDescription: String? = null,
	enabled: Boolean = true,
) {
	FilterChip(
		selected = selected,
		onClick = onClick,
		enabled = enabled,
		label = { Text(label, style = TextRoles.caption, maxLines = 1, overflow = TextOverflow.Ellipsis) },
		leadingIcon = icon?.let { { Icon(it, contentDescription = null, tint = iconTint ?: (if (selected) palette.action else palette.ink), modifier = Modifier.size(16.dp)) } },
		shape = CircleShape,
		colors = FilterChipDefaults.filterChipColors(
			containerColor = Color.Transparent,
			labelColor = palette.ink,
			selectedContainerColor = palette.accentTint,
			selectedLabelColor = palette.ink,
			selectedLeadingIconColor = palette.action,
		),
		border = FilterChipDefaults.filterChipBorder(
			enabled = enabled,
			selected = selected,
			borderColor = palette.line,
			selectedBorderColor = palette.accent,
			borderWidth = 1.dp,
			selectedBorderWidth = 1.5.dp,
		),
		modifier = if (contentDescription != null) modifier.semantics { this.contentDescription = contentDescription } else modifier,
	)
}

/** A one-shot action shaped like a chip, for rows of station or ride actions. */
@Composable
fun ActionChip(
	label: String,
	onClick: () -> Unit,
	modifier: Modifier = Modifier,
	icon: ImageVector? = null,
	iconTint: Color? = null,
	selected: Boolean = false,
	enabled: Boolean = true,
) {
	AssistChip(
		onClick = onClick,
		enabled = enabled,
		label = { Text(label, style = TextRoles.caption, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.widthIn(max = 200.dp)) },
		leadingIcon = icon?.let { { Icon(it, contentDescription = null, tint = iconTint ?: palette.action, modifier = Modifier.size(16.dp)) } },
		shape = CircleShape,
		colors = AssistChipDefaults.assistChipColors(
			containerColor = if (selected) palette.accentTint else Color.Transparent,
			labelColor = palette.ink,
			leadingIconContentColor = palette.action,
		),
		border = AssistChipDefaults.assistChipBorder(enabled = enabled, borderColor = if (selected) palette.accent else palette.line),
		modifier = modifier,
	)
}

/** A horizontally scrolling row of chips that never truncates its choices behind a menu. */
@Composable
fun ChipRow(modifier: Modifier = Modifier, content: @Composable RowScope.() -> Unit) {
	Row(
		modifier.horizontalScroll(rememberScrollState()),
		horizontalArrangement = Arrangement.spacedBy(6.dp),
		verticalAlignment = Alignment.CenterVertically,
		content = content,
	)
}

/** Warning text with its icon, read as one sentence by TalkBack. */
@Composable
fun Notice(text: String, modifier: Modifier = Modifier) {
	Row(
		modifier.fillMaxWidth().semantics(mergeDescendants = true) {},
		horizontalArrangement = Arrangement.spacedBy(6.dp),
		verticalAlignment = Alignment.Top,
	) {
		Icon(Icons.Filled.Warning, contentDescription = null, tint = palette.warning, modifier = Modifier.padding(top = 2.dp).size(14.dp))
		Text(text, style = TextRoles.footnote, color = palette.muted)
	}
}

/**
 * A determinate bar in place of a spinner: what is loading, how far along it is, and the step in
 * progress. Exact percents show plainly, estimates with "~", and unmeasured work shows none.
 */
@Composable
fun LoadingBar(
	title: String,
	fraction: Float?,
	percentLabel: String?,
	spokenPercent: String?,
	detail: String,
	modifier: Modifier = Modifier,
) {
	val shown = animateFloatAsState(fraction ?: 0f, animationSpec = tween(200), label = "load")
	Column(
		modifier
			.fillMaxWidth()
			.padding(vertical = 4.dp)
			.clearAndSetSemantics {
				contentDescription = title
				stateDescription = listOfNotNull(spokenPercent, detail).joinToString(". ")
				progressBarRangeInfo = if (fraction == null) ProgressBarRangeInfo.Indeterminate else ProgressBarRangeInfo(fraction, 0f..1f)
			},
		verticalArrangement = Arrangement.spacedBy(5.dp),
	) {
		Row(verticalAlignment = Alignment.CenterVertically) {
			Text(title, style = TextRoles.subheadlineBold, modifier = Modifier.weight(1f))
			if (percentLabel != null) Text(percentLabel, style = TextRoles.subheadlineBold)
		}
		LinearProgressIndicator(
			progress = { shown.value },
			modifier = Modifier.fillMaxWidth(),
			color = palette.accent,
			trackColor = palette.line,
			strokeCap = StrokeCap.Round,
			gapSize = 0.dp,
			drawStopIndicator = {},
		)
		Text(detail, style = TextRoles.caption, color = palette.muted)
	}
}

/** A text action in the theme's readable accent. */
@Composable
fun ActionButton(label: String, onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true, destructive: Boolean = false) {
	TextButton(onClick = onClick, enabled = enabled, modifier = modifier) {
		Text(label, style = TextRoles.subheadline, color = if (!enabled) palette.muted else if (destructive) palette.danger else palette.action)
	}
}

/** Small labeled values in as many columns as fit, for identifiers that do not need a row each. */
@Composable
fun FactGrid(facts: List<Pair<String, String>>, modifier: Modifier = Modifier) {
	androidx.compose.foundation.layout.FlowRow(
		modifier.fillMaxWidth(),
		horizontalArrangement = Arrangement.spacedBy(12.dp),
		verticalArrangement = Arrangement.spacedBy(8.dp),
	) {
		for ((label, value) in facts) {
			Column(Modifier.widthIn(min = 140.dp).semantics(mergeDescendants = true) {}) {
				Text(label, style = TextRoles.caption2, color = palette.muted)
				Text(value, style = TextRoles.subheadline)
			}
		}
	}
}

@Composable
fun Gap(height: androidx.compose.ui.unit.Dp) = Spacer(Modifier.padding(top = height))

/** Opens web pages in a Custom Tab so the rider returns to the same screen. */
fun openLink(context: Context, url: String) {
	val uri = Uri.parse(url)
	runCatching { CustomTabsIntent.Builder().setShowTitle(true).build().launchUrl(context, uri) }
		.onFailure { runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) } }
}

/** Opens this app's system settings page, where riders can change permissions. */
fun openAppSettings(context: Context) {
	val intent = Intent(AndroidSettings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
	runCatching { context.startActivity(intent) }
}

@Composable
fun LinkButton(label: String, url: String, modifier: Modifier = Modifier, tag: String? = null) {
	val context = LocalContext.current
	ActionButton(label, onClick = { openLink(context, url) }, modifier = if (tag != null) modifier.testTag(tag) else modifier)
}
