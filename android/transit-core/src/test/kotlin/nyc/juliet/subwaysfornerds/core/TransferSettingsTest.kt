package nyc.juliet.subwaysfornerds.core

import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant

/** The cross-platform `settings.transfers` contract and portable format v5. */
class TransferSettingsTest {
	private fun file(version: Int, settings: JsonObject): String = buildJsonObject {
		put("format", "subways-for-nerds"); put("version", version); put("exportedAt", "2026-10-13T12:00:00Z")
		put("lastStation", "602"); put("settings", settings)
	}.toString()
	private val current: JsonObject get() = TransitJson.encodeToJsonElement(Settings.serializer(), Settings()).jsonObject
	private fun withTransfers(transfers: JsonElement): JsonObject = JsonObject(current + ("transfers" to transfers))
	private fun transfers(separate: JsonElement = JsonPrimitive(false), stations: JsonElement = JsonObject(emptyMap())) =
		buildJsonObject { put("separateFilters", separate); put("stations", stations) }
	private fun entry(direction: String = "ALL", routes: List<String> = emptyList()) =
		buildJsonObject { put("direction", direction); put("routes", JsonArray(routes.map(::JsonPrimitive))) }

	@Test fun defaultsToSharedWithNoEntries() {
		assertEquals(TransferSettings(separateFilters = false, stations = emptyMap()), Settings().transfers)
		val encoded = TransitJson.encodeToJsonElement(Settings.serializer(), Settings()).jsonObject
		assertEquals(transfers(), encoded["transfers"])
	}

	@Test fun exportsVersionFiveWithTransfersAndRoundTrips() {
		val settings = Settings(transfers = TransferSettings(true, mapOf("601" to TransferFilter("SOUTH", listOf("L", "2")), "unknown" to TransferFilter())))
		val text = NerdsCodec.encode(settings, "602", Instant.parse("2026-10-13T12:00:00Z"))
		val raw = TransitJson.parseToJsonElement(text).jsonObject
		assertEquals(JsonPrimitive(5), raw["version"])
		assertTrue(raw.getValue("settings").jsonObject.containsKey("transfers"))
		val decoded = NerdsCodec.decode(text)
		assertEquals(5, decoded.version)
		// Routes normalize to sorted order like station filters; entries never carry a view.
		assertEquals(listOf("2", "L"), decoded.settings.transfers.stations.getValue("601").routes)
		assertEquals(NerdsCodec.validate(settings), decoded.settings)
		val entries = raw.getValue("settings").jsonObject.getValue("transfers").jsonObject.getValue("stations").jsonObject
		assertTrue(entries.values.all { it.jsonObject.keys == setOf("direction", "routes") })
	}

	@Test fun versionFiveRequiresTransfers() {
		assertThrows(SettingsException::class.java) { NerdsCodec.decode(file(5, JsonObject(current - "transfers"))) }
		assertEquals(Settings(), NerdsCodec.decode(file(5, current)).settings)
	}

	@Test fun olderPortableVersionsCannotContainTransfersAndDefaultToShared() {
		for (version in 1..4) {
			val values = (current - "transfers").toMutableMap()
			if (version < 4) { values.remove("combinedStations"); values.remove("hiddenRoutes") }
			if (version < 3) values.remove("offline")
			if (version < 2) {
				values.remove("trainFavorites"); values.remove("stationSelection"); values.remove("units")
				values["widgets"] = JsonObject(values.getValue("widgets").jsonObject.filterKeys { it != "stationSelection" })
			}
			val decoded = NerdsCodec.decode(file(version, JsonObject(values)))
			assertEquals(version, decoded.version)
			assertEquals(TransferSettings(), decoded.settings.transfers)
			assertThrows("v$version with transfers", SettingsException::class.java) {
				NerdsCodec.decode(file(version, JsonObject(values + ("transfers" to transfers(JsonPrimitive(true))))))
			}
		}
	}

	@Test fun strictValidationOfTransferShape() {
		val bad = listOf(
			JsonNull,
			JsonPrimitive(true),
			buildJsonObject { put("separateFilters", false) },
			buildJsonObject { put("stations", JsonObject(emptyMap())) },
			JsonObject(transfers() + ("extra" to JsonPrimitive(1))),
			transfers(separate = JsonPrimitive("true")),
			transfers(separate = JsonNull),
			transfers(stations = JsonArray(emptyList())),
			// Transfer entries follow station filters but never carry a board view.
			transfers(stations = buildJsonObject { put("601", JsonObject(entry() + ("view" to JsonPrimitive("track")))) }),
			transfers(stations = buildJsonObject { put("601", buildJsonObject { put("direction", "ALL") }) }),
			transfers(stations = buildJsonObject { put("601", entry(direction = "EAST")) }),
			transfers(stations = buildJsonObject { put("601", entry(routes = listOf("A", "A"))) }),
			transfers(stations = buildJsonObject { put("601", entry(routes = List(129) { "R$it" })) }),
			transfers(stations = buildJsonObject { put("601", entry(routes = listOf(""))) }),
			transfers(stations = buildJsonObject { put("__proto__", entry()) }),
			transfers(stations = buildJsonObject { put("x".repeat(129), entry()) }),
			transfers(stations = JsonObject((0..2000).associate { "s$it" to entry() })),
		)
		for (value in bad) assertThrows(value.toString().take(120), SettingsException::class.java) { NerdsCodec.validate(withTransfers(value)) }
		val ok = NerdsCodec.validate(withTransfers(transfers(JsonPrimitive(true), buildJsonObject {
			put("601", entry("TO_NJ", listOf("PATH-HOB-33", "F")))
			put("combined:6d9542db-9ab7-422e-9548-fd66c1d4a384", entry("UNKNOWN"))
		})))
		assertTrue(ok.transfers.separateFilters)
		assertEquals(listOf("F", "PATH-HOB-33"), ok.transfers.stations.getValue("601").routes)
	}

	@Test fun deviceAndAccountSettingsWithoutTransfersMigrate() {
		// Saved device documents and account payloads from older apps simply lack the key.
		val legacy = JsonObject(current - "transfers")
		assertEquals(TransferSettings(), NerdsCodec.validate(legacy).transfers)
		assertEquals(TransferSettings(), TransitJson.decodeFromJsonElement(Settings.serializer(), legacy).transfers)
	}

	@Test fun mergeKeepsIndependentTransferEditsAndReportsConflicts() {
		val base = Settings(transfers = TransferSettings(true, mapOf("601" to TransferFilter("SOUTH"))))
		val local = base.copy(transfers = TransferSettings(true, mapOf("601" to TransferFilter("NORTH"), "602" to TransferFilter(routes = listOf("L")))))
		val remote = base.copy(transfers = TransferSettings(false, mapOf("601" to TransferFilter("SOUTH", listOf("1")))))
		val merged = SettingsMerge.merge(base, local, remote)
		assertTrue(merged.conflicts.isEmpty())
		assertFalse(merged.settings.transfers.separateFilters)
		assertEquals(TransferFilter("NORTH", listOf("1")), merged.settings.transfers.stations.getValue("601"))
		assertEquals(TransferFilter(routes = listOf("L")), merged.settings.transfers.stations.getValue("602"))

		val clash = SettingsMerge.merge(base, local, base.copy(transfers = TransferSettings(true, mapOf("601" to TransferFilter("TO_NJ")))))
		assertEquals(listOf("/transfers/stations/601/direction"), clash.conflicts.map { it.path })
		val resolved = SettingsMerge.merge(base, local, base.copy(transfers = TransferSettings(true, mapOf("601" to TransferFilter("TO_NJ")))), mapOf("/transfers/stations/601/direction" to "remote"))
		assertEquals("TO_NJ", resolved.settings.transfers.stations.getValue("601").direction)
		assertTrue(SettingsMerge.changes(base, local).any { it.path == "transfers / stations / 602" })
	}

	@Test fun disablingSeparateFiltersRetainsTheMap() {
		val separate = Settings(transfers = TransferSettings(true, mapOf("601" to TransferFilter("SOUTH"))))
		val shared = NerdsCodec.validate(separate.copy(transfers = separate.transfers.copy(separateFilters = false)))
		assertEquals(separate.transfers.stations, shared.transfers.stations)
		assertEquals(separate.transfers, NerdsCodec.validate(shared.copy(transfers = shared.transfers.copy(separateFilters = true))).transfers)
	}

	@Test fun canonicalVersionFiveFixtureDecodesAndReencodes() {
		val text = javaClass.getResourceAsStream("/fixtures/transfers.nerds")!!.bufferedReader().use { it.readText() }
		val file = NerdsCodec.decode(text)
		assertEquals(5, file.version)
		assertEquals(TransferSettings(true, mapOf(
			"602" to TransferFilter("SOUTH", listOf("5", "6")),
			"future:station" to TransferFilter("ALL", listOf("S", "SIR")),
			"path-wtc" to TransferFilter("TO_NJ"),
		)), file.settings.transfers)
		val again = NerdsCodec.decode(NerdsCodec.encode(file.settings, file.lastStation, Instant.parse(file.exportedAt)))
		assertEquals(file, again)
		// Separate transfer entries never change the station's own board filters.
		assertEquals(StationSettings("NORTH", listOf("4"), "family"), file.settings.stations.getValue("602"))
	}
}
