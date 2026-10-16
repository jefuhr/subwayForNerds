@file:OptIn(kotlinx.serialization.ExperimentalSerializationApi::class)

package nyc.juliet.subwaysfornerds.core

import kotlinx.serialization.EncodeDefault
import kotlinx.serialization.EncodeDefault.Mode.NEVER
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

// Mirrors shared/track-map.ts. Coordinates are PDF points with the origin at the top left of the crop box.

@Serializable data class TrackMapPoint(val x: Double, val y: Double) {
	val isFinite: Boolean get() = x.isFinite() && y.isFinite()
}
@Serializable data class TrackMapPage(val width: Double, val height: Double) {
	fun contains(point: TrackMapPoint): Boolean = point.isFinite && point.x in 0.0..width && point.y in 0.0..height
}
@Serializable data class TrackMapStation(val id: String, val stationId: String, val partId: String, val name: String, val point: TrackMapPoint, val stopIds: List<String>)
@Serializable data class TrackMapNode(val id: String, val point: TrackMapPoint)
@Serializable data class TrackMapEdge(val id: String, val from: String, val to: String, val points: List<TrackMapPoint>, val bidirectional: Boolean, val revenue: Boolean)
@Serializable data class TrackMapPlatform(val id: String, val stopId: String, val trackCodes: List<String>, val nodeId: String)
@Serializable data class TrackMapTopologyCoverage(val mappedStopIds: List<String>, val unresolvedStopIds: List<String>, val notes: List<String>)

@Serializable data class TrackMapTopology(
	val schemaVersion: Int,
	val mapVersion: String,
	val pdfSha256: String,
	val page: TrackMapPage,
	val attribution: String,
	val sourceURL: String,
	val stations: List<TrackMapStation>,
	val nodes: List<TrackMapNode>,
	val edges: List<TrackMapEdge>,
	val platforms: List<TrackMapPlatform>,
	val coverage: TrackMapTopologyCoverage,
)

/** Progress is arc length along `points`, from 0 to 1, clamped to this window. Times are Unix seconds. */
@Serializable data class TrackMapMotion(
	val edgeIds: List<String>,
	val points: List<TrackMapPoint>,
	val fromProgress: Double,
	val toProgress: Double,
	val startTime: Double,
	val endTime: Double,
)

@Serializable enum class TrackMapTrackBasis { @SerialName("reported") REPORTED, @SerialName("scheduled") SCHEDULED, @SerialName("inferred") INFERRED, @SerialName("unknown") UNKNOWN }
@Serializable enum class TrackMapPositionBasis { @SerialName("reported") REPORTED, @SerialName("estimated") ESTIMATED, @SerialName("unknown") UNKNOWN }
@Serializable enum class TrackMapPlacement { @SerialName("track") TRACK, @SerialName("near-stop") NEAR_STOP, @SerialName("unplaced") UNPLACED }
@Serializable enum class TrackMapFreshness { @SerialName("live") LIVE, @SerialName("stale") STALE, @SerialName("unavailable") UNAVAILABLE }

@Serializable data class TrackMapTrain(
	val key: String,
	val feed: String,
	val route: String,
	val destination: String,
	val direction: String,
	@EncodeDefault(NEVER) val stopId: String? = null,
	@EncodeDefault(NEVER) val stationId: String? = null,
	@EncodeDefault(NEVER) val status: String? = null,
	@EncodeDefault(NEVER) val trackCode: String? = null,
	val trackBasis: TrackMapTrackBasis,
	val positionBasis: TrackMapPositionBasis,
	val placement: TrackMapPlacement,
	@EncodeDefault(NEVER) val point: TrackMapPoint? = null,
	@EncodeDefault(NEVER) val motion: TrackMapMotion? = null,
	/** Original evidence age, never the time a cached response was read. */
	val observedAt: Double?,
	val feedTimestamp: Double,
	val staleAt: Double?,
	val expiresAt: Double?,
	val freshness: TrackMapFreshness,
	@EncodeDefault(NEVER) val reason: String? = null,
)

@Serializable data class TrackMapSnapshotCoverage(val placed: Int, val uncertain: Int, val unplaced: Int)

@Serializable data class TrackMapSnapshot(
	val schemaVersion: Int,
	val mapVersion: String,
	val pdfSha256: String,
	val generatedAt: Double,
	val sources: List<SourceState>,
	val trains: List<TrackMapTrain>,
	val coverage: TrackMapSnapshotCoverage,
)
