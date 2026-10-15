package nyc.juliet.subwaysfornerds.fleet

import androidx.test.platform.app.InstrumentationRegistry
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID
import java.util.zip.GZIPOutputStream
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import nyc.juliet.subwaysfornerds.core.*
import org.junit.Assert.*
import org.junit.Test

class OfflineFleetStoreTest {
	private fun root(): File = File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir, "fleet-test-${UUID.randomUUID()}").apply { mkdirs() }
	private fun asset(name: String): ByteArray = InstrumentationRegistry.getInstrumentation().context.assets.open("server-packs/$name").use { it.readBytes() }
	private data class Fixture(val archive: File, val manifest: FleetPackManifest, val lines: List<JsonArray>)
	private fun fixture(root: File, eventCount: Int = 401, transform: (List<JsonArray>) -> List<JsonArray> = { it }): Fixture {
		val counts = FleetPackCounts(2, 1, eventCount, 1, eventCount * 2, 1, 1)
		val selection = FleetPackSelection(listOf("R1"), listOf("unknown"), 7)
		fun car(id: String, equipment: String) = FleetCar(id, id.last().toString(), equipment, "passenger", lifecycle = "Active", fixedSet = "set:pair", reporting = true)
		val lines = buildList {
			add(JsonArray(listOf(JsonPrimitive("header"), JsonPrimitive(2), JsonPrimitive(10_000), JsonPrimitive(0), JsonPrimitive(10_000), TransitJson.encodeToJsonElement(selection))))
			add(JsonArray(listOf(JsonPrimitive("car"), JsonPrimitive("car:1"), JsonPrimitive(TransitJson.encodeToString(car("car:1", "R1"))))))
			add(JsonArray(listOf(JsonPrimitive("car"), JsonPrimitive("car:2"), JsonPrimitive(TransitJson.encodeToString(car("car:2", "R10"))))))
			add(JsonArray(listOf(JsonPrimitive("assertion"), JsonPrimitive("assertion:1"), JsonPrimitive("car:1"), JsonPrimitive("{}"))))
			add(JsonArray(listOf(JsonPrimitive("consist"), JsonPrimitive("observed:pair"), JsonPrimitive("[\"car:2\",\"car:1\"]"))))
			repeat(eventCount) { index ->
				val observation = FleetObservation(9999.0 - index, "Station", "L", "trip", "observed:pair", listOf("car:2", "car:1", "context:not-selected"))
				add(JsonArray(listOf(JsonPrimitive("event"), JsonPrimitive("event:$index"), JsonPrimitive(observation.timestamp), JsonPrimitive(TransitJson.encodeToString(observation)), JsonArray(listOf(JsonPrimitive("car:1"), JsonPrimitive("car:2"))))))
			}
			add(JsonArray(listOf(JsonPrimitive("end"), TransitJson.encodeToJsonElement(counts))))
		}.let(transform)
		val bytes = lines.joinToString("\n", postfix = "\n").toByteArray()
		val archive = File(root, "${UUID.randomUUID()}.gz")
		archive.outputStream().use { GZIPOutputStream(it).use { gzip -> gzip.write(bytes) } }
		val hash = FleetArchive.digest(archive)
		return Fixture(archive, FleetPackManifest(id = hash, generatedAt = 10_000.0, historyStart = 0.0, historyEnd = 10_000.0, selection = selection, counts = counts,
			archiveByteLength = archive.length(), archiveSha256 = hash, uncompressedByteLength = bytes.size.toLong(), estimatedSavedByteLength = 1_048_576, downloadURL = "/pack.gz"), lines)
	}

	@Test fun selectiveImportReopensGroupsSearchesAndPagesAllRetainedHistory() = runBlocking {
		val root = root()
		try {
			val fixture = fixture(root); val saved = File(root, "saved")
			val store = OfflineFleetStore(saved); store.install(fixture.archive, fixture.manifest)
			val manifest = store.manifest()!!
			assertEquals(fixture.manifest, manifest.pack)
			assertEquals(2, store.fleet(mapOf("equipment" to "R1")).rows.single().cars.size)
			assertTrue(store.fleet().rows.all { !it.reporting && it.cars.all { car -> car.reporting == false } })
			assertEquals(0, store.fleet(mapOf("status" to "reporting")).total)
			val reopened = OfflineFleetStore(saved)
			assertEquals(manifest, reopened.manifest())
			assertEquals(listOf("car:2", "car:1"), reopened.fleetDetail("consist", "observed:pair").cars.map { it.id })
			assertEquals(401, (0..2).sumOf { reopened.fleetDetail("car", "car:1", offset = it * 200).history.size })
			assertEquals(9799.0, reopened.fleetDetail("car", "car:1", offset = 200).history.first().timestamp, 0.0)
		} finally { root.deleteRecursively() }
	}

	@Test fun corruptCountsReferencesHeadersAndCancellationPreservePreviousPack() = runBlocking {
		val root = root()
		try {
			val good = fixture(root, 1); val saved = File(root, "saved"); val store = OfflineFleetStore(saved)
			store.install(good.archive, good.manifest); val previous = store.manifest()
			val mutations: List<(List<JsonArray>) -> List<JsonArray>> = listOf(
				{ it.dropLast(1) },
				{ it + listOf(JsonArray(listOf(JsonPrimitive("meta"), JsonPrimitive("after"), JsonPrimitive("{}")))) },
				{ lines -> lines.mapIndexed { index, line -> if (index == 3) JsonArray(listOf(JsonPrimitive("assertion"), JsonPrimitive("assertion:1"), JsonPrimitive("missing"), JsonPrimitive("{}"))) else line } },
				{ lines -> lines.mapIndexed { index, line -> if (index == 0) JsonArray(line.toMutableList().apply { this[1] = JsonPrimitive(3) }) else line } },
			)
			for (mutation in mutations) {
				val bad = fixture(root, 1, mutation)
				try { store.install(bad.archive, bad.manifest); fail("Invalid pack activated") } catch (_: Exception) { }
				assertEquals(previous, store.manifest())
			}
			try { store.install(good.archive, good.manifest.copy(uncompressedByteLength = 10)); fail("Oversized expansion accepted") } catch (_: FleetValidationException) { }
			try { store.install(good.archive, good.manifest) { if (it.stage == FleetDownloadStage.IMPORTING && it.completedBytes > 0) throw CancellationException("test cancellation") }; fail("Cancelled pack activated") } catch (_: CancellationException) { }
			assertEquals(previous, store.manifest())
			assertEquals(1, saved.listFiles()!!.count { it.name.endsWith(".sqlite") })
			val lowSpace = OfflineFleetStore(File(root, "low-space"), availableBytes = { 256 * 1024 * 1024L })
			try { lowSpace.install(good.archive, good.manifest); fail("Reserve ignored") } catch (_: FleetValidationException) { }
		} finally { root.deleteRecursively() }
	}

	@Test fun legacyGzipSQLiteImportChecksSchemaCountsAndPreservesHistory() = runBlocking {
		val root = root()
		try {
			val fixture = fixture(root, 3); val database = File(root, "legacy.sqlite")
			FleetPackImporter(database, fixture.manifest, {}, {}).use { importer ->
				fixture.archive.inputStream().use { FleetArchive.expand(it, fixture.manifest.uncompressedByteLength) { block -> importer.consume(block) } }; importer.finish()
			}
			FleetSqlite(database, readOnly = false).use { db ->
				db.execute("UPDATE meta SET data=? WHERE key='snapshot'", listOf("{\"schemaVersion\":1,\"generatedAt\":10000,\"historyStart\":0,\"historyEnd\":10000}"))
			}
			val gzip = File(root, "legacy.gz"); database.inputStream().use { source -> gzip.outputStream().use { target -> GZIPOutputStream(target).use { source.copyTo(it) } } }
			val manifest = FleetOfflineManifest(id = FleetArchive.digest(database), generatedAt = 10_000.0, historyStart = 0.0, historyEnd = 10_000.0, counts = FleetOfflineCounts(2, 1, 3, 1), byteLength = database.length(), sha256 = FleetArchive.digest(database), downloadURL = "/legacy.gz", compression = "gzip", compressedByteLength = gzip.length(), compressedSha256 = FleetArchive.digest(gzip))
			val store = OfflineFleetStore(File(root, "saved")); store.install(gzip, manifest)
			assertEquals(3, store.fleetDetail("car", "car:1").history.size)
			try { store.install(gzip, manifest.copy(counts = manifest.counts.copy(events = 4))); fail("Count mismatch accepted") } catch (_: FleetValidationException) { }
			assertEquals(manifest, store.manifest())
			FleetSqlite(database, readOnly = false).use { it.execute("PRAGMA user_version=9") }
			val bad = manifest.copy(compression = null, compressedByteLength = null, compressedSha256 = null, byteLength = database.length(), sha256 = FleetArchive.digest(database))
			try { store.install(database, bad); fail("Unsupported schema accepted") } catch (_: FleetValidationException) { }
			assertEquals(manifest, store.manifest())
		} finally { root.deleteRecursively() }
	}

	@Test fun reopeningCleansInterruptedCandidatesWithoutRemovingActiveSnapshot() = runBlocking {
		val root = root()
		try {
			val fixture = fixture(root, 1); val saved = File(root, "saved"); val store = OfflineFleetStore(saved)
			store.install(fixture.archive, fixture.manifest); val active = store.manifest()
			val activeFile = saved.listFiles()!!.single { it.name.endsWith(".sqlite") }
			for (name in listOf("interrupted.sqlite", "interrupted.sqlite-journal", "interrupted.sqlite-wal", "orphan.sqlite-shm", "pending.archive", ".pending.staging")) File(saved, name).writeBytes(byteArrayOf(1, 2, 3))
			val reopened = OfflineFleetStore(saved)
			assertEquals(active, reopened.manifest())
			assertTrue(activeFile.exists())
			assertFalse(saved.listFiles()!!.any { it.name.startsWith("interrupted") || it.name.startsWith("orphan") || it.name.endsWith(".archive") || it.name.endsWith(".staging") })
			assertEquals(1, reopened.fleetDetail("car", "car:1").history.size)
		} finally { root.deleteRecursively() }
	}

	@Test fun scopedPackKeepsExcludedHistoricalFormationContextWithoutInventingRosterCars() = runBlocking {
		val root = root()
		try {
			val fixture = fixture(root, 1) { lines -> lines.map { line ->
				if (line[0] == JsonPrimitive("consist")) JsonArray(listOf(JsonPrimitive("consist"), JsonPrimitive("observed:pair"), JsonPrimitive("[\"car:2\",\"car:1\",\"context:not-selected\"]"))) else line
			} }
			val saved = File(root, "saved"); val store = OfflineFleetStore(saved)
			store.install(fixture.archive, fixture.manifest)
			val database = saved.listFiles()!!.single { it.name.endsWith(".sqlite") }
			FleetDatabase(database).use { db ->
				val formation = TransitJson.decodeFromString<List<String>>(db.rows("SELECT data FROM consists WHERE id=?", listOf("observed:pair")).single().single())
				assertEquals(listOf("car:2", "car:1", "context:not-selected"), formation)
				assertEquals(2L, db.count("cars"))
			}
			val detail = store.fleetDetail("consist", "observed:pair")
			assertEquals(listOf("car:2", "car:1"), detail.cars.map { it.id })
			assertEquals(listOf("car:2", "car:1", "context:not-selected"), detail.history.single().cars)
		} finally { root.deleteRecursively() }
	}

	@Test fun legacyEventWithoutCarsUsesSelectedTransportIndexWithoutInventingPayloadMembership() = runBlocking {
		val root = root()
		try {
			val fixture = fixture(root, 1) { lines -> lines.map { line ->
				if (line[0] == JsonPrimitive("event")) JsonArray(line.toMutableList().apply {
					val raw = TransitJson.parseToJsonElement(line[3].jsonPrimitive.content).jsonObject
					this[3] = JsonPrimitive(JsonObject(raw - "cars").toString())
				}) else line
			} }
			val store = OfflineFleetStore(File(root, "saved")); store.install(fixture.archive, fixture.manifest)
			val detail = store.fleetDetail("car", "car:1")
			assertEquals(1, detail.history.size)
			assertTrue(detail.history.single().cars.isEmpty())
			assertEquals("Station", detail.history.single().location)
		} finally { root.deleteRecursively() }
	}

	@Test fun realServerExportsKeepHistoricalContextAndLegacyEventIndexes() = runBlocking {
		val root = root()
		try {
			for (name in listOf("fleet-history-fixture", "fleet-legacy-fixture")) {
			// Opaque asset suffix preserves the exact gzip bytes through APK packaging.
			val archive = File(root, "$name.gz").apply { writeBytes(asset("$name.archive")) }
				val manifest = TransitJson.decodeFromString<FleetPackManifest>(asset("$name.manifest.json").decodeToString())
				val saved = File(root, name); val store = OfflineFleetStore(saved)
				store.install(archive, manifest)
				assertEquals(1, store.fleet(mapOf("view" to "cars")).total)
				val history = store.fleetDetail("car", "nyct:R160:1").history
				assertEquals(2, history.size)
				if (name == "fleet-history-fixture") assertTrue(history.any { "nyct:R211:2" in it.cars }) else assertTrue(history.all { it.cars.isEmpty() })
				FleetDatabase(saved.listFiles()!!.single { it.name.endsWith(".sqlite") }).use { db ->
					assertTrue(db.rows("SELECT data FROM consists").any { "nyct:R211:2" in it.single() })
					assertEquals(2L, db.count("event_cars"))
				}
			}
		} finally { root.deleteRecursively() }
	}
}
