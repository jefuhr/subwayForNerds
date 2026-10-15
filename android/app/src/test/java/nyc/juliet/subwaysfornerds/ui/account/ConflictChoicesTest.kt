package nyc.juliet.subwaysfornerds.ui.account

import kotlinx.serialization.json.JsonPrimitive
import nyc.juliet.subwaysfornerds.core.SettingsConflict
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ConflictChoicesTest {
	private val theme = SettingsConflict("/theme", JsonPrimitive("kuromi"), JsonPrimitive("hacker"))
	private val units = SettingsConflict("/units/time", JsonPrimitive("12h"), JsonPrimitive("24h"))

	@Test fun everyConflictNeedsAnExplicitChoice() {
		var choices = ConflictChoices()
		choices = choices.select("local", theme)
		assertNull(choices.resolved(listOf(theme, units)))
		choices = choices.select("remote", units)
		assertEquals(mapOf("/theme" to "local", "/units/time" to "remote"), choices.resolved(listOf(theme, units)))
	}

	@Test fun aChoiceBelongsToTheExactValuesShown() {
		val choices = ConflictChoices().select("remote", theme)
		val changed = theme.copy(remote = JsonPrimitive("burger-king"))
		assertEquals("", choices.selection(changed))
		assertNull(choices.resolved(listOf(changed)))
	}

	@Test fun clearingAChoiceRemovesIt() {
		val choices = ConflictChoices().select("local", theme).select("", theme)
		assertEquals("", choices.selection(theme))
	}
}
