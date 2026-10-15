package nyc.juliet.subwaysfornerds.ui.theme

import androidx.compose.ui.graphics.Color
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AppThemeTest {
	@Test fun keepsAllTenThemesInPortableOrder() {
		assertEquals(
			listOf("subway", "nyc-ferry", "night", "hello-kitty", "cinnamoroll", "pompompurin", "kuromi", "windows-xp", "hacker", "burger-king"),
			AppTheme.all.map { it.id },
		)
	}

	@Test fun unknownThemeIdsDisplayTheDefaultPalette() {
		assertEquals("subway", AppTheme.forId("future-theme").id)
		assertEquals("subway", AppTheme.forId(null).id)
		assertEquals("kuromi", AppTheme.forId("kuromi").id)
	}

	@Test fun everyPaletteMeetsTextContrast() {
		for (theme in AppTheme.all) {
			val palette = AppPalette.from(theme)
			assertContrast(theme.id + " ink on background", palette.ink, palette.background, 7.0)
			assertContrast(theme.id + " ink on card", palette.ink, palette.card, 7.0)
			assertContrast(theme.id + " muted on card", palette.muted, palette.card, 4.5)
			assertContrast(theme.id + " muted on background", palette.muted, palette.background, 4.5)
			assertContrast(theme.id + " action on card", palette.action, palette.card, 4.5)
			assertContrast(theme.id + " action on background", palette.action, palette.background, 4.5)
			assertContrast(theme.id + " text on accent", palette.onAccent, palette.accent, 4.5)
			assertContrast(theme.id + " white on selection", Color.White, palette.selection, 4.5)
		}
	}

	@Test fun darkThemesDeepenSelectionForWhiteText() {
		val subway = AppTheme.forId("subway")
		assertTrue(subway.dark)
		assertTrue(subway.selection.luminanceValue() < subway.accent.luminanceValue())
		val ferry = AppTheme.forId("nyc-ferry")
		assertEquals(ferry.accent, ferry.selection)
	}

	private fun assertContrast(label: String, foreground: Color, background: Color, minimum: Double) {
		val ratio = contrastRatio(foreground, background)
		assertTrue("$label is $ratio, needs $minimum", ratio >= minimum)
	}
}
