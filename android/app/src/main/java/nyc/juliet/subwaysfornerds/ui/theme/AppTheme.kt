package nyc.juliet.subwaysfornerds.ui.theme

import androidx.compose.runtime.Immutable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.graphics.lerp
import kotlin.math.pow

/** One of the ten portable themes. IDs are shared with the web and iOS clients. */
@Immutable
data class AppTheme(
	val id: String,
	val name: String,
	val note: String,
	val accent: Color,
	val background: Color,
	val ink: Color,
	val dark: Boolean,
) {
	/** Selected rows use white text, so dark themes' light accents are deepened for contrast. */
	val selection: Color get() = if (dark) lerp(accent, Color.Black, 0.55f) else accent

	companion object {
		val all: List<AppTheme> = listOf(
			AppTheme("subway", "Subway console", "Your next move, in focus", Color(0xFFC7F36B), Color(0xFF111610), Color(0xFFF6F9F1), dark = true),
			AppTheme("nyc-ferry", "NYC Ferry", "A little familiar blue", Color(0xFF0075B8), Color(0xFFF2FAFF), Color(0xFF12334B), dark = false),
			AppTheme("night", "Night", "For the late train home", Color(0xFF7FD4FF), Color(0xFF0D1728), Color(0xFFEAF6FF), dark = true),
			AppTheme("hello-kitty", "Hello Kitty", "Pink with a purpose", Color(0xFFB62461), Color(0xFFFFF1F6), Color(0xFF48233A), dark = false),
			AppTheme("cinnamoroll", "Cinnamoroll", "Sky blue and quiet", Color(0xFF257AA9), Color(0xFFEEF9FF), Color(0xFF28465A), dark = false),
			AppTheme("pompompurin", "Pompompurin", "Butter yellow, brown beret", Color(0xFF8D5E14), Color(0xFFFFF7CF), Color(0xFF543814), dark = false),
			AppTheme("kuromi", "Kuromi", "A little dark and twisty", Color(0xFFCB9DE8), Color(0xFF21152C), Color(0xFFFAEFFF), dark = true),
			AppTheme("windows-xp", "Windows XP", "Next stop: 2001", Color(0xFF245CB5), Color(0xFFECE9D8), Color(0xFF182B4A), dark = false),
			AppTheme("hacker", "Hacker", "Mind the terminal gap", Color(0xFF00FF41), Color(0xFF050C07), Color(0xFFBAFFCB), dark = true),
			AppTheme("burger-king", "Burger King", "Have it your way", Color(0xFFD62300), Color(0xFFF5EBDC), Color(0xFF502314), dark = false),
		)

		/** Unknown theme IDs stay stored in settings and display the default palette until supported. */
		fun forId(id: String?): AppTheme = all.firstOrNull { it.id == id } ?: all[0]
	}
}

/**
 * Concrete colors derived from a theme. Cards sit slightly off the background like iOS
 * inset-grouped lists; secondary text keeps the theme's ink hue rather than a system gray.
 */
@Immutable
data class AppPalette(
	val theme: AppTheme,
	val accent: Color,
	val onAccent: Color,
	val background: Color,
	val card: Color,
	val raised: Color,
	val ink: Color,
	val muted: Color,
	val line: Color,
	/** Accent adjusted toward the ink only as far as needed for 4.5:1 text on cards and background. */
	val action: Color,
	val selection: Color,
	val accentTint: Color,
	val warning: Color,
	val danger: Color,
	val unplanned: Color,
	val planned: Color,
) {
	companion object {
		fun from(theme: AppTheme): AppPalette {
			val background = theme.background
			val card = if (theme.dark) lerp(background, theme.ink, 0.07f) else lerp(background, Color.White, 0.7f)
			val raised = if (theme.dark) lerp(background, theme.ink, 0.13f) else lerp(background, theme.ink, 0.06f)
			val muted = readable(lerp(background, theme.ink, 0.72f), theme.ink, listOf(card, background))
			val action = readable(theme.accent, theme.ink, listOf(card, background))
			val onAccent = if (contrastRatio(Color.White, theme.accent) >= contrastRatio(Color(0xFF0B0F0A), theme.accent)) Color.White else Color(0xFF0B0F0A)
			return AppPalette(
				theme = theme,
				accent = theme.accent,
				onAccent = onAccent,
				background = background,
				card = card,
				raised = raised,
				ink = theme.ink,
				muted = muted,
				line = theme.ink.copy(alpha = 0.2f).compositeOver(card),
				action = action,
				selection = theme.selection,
				accentTint = theme.accent.copy(alpha = 0.18f).compositeOver(card),
				warning = if (theme.dark) Color(0xFFEDBB78) else Color(0xFFB25E00),
				danger = if (theme.dark) Color(0xFFF19484) else Color(0xFFA53A23),
				unplanned = Color(0xFFE53935),
				planned = Color(0xFFD5A000),
			)
		}

		/** Moves a color toward the ink in small steps until it reads at 4.5:1 on every surface. */
		private fun readable(color: Color, ink: Color, surfaces: List<Color>): Color {
			var value = color
			var step = 0
			while (step < 20 && surfaces.any { contrastRatio(value, it) < 4.5 }) {
				step += 1
				value = lerp(color, ink, step * 0.05f)
			}
			return value
		}
	}
}

/** WCAG relative luminance of an opaque color. */
fun Color.luminanceValue(): Double {
	fun channel(value: Float): Double = if (value <= 0.03928f) value / 12.92 else ((value + 0.055) / 1.055).pow(2.4)
	return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
}

fun contrastRatio(foreground: Color, background: Color): Double {
	val a = foreground.compositeOver(background).luminanceValue()
	val b = background.luminanceValue()
	return (maxOf(a, b) + 0.05) / (minOf(a, b) + 0.05)
}
