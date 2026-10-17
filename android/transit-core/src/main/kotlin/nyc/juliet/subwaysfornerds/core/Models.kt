@file:OptIn(kotlinx.serialization.ExperimentalSerializationApi::class)

package nyc.juliet.subwaysfornerds.core

import kotlinx.serialization.EncodeDefault
import kotlinx.serialization.EncodeDefault.Mode.NEVER
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement

/** Required nullable values encode as null; optional defaults stay absent, including false/zero distinctions. */
val TransitJson = Json { ignoreUnknownKeys = true; encodeDefaults = true; explicitNulls = true }

@Serializable data class StationPart(
	val id: String, val stationId: String, val name: String, val line: String,
	val routes: List<String> = emptyList(), val lat: Double, val lon: Double,
	val ada: String, val adaNotes: String = "", val north: String, val south: String,
)

@Serializable data class Station(
	val id: String, val name: String, val borough: String, val routes: List<String> = emptyList(),
	val lat: Double, val lon: Double, val parts: List<StationPart> = emptyList(),
	@EncodeDefault(NEVER) val municipality: String? = null,
	@EncodeDefault(NEVER) val departureMode: String? = null,
) {
	val isCombined: Boolean get() = id.startsWith("combined:")
	val isNjt: Boolean get() = !isCombined && (id.startsWith("njt-") || routes.any { it.startsWith("NJT-") })
}

@Serializable data class SourceState(
	val id: String, val timestamp: Double? = null, val fetchedAt: Double? = null, val error: String? = null,
	@EncodeDefault(NEVER) val staleAfter: Double? = null,
)

@Serializable data class VehiclePosition(
	val id: String, val provider: String, val vehicleId: String, val route: String,
	@EncodeDefault(NEVER) val tripId: String? = null,
	@EncodeDefault(NEVER) val serviceDate: String? = null,
	@EncodeDefault(NEVER) val startTime: String? = null,
	val lat: Double, val lon: Double,
	@EncodeDefault(NEVER) val stopId: String? = null,
	@EncodeDefault(NEVER) val stopName: String? = null,
	@EncodeDefault(NEVER) val status: String? = null,
	val timestamp: Double, val fetchedAt: Double,
)

@Serializable data class NjtState(
	val configured: Boolean, val predictions: SourceState, val positions: SourceState, val cacheError: String? = null,
)

@Serializable data class ChangeEvidence(
	val source: String, val timestamp: Double, val staleAfter: Double,
	@EncodeDefault(NEVER) val unavailable: Boolean? = null,
)

@Serializable data class TripChange(
	val id: String, val kind: String, val classification: String, val label: String,
	@EncodeDefault(NEVER) val description: String? = null,
	@EncodeDefault(NEVER) val location: String? = null,
	val stopIndices: List<Int> = emptyList(), val affectedStops: List<String> = emptyList(),
	@EncodeDefault(NEVER) val before: String? = null,
	@EncodeDefault(NEVER) val after: String? = null,
	val evidence: List<ChangeEvidence> = emptyList(), val alertIds: List<String> = emptyList(),
	@EncodeDefault(NEVER) val advisory: Boolean? = null,
)

@Serializable data class StopPrediction(
	val id: String, val name: String,
	@EncodeDefault(NEVER) val stationId: String? = null,
	val arrival: Double? = null, val departure: Double? = null,
	@EncodeDefault(NEVER) val scheduledTrack: String? = null,
	@EncodeDefault(NEVER) val actualTrack: String? = null,
	@EncodeDefault(NEVER) val relationship: String? = null,
	@EncodeDefault(NEVER) val changes: List<TripChange>? = null,
	@EncodeDefault(NEVER) val sequence: Int? = null,
)

@Serializable data class ConsistCar(val number: String, @EncodeDefault(NEVER) val type: String? = null)
@Serializable data class Consist(val cars: List<ConsistCar>, val updatedAt: Double, val fetchedAt: Double, val source: String = "helium")
@Serializable data class TrainPosition(
	val name: String,
	@EncodeDefault(NEVER) val stopId: String? = null,
	@EncodeDefault(NEVER) val status: String? = null,
	@EncodeDefault(NEVER) val timestamp: Double? = null,
)
@Serializable data class ScheduledPattern(val shape: String, val headsign: String, val stops: List<String>, val source: String)

/**
 * An estimated slow segment between two consecutive GTFS stops, from Transit Lab's weekday run times.
 * It is not an official MTA speed restriction. `kind` stays a string so future kinds still decode;
 * only "disruption" reads differently. `since` and `through` are calendar dates (YYYY-MM-DD).
 */
interface SlowZoneEstimate {
	val from: String
	val to: String
	val segment: String
	val kind: String
	val since: String
	val through: String
	val extraSeconds: Double
	val baselineSeconds: Double
	val slowDays: Int
}

/** The zone a board row's train is in right now. */
@Serializable data class SlowZone(
	override val from: String, override val to: String, override val segment: String, override val kind: String,
	override val since: String, override val through: String,
	override val extraSeconds: Double, override val baselineSeconds: Double, override val slowDays: Int,
) : SlowZoneEstimate

/** A zone ahead of a train. `toIndex` is the segment's end stop in this snapshot's `Train.stops`; the current zone comes first. */
@Serializable data class TrainSlowZone(
	override val from: String, override val to: String, override val segment: String, override val kind: String,
	override val since: String, override val through: String,
	override val extraSeconds: Double, override val baselineSeconds: Double, override val slowDays: Int,
	val toIndex: Int,
	@EncodeDefault(NEVER) val current: Boolean? = null,
) : SlowZoneEstimate {
	val zone: SlowZone get() = SlowZone(from, to, segment, kind, since, through, extraSeconds, baselineSeconds, slowDays)
}

@Serializable data class Train(
	val key: String, val feed: String, val tripId: String, val route: String, val destination: String,
	val direction: String, val timestamp: Double, val stops: List<StopPrediction> = emptyList(), val alerts: List<String> = emptyList(),
	@EncodeDefault(NEVER) val staleAfter: Double? = null,
	@EncodeDefault(NEVER) val vehiclePosition: VehiclePosition? = null,
	@EncodeDefault(NEVER) val changes: List<TripChange>? = null,
	@EncodeDefault(NEVER) val startTime: String? = null,
	@EncodeDefault(NEVER) val serviceDate: String? = null,
	@EncodeDefault(NEVER) val trainId: String? = null,
	@EncodeDefault(NEVER) val assigned: Boolean? = null,
	@EncodeDefault(NEVER) val position: TrainPosition? = null,
	@EncodeDefault(NEVER) val relationship: String? = null,
	@EncodeDefault(NEVER) val consist: Consist? = null,
	@EncodeDefault(NEVER) val scheduledPattern: ScheduledPattern? = null,
	@EncodeDefault(NEVER) val slowZones: List<TrainSlowZone>? = null,
)

@Serializable data class OnwardStop(val stationId: String, val stopId: String, val name: String, val time: Double? = null)

@Serializable(with = DepartureSerializer::class) data class Departure(
	val key: String, val tripKey: String, val route: String, val destination: String, val direction: String,
	val stopId: String, val partId: String, val area: String, val time: Double? = null, val arrival: Double? = null,
	val pattern: String, val patternSource: String, val location: String, val stopsAway: Int? = null,
	val feed: String, val timestamp: Double, val alerts: List<String> = emptyList(), val onward: List<OnwardStop> = emptyList(),
	@EncodeDefault(NEVER) val staleAfter: Double? = null,
	@EncodeDefault(NEVER) val vehiclePosition: VehiclePosition? = null,
	@EncodeDefault(NEVER) val changes: List<TripChange>? = null,
	@EncodeDefault(NEVER) val departure: Double? = null,
	@EncodeDefault(NEVER) val scheduledTrack: String? = null,
	@EncodeDefault(NEVER) val actualTrack: String? = null,
	@EncodeDefault(NEVER) val locationTimestamp: Double? = null,
	@EncodeDefault(NEVER) val assigned: Boolean? = null,
	@EncodeDefault(NEVER) val relationship: String? = null,
	@EncodeDefault(NEVER) val consist: Consist? = null,
	@EncodeDefault(NEVER) val gap: Double? = null,
	@EncodeDefault(NEVER) val basis: String? = null,
	@EncodeDefault(NEVER) val slowZone: SlowZone? = null,
	@kotlinx.serialization.Transient internal val explicitNullDeparture: Boolean = false,
)


@Serializable data class AlertSelector(
	@EncodeDefault(NEVER) val route: String? = null,
	@EncodeDefault(NEVER) val stop: String? = null,
	@EncodeDefault(NEVER) val trip: String? = null,
	@EncodeDefault(NEVER) val direction: Int? = null,
	@EncodeDefault(NEVER) val serviceDate: String? = null,
	@EncodeDefault(NEVER) val startTime: String? = null,
	@EncodeDefault(NEVER) val priority: Int? = null,
)
@Serializable data class AlertPeriod(@EncodeDefault(NEVER) val start: Double? = null, @EncodeDefault(NEVER) val end: Double? = null)

@Serializable data class ServiceAlert(
	val id: String, val title: String, val description: String, val routes: List<String> = emptyList(),
	val stops: List<String> = emptyList(), val selectors: List<AlertSelector> = emptyList(), val periods: List<AlertPeriod> = emptyList(),
	@EncodeDefault(NEVER) val alertType: String? = null,
	@EncodeDefault(NEVER) val activePeriodLabel: String? = null,
	@EncodeDefault(NEVER) val planNumbers: List<String>? = null,
	@EncodeDefault(NEVER) val affectedSelectors: List<AlertSelector>? = null,
	@EncodeDefault(NEVER) val effect: String? = null,
	@EncodeDefault(NEVER) val updatedAt: Double? = null,
	@EncodeDefault(NEVER) val raw: JsonElement? = null,
)

@Serializable data class Board(
	val station: Station, val generatedAt: Double, val sources: List<SourceState> = emptyList(),
	val departures: List<Departure> = emptyList(), val alerts: List<ServiceAlert> = emptyList(),
	@EncodeDefault(NEVER) val njt: NjtState? = null,
	@EncodeDefault(NEVER) val vehiclePositions: List<VehiclePosition>? = null,
) {
	val usesExternalDepartures: Boolean get() = !station.isCombined && (station.departureMode == "external" || station.isNjt) && njt?.configured != true
}

@Serializable data class TripSource(val state: SourceState, @EncodeDefault(NEVER) val header: JsonElement? = null)
@Serializable data class TripDetail(val train: Train, @EncodeDefault(NEVER) val raw: JsonElement? = null, @EncodeDefault(NEVER) val source: TripSource? = null)

@Serializable data class TransferResult(
	val arrival: Double? = null, val basis: String, val connections: List<Departure> = emptyList(), val sources: List<SourceState> = emptyList(),
	@EncodeDefault(NEVER) val originTimestamp: Double? = null,
	@EncodeDefault(NEVER) val originStaleAfter: Double? = null,
	@EncodeDefault(NEVER) val station: Station? = null,
	@EncodeDefault(NEVER) val message: String? = null,
)

@Serializable data class StationContext(
	val entrances: List<Map<String, String>> = emptyList(), val equipment: List<Map<String, String>> = emptyList(),
	val outages: List<Map<String, String>> = emptyList(), val sources: List<SourceState> = emptyList(),
)
