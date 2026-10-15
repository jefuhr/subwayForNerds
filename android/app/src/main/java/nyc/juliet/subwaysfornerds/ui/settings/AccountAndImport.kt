package nyc.juliet.subwaysfornerds.ui.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import nyc.juliet.subwaysfornerds.core.Settings
import nyc.juliet.subwaysfornerds.core.SettingsMerge
import nyc.juliet.subwaysfornerds.core.TrainFavorites
import nyc.juliet.subwaysfornerds.core.TrainFavoriteRules
import nyc.juliet.subwaysfornerds.ui.AppModel
import nyc.juliet.subwaysfornerds.ui.Labels
import nyc.juliet.subwaysfornerds.ui.account.AccountModel
import nyc.juliet.subwaysfornerds.ui.components.ActionButton
import nyc.juliet.subwaysfornerds.ui.components.ChipRow
import nyc.juliet.subwaysfornerds.ui.components.ChoiceChip
import nyc.juliet.subwaysfornerds.ui.components.LinkButton
import nyc.juliet.subwaysfornerds.ui.components.ListScreen
import nyc.juliet.subwaysfornerds.ui.components.RowContainer
import nyc.juliet.subwaysfornerds.ui.components.ScreenExit
import nyc.juliet.subwaysfornerds.ui.components.section
import nyc.juliet.subwaysfornerds.ui.theme.AppTheme
import nyc.juliet.subwaysfornerds.ui.theme.TextRoles
import nyc.juliet.subwaysfornerds.ui.theme.palette
import java.util.Locale
import kotlinx.coroutines.CancellationException

/** Human-readable portable setting values for previews and conflicts. */
object SettingsText {
	fun value(value: JsonElement?): String = when (value) {
		null, JsonNull -> "Not set"
		is JsonPrimitive -> when {
			value.isString -> text(value.content)
			value.booleanOrNull != null -> if (value.booleanOrNull == true) "On" else "Off"
			else -> value.doubleOrNull?.let { if (it % 1.0 == 0.0) String.format(Locale.US, "%,d", it.toLong()) else it.toString() } ?: value.content
		}
		is JsonArray -> if (value.isEmpty()) "None" else value.joinToString("; ") { item ->
			if (item is JsonArray) "${item.size}-car consist: " + item.joinToString(", ") { value(it) } else value(item)
		}
		is JsonObject -> value.keys.sorted().joinToString(" · ") { it.replaceFirstChar { c -> c.uppercase() } + ": " + value(value[it]) }
	}

	private fun text(raw: String): String =
		AppTheme.all.firstOrNull { it.id == raw }?.name
			?: Labels.widgetFields.firstOrNull { it == raw }?.let(Labels::widgetFieldTitle)
			?: Labels.stationModes.firstOrNull { it == raw }?.let(Labels::stationModeTitle)
			?: Labels.trainMatches.firstOrNull { it == raw }?.let(Labels::trainMatchTitle)
			?: Labels.distanceUnits.firstOrNull { it == raw }?.let(Labels::distanceTitle)
			?: Labels.timeFormats.firstOrNull { it == raw }?.let(Labels::timeFormatTitle)
			?: if (TrainFavorites.validCarID(raw)) TrainFavoriteRules.label(raw) else raw
}

private fun LazyListScope.changeRows(model: AppModel, from: Settings, to: Settings) {
	section("changes", header = "Changes") {
		val changes = runCatching { SettingsMerge.changes(from, to) }.getOrDefault(emptyList())
		changes.forEach { change ->
			row(change.path) {
				RowContainer {
					Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
						Text(Labels.settingPath(change.path) { id -> model.allStations.firstOrNull { it.id == id }?.name }, style = TextRoles.subheadlineBold)
						Text("Current: " + SettingsText.value(change.local), style = TextRoles.caption, color = palette.muted)
						Text("New: " + SettingsText.value(change.remote), style = TextRoles.caption)
					}
				}
			}
		}
		if (changes.isEmpty()) row { RowContainer { Text("These settings match this device.", style = TextRoles.footnote, color = palette.muted) } }
	}
}

/** Preview before a `.nerds` file replaces this device's settings. */
@Composable
fun ImportPreviewScreen(model: AppModel, account: AccountModel, close: () -> Unit) {
	val file = model.pendingImport
	var error by rememberSaveable { mutableStateOf<String?>(null) }
	var saving by remember { mutableStateOf(false) }
	ListScreen("Import settings", exit = ScreenExit.CLOSE, onExit = { model.cancelImport(); close() }, tag = "importPreview") {
		if (file == null) {
			section("none") { row { RowContainer { Text("No settings file is waiting to import.", style = TextRoles.footnote) } } }
			return@ListScreen
		}
		val settings = file.settings
		section("summary") {
			row { RowContainer { Text("${settings.favorites.size} favorite stations · ${settings.trainFavorites.cars.size} cars · ${settings.trainFavorites.consists.size} consists", style = TextRoles.subheadline) } }
			row { RowContainer { Text("${settings.combinedStations.size} combined stations · ${settings.hiddenRoutes.size} hidden lines", style = TextRoles.subheadline) } }
			row { RowContainer { Text("Last station: " + (settings.combinedStations[file.lastStation]?.name ?: model.stations.firstOrNull { it.id == file.lastStation }?.name ?: file.lastStation), style = TextRoles.subheadline) } }
			row { RowContainer { Text(if (account.account == null) "This replaces settings on this device." else "This replaces settings on this device and will sync to your account.", style = TextRoles.subheadline) } }
		}
		changeRows(model, model.settings, settings)
		section("confirm") {
			row {
				ActionButton(if (saving) "Saving settings…" else "Replace settings", {
					saving = true
					// The model's scope finishes the save; the preview stays open if saving fails.
					model.launch {
						try { model.importSettings(file); close() }
						catch (failure: CancellationException) { throw failure }
						catch (failure: Exception) { error = "Settings could not be saved on this device. Your previous preferences are unchanged. " + (failure.message ?: "") }
						finally { saving = false }
					}
				}, Modifier.padding(start = 4.dp).testTag("confirmSettingsImport"), enabled = !saving, destructive = true)
			}
			error?.let { message -> row { RowContainer { Text(message, style = TextRoles.footnote, color = palette.danger) } } }
		}
	}
}

/** Optional accounts. Sign-in opens the server's browser page in a Custom Tab. */
fun LazyListScope.accountSection(model: AppModel, account: AccountModel) {
	section("account", header = "Account and sync", footer = "Your current station stays separate on each device. Signing out keeps local settings.") {
		if (account.pendingUnreadable) row { PendingSignInRecovery(account) }
		when {
			!account.ready -> row { RowContainer { Text("Checking account availability…", style = TextRoles.footnote) } }
			!account.enabled -> row { RowContainer { Text("Sign-in is currently unavailable. You can still move settings with a .nerds file.", style = TextRoles.footnote, modifier = Modifier.testTag("accountsUnavailable")) } }
			account.account != null -> {
				val user = account.account!!
				row { RowContainer { Text(account.status, style = TextRoles.footnote, modifier = Modifier.testTag("syncStatus")) } }
				user.identities.forEach { identity ->
					row("identity:${identity.provider}") {
						Column(Modifier.padding(start = 16.dp, top = 8.dp)) {
							Text(identity.provider.replaceFirstChar { it.uppercase() } + " · " + (identity.email ?: "Connected"), style = TextRoles.subheadline)
							if (user.identities.size > 1) UnlinkButton(account, identity.provider)
						}
					}
				}
				account.providers.filter { provider -> user.identities.none { it.provider == provider } }.forEach { provider ->
					row("link:$provider") { ActionButton("Link ${provider.replaceFirstChar { it.uppercase() }}", { account.login(provider, "link") }, Modifier.padding(start = 4.dp), enabled = !account.signingIn && !account.pendingUnreadable) }
				}
				account.first?.settings?.let { remote ->
					row { RowContainer { Text("Choose settings to start syncing", style = TextRoles.headline) } }
					runCatching { SettingsMerge.changes(model.settings, remote) }.getOrDefault(emptyList()).forEach { change ->
						row("first:${change.path}") {
							RowContainer {
								Column {
									Text(Labels.settingPath(change.path) { id -> model.allStations.firstOrNull { it.id == id }?.name }, style = TextRoles.subheadlineBold)
									Text("This device: " + SettingsText.value(change.local), style = TextRoles.caption, color = palette.muted)
									Text("Account: " + SettingsText.value(change.remote), style = TextRoles.caption)
								}
							}
						}
					}
					row { ActionButton("Use this device’s settings", { account.chooseInitial(remote = false) }, Modifier.padding(start = 4.dp).testTag("useDeviceSettings")) }
					row { ActionButton("Use account settings", { account.chooseInitial(remote = true) }, Modifier.padding(start = 4.dp).testTag("useAccountSettings")) }
				}
				if (account.conflicts.isNotEmpty()) {
					row { RowContainer { Text("Choose which changes to keep", style = TextRoles.headline) } }
					account.conflicts.forEach { conflict ->
						row("conflict:${conflict.path}") {
							Column(Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
								Text(Labels.settingPath(conflict.path) { id -> model.allStations.firstOrNull { it.id == id }?.name }, style = TextRoles.subheadline, modifier = Modifier.padding(horizontal = 16.dp))
								val choice = account.choices.selection(conflict)
								ChipRow(Modifier.padding(horizontal = 12.dp)) {
									ChoiceChip("This device: " + SettingsText.value(conflict.local), choice == "local", { account.choices = account.choices.select("local", conflict) })
									ChoiceChip("Account: " + SettingsText.value(conflict.remote), choice == "remote", { account.choices = account.choices.select("remote", conflict) })
								}
							}
						}
					}
					row { ActionButton("Save choices", { account.resolve() }, Modifier.padding(start = 4.dp).testTag("saveConflictChoices"), enabled = account.choices.resolved(account.conflicts) != null) }
				}
				row { ActionButton("Sync now", { model.launch { account.sync() } }, Modifier.padding(start = 4.dp).testTag("syncNow")) }
				row { ActionButton("Sign out", { account.logout() }, Modifier.padding(start = 4.dp).testTag("signOut")) }
				row { DeleteAccountButton(account) }
			}
			else -> {
				row { RowContainer { Text("Sign in to keep your settings across devices, or continue using the app without an account.", style = TextRoles.footnote) } }
				account.providers.forEach { provider ->
					row("signIn:$provider") {
						ActionButton("Continue with ${provider.replaceFirstChar { it.uppercase() }}", { account.login(provider) }, Modifier.padding(start = 4.dp).testTag("signIn_$provider"), enabled = !account.signingIn && !account.pendingUnreadable)
					}
				}
			}
		}
		account.error?.let { message ->
			row { RowContainer { Text(message, style = TextRoles.footnote, color = palette.danger) } }
			account.account?.identities?.forEach { identity ->
				row("verify:${identity.provider}") { ActionButton("Verify again with ${identity.provider.replaceFirstChar { it.uppercase() }}", { account.login(identity.provider, "reauth") }, Modifier.padding(start = 4.dp)) }
			}
		}
		row { LinkButton("Privacy", "https://juliet.nyc/subwaysForNerds/privacy.html", Modifier.padding(start = 4.dp)) }
	}
}

@Composable
private fun PendingSignInRecovery(account: AccountModel) {
	var confirmReplacement by rememberSaveable { mutableStateOf(false) }
	Column(Modifier.fillMaxWidth().padding(12.dp).testTag("pendingSignInRecovery")) {
		Text("Pending sign-in is preserved", style = TextRoles.subheadlineBold)
		Text("This device could not unlock the saved sign-in proof. Unlock your device and retry. Replacing it discards only the pending sign-in; your current account and settings stay saved.", style = TextRoles.footnote, color = palette.muted)
		ActionButton("Retry unlocking sign-in", { account.retryPendingSignIn() }, Modifier.testTag("retryPendingSignIn"))
		ActionButton("Replace pending sign-in…", { confirmReplacement = true }, Modifier.testTag("replacePendingSignIn"), destructive = true)
	}
	if (confirmReplacement) AlertDialog(
		onDismissRequest = { confirmReplacement = false },
		title = { Text("Replace the pending sign-in?") },
		text = { Text("The saved proof will be removed, so the previous browser sign-in cannot finish. You can then start a new sign-in. Your current account and settings will stay saved.") },
		confirmButton = { TextButton(onClick = { confirmReplacement = false; account.replacePendingSignIn() }, modifier = Modifier.testTag("confirmReplacePendingSignIn")) { Text("Replace pending sign-in", color = palette.danger) } },
		dismissButton = { TextButton(onClick = { confirmReplacement = false }, modifier = Modifier.testTag("cancelReplacePendingSignIn")) { Text("Keep saved proof", color = palette.action) } },
	)
}

@Composable
private fun UnlinkButton(account: AccountModel, provider: String) {
	var confirm by rememberSaveable { mutableStateOf(false) }
	TextButton(onClick = { confirm = true }) { Text("Unlink ${provider.replaceFirstChar { it.uppercase() }}", color = palette.danger) }
	if (confirm) AlertDialog(
		onDismissRequest = { confirm = false },
		title = { Text("Unlink ${provider.replaceFirstChar { it.uppercase() }}?") },
		text = { Text("You will be signed out on all devices. Sign in with your remaining login method.") },
		confirmButton = { TextButton(onClick = { confirm = false; account.remove(provider) }) { Text("Unlink", color = palette.danger) } },
		dismissButton = { TextButton(onClick = { confirm = false }) { Text("Cancel", color = palette.action) } },
	)
}

@Composable
private fun DeleteAccountButton(account: AccountModel) {
	var confirm by rememberSaveable { mutableStateOf(false) }
	ActionButton("Delete account", { confirm = true }, Modifier.padding(start = 4.dp).testTag("deleteAccount"), destructive = true)
	if (confirm) AlertDialog(
		onDismissRequest = { confirm = false },
		title = { Text("Delete your account and all synced settings?") },
		text = { Text("Settings already on devices will remain there.") },
		confirmButton = { TextButton(onClick = { confirm = false; account.remove() }) { Text("Delete account", color = palette.danger) } },
		dismissButton = { TextButton(onClick = { confirm = false }) { Text("Cancel", color = palette.action) } },
	)
}
