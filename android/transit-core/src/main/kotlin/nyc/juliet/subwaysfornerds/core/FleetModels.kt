@file:OptIn(kotlinx.serialization.ExperimentalSerializationApi::class)

package nyc.juliet.subwaysfornerds.core

import kotlinx.serialization.EncodeDefault
import kotlinx.serialization.EncodeDefault.Mode.NEVER
import kotlinx.serialization.Serializable

@Serializable data class Evidence(val url: String, val date: String, val note: String)
@Serializable data class YardEvidence(val url: String, val date: String, val note: String, val name: String)
@Serializable data class FleetNextStop(val name: String, val time: Double? = null, @EncodeDefault(NEVER) val stationId: String? = null)
@Serializable data class FleetObservation(
	val timestamp: Double, val location: String, val route: String, val tripKey: String, val consistId: String,
	val cars: List<String> = emptyList(), @EncodeDefault(NEVER) val locationTimestamp: Double? = null,
	@EncodeDefault(NEVER) val next: FleetNextStop? = null,
)
@Serializable data class FleetCar(
	val id: String, val number: String, val equipment: String, val category: String, val aliases: List<String> = emptyList(),
	val lifecycle: String, val evidence: List<Evidence> = emptyList(),
	@EncodeDefault(NEVER) val conflicts: List<String>? = null,
	@EncodeDefault(NEVER) val fixedSet: String? = null,
	@EncodeDefault(NEVER) val facts: Map<String, String>? = null,
	@EncodeDefault(NEVER) val yard: YardEvidence? = null,
	@EncodeDefault(NEVER) val last: FleetObservation? = null,
	@EncodeDefault(NEVER) val reporting: Boolean? = null,
	@EncodeDefault(NEVER) val estimatedYard: YardEvidence? = null,
)
@Serializable data class FleetRow(val id: String, val kind: String, val cars: List<FleetCar> = emptyList(), val reporting: Boolean)
@Serializable data class FleetCoverage(val category: String, val count: Int, val note: String)
@Serializable data class FleetFacets(val equipment: List<String> = emptyList(), val route: List<String> = emptyList(), val yard: List<String> = emptyList())
@Serializable data class FleetPage(
	val rows: List<FleetRow> = emptyList(), val total: Int, val page: Int, val pages: Int, val generatedAt: Double,
	val coverage: List<FleetCoverage> = emptyList(), val facets: FleetFacets = FleetFacets(), val sources: List<Evidence> = emptyList(),
	@EncodeDefault(NEVER) val error: String? = null,
)
@Serializable data class FleetDetail(val cars: List<FleetCar> = emptyList(), val history: List<FleetObservation> = emptyList(), val generatedAt: Double)
@Serializable data class FleetSnapshotObservation(
	val timestamp: Double, val location: String, val route: String, val tripKey: String,
	@EncodeDefault(NEVER) val locationTimestamp: Double? = null,
	@EncodeDefault(NEVER) val next: FleetNextStop? = null,
)
@Serializable data class FleetSnapshot(val cars: List<ConsistCar>, val namespace: String, val observation: FleetSnapshotObservation)
@Serializable data class FleetOfflineCounts(val cars: Int, val consists: Int, val events: Int, val assertions: Int)
@Serializable data class FleetOfflineManifest(
	val schemaVersion: Int = 1, val id: String, val generatedAt: Double, val historyStart: Double, val historyEnd: Double,
	val counts: FleetOfflineCounts, val byteLength: Long, val sha256: String, val downloadURL: String,
	@EncodeDefault(NEVER) val observedAt: Double? = null,
	@EncodeDefault(NEVER) val compression: String? = null,
	@EncodeDefault(NEVER) val compressedByteLength: Long? = null,
	@EncodeDefault(NEVER) val compressedSha256: String? = null,
	@EncodeDefault(NEVER) val pack: FleetPackManifest? = null,
) {
	val downloadByteLength: Long get() = pack?.archiveByteLength ?: if (compression == "gzip") compressedByteLength ?: byteLength else byteLength
}

@Serializable data class FleetPackSelection(val equipment: List<String> = emptyList(), val yards: List<String> = emptyList(), val historyDays: Int = 7) {
	val isValid: Boolean get() = historyDays in listOf(7, 30) && listOf(equipment, yards).all { values ->
		values.size <= 256 && values.distinct().size == values.size && values.all { it.isNotEmpty() && it.toByteArray().size <= 256 && !it.contains('\u0000') }
	}
	val scopeDescription: String get() = "${equipment.ifEmpty { listOf("All car types") }.joinToString(", ")} · ${yards.ifEmpty { listOf("All estimated home yards") }.joinToString(", ") { if (it == "unknown") "Unknown home yard" else it }} · $historyDays days of history"
}
@Serializable data class FleetPackCounts(val cars: Int, val consists: Int, val events: Int, val assertions: Int, val eventCars: Int, val matchedCars: Int, val linkedCars: Int)
@Serializable data class FleetPackManifest(
	val schemaVersion: Int = 2, val format: String = "fleet-jsonl-v2", val compression: String = "gzip", val id: String,
	val generatedAt: Double, val historyStart: Double, val historyEnd: Double, val selection: FleetPackSelection,
	val counts: FleetPackCounts, val archiveByteLength: Long, val archiveSha256: String, val uncompressedByteLength: Long,
	val estimatedSavedByteLength: Long, val downloadURL: String,
	@EncodeDefault(NEVER) val observedAt: Double? = null,
) {
	val isValid: Boolean get() = schemaVersion == 2 && format == "fleet-jsonl-v2" && compression == "gzip" && selection.isValid &&
		id == archiveSha256 && archiveSha256.matches(Regex("[0-9a-fA-F]{64}")) &&
		listOf(archiveByteLength, uncompressedByteLength, estimatedSavedByteLength).all { it > 0 && it < Long.MAX_VALUE / 8 } &&
		listOf(generatedAt, historyStart, historyEnd).all { it.isFinite() && it >= 0 } && historyStart <= historyEnd && historyEnd >= generatedAt &&
		(observedAt == null || observedAt.isFinite()) && listOf(counts.cars, counts.consists, counts.events, counts.assertions, counts.eventCars, counts.matchedCars, counts.linkedCars).all { it >= 0 && it < Int.MAX_VALUE / 8 } &&
		counts.matchedCars.toLong() + counts.linkedCars == counts.cars.toLong()
}
@Serializable data class FleetPackProgress(val stage: String, val label: String, val step: Int, val steps: Int, val done: Long, val total: Long, val fraction: Double)
typealias FleetPackBuildProgress = FleetPackProgress
@Serializable data class FleetPackJob(
	val jobId: String, val state: String, @EncodeDefault(NEVER) val manifest: FleetPackManifest? = null,
	@EncodeDefault(NEVER) val progress: FleetPackProgress? = null,
)
