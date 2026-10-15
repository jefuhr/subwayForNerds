package nyc.juliet.subwaysfornerds.fleet

import androidx.sqlite.SQLiteStatement
import java.io.ByteArrayOutputStream
import java.io.File
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import nyc.juliet.subwaysfornerds.core.*

/** Swift's v1 query schema; the v2 transport is bounded JSONL, not SQLite bytes. */
internal class FleetPackImporter(file: File, private val pack: FleetPackManifest, private val check: () -> Unit, private val checkSpace: () -> Unit) : AutoCloseable {
	private val db = FleetSqlite(file, readOnly = false, check)
	private val statements = mutableMapOf<String, SQLiteStatement>()
	private val pending = ByteArrayOutputStream()
	private var header = false; private var end = false; private var committed = false
	private var metas = 0; private var cars = 0; private var consists = 0; private var assertions = 0; private var events = 0; private var eventCars = 0
	init {
		try {
			db.execute("PRAGMA journal_mode=DELETE")
			listOf("PRAGMA foreign_keys=ON", "PRAGMA user_version=1", "PRAGMA cache_size=-4096",
				"CREATE TABLE meta(key TEXT PRIMARY KEY NOT NULL,data TEXT NOT NULL)",
				"CREATE TABLE cars(id TEXT PRIMARY KEY NOT NULL,data TEXT NOT NULL)",
				"CREATE TABLE assertions(id TEXT PRIMARY KEY NOT NULL,car_id TEXT NOT NULL REFERENCES cars(id) DEFERRABLE INITIALLY DEFERRED,data TEXT NOT NULL)",
				"CREATE TABLE consists(id TEXT PRIMARY KEY NOT NULL,data TEXT NOT NULL)",
				"CREATE TABLE events(id TEXT PRIMARY KEY NOT NULL,timestamp INTEGER NOT NULL,data TEXT NOT NULL)",
				"CREATE TABLE event_cars(event_id TEXT NOT NULL REFERENCES events(id) DEFERRABLE INITIALLY DEFERRED,car_id TEXT NOT NULL REFERENCES cars(id) DEFERRABLE INITIALLY DEFERRED,PRIMARY KEY(event_id,car_id))", "BEGIN").forEach { db.execute(it) }
		} catch (error: Exception) { db.close(); throw error }
	}
	fun consume(block: ByteArray) {
		check(); checkSpace()
		var start = 0
		for (index in block.indices) if (block[index] == 10.toByte()) {
			append(block, start, index - start); record(pending.toByteArray()); pending.reset(); start = index + 1
		}
		append(block, start, block.size - start)
	}
	private fun append(block: ByteArray, offset: Int, length: Int) {
		if (length > MAX_LINE_BYTES - pending.size()) invalid()
		pending.write(block, offset, length)
	}
	fun finish() {
		check(); checkSpace()
		if (pending.size() > 0) { record(pending.toByteArray()); pending.reset() }
		if (!header || !end) invalid()
		val metadata = buildJsonObject {
			put("schemaVersion", 2); put("generatedAt", pack.generatedAt); put("historyStart", pack.historyStart); put("historyEnd", pack.historyEnd)
			put("selection", TransitJson.encodeToJsonElement(pack.selection))
		}
		insert("INSERT INTO meta(key,data) VALUES('snapshot',?) ON CONFLICT(key) DO UPDATE SET data=excluded.data", listOf(metadata.toString()))
		for (sql in listOf(
			"CREATE INDEX car_category ON cars(json_extract(data,'$.category'))", "CREATE INDEX car_equipment ON cars(json_extract(data,'$.equipment'))",
			"CREATE INDEX car_fixed_set ON cars(json_extract(data,'$.fixedSet'))", "CREATE INDEX assertion_car_lookup ON assertions(car_id)",
			"CREATE INDEX event_car_lookup ON event_cars(car_id,event_id)", "CREATE INDEX event_time ON events(timestamp DESC,id DESC)",
			"CREATE INDEX event_consist_time ON events(json_extract(data,'$.consistId'),timestamp DESC,id DESC)")) { check(); checkSpace(); db.execute(sql) }
		check(); db.execute("COMMIT"); committed = true; check()
	}
	private fun record(bytes: ByteArray) {
		check()
		if (end || bytes.isEmpty()) invalid()
		val values = try { TransitJson.parseToJsonElement(bytes.decodeToString(throwOnInvalidSequence = true)) as? JsonArray ?: invalid() } catch (error: Exception) { throw FleetValidationException("The fleet pack contains an invalid JSON record.", error) }
		val kind = string(values.firstOrNull())
		if (!header) {
			if (kind != "header" || values.size != 6 || number(values[1]) != 2.0 || number(values[2]) != pack.generatedAt || number(values[3]) != pack.historyStart || number(values[4]) != pack.historyEnd || TransitJson.decodeFromJsonElement<FleetPackSelection>(values[5]) != pack.selection) invalid()
			header = true; return
		}
		when (kind) {
			"meta" -> {
				if (values.size != 3 || metas >= 256) invalid()
				val id = identifier(values[1]); val raw = raw(values[2])
				if (id == "snapshot") {
					val snapshot = TransitJson.parseToJsonElement(raw).jsonObject
					if (number(snapshot["schemaVersion"]) != 2.0 || number(snapshot["generatedAt"]) != pack.generatedAt || number(snapshot["historyStart"]) != pack.historyStart || number(snapshot["historyEnd"]) != pack.historyEnd) invalid()
				}
				insert("INSERT INTO meta VALUES(?,?)", listOf(id, raw)); metas++
			}
			"car" -> {
				if (values.size != 3 || cars >= pack.counts.cars) invalid()
				val id = identifier(values[1]); val raw = raw(values[2]); val car = TransitJson.decodeFromString<FleetCar>(raw)
				if (car.id != id) invalid()
				insert("INSERT INTO cars VALUES(?,?)", listOf(id, raw)); cars++
			}
			"assertion" -> {
				if (values.size != 4 || assertions >= pack.counts.assertions) invalid()
				insert("INSERT INTO assertions VALUES(?,?,?)", listOf(identifier(values[1]), identifier(values[2]), raw(values[3]))); assertions++
			}
			"consist" -> {
				if (values.size != 3 || consists >= pack.counts.consists) invalid()
				val raw = raw(values[2]); val members = TransitJson.decodeFromString<List<String>>(raw)
				if (members.isEmpty() || members.distinct().size != members.size) invalid()
				members.forEach { identifier(JsonPrimitive(it)) }
				insert("INSERT INTO consists VALUES(?,?)", listOf(identifier(values[1]), raw)); consists++
			}
			"event" -> {
				if (values.size != 5 || events >= pack.counts.events) invalid()
				val time = number(values[2]); val members = (values[4] as? JsonArray)?.map(::identifier) ?: invalid()
				if (time < pack.historyStart || time > pack.historyEnd || members.isEmpty() || members.distinct().size != members.size || members.size > pack.counts.eventCars - eventCars) invalid()
				val id = identifier(values[1]); val raw = raw(values[3]); val observation = TransitJson.decodeFromString<FleetObservation>(raw)
				if (observation.timestamp != time) invalid()
				// Older event JSON can omit cars. The transport's selected members are
				// authoritative for event_cars; keep the historical JSON unchanged.
				insert("INSERT INTO events VALUES(?,?,?)", listOf(id, time.toString(), raw)); events++
				for (member in members) { insert("INSERT INTO event_cars VALUES(?,?)", listOf(id, member)); eventCars++ }
			}
			"end" -> {
				if (values.size != 2 || TransitJson.decodeFromJsonElement<FleetPackCounts>(values[1]) != pack.counts || cars != pack.counts.cars || consists != pack.counts.consists || assertions != pack.counts.assertions || events != pack.counts.events || eventCars != pack.counts.eventCars) invalid()
				end = true
			}
			else -> invalid()
		}
	}
	private fun string(value: JsonElement?): String = (value as? JsonPrimitive)?.takeIf { it.isString }?.content ?: invalid()
	private fun identifier(value: JsonElement?): String = string(value).also { if (it.isEmpty() || it.toByteArray().size > 1024 || it.contains('\u0000')) invalid() }
	private fun raw(value: JsonElement): String = string(value).also { if (it.contains('\u0000')) invalid(); TransitJson.parseToJsonElement(it) }
	private fun number(value: JsonElement?): Double = (value as? JsonPrimitive)?.takeIf { !it.isString }?.doubleOrNull?.takeIf { it.isFinite() } ?: invalid()
	private fun insert(sql: String, values: List<String>) {
		check()
		val statement = statements.getOrPut(sql) { db.prepare(sql) }
		try { statement.clearBindings(); values.forEachIndexed { index, value -> statement.bindText(index + 1, value) }; if (statement.step()) invalid() }
		finally { statement.reset(); statement.clearBindings() }
	}
	private fun invalid(): Nothing = throw FleetValidationException("The fleet pack contains invalid or missing records. Your previous download is still available.")
	override fun close() {
		statements.values.forEach { it.close() }
		if (!committed) try { db.execute("ROLLBACK") } catch (_: Exception) { }
		db.close()
	}
	companion object { const val MAX_LINE_BYTES = 1_048_576 }
}
