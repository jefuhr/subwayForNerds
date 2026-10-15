package nyc.juliet.subwaysfornerds.ui

import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import nyc.juliet.subwaysfornerds.core.FleetFacets
import nyc.juliet.subwaysfornerds.core.FleetOfflineManifest
import nyc.juliet.subwaysfornerds.core.FleetPackJob
import nyc.juliet.subwaysfornerds.core.FleetPackManifest
import nyc.juliet.subwaysfornerds.core.FleetPackSelection
import nyc.juliet.subwaysfornerds.core.LoadProgress
import nyc.juliet.subwaysfornerds.core.TransitException
import nyc.juliet.subwaysfornerds.core.load
import nyc.juliet.subwaysfornerds.ui.data.FleetDownloadExpiredException
import nyc.juliet.subwaysfornerds.ui.data.FleetStorage
import nyc.juliet.subwaysfornerds.ui.data.FleetTransfer
import nyc.juliet.subwaysfornerds.ui.data.TransitService
import java.net.URI
import java.util.UUID

/**
 * Explicit, foreground-bound fleet downloads: prepare a pack for the chosen scope, review its
 * sizes, then download. A failed or canceled update always keeps the previous saved fleet.
 */
@Stable
class FleetPackModel(private val scope: CoroutineScope, private val app: AppModel, val store: FleetStorage?) {
	var offlineManifest by mutableStateOf<FleetOfflineManifest?>(null); private set
	var availablePack by mutableStateOf<FleetPackManifest?>(null); private set
	var selection by mutableStateOf(FleetPackSelection()); private set
	var facets by mutableStateOf(FleetFacets()); private set
	var facetsError by mutableStateOf<String?>(null); private set
	var isPreparing by mutableStateOf(false); private set
	/** The pack job while the server prepares it; null until the request is accepted. */
	var job by mutableStateOf<FleetPackJob?>(null); private set
	var download by mutableStateOf<FleetTransfer?>(null); private set
	var error by mutableStateOf<String?>(null); private set
	/** Browse the saved download instead of live fleet reports. */
	var useSavedFleet by mutableStateOf(false)
	private var task by mutableStateOf<Job?>(null)
	private var generation: UUID? = null
	/** Set when the app left the screen during a download, so the stop is explained rather than silent. */
	private var stoppedByBackground = false

	val isDownloading: Boolean get() = task != null

	suspend fun refreshManifest() {
		offlineManifest = runCatching { store?.manifest() }.getOrNull()
	}

	suspend fun loadFacets() {
		val requested = app.endpoint
		if (!app.connected) return
		facetsError = null
		try {
			val page = app.service.fleet(mapOf("view" to "cars", "retired" to "true"))
			if (requested == app.endpoint) facets = page.facets
		} catch (failure: CancellationException) { throw failure }
		catch (_: Exception) {
			if (requested == app.endpoint) facetsError = "Car type and yard choices are unavailable. You can still prepare all cars or retry loading the choices."
		}
	}

	fun chooseSelection(value: FleetPackSelection) {
		if (task != null) return
		selection = value
		availablePack = null
		error = null
	}

	/** Asks the server to build the pack and waits, showing its own build progress once reported. */
	fun prepare() {
		if (task != null) return
		val token = UUID.randomUUID()
		val client = app.service
		val wanted = selection
		generation = token
		error = null
		availablePack = null
		isPreparing = true
		job = null
		task = scope.launch {
			try {
				val pack = preparePack(client, wanted) { if (generation == token) job = it }
				if (generation == token && client === app.service) availablePack = pack
			} catch (failure: CancellationException) { throw failure }
			catch (failure: Exception) { if (generation == token) error = failure.message ?: "The fleet pack could not be prepared." }
			finally { finish(token) }
		}
	}

	private suspend fun preparePack(client: TransitService, wanted: FleetPackSelection, update: (FleetPackJob) -> Unit): FleetPackManifest {
		var current = client.prepareFleetPack(wanted)
		update(current)
		var restarted = false
		// The server may scan several million recent events on its first build; wait through its 20-minute limit.
		val deadline = System.currentTimeMillis() + 21 * 60 * 1000L
		while (current.state == "preparing") {
			if (System.currentTimeMillis() > deadline) throw IllegalStateException("This fleet pack is taking longer than expected. Try preparing it again. Your saved fleet is still available.")
			delay(1000)
			current = try { client.fleetPackStatus(current.jobId) } catch (expired: TransitException.NotFound) {
				if (restarted) throw expired
				restarted = true
				client.prepareFleetPack(wanted)
			}
			update(current)
		}
		val pack = current.manifest
		if (current.state != "ready" || pack == null || pack.selection.historyDays != wanted.historyDays ||
			pack.selection.equipment.toSet() != wanted.equipment.toSet() || pack.selection.yards.toSet() != wanted.yards.toSet()) {
			throw IllegalStateException("The server returned a fleet pack for a different selection. Prepare it again.")
		}
		return pack
	}

	fun startDownload() {
		val pack = availablePack ?: return
		val storage = store ?: return
		if (task != null) return
		error = null
		download = FleetTransfer("Downloading fleet archive", 0, pack.archiveByteLength, null)
		stoppedByBackground = false
		val token = UUID.randomUUID()
		generation = token
		val base = app.endpoint
		val client = app.service
		task = scope.launch {
			try {
				storage.download(pack, base) { progress ->
					scope.launch {
						if (generation != token || isPreparing) return@launch
						val previous = download
						// Updates can arrive out of order; within a stage the bar only moves forward.
						if (previous == null || previous.stageLabel != progress.stageLabel || (progress.fraction ?: 0.0) >= (previous.fraction ?: 0.0)) download = progress
					}
				}
				val saved = storage.manifest()
				if (generation == token) offlineManifest = saved
			} catch (failure: FleetDownloadExpiredException) {
				if (generation != token || base != app.endpoint) return@launch
				availablePack = null
				isPreparing = true
				download = null
				job = null
				try {
					val fresh = preparePack(client, pack.selection) { if (generation == token) job = it }
					if (generation == token && base == app.endpoint) {
						availablePack = fresh
						error = "The previous archive expired. A fresh pack is ready; review its size and choose Download again."
					}
				} catch (again: CancellationException) { throw again }
				catch (again: Exception) { if (generation == token) error = again.message }
			} catch (failure: CancellationException) { throw failure }
			catch (failure: Exception) { if (generation == token) error = failure.message ?: "The fleet download failed. Your previous download is still available." }
			finally { finish(token) }
		}
	}

	/**
	 * The app is leaving the foreground. The store cancels a download and keeps the previous fleet;
	 * preparing (including re-preparing an expired archive) stops polling the server as well.
	 */
	fun leavingForeground() {
		val running = task ?: return
		if (!isPreparing) { stoppedByBackground = true; return }
		running.cancel()
		generation?.let { finish(it) }
		error = "Preparing the fleet pack stopped because the app left the screen. Your saved fleet is still available. Prepare it again to continue."
	}

	private fun finish(token: UUID) {
		if (generation != token) return
		if (stoppedByBackground) {
			stoppedByBackground = false
			error = "The fleet download stopped because the app left the screen. Your previous download is still available. Keep the app open while saving."
		}
		download = null
		job = null
		isPreparing = false
		generation = null
		task = null
	}

	fun cancel() {
		val running = task ?: return
		running.cancel()
		generation?.let { finish(it) }
	}

	suspend fun delete() {
		if (task != null) return
		try {
			store?.delete()
			offlineManifest = null
			useSavedFleet = false
		} catch (failure: CancellationException) { throw failure }
		catch (failure: Exception) { error = failure.message }
	}

	/** Cached content belongs to one endpoint. */
	fun endpointChanged() {
		cancel()
		availablePack = null
		facets = FleetFacets()
	}

	/** The bar while the server builds a pack: its own build progress once the job reports it. */
	val packLoad: LoadProgress get() {
		val current = job ?: return LoadProgress(null, "Sending your fleet selection to ${hostOf(app.endpoint)}…")
		val progress = current.progress ?: return LoadProgress(null, "The server is preparing your fleet pack…")
		return progress.load
	}
	val downloadLoad: LoadProgress get() = (download ?: FleetTransfer("Downloading fleet archive", 0, null, null)).load

	private fun hostOf(endpoint: String): String = runCatching { URI(endpoint).host }.getOrNull() ?: "the server"
}
