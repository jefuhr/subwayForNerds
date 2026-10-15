package nyc.juliet.subwaysfornerds.widgets.runtime

import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import nyc.juliet.subwaysfornerds.core.*
import nyc.juliet.subwaysfornerds.data.AtomicStorage
import nyc.juliet.subwaysfornerds.data.OfflinePlanner
import nyc.juliet.subwaysfornerds.data.ActiveRideRecord
import nyc.juliet.subwaysfornerds.data.CachedTrip

@Serializable internal data class SavedWidgetMember(val station: Station, val board: Board?, val cached: Boolean, val savedAt: Double? = null, val error: String? = null) {
	fun member() = MemberBoardSnapshot(station, board, cached, savedAt, error)
}
@Serializable internal data class WidgetContent(
	val version: Int = 1, val endpoint: String, val stationID: String?, val board: Board? = null,
	val members: List<SavedWidgetMember> = emptyList(), val definition: CombinedStation? = null,
	val rideKey: String? = null, val rideStartedAt: Double? = null, val rideID: String? = null, val cached: Boolean = true,
	val notice: String? = null, val message: String? = null, val refreshedAt: Double,
)

internal data class WidgetPublicationState(val endpoint: String, val stationID: String?, val definition: CombinedStation?, val activeRide: ActiveRideRecord?)

/** The same eligibility drives reading, refresh and the final activation guard. */
internal fun supportedWidgetRide(settings: Settings, active: ActiveRideRecord?, trip: CachedTrip?): ActiveRideRecord? =
	active?.takeIf { settings.offline.widgetsFollowActiveRide && !it.key.startsWith("path|") && trip?.key == it.key && trip.train?.key == it.key }

internal fun acceptsWidgetContent(value: WidgetContent, latest: WidgetPublicationState): Boolean {
	if (value.endpoint != latest.endpoint) return false
	if (value.rideKey != null) return latest.activeRide?.let { it.key == value.rideKey && it.id == value.rideID } == true
	return latest.activeRide == null && value.stationID == latest.stationID && value.definition == latest.definition
}

/** Only final local activation is serialized; no network work runs while this lock is held. */
internal class WidgetContentStore(directory: File) {
	private val storage = AtomicStorage(directory)
	fun read(): WidgetContent? = storage.locked { readLocked() }
	fun activate(next: WidgetContent, guard: (WidgetContent?) -> Boolean = { true }): Boolean = storage.locked {
		val current = readLocked()
		if (!guard(current)) return@locked false
		// Re-read and source-merge inside the same activation lock. A slow response
		// may finish after the foreground has already published a newer report.
		val merged = merge(next, current)
		storage.write("content.json", TransitJson.encodeToString(merged).toByteArray())
		true
	}
	private fun merge(next: WidgetContent, current: WidgetContent?): WidgetContent {
		if (current == null || next.endpoint != current.endpoint || next.stationID != current.stationID || next.definition != current.definition || next.rideID != current.rideID) return next
		fun mergeBoard(incoming: Board?, stored: Board?): Board? = if (incoming == null) stored else OfflinePlanner.mergeBoard(incoming, stored).board
		val members = next.members.map { incoming ->
			val stored = current.members.firstOrNull { it.station.id == incoming.station.id }
			incoming.copy(board = mergeBoard(incoming.board, stored?.board), savedAt = listOfNotNull(incoming.savedAt, stored?.savedAt).maxOrNull())
		}
		return next.copy(board = mergeBoard(next.board, current.board), members = members, refreshedAt = maxOf(next.refreshedAt, current.refreshedAt))
	}
	private fun readLocked(): WidgetContent? = storage.read("content.json")?.let {
		TransitJson.decodeFromString<WidgetContent>(it.decodeToString()).also { value -> require(value.version == 1) }
	}
}
