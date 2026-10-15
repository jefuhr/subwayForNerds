package nyc.juliet.subwaysfornerds.ui.theme

import android.app.Activity
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.view.WindowCompat

val LocalPalette = staticCompositionLocalOf { AppPalette.from(AppTheme.all[0]) }

/** The palette of the selected theme, for colors Material roles do not cover. */
val palette: AppPalette
	@Composable get() = LocalPalette.current

fun AppPalette.colorScheme(): ColorScheme {
	val base = if (theme.dark) darkColorScheme() else lightColorScheme()
	return base.copy(
		primary = accent,
		onPrimary = onAccent,
		primaryContainer = accentTint,
		onPrimaryContainer = ink,
		inversePrimary = selection,
		secondary = action,
		onSecondary = onAccent,
		secondaryContainer = accentTint,
		onSecondaryContainer = ink,
		tertiary = warning,
		onTertiary = background,
		tertiaryContainer = warning.copy(alpha = 0.18f).compositeOver(card),
		onTertiaryContainer = ink,
		background = background,
		onBackground = ink,
		surface = background,
		onSurface = ink,
		surfaceVariant = raised,
		onSurfaceVariant = muted,
		surfaceTint = accent,
		surfaceBright = card,
		surfaceDim = background,
		surfaceContainerLowest = background,
		surfaceContainerLow = card,
		surfaceContainer = card,
		surfaceContainerHigh = raised,
		surfaceContainerHighest = raised,
		inverseSurface = ink,
		inverseOnSurface = background,
		error = danger,
		onError = if (theme.dark) Color(0xFF1A0B08) else Color.White,
		errorContainer = danger.copy(alpha = 0.16f).compositeOver(card),
		onErrorContainer = ink,
		outline = line,
		outlineVariant = ink.copy(alpha = 0.12f).compositeOver(card),
		scrim = Color.Black,
	)
}

/**
 * Dense type scale modeled on the iOS text styles the board was designed with.
 * All sizes are in sp so large text settings scale every line.
 */
val AppTypography: Typography = Typography().let { base ->
	base.copy(
		headlineSmall = base.headlineSmall.copy(fontSize = 22.sp, lineHeight = 28.sp, fontWeight = FontWeight.Bold),
		titleLarge = base.titleLarge.copy(fontSize = 20.sp, lineHeight = 26.sp, fontWeight = FontWeight.Bold),
		titleMedium = base.titleMedium.copy(fontSize = 17.sp, lineHeight = 22.sp, fontWeight = FontWeight.SemiBold),
		titleSmall = base.titleSmall.copy(fontSize = 15.sp, lineHeight = 20.sp, fontWeight = FontWeight.SemiBold),
		bodyLarge = base.bodyLarge.copy(fontSize = 16.sp, lineHeight = 22.sp),
		bodyMedium = base.bodyMedium.copy(fontSize = 15.sp, lineHeight = 20.sp),
		bodySmall = base.bodySmall.copy(fontSize = 13.sp, lineHeight = 18.sp),
		labelLarge = base.labelLarge.copy(fontSize = 14.sp, lineHeight = 18.sp, fontWeight = FontWeight.SemiBold),
		labelMedium = base.labelMedium.copy(fontSize = 12.sp, lineHeight = 16.sp, fontWeight = FontWeight.SemiBold),
		labelSmall = base.labelSmall.copy(fontSize = 11.sp, lineHeight = 14.sp, fontWeight = FontWeight.Medium),
	)
}

/** Named text roles so screens read like the iOS views they mirror. */
object TextRoles {
	val headline: TextStyle @Composable get() = MaterialTheme.typography.titleMedium
	val subheadline: TextStyle @Composable get() = MaterialTheme.typography.bodyMedium
	val subheadlineBold: TextStyle @Composable get() = MaterialTheme.typography.titleSmall
	val footnote: TextStyle @Composable get() = MaterialTheme.typography.bodySmall
	val caption: TextStyle @Composable get() = MaterialTheme.typography.bodySmall.copy(fontSize = 12.sp, lineHeight = 16.sp)
	val caption2: TextStyle @Composable get() = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.Normal)
	val title2: TextStyle @Composable get() = MaterialTheme.typography.headlineSmall
	val title3: TextStyle @Composable get() = MaterialTheme.typography.titleLarge
}

val AppShapes = Shapes(
	extraSmall = RoundedCornerShape(6.dp),
	small = RoundedCornerShape(8.dp),
	medium = RoundedCornerShape(12.dp),
	large = RoundedCornerShape(16.dp),
	extraLarge = RoundedCornerShape(24.dp),
)

@Composable
fun SubwaysTheme(theme: AppTheme, content: @Composable () -> Unit) {
	val palette = remember(theme) { AppPalette.from(theme) }
	val view = LocalView.current
	if (!view.isInEditMode) {
		SideEffect {
			val window = (view.context as? Activity)?.window ?: return@SideEffect
			val controller = WindowCompat.getInsetsController(window, view)
			controller.isAppearanceLightStatusBars = !theme.dark
			controller.isAppearanceLightNavigationBars = !theme.dark
		}
	}
	CompositionLocalProvider(LocalPalette provides palette) {
		MaterialTheme(colorScheme = palette.colorScheme(), typography = AppTypography, shapes = AppShapes, content = content)
	}
}
