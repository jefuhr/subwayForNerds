package nyc.juliet.subwaysfornerds.ui

import android.Manifest
import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import nyc.juliet.subwaysfornerds.core.MAX_SETTINGS_BYTES
import nyc.juliet.subwaysfornerds.ui.account.AccountModel
import nyc.juliet.subwaysfornerds.ui.components.openAppSettings
import nyc.juliet.subwaysfornerds.ui.components.openLink
import nyc.juliet.subwaysfornerds.ui.data.LocationPermission
import nyc.juliet.subwaysfornerds.ui.settings.SettingsActions
import nyc.juliet.subwaysfornerds.ui.theme.palette
import java.time.LocalDate
import java.time.ZoneId

/** The MIME type the manifest declares for `.nerds` settings files. */
const val NERDS_MIME = "application/vnd.subwaysfornerds.settings+json"

/** Reads a `.nerds` file within the 1 MiB limit. Returns the text, or an error for the rider. */
suspend fun readNerds(context: Context, uri: Uri, requireExtension: Boolean): Pair<String?, String?> = withContext(Dispatchers.IO) {
	try {
		if (requireExtension) {
			val name = context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
				if (cursor.moveToFirst()) cursor.getString(0) else null
			}
			if (name != null && !name.lowercase().endsWith(".nerds")) return@withContext null to "Choose a .nerds settings file."
		}
		val bytes = context.contentResolver.openInputStream(uri)?.use { input ->
			val buffer = java.io.ByteArrayOutputStream()
			val chunk = ByteArray(16 * 1024)
			while (buffer.size() <= MAX_SETTINGS_BYTES) {
				val count = input.read(chunk)
				if (count < 0) break
				buffer.write(chunk, 0, count)
			}
			buffer.toByteArray()
		} ?: return@withContext null to "This settings file could not be read. Choose a valid .nerds file."
		if (bytes.size > MAX_SETTINGS_BYTES) return@withContext null to "Settings files must be smaller than 1 MiB."
		bytes.toString(Charsets.UTF_8) to null
	} catch (_: Exception) {
		null to "This settings file could not be read. Choose a valid .nerds file."
	}
}

/**
 * System dialogs, file pickers and Custom Tabs, registered in composition so they survive
 * rotation. Location is requested only after an explicit tap; background access is a second,
 * explained step that Android shows on the app's permission page.
 */
@Composable
fun rememberSettingsActions(model: AppModel, account: AccountModel): SettingsActions {
	val context = LocalContext.current
	var explainBackground by rememberSaveable { mutableStateOf(false) }
	var awaitingBackgroundStep by rememberSaveable { mutableStateOf(false) }

	val foreground = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { result ->
		model.permissionResult(result.values.any { it })
	}
	val background = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { _ ->
		model.launch { model.refreshLocationStatus() }
	}
	val exporter = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument(NERDS_MIME)) { uri ->
		if (uri != null) model.launch {
			val text = runCatching { model.exportSettings() }.getOrElse { model.settingsError = it.message; return@launch }
			val written = withContext(Dispatchers.IO) {
				runCatching { context.contentResolver.openOutputStream(uri, "wt")?.use { it.write(text.toByteArray(Charsets.UTF_8)) } != null }.getOrDefault(false)
			}
			if (!written) model.settingsError = "The settings file could not be saved. Choose another location."
		}
	}
	val importer = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
		if (uri != null) model.launch {
			val (text, error) = readNerds(context, uri, requireExtension = true)
			model.previewSettingsFile(text, error)
		}
	}

	LaunchedEffect(model.permissionRequest) {
		if (model.permissionRequest != null) foreground.launch(arrayOf(Manifest.permission.ACCESS_COARSE_LOCATION, Manifest.permission.ACCESS_FINE_LOCATION))
	}
	LaunchedEffect(account.pendingSignInPage) {
		account.pendingSignInPage?.let { page -> openLink(context, page); account.signInPageOpened() }
	}
	val status = model.widgetLocationStatus
	LaunchedEffect(status, awaitingBackgroundStep) {
		if (awaitingBackgroundStep && status.enabled && status.foregroundAllowed) {
			awaitingBackgroundStep = false
			if (!status.backgroundAllowed) explainBackground = true
		}
	}

	if (explainBackground) AlertDialog(
		onDismissRequest = { explainBackground = false },
		title = { Text("Allow location in the background?") },
		text = { Text("Widgets refresh while the app is closed. To let them use a recent location, choose “Allow all the time” on the next screen. You can change this anytime; without it, widgets keep a saved station and say so.") },
		confirmButton = {
			TextButton(onClick = {
				explainBackground = false
				runCatching { background.launch(Manifest.permission.ACCESS_BACKGROUND_LOCATION) }.onFailure { openAppSettings(context) }
			}, modifier = Modifier.testTag("continueBackgroundLocation")) { Text("Continue", color = palette.action) }
		},
		dismissButton = { TextButton(onClick = { explainBackground = false }) { Text("Not now", color = palette.action) } },
	)

	return remember(model, account) {
		object : SettingsActions {
			override fun exportSettings() {
				val date = LocalDate.now(ZoneId.of("America/New_York"))
				exporter.launch("subway-settings-$date.nerds")
			}
			override fun importSettings() { importer.launch(arrayOf(NERDS_MIME, "application/json", "application/octet-stream", "text/plain", "*/*")) }
			override fun enableWidgetLocation() {
				awaitingBackgroundStep = true
				if (model.locationForegroundPermission() == LocationPermission.GRANTED) model.setWidgetBackgroundLocation(true)
				else model.requestWidgetLocationPermission()
			}
			override fun openLocationSettings() { openAppSettings(context) }
		}
	}
}
