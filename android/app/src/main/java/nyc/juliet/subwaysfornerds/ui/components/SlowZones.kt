package nyc.juliet.subwaysfornerds.ui.components

import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.addPathNodes
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import nyc.juliet.subwaysfornerds.core.SlowZone
import nyc.juliet.subwaysfornerds.core.SlowZoneDisplay
import nyc.juliet.subwaysfornerds.core.SlowZoneEstimate
import nyc.juliet.subwaysfornerds.core.TrainSlowZone
import nyc.juliet.subwaysfornerds.ui.theme.TextRoles
import nyc.juliet.subwaysfornerds.ui.theme.palette

/*
 * The snail glyph is Lucide's "snail" icon, as the web client shows it, rebuilt from the 24x24 stroke
 * paths in lucide-react 0.468.0 (its circle drawn as two arcs). Lucide's license:
 *
 * ISC License
 *
 * Copyright (c) for portions of Lucide are held by Cole Bemis 2013-2022 as part of Feather (MIT). All
 * other copyright (c) for Lucide are held by Lucide Contributors 2022.
 *
 * Permission to use, copy, modify, and/or distribute this software for any purpose with or without fee
 * is hereby granted, provided that the above copyright notice and this permission notice appear in all
 * copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE
 * INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE
 * FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
 * LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION,
 * ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 */
val SnailIcon: ImageVector by lazy {
	ImageVector.Builder("Snail", 24.dp, 24.dp, 24f, 24f).apply {
		listOf(
			"M2 13a6 6 0 1 0 12 0 4 4 0 1 0-8 0 2 2 0 0 0 4 0",
			"M2 13a8 8 0 1 0 16 0a8 8 0 1 0-16 0",
			"M2 21h12c4.4 0 8-3.6 8-8V7a2 2 0 1 0-4 0v6",
			"M18 3 19.1 5.2",
			"M22 3 20.9 5.2",
		).forEach { path ->
			// Icon tint replaces this stroke color.
			addPath(addPathNodes(path), fill = null, stroke = SolidColor(Color.Black), strokeLineWidth = 2f, strokeLineCap = StrokeCap.Round, strokeLineJoin = StrokeJoin.Round)
		}
	}.build()
}

/** Amber for slow zones, red for major slowdowns, as on the web. */
@Composable
private fun slowZoneTint(zone: SlowZoneEstimate): Color = if (zone.kind == "disruption") palette.danger else palette.warning

/** A board row's compact tag for the zone its train is in now: the snail and the typical extra time. */
@Composable
fun SlowZoneTag(zone: SlowZone, tag: String, modifier: Modifier = Modifier) {
	val tint = slowZoneTint(zone)
	val label = SlowZoneDisplay.accessibilityLabel(zone)
	Row(
		modifier.clearAndSetSemantics { contentDescription = label; testTag = tag },
		horizontalArrangement = Arrangement.spacedBy(2.dp),
		verticalAlignment = Alignment.CenterVertically,
	) {
		Icon(SnailIcon, contentDescription = null, tint = tint, modifier = Modifier.size(12.dp))
		Text(SlowZoneDisplay.tag(zone), style = TextRoles.caption2.copy(fontWeight = FontWeight.SemiBold, fontFamily = FontFamily.Monospace), color = tint, maxLines = 1)
	}
}

/** Train details: how many zones are ahead and their typical extra time together. */
@Composable
fun SlowZoneSummary(summary: String, modifier: Modifier = Modifier) {
	Row(
		modifier.clearAndSetSemantics { contentDescription = summary; testTag = "slowZoneSummary" },
		horizontalArrangement = Arrangement.spacedBy(6.dp),
		verticalAlignment = Alignment.CenterVertically,
	) {
		Icon(SnailIcon, contentDescription = null, tint = palette.warning, modifier = Modifier.size(14.dp))
		Text(summary, style = TextRoles.caption.copy(fontWeight = FontWeight.SemiBold), color = palette.warning)
	}
}

/** A slim, untappable row between the two stops a zone covers; `live` decides whether "now" shows. */
@Composable
fun SlowZoneSegmentRow(zone: TrainSlowZone, live: Boolean, modifier: Modifier = Modifier) {
	val tint = slowZoneTint(zone)
	val now = zone.current == true && live
	val label = SlowZoneDisplay.segmentAccessibilityLabel(zone, live)
	Row(
		modifier.fillMaxWidth()
			.padding(start = 16.dp, end = 8.dp, top = 4.dp, bottom = 4.dp)
			.clearAndSetSemantics { contentDescription = label; testTag = "slowZoneSegment_${zone.from}_${zone.to}" },
		horizontalArrangement = Arrangement.spacedBy(8.dp),
		verticalAlignment = Alignment.CenterVertically,
	) {
		Icon(
			SnailIcon, contentDescription = null, tint = tint,
			modifier = Modifier.size(16.dp).then(if (now) Modifier.border(1.dp, tint, CircleShape).padding(2.dp) else Modifier),
		)
		Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
			Text(SlowZoneDisplay.heading(zone, live), style = TextRoles.caption2.copy(fontWeight = FontWeight.Bold), color = tint)
			Text(SlowZoneDisplay.detail(zone), style = TextRoles.caption2, color = palette.muted)
		}
	}
}
