@file:OptIn(kotlinx.serialization.ExperimentalSerializationApi::class)

package nyc.juliet.subwaysfornerds.core

import kotlinx.serialization.*
import kotlinx.serialization.EncodeDefault.Mode.NEVER
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.*

/** `departure` is optional AND nullable in shared/types.ts. Keep explicit null distinct from an absent prediction. */
object DepartureSerializer : KSerializer<Departure> {
	private val delegate = DepartureWire.serializer()
	override val descriptor: SerialDescriptor get() = delegate.descriptor
	override fun deserialize(decoder: Decoder): Departure {
		val raw = (decoder as? JsonDecoder)?.decodeJsonElement()
		val value = if (raw != null) (decoder as JsonDecoder).json.decodeFromJsonElement(delegate, raw) else delegate.deserialize(decoder)
		return Departure(
		key = value.key,
		tripKey = value.tripKey,
		route = value.route,
		destination = value.destination,
		direction = value.direction,
		stopId = value.stopId,
		partId = value.partId,
		area = value.area,
		time = value.time,
		arrival = value.arrival,
		pattern = value.pattern,
		patternSource = value.patternSource,
		location = value.location,
		stopsAway = value.stopsAway,
		feed = value.feed,
		timestamp = value.timestamp,
		alerts = value.alerts,
		onward = value.onward,
		staleAfter = value.staleAfter,
		vehiclePosition = value.vehiclePosition,
		changes = value.changes,
		departure = value.departure,
		scheduledTrack = value.scheduledTrack,
		actualTrack = value.actualTrack,
		locationTimestamp = value.locationTimestamp,
		assigned = value.assigned,
		relationship = value.relationship,
		consist = value.consist,
		gap = value.gap,
		basis = value.basis,
			explicitNullDeparture = (raw as? JsonObject)?.get("departure") == JsonNull,
		)
	}
	override fun serialize(encoder: Encoder, value: Departure) {
		val wire = DepartureWire(
		key = value.key,
		tripKey = value.tripKey,
		route = value.route,
		destination = value.destination,
		direction = value.direction,
		stopId = value.stopId,
		partId = value.partId,
		area = value.area,
		time = value.time,
		arrival = value.arrival,
		pattern = value.pattern,
		patternSource = value.patternSource,
		location = value.location,
		stopsAway = value.stopsAway,
		feed = value.feed,
		timestamp = value.timestamp,
		alerts = value.alerts,
		onward = value.onward,
		staleAfter = value.staleAfter,
		vehiclePosition = value.vehiclePosition,
		changes = value.changes,
		departure = value.departure,
		scheduledTrack = value.scheduledTrack,
		actualTrack = value.actualTrack,
		locationTimestamp = value.locationTimestamp,
		assigned = value.assigned,
		relationship = value.relationship,
		consist = value.consist,
		gap = value.gap,
		basis = value.basis,
		)
		if (encoder is JsonEncoder) {
			val fields = encoder.json.encodeToJsonElement(delegate, wire).jsonObject
			encoder.encodeJsonElement(if (value.departure == null && value.explicitNullDeparture) JsonObject(fields + ("departure" to JsonNull)) else fields)
		} else delegate.serialize(encoder, wire)
	}
}

@Serializable @SerialName("nyc.juliet.subwaysfornerds.core.Departure") internal data class DepartureWire(
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
)
