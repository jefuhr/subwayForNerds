package nyc.juliet.subwaysfornerds.widgets.runtime

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.UserManager
import androidx.work.*
import java.io.File
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import nyc.juliet.subwaysfornerds.core.*
import nyc.juliet.subwaysfornerds.data.*
import nyc.juliet.subwaysfornerds.location.LocationController
import nyc.juliet.subwaysfornerds.widgets.ui.TransitWidgetUi

object WidgetRuntime {
	private val refreshLock = Mutex()
	private const val periodicName = "transit-widget-periodic-v1"
	private const val manualName = "transit-widget-refresh-v1"

	/** Local read only. Widgets share settings/cache; no account token is needed or read. */
	fun read(context: Context): WidgetSnapshot = runBlocking(Dispatchers.IO) { readAsync(context) }
	suspend fun readAsync(context: Context): WidgetSnapshot {
		if (!unlocked(context)) return WidgetSnapshot(message = "Unlock your device to view saved trains.")
		return try {
			val settingsStore = AndroidSettingsStore(context)
			val settings = settingsStore.load(); val base = settingsStore.apiBase()
			val cache = AndroidTransitCache(context, base); cache.setPreferences(settings.offline)
			val content = readContent(context)?.takeIf { it.endpoint == AndroidTransitCache.endpointKey(base) }
			val now = System.currentTimeMillis() / 1000.0
			if (settings.offline.widgetsFollowActiveRide) {
				val record = cache.activeRideRecord()
				val trip = record?.takeIf { !it.key.startsWith("path|") }?.let { cachedRideTrip(cache, it.key) }
				val active = supportedWidgetRide(settings, record, trip)
				if (active != null && trip != null) return WidgetSnapshotFactory.ride(trip, settings, now,
					cached = !(content?.rideKey == active.key && content.rideID == active.id && content.rideStartedAt == active.startedAt && !content.cached))
			}
			val catalog = cache.catalog()
			val previous = content?.stationID ?: settingsStore.lastStation()
			val locator = LocationController(context)
			val location = locator.lastLocation()
			val notice = locator.status().notice ?: content?.notice
			val station = selectedStation(settings, catalog, location, previous, now)
			if (station == null) return empty(settings, now, selectionMessage(settings, catalog), notice)
			val definition = settings.combinedStations[station.id]
			if (definition != null) {
				val members = if (content?.stationID == station.id && content.definition == definition && content.members.isNotEmpty()) content.members.map { it.member() }
					else definition.stationIDs.map { id -> val saved = cache.boardSnapshot(id); MemberBoardSnapshot(catalog.firstOrNull { it.id == id } ?: saved?.board?.station ?: missingStation(id), saved?.board, true, saved?.savedAt, if (saved == null) "Departures unavailable" else null) }
				val combined = CombinedBoards.merge(station, members)
				return WidgetSnapshotFactory.board(combined.board, settings, now, members.none { it.board != null && !it.cached }, notice, combined,
					combined.warnings.takeIf { it.isNotEmpty() }?.joinToString("; ", prefix = "Partial board · "))
			}
			val current = content?.takeIf { it.stationID == station.id && it.rideKey == null }?.board
			val board = current ?: cache.loadBoard(station.id)
			if (board == null) return empty(settings, now, if (station.departureMode == "external") "Open station for departure times." else "Train feed unavailable. Tap to open the app.", notice).copy(stationID = station.id, stationName = station.name)
			WidgetSnapshotFactory.board(board, settings, now, cached = if (current != null) content.cached else true, notice = notice)
		} catch (error: CancellationException) { throw error }
		catch (_: Exception) { WidgetSnapshot(message = "Saved widget data could not be read. Open the app.", generatedAt = System.currentTimeMillis() / 1000.0) }
	}

	suspend fun refresh(context: Context) { refreshInternal(context.applicationContext, foreground = false) }
	suspend fun refreshForeground(context: Context) { refreshInternal(context.applicationContext, foreground = true) }
	/** Publishes app-fetched data without spending another refresh or discarding live widget rows. */
	suspend fun boardSaved(context: Context, board: Board) { publishBoard(context, board, cached = false) }
	suspend fun boardSaved(context: Context) {
		if (!unlocked(context)) return
		val store = AndroidSettingsStore(context); val base = store.apiBase(); val settings = store.load()
		val cache = AndroidTransitCache(context, base)
		val content = readContent(context)
		val selected = selectedStation(settings, cache.catalog(), LocationController(context).lastLocation(), content?.stationID ?: store.lastStation(), System.currentTimeMillis() / 1000.0)
		selected?.let { cache.loadBoard(it.id) }?.let { publishBoard(context, it, cached = true) } ?: TransitWidgetUi.updateAll(context)
	}
	private suspend fun publishBoard(context: Context, board: Board, cached: Boolean) {
		if (!unlocked(context)) return
		val store = AndroidSettingsStore(context); val settings = store.load(); val base = store.apiBase()
		val cache = AndroidTransitCache(context, base); val catalog = cache.catalog()
		val content = readContent(context)?.takeIf { it.endpoint == AndroidTransitCache.endpointKey(base) }
		val now = System.currentTimeMillis() / 1000.0
		val selected = selectedStation(settings, catalog, LocationController(context).lastLocation(), content?.stationID ?: store.lastStation(), now)
		val definition = selected?.let { settings.combinedStations[it.id] }
		if (selected?.id == board.station.id && definition == null) {
			val previous = content?.takeIf { it.stationID == selected.id }?.board
			writeContent(context, WidgetContent(endpoint = AndroidTransitCache.endpointKey(base), stationID = selected.id,
				board = OfflinePlanner.mergeBoard(board, previous).board, cached = cached, notice = content?.notice, refreshedAt = now))
		} else if (selected != null && definition?.stationIDs?.contains(board.station.id) == true) {
			val previous = content?.takeIf { it.stationID == selected.id && it.definition == definition }
			val members = definition.stationIDs.map { id ->
				val old = previous?.members?.firstOrNull { it.station.id == id }
				if (id == board.station.id) SavedWidgetMember(board.station, OfflinePlanner.mergeBoard(board, old?.board).board, cached)
				else old ?: cache.boardSnapshot(id).let { saved -> SavedWidgetMember(catalog.firstOrNull { it.id == id } ?: saved?.board?.station ?: missingStation(id), saved?.board, true, saved?.savedAt) }
			}
			writeContent(context, WidgetContent(endpoint = AndroidTransitCache.endpointKey(base), stationID = selected.id, members = members, definition = definition, notice = content?.notice, refreshedAt = now))
		}
		TransitWidgetUi.updateAll(context)
	}
	private suspend fun refreshInternal(context: Context, foreground: Boolean) {
		if (!refreshPlan(context).refreshAllowed || !refreshLock.tryLock()) return
		try {
			val settingsStore = AndroidSettingsStore(context)
			var settings = settingsStore.load(); val base = settingsStore.apiBase()
			val cache = AndroidTransitCache(context, base); cache.setPreferences(settings.offline)
			val client = TransitClient(base)
			val old = readContent(context)?.takeIf { it.endpoint == AndroidTransitCache.endpointKey(base) }
			var catalog = cache.catalog()
			if (catalog.isEmpty() && connected(context)) {
				try { withTimeout(8000) { catalog = TransitFetchSlots.run(OfflineFetchPriority.SELECTED) { client.stations() }; cache.saveCatalog(catalog) } }
				catch (error: CancellationException) { if (error !is TimeoutCancellationException) throw error }
				catch (_: Exception) { }
			}
			if (settings.offline.widgetsFollowActiveRide) {
				val ride = cache.activeRideRecord()
				if (ride != null && !ride.key.startsWith("path|")) {
					var live = false
					if (connected(context)) try {
						withTimeout(8000) {
							val trip = TransitFetchSlots.run(OfflineFetchPriority.ACTIVE_RIDE) { client.trip(ride.key) }
							if (trip.train.key == ride.key && trip.source?.state?.error == null) { cache.saveTrip(trip); live = true }
						}
					} catch (error: CancellationException) { if (error !is TimeoutCancellationException) throw error } catch (_: Exception) { }
					settings = settingsStore.load()
					val current = cache.activeRideRecord()
					val eligible = supportedWidgetRide(settings, current, cachedRideTrip(cache, ride.key))
					if (settingsStore.apiBase() == base && eligible == ride) {
						writeContent(context, WidgetContent(endpoint = AndroidTransitCache.endpointKey(base), stationID = old?.stationID,
							rideKey = ride.key, rideStartedAt = ride.startedAt, rideID = ride.id, cached = !live, refreshedAt = System.currentTimeMillis() / 1000.0))
						return
					}
				}
			}
			val locator = LocationController(context)
			val locationStatus = locator.status()
			val located = if (foreground || locationStatus.backgroundEnabled && locationStatus.backgroundPermission) locator.locate(foreground = foreground) else null
			val location = located?.coordinate ?: locator.lastLocation()
			settings = settingsStore.load()
			if (settingsStore.apiBase() != base) return
			val now = System.currentTimeMillis() / 1000.0
			val station = selectedStation(settings, catalog, location, old?.stationID ?: settingsStore.lastStation(), now)
			val notice = located?.notice ?: if (location == null) locationStatus.notice ?: "Location unavailable · saved station" else if (locator.lastLocationApproximate()) "Approximate location" else null
			if (station == null) {
				writeContent(context, WidgetContent(endpoint = AndroidTransitCache.endpointKey(base), stationID = null, notice = notice, message = selectionMessage(settings, catalog), refreshedAt = now)); return
			}
			val definition = settings.combinedStations[station.id]
			if (definition != null) {
				val members = definition.stationIDs.map { id -> val saved = cache.boardSnapshot(id); SavedWidgetMember(catalog.firstOrNull { it.id == id } ?: saved?.board?.station ?: missingStation(id), saved?.board, true, saved?.savedAt, if (saved == null) "Departures unavailable" else null) }.toMutableList()
				if (connected(context)) withTimeoutOrNull(8000) {
					// At most three child tasks exist at once, even for a large group.
					for (indices in members.indices.toList().chunked(3)) coroutineScope {
						indices.map { index -> async {
							val member = members[index]
							if (member.station.isNjt || member.station.departureMode != "external") try {
								val board = TransitFetchSlots.run(OfflineFetchPriority.SELECTED) { client.board(member.station.id) }
								if (board.station.id != member.station.id) throw TransitException.InvalidResponse()
								val merged = cache.saveBoardMerged(board)
								members[index] = SavedWidgetMember(board.station, merged, false, cache.boardSnapshot(board.station.id)?.savedAt)
							} catch (error: CancellationException) { throw error } catch (_: Exception) { members[index] = member.copy(error = "Feed unavailable") }
						} }.awaitAll()
					}
				}
				val latest = settingsStore.load()
				if (settingsStore.apiBase() == base && latest.combinedStations[station.id] == definition) writeContent(context, WidgetContent(endpoint = AndroidTransitCache.endpointKey(base), stationID = station.id, members = members, definition = definition, notice = notice, refreshedAt = System.currentTimeMillis() / 1000.0))
			} else {
				var board = cache.loadBoard(station.id); var cached = true
				if (connected(context) && (station.departureMode != "external" || station.isNjt)) try {
					withTimeout(8000) {
						val incoming = TransitFetchSlots.run(OfflineFetchPriority.SELECTED) { client.board(station.id) }
						if (incoming.station.id != station.id) throw TransitException.InvalidResponse()
						board = cache.saveBoardMerged(incoming); cached = false
					}
				} catch (error: CancellationException) { if (error !is TimeoutCancellationException) throw error } catch (_: Exception) { }
				if (settingsStore.apiBase() == base) writeContent(context, WidgetContent(endpoint = AndroidTransitCache.endpointKey(base), stationID = station.id, board = board, cached = cached, notice = notice, refreshedAt = System.currentTimeMillis() / 1000.0))
			}
		} finally {
			refreshLock.unlock()
			withContext(NonCancellable) { TransitWidgetUi.updateAll(context) }
		}
	}

	/** Preserves all portable interval choices; Android's periodic minimum is 15 minutes. */
	fun schedule(context: Context) {
		scheduleOperations(context)
	}
	/** Broadcast owners keep their lifetime until scheduling/cancellation is durable. */
	suspend fun scheduleAndAwait(context: Context) = withContext(Dispatchers.IO) {
		awaitWidgetOperations(scheduleOperations(context))
	}
	private fun scheduleOperations(context: Context): List<Operation> {
		val initial = refreshPlan(context)
		if (initial.cancelOwnWork) return cancellationOperations(context)
		if (!initial.refreshAllowed) return emptyList()
		val settings = runBlocking(Dispatchers.IO) { AndroidSettingsStore(context).load() }
		val plan = refreshPlan(context, settings)
		if (plan.cancelOwnWork) return cancellationOperations(context)
		val interval = plan.periodicIntervalMinutes ?: return emptyList()
		val request = PeriodicWorkRequestBuilder<TransitWidgetRefreshWorker>(interval, TimeUnit.MINUTES).build()
		return listOf(WorkManager.getInstance(context).enqueueUniquePeriodicWork(periodicName, ExistingPeriodicWorkPolicy.UPDATE, request))
	}
	fun requestRefresh(context: Context) {
		refreshOperations(context)
	}
	suspend fun requestRefreshAndAwait(context: Context) = withContext(Dispatchers.IO) {
		awaitWidgetOperations(refreshOperations(context))
	}
	private fun refreshOperations(context: Context): List<Operation> {
		val plan = refreshPlan(context)
		if (plan.cancelOwnWork) return cancellationOperations(context)
		if (!plan.refreshAllowed) return emptyList()
		return listOf(WorkManager.getInstance(context).enqueueUniqueWork(manualName, ExistingWorkPolicy.KEEP, OneTimeWorkRequestBuilder<TransitWidgetRefreshWorker>().build()))
	}
	/** Receiver onDisabled uses this; never cancel other app WorkManager jobs. */
	fun cancelScheduledRefresh(context: Context) {
		cancellationOperations(context)
	}
	suspend fun cancelScheduledRefreshAndAwait(context: Context) = withContext(Dispatchers.IO) {
		awaitWidgetOperations(cancellationOperations(context))
	}
	private fun cancellationOperations(context: Context): List<Operation> {
		if (!unlocked(context)) return emptyList()
		val manager = WorkManager.getInstance(context)
		return listOf(manager.cancelUniqueWork(periodicName), manager.cancelUniqueWork(manualName))
	}
	fun installedWidgetCount(context: Context): Int = AppWidgetManager.getInstance(context).getAppWidgetIds(
		ComponentName(context, "nyc.juliet.subwaysfornerds.widgets.ui.TransitWidgetReceiver")).size
	private fun refreshPlan(context: Context, settings: Settings = Settings()): WidgetSchedulePlan =
		if (!unlocked(context)) WidgetSnapshotFactory.schedulePlan(settings, 0, false)
		else WidgetSnapshotFactory.schedulePlan(settings, installedWidgetCount(context), true)
	fun navigationIntent(context: Context, snapshot: WidgetSnapshot): Intent {
		val uri = Uri.Builder().scheme("subwaynerds").authority(if (snapshot.rideKey != null) "ride" else "board")
		if (snapshot.rideKey != null) uri.appendQueryParameter("key", snapshot.rideKey) else snapshot.stationID?.let { uri.appendQueryParameter("station", it) }
		return Intent(Intent.ACTION_VIEW, uri.build()).setClassName(context.packageName, "nyc.juliet.subwaysfornerds.MainActivity").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
	}
	fun navigationPendingIntent(context: Context, snapshot: WidgetSnapshot): PendingIntent = PendingIntent.getActivity(context,
		(snapshot.rideKey ?: snapshot.stationID ?: "board").hashCode(), navigationIntent(context, snapshot), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
	private fun selectedStation(settings: Settings, catalog: List<Station>, location: StationLocation?, previous: String?, now: Double): Station? {
		val selection = if (settings.widgets.stationSelection.followApp) settings.stationSelection else settings.widgets.stationSelection.selection
		return selection.select(CombinedBoards.catalog(settings, catalog), settings.favorites, location, previous, now)
	}
	private fun selectionMessage(settings: Settings, catalog: List<Station>): String {
		val selection = if (settings.widgets.stationSelection.followApp) settings.stationSelection else settings.widgets.stationSelection.selection
		return when { selection.mode == "favorite" && settings.favorites.isEmpty() -> "Add a favorite or choose Closest station in Settings."; catalog.isEmpty() -> "Open the app to load your stations."; else -> "No enabled stations match. Open Lines in settings." }
	}
	private fun empty(settings: Settings, now: Double, message: String, notice: String?): WidgetSnapshot = WidgetSnapshot(themeID = settings.theme, generatedAt = now, message = message, notice = notice, display = settings.widgets.display, lockScreen = settings.widgets.lockScreen, timeFormat = settings.units.time)
	private fun missingStation(id: String) = Station(id, id, "", lat = 0.0, lon = 0.0)
	private fun contentStorage(context: Context) = WidgetContentStore(File(context.applicationContext.noBackupFilesDir, "widget-v1"))
	private suspend fun cachedRideTrip(cache: AndroidTransitCache, key: String): CachedTrip? = try { cache.tripSnapshot(key) }
		catch (error: CancellationException) { throw error } catch (_: Exception) { null }
	private suspend fun readContent(context: Context): WidgetContent? = withContext(Dispatchers.IO) { contentStorage(context).read() }
	private suspend fun writeContent(context: Context, value: WidgetContent) = withContext(Dispatchers.IO) {
		contentStorage(context).activate(value) { previous ->
			val latest = AndroidSettingsStore(context).snapshotBlocking()
			val endpoint = AndroidTransitCache.endpointKey(latest.apiBase)
			if (endpoint != value.endpoint) return@activate false
			val cache = AndroidTransitCache(context, latest.apiBase)
			val record = cache.activeRideRecordBlocking()
			val trip = record?.takeIf { !it.key.startsWith("path|") }?.let { try { cache.tripSnapshotBlocking(it.key) } catch (_: Exception) { null } }
			val active = supportedWidgetRide(latest.settings, record, trip)
			val selected = if (active == null) selectedStation(latest.settings, cache.catalogBlocking(), LocationController(context).lastLocationBlocking(), previous?.stationID ?: latest.lastStation, System.currentTimeMillis() / 1000.0) else null
			acceptsWidgetContent(value, WidgetPublicationState(endpoint, selected?.id, latest.settings.combinedStations[selected?.id], active))
		}
	}
	private fun unlocked(context: Context) = context.getSystemService(UserManager::class.java)?.isUserUnlocked != false
	private fun connected(context: Context): Boolean {
		val manager = context.getSystemService(ConnectivityManager::class.java) ?: return false
		return manager.getNetworkCapabilities(manager.activeNetwork)?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true
	}
}

class TransitWidgetRefreshWorker(context: Context, parameters: WorkerParameters) : CoroutineWorker(context, parameters) {
	override suspend fun doWork(): Result = try { WidgetRuntime.refresh(applicationContext); Result.success() }
	catch (error: CancellationException) { throw error }
	catch (_: Exception) { Result.failure() }
}
