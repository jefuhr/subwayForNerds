package nyc.juliet.subwaysfornerds.fleet

import java.io.File
import kotlinx.serialization.json.*
import nyc.juliet.subwaysfornerds.core.*

/** Read-only queries never alter or delete the active saved file on corruption. */
internal class FleetDatabase(file: File, private val check: () -> Unit = {}) : AutoCloseable {
	private val db = FleetSqlite(file, readOnly = true, check)
	fun rows(sql: String, values: List<String> = emptyList()): List<List<String>> = db.rows(sql, values)
	fun count(table: String): Long = rows("SELECT COUNT(*) FROM $table").single().single().toLong()
	private fun schema() {
		if (rows("PRAGMA user_version") != listOf(listOf("1")) || rows("PRAGMA quick_check") != listOf(listOf("ok")) || rows("PRAGMA foreign_key_check").isNotEmpty()) invalid("The downloaded fleet database is incompatible or damaged.")
		val required = mapOf("meta" to listOf("key", "data"), "cars" to listOf("id", "data"), "consists" to listOf("id", "data"),
			"assertions" to listOf("id", "car_id", "data"), "events" to listOf("id", "timestamp", "data"), "event_cars" to listOf("event_id", "car_id"))
		for ((table, columns) in required) {
			if (rows("SELECT type FROM sqlite_master WHERE name=?", listOf(table)) != listOf(listOf("table")) || rows("PRAGMA table_info($table)").map { it[1] } != columns) invalid("The fleet database has an unsupported schema.")
		}
		if (rows("SELECT name FROM sqlite_master WHERE type='trigger'").isNotEmpty()) invalid("The fleet database has an unsupported schema.")
		// Also verify references directly: v1 may not declare every foreign key.
		if (rows("SELECT 1 FROM event_cars ec LEFT JOIN events e ON e.id=ec.event_id LEFT JOIN cars c ON c.id=ec.car_id WHERE e.id IS NULL OR c.id IS NULL LIMIT 1").isNotEmpty() ||
			rows("SELECT 1 FROM assertions a LEFT JOIN cars c ON c.id=a.car_id WHERE c.id IS NULL LIMIT 1").isNotEmpty()) invalid("The fleet database contains missing references.")
	}
	private fun metadata(schema: Int, generatedAt: Double, historyStart: Double, historyEnd: Double): JsonObject {
		val raw = rows("SELECT data FROM meta WHERE key='snapshot'").firstOrNull()?.firstOrNull() ?: invalid("The fleet database has no snapshot information.")
		val value = TransitJson.parseToJsonElement(raw) as? JsonObject ?: invalid("Invalid fleet snapshot information.")
		if (value["schemaVersion"]?.jsonPrimitive?.intOrNull != schema || value["generatedAt"]?.jsonPrimitive?.doubleOrNull != generatedAt ||
			value["historyStart"]?.jsonPrimitive?.doubleOrNull != historyStart || value["historyEnd"]?.jsonPrimitive?.doubleOrNull != historyEnd) invalid("The fleet database does not match its download information.")
		return value
	}
	fun validate(manifest: FleetOfflineManifest) {
		schema()
		for ((table, count) in listOf("cars" to manifest.counts.cars, "consists" to manifest.counts.consists, "events" to manifest.counts.events, "assertions" to manifest.counts.assertions)) {
			if (count(table) != count.toLong()) invalid("The fleet download is missing records.")
		}
		metadata(manifest.schemaVersion, manifest.generatedAt, manifest.historyStart, manifest.historyEnd)
	}
	fun validate(pack: FleetPackManifest) {
		schema()
		for ((table, count) in listOf("cars" to pack.counts.cars, "consists" to pack.counts.consists, "events" to pack.counts.events, "assertions" to pack.counts.assertions, "event_cars" to pack.counts.eventCars)) {
			if (count(table) != count.toLong()) invalid("The fleet pack is missing records.")
		}
		val metadata = metadata(2, pack.generatedAt, pack.historyStart, pack.historyEnd)
		if (metadata["selection"]?.let { TransitJson.decodeFromJsonElement<FleetPackSelection>(it) } != pack.selection) invalid("The fleet pack does not match its selected scope.")
		val conditions = mutableListOf<String>(); val arguments = mutableListOf<String>()
		for ((values, expression) in listOf(pack.selection.equipment to "json_extract(data,'$.equipment')", pack.selection.yards to "COALESCE(NULLIF(json_extract(data,'$.estimatedYard.name'),''),'unknown')")) if (values.isNotEmpty()) {
			conditions += "$expression IN (${values.joinToString(",") { "?" }})"; arguments += values
		}
		val condition = conditions.joinToString(" AND ").ifEmpty { "1=1" }
		if (rows("SELECT COUNT(*) FROM cars WHERE $condition", arguments) != listOf(listOf(pack.counts.matchedCars.toString()))) invalid("The fleet pack does not match its selected car types and yards.")
		if (rows("SELECT 1 FROM events WHERE timestamp < ? OR timestamp > ? LIMIT 1", listOf(pack.historyStart.toString(), pack.historyEnd.toString())).isNotEmpty()) invalid("Fleet history falls outside the saved window.")
		// Historical formations intentionally retain IDs outside a filtered roster.
		// Only selected/indexed assertions and event_cars are foreign-key references.
	}
	override fun close() { db.close() }
	private fun invalid(message: String): Nothing = throw FleetValidationException(message)
}
