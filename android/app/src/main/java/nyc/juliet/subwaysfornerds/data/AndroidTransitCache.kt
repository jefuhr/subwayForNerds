package nyc.juliet.subwaysfornerds.data

import android.content.Context
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import nyc.juliet.subwaysfornerds.core.*
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

@Serializable
data class CachedBoard(val board: Board, val savedAt: Double, val accessedAt: Double, val viewedStationID: String? = null, val distanceMeters: Double? = null)

@Serializable
data class CachedTrip(
	val key: String,
	val detail: TripDetail? = null,
	val departure: Departure? = null,
	val manual: Boolean = false,
	val savedAt: Double,
	val accessedAt: Double,
	val boardingStationID: String? = null,
	val boardingStationName: String? = null,
) {
	val isComplete: Boolean get() = detail != null
	val sourceTime: Double? get() = (detail?.train?.timestamp ?: departure?.timestamp)?.takeIf { it.isFinite() && it > 0 }
	val sourceTimestamp: Double? get() = sourceTime
	val train: Train? get() = asDetail()?.train
	val stops: List<StopPrediction> get() = train?.stops.orEmpty()
	/** Partial snapshots contain only observed boarding/onward predictions, never a made-up train position. */
	fun asDetail(): TripDetail? {
		detail?.let { return it }
		val row = departure ?: return null
		val stops = buildList<JsonElement> {
			if (row.onward.firstOrNull()?.stopId != row.stopId) add(buildJsonObject {
				put("id", row.stopId); put("name", boardingStationName ?: "Boarding stop")
				boardingStationID?.let { put("stationId", it) }
				row.arrival?.let { put("arrival", it) }; (row.departure ?: row.time)?.let { put("departure", it) }
				row.scheduledTrack?.let { put("scheduledTrack", it) }; row.actualTrack?.let { put("actualTrack", it) }
				row.relationship?.let { put("relationship", it) }
			})
			row.onward.forEach { stop -> add(buildJsonObject {
				put("id", stop.stopId); put("name", stop.name); stop.stationId?.let { put("stationId", it) }; stop.time?.let { put("arrival", it) }
			}) }
		}
		val encoded = TransitJson.encodeToJsonElement(row).jsonObject
		val train = buildJsonObject {
			for (field in listOf("changes", "route", "destination", "direction", "assigned", "timestamp", "relationship", "alerts", "consist", "staleAfter", "vehiclePosition")) encoded[field]?.let { put(field, it) }
			put("key", key); put("tripId", key); put("feed", row.feed); put("stops", JsonArray(stops))
		}
		return TransitJson.decodeFromJsonElement(buildJsonObject { put("train", train) })
	}
}

@Serializable data class ActiveRideRecord(val key: String, val boardingStationID: String? = null, val startedAt: Double, val id: String = java.util.UUID.randomUUID().toString())
@Serializable data class LocalNavigation(val stationID: String = "602", val tripKey: String? = null, val screen: String = "board", val fleetKind: String? = null, val fleetID: String? = null)
data class CacheUsage(val totalBytes: Long, val protectedBytes: Long, val boardCount: Int, val tripCount: Int, val savedTripCount: Int, val overLimit: Boolean)
data class CacheEvictionReport(val expiredTripKeys: List<String> = emptyList(), val expiredStationIDs: List<String> = emptyList(), val evictedTripKeys: List<String> = emptyList(), val evictedStationIDs: List<String> = emptyList())
data class CacheFailure(val operation: String, val identity: String, val message: String, val failedAt: Double)

@Serializable private data class CacheRecord(val version: Int = 1, val endpoint: String, val board: CachedBoard? = null, val trip: CachedTrip? = null)
@Serializable private data class IndexEntry(val kind: String, val key: String, val file: String, val savedAt: Double, val accessedAt: Double, val bytes: Long, val manual: Boolean = false)
@Serializable private data class CacheIndex(val version: Int = 1, val entries: Map<String, IndexEntry> = emptyMap())
@Serializable private data class RideDocument(val version: Int = 1, val ride: ActiveRideRecord? = null)
@Serializable private data class CatalogDocument(val version: Int = 1, val stations: List<Station>)
@Serializable private data class NavigationDocument(val version: Int = 1, val navigation: LocalNavigation)

/** Device-local endpoint-partitioned snapshots; manual/active protection lives in durable records. */
class AndroidTransitCache internal constructor(root: File, val apiBase: String, private val clock: () -> Double = { System.currentTimeMillis() / 1000.0 }) {
	constructor(context: Context, apiBase: String) : this(File(context.applicationContext.noBackupFilesDir, "transit-v1"), apiBase)
	private val endpoint = endpointKey(apiBase)
	private val storage = AtomicStorage(File(root, hash(endpoint)))
	private var preferences = OfflineSettings()
	private var reconciled = false
	private val _failures = MutableStateFlow<List<CacheFailure>>(emptyList())
	val failures: StateFlow<List<CacheFailure>> = _failures

	suspend fun setPreferences(value: OfflineSettings) { val valid = NerdsCodec.validate(Settings(offline = value)).offline; operation("preferences") { preferences = valid } }
	suspend fun saveBoard(board: Board) { saveBoardMerged(board) }
	suspend fun saveBoard(board: Board, viewedStationID: String?, distanceMeters: Double? = null) { saveBoardMerged(board, viewedStationID, distanceMeters) }
	/** Returns the untrimmed source-merged board for live presentation. Only the durable copy has quotas. */
	suspend fun saveBoardMerged(board: Board, viewedStationID: String? = null, distanceMeters: Double? = null): Board = operation("board", board.station.id) {
		val name = fileName("board", board.station.id)
		val existing = record(name)?.board
		val merged = OfflinePlanner.mergeBoard(board, existing?.board)
		val now = clock()
		val savedAt = if (merged.predictionsAdvanced) now else existing?.savedAt ?: now
		val retained = OfflinePlanner.retainedBoard(merged.board, preferences)
		if (retained != existing?.board || merged.advanced) {
			writeRecord(name, CacheRecord(endpoint = endpoint, board = CachedBoard(retained, savedAt, now, viewedStationID ?: existing?.viewedStationID, distanceMeters ?: existing?.distanceMeters)))
			pruneLocked(now)
		} else touch(name, now)
		merged.board
	}
	suspend fun loadBoard(stationID: String): Board? = boardSnapshot(stationID)?.board
	suspend fun boardSnapshot(stationID: String): CachedBoard? = operation("read board", stationID) {
		val name = fileName("board", stationID)
		record(name)?.board?.let { value -> touch(name, clock()); value.copy(accessedAt = clock()) }
	}
	suspend fun saveTrip(trip: TripDetail, manual: Boolean = false) = operation("trip", trip.train.key) {
		storeTrip(CachedTrip(trip.train.key, detail = trip, savedAt = 0.0, accessedAt = 0.0), if (manual) true else null)
	}
	suspend fun saveDeparture(departure: Departure, station: Station, manual: Boolean = false) = operation("partial trip", departure.tripKey) {
		storeTrip(CachedTrip(departure.tripKey, departure = departure, savedAt = 0.0, accessedAt = 0.0, boardingStationID = station.id, boardingStationName = station.name), if (manual) true else null)
	}
	private fun storeTrip(candidate: CachedTrip, manual: Boolean?) {
		require(candidate.key.isNotEmpty())
		val name = fileName("trip", candidate.key)
		val existing = record(name)?.trip
		val positional = candidate.key.startsWith("path|")
		val firstPositionalSave = positional && manual == true && existing?.manual != true
		val takeNew = existing == null || firstPositionalSave || (!positional || !existing.manual) &&
			(candidate.detail?.source?.state?.error == null && candidate.sourceTime != null &&
				(existing.sourceTime == null || candidate.sourceTime!! > existing.sourceTime!! || (!existing.isComplete && candidate.isComplete && candidate.sourceTime!! >= existing.sourceTime!!)) &&
				(!existing.isComplete || candidate.isComplete))
		val now = clock()
		val next = (if (takeNew) candidate.copy(savedAt = now,
			departure = candidate.departure ?: if (firstPositionalSave) null else existing?.departure,
			boardingStationID = candidate.boardingStationID ?: existing?.boardingStationID,
			boardingStationName = candidate.boardingStationName ?: existing?.boardingStationName) else existing!!)
			.copy(manual = manual ?: existing?.manual ?: false, accessedAt = now)
		if (takeNew || next.manual != existing?.manual) writeRecord(name, CacheRecord(endpoint = endpoint, trip = next)) else touch(name, now)
		pruneLocked(now)
	}
	suspend fun loadTrip(key: String): TripDetail? = tripSnapshot(key)?.asDetail()
	suspend fun tripSnapshot(key: String): CachedTrip? = operation("read trip", key) {
		val name = fileName("trip", key)
		record(name)?.trip?.let { value -> touch(name, clock()); value.copy(accessedAt = clock()) }
	}
	internal fun tripSnapshotBlocking(key: String): CachedTrip? = storage.locked { record(fileName("trip", key))?.trip }
	suspend fun savedTrips(): List<TripDetail> = entries().filter { it.manual }.sortedByDescending { it.savedAt }.mapNotNull { it.asDetail() }
	suspend fun entries(): List<CachedTrip> = operation("read trips") {
		index().entries.values.filter { it.kind == "trip" }.mapNotNull { entry -> record(entry.file)?.trip?.copy(accessedAt = entry.accessedAt) }
			.sortedWith(compareByDescending<CachedTrip> { it.accessedAt }.thenBy { it.key })
	}
	suspend fun setManuallySaved(key: String, saved: Boolean) = operation("save trip", key) {
		val name = fileName("trip", key)
		val existing = record(name)?.trip ?: throw IOException("This trip is not cached.")
		writeRecord(name, CacheRecord(endpoint = endpoint, trip = existing.copy(manual = saved)))
	}
	suspend fun removeTrip(key: String) = operation("remove trip", key) {
		val name = fileName("trip", key)
		if (ride()?.key == key) {
			record(name)?.trip?.let { writeRecord(name, CacheRecord(endpoint = endpoint, trip = it.copy(manual = false))) }
		} else { storage.delete(name); saveIndex(index().entries - name) }
	}
	suspend fun setActiveRide(key: String?) = operation("active ride", key ?: "end") {
		val previous = ride()
		val next = key?.let {
			require(!it.startsWith("path|")) { "PATH arrival identities cannot become active rides." }
			val trip = record(fileName("trip", it))?.trip ?: throw IOException("Save this trip before starting a ride.")
			if (previous?.key == it) previous else ActiveRideRecord(it, trip.boardingStationID, clock())
		}
		storage.write("ride.json", TransitJson.encodeToString(RideDocument(ride = next)).toByteArray())
		previous?.let { touch(fileName("trip", it.key), clock()) }
	}
	suspend fun activeRideRecord(): ActiveRideRecord? = operation("read ride") { ride() }
	internal fun activeRideRecordBlocking(): ActiveRideRecord? = storage.locked { ride() }
	suspend fun activeRide(): TripDetail? = operation("read ride") { ride()?.let { record(fileName("trip", it.key))?.trip?.asDetail() } }
	suspend fun clearAutomatic() { operation("clear automatic") { pruneLocked(clock(), clear = true) } }
	suspend fun prune(now: Double = clock()): CacheEvictionReport = operation("prune") { pruneLocked(now) }
	suspend fun evict(): CacheEvictionReport = prune()
	fun clearFailures() { _failures.value = emptyList() }
	suspend fun usage(): CacheUsage = operation("usage") {
		val entries = index().entries.values
		val active = ride()?.key
		val total = entries.sumOf { it.bytes }
		CacheUsage(total, entries.filter { protected(it, active) }.sumOf { it.bytes }, entries.count { it.kind == "board" }, entries.count { it.kind == "trip" }, entries.count { it.manual }, total > preferences.storageLimitMiB * 1_048_576L)
	}
	suspend fun saveCatalog(stations: List<Station>) = operation("catalog") {
		storage.write("catalog.json", TransitJson.encodeToString(CatalogDocument(stations = stations)).toByteArray())
	}
	suspend fun catalog(): List<Station> = operation("read catalog") { readCatalog() }
	internal fun catalogBlocking(): List<Station> = storage.locked { readCatalog() }
	private fun readCatalog(): List<Station> =
		storage.read("catalog.json")?.let { TransitJson.decodeFromString<CatalogDocument>(it.decodeToString()).also { value -> require(value.version == 1) }.stations } ?: emptyList()
	suspend fun saveNavigation(value: LocalNavigation) = operation("navigation") {
		storage.write("navigation.json", TransitJson.encodeToString(NavigationDocument(navigation = value)).toByteArray())
	}
	suspend fun navigation(): LocalNavigation? = operation("read navigation") {
		storage.read("navigation.json", 64 * 1024)?.let { TransitJson.decodeFromString<NavigationDocument>(it.decodeToString()).also { value -> require(value.version == 1) }.navigation }
	}

	private suspend fun <T> operation(kind: String, key: String = "", block: () -> T): T = withContext(Dispatchers.IO) {
		storage.locked {
			try { if (!reconciled) reconcile(); block() }
			catch (error: Exception) { failure(kind, key, error); throw error }
		}
	}
	private fun record(name: String): CacheRecord? = storage.read(name)?.let { bytes ->
		val value = TransitJson.decodeFromString<CacheRecord>(bytes.decodeToString(throwOnInvalidSequence = true))
		if (value.version != 1 || value.endpoint != endpoint || (value.trip == null) == (value.board == null)) throw IOException("Saved snapshot is incompatible. It has been preserved.")
		val expected = value.trip?.let { fileName("trip", it.key) } ?: value.board!!.let { fileName("board", it.board.station.id) }
		if (expected != name) throw IOException("Saved snapshot identity does not match.")
		value
	}
	private fun index(): CacheIndex = try {
		storage.read("index.json", 8L * 1_048_576)?.let { TransitJson.decodeFromString<CacheIndex>(it.decodeToString()).also { index -> require(index.version == 1) } } ?: run { reconcile(); TransitJson.decodeFromString<CacheIndex>(storage.read("index.json")!!.decodeToString()) }
	} catch (_: Exception) { reconcile(); TransitJson.decodeFromString<CacheIndex>(storage.read("index.json")!!.decodeToString()) }
	private fun saveIndex(entries: Map<String, IndexEntry>) {
		try { storage.write("index.json", TransitJson.encodeToString(CacheIndex(entries = entries)).toByteArray()) }
		catch (error: Exception) { reconciled = false; throw error }
	}
	private fun writeRecord(name: String, value: CacheRecord) {
		val bytes = TransitJson.encodeToString(value).toByteArray()
		if (bytes.size > 32 * 1_048_576) throw IOException("This snapshot exceeds its supported size.")
		storage.write(name, bytes)
		val entry = entry(name, value, bytes.size.toLong())
		saveIndex(index().entries + (name to entry))
	}
	private fun entry(name: String, value: CacheRecord, size: Long): IndexEntry = value.trip?.let {
		IndexEntry("trip", it.key, name, it.savedAt, it.accessedAt, size, it.manual)
	} ?: value.board!!.let { IndexEntry("board", it.board.station.id, name, it.savedAt, it.accessedAt, size) }
	private fun reconcile() {
		val previous = try { storage.read("index.json")?.let { TransitJson.decodeFromString<CacheIndex>(it.decodeToString()).entries } ?: emptyMap() } catch (_: Exception) { emptyMap() }
		val entries = mutableMapOf<String, IndexEntry>()
		storage.directory.listFiles().orEmpty().forEach { file ->
			if (file.name.endsWith(".staging")) { file.delete(); return@forEach }
			if (!(file.name.startsWith("board-") || file.name.startsWith("trip-")) || !file.name.endsWith(".json")) return@forEach
			try { record(file.name)?.let { value -> entries[file.name] = entry(file.name, value, file.length()).let { next -> next.copy(accessedAt = maxOf(next.accessedAt, previous[file.name]?.accessedAt ?: 0.0)) } } }
			catch (error: Exception) { previous[file.name]?.let { entries[file.name] = it }; failure("reconcile", file.name, error) }
		}
		storage.write("index.json", TransitJson.encodeToString(CacheIndex(entries = entries)).toByteArray())
		reconciled = true
	}
	private fun touch(name: String, now: Double) {
		val entries = index().entries
		entries[name]?.let { saveIndex(entries + (name to it.copy(accessedAt = maxOf(it.accessedAt, now)))) }
	}
	private fun ride(): ActiveRideRecord? = storage.read("ride.json", 64 * 1024)?.let {
		TransitJson.decodeFromString<RideDocument>(it.decodeToString()).also { value -> require(value.version == 1) }.ride
	}
	private fun protected(entry: IndexEntry, active: String?): Boolean {
		if (entry.manual || entry.kind == "trip" && entry.key == active) return true
		if (entry.kind != "trip") return false
		return try { record(entry.file)?.trip?.manual == true } catch (error: Exception) { failure("protected snapshot", entry.key, error); true }
	}
	private fun pruneLocked(now: Double, clear: Boolean = false): CacheEvictionReport {
		val entries = index().entries.toMutableMap()
		val active = ride()?.key
		val expiredTrips = mutableListOf<String>(); val expiredBoards = mutableListOf<String>()
		val evictedTrips = mutableListOf<String>(); val evictedBoards = mutableListOf<String>()
		var total = entries.values.sumOf { it.bytes }
		val candidates = entries.values.filter { !protected(it, active) }.sortedWith(compareBy<IndexEntry> { it.accessedAt }.thenBy { it.file })
		fun remove(entry: IndexEntry, expired: Boolean) {
			storage.delete(entry.file); entries.remove(entry.file); total -= entry.bytes
			if (entry.kind == "trip") (if (expired && !clear) expiredTrips else evictedTrips).add(entry.key)
			else (if (expired && !clear) expiredBoards else evictedBoards).add(entry.key)
		}
		for (entry in candidates) if (clear || now - entry.savedAt > preferences.retentionHours * 3600.0) remove(entry, expired = !clear)
		for (entry in candidates) if (entry.file in entries && total > preferences.storageLimitMiB * 1_048_576L) remove(entry, expired = false)
		saveIndex(entries)
		return CacheEvictionReport(expiredTrips, expiredBoards, evictedTrips, evictedBoards)
	}
	private fun failure(operation: String, key: String, error: Exception) {
		_failures.value = (_failures.value + CacheFailure(operation, key, error.message ?: "Saved data could not be read or written.", clock())).takeLast(32)
	}
	private fun fileName(kind: String, key: String) = "$kind-${hash(key)}.json"
	companion object {
		internal fun endpointKey(base: String): String {
			val url = base.trim().toHttpUrlOrNull()
			val normalized = url?.toString()?.let { if (it.endsWith('/')) it else "$it/" } ?: base.trim().trimEnd('/') + "/"
			return if (normalized in setOf("https://juliet.nyc/subwaysForNerds/api/v1/", "https://subwaysfornerds.juliet.nyc/api/v1/")) "production" else normalized
		}
		private fun hash(text: String): String = MessageDigest.getInstance("SHA-256").digest(text.toByteArray()).joinToString("") { "%02x".format(it.toInt() and 255) }
	}
}
