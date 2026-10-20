package nyc.juliet.subwaysfornerds.core

import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant

/** The cross-platform `settings.departureRows` contract and portable format v6. */
class DepartureRowSettingsTest {
	private fun file(version: Int, settings: JsonObject): String = buildJsonObject {
		put("format", "subways-for-nerds"); put("version", version); put("exportedAt", "2026-10-19T12:00:00Z")
		put("lastStation", "602"); put("settings", settings)
	}.toString()
	private val current: JsonObject get() = TransitJson.encodeToJsonElement(Settings.serializer(), Settings()).jsonObject
	private fun withRows(rows: JsonElement): JsonObject = JsonObject(current + ("departureRows" to rows))
	private fun rows(provenance: JsonElement = JsonPrimitive(false), combine: JsonElement = JsonPrimitive(true), consist: JsonElement = JsonPrimitive(true), headway: JsonElement = JsonPrimitive(true)) =
		buildJsonObject { put("showTrackProvenance", provenance); put("combinePosition", combine); put("showConsist", consist); put("showHeadway", headway) }
	private val nonDefault = DepartureRowSettings(showTrackProvenance = true, combinePosition = false, showConsist = false, showHeadway = true)

	@Test fun defaultsHideProvenanceAndCombinePosition() {
		assertEquals(DepartureRowSettings(false, true, true, true), Settings().departureRows)
		assertEquals(rows(), TransitJson.encodeToJsonElement(Settings.serializer(), Settings()).jsonObject["departureRows"])
		assertEquals(Settings().departureRows, NerdsCodec.validate(JsonObject(current - "departureRows")).departureRows)
	}

	@Test fun encodesVersionSixAndRoundTrips() {
		val settings = Settings(departureRows = nonDefault)
		val text = NerdsCodec.encode(settings, "602", Instant.parse("2026-10-19T12:00:00Z"))
		val raw = TransitJson.parseToJsonElement(text).jsonObject
		assertEquals(JsonPrimitive(6), raw["version"])
		assertTrue(raw.getValue("settings").jsonObject.containsKey("departureRows"))
		val decoded = NerdsCodec.decode(text)
		assertEquals(6, decoded.version)
		assertEquals(nonDefault, decoded.settings.departureRows)
		assertEquals(settings, decoded.settings)
	}

	@Test fun versionSixRequiresDepartureRows() {
		assertThrows(SettingsException::class.java) { NerdsCodec.decode(file(6, JsonObject(current - "departureRows"))) }
		assertEquals(Settings(), NerdsCodec.decode(file(6, current)).settings)
	}

	@Test fun versionFiveImportGetsDefaultsAndCannotCarryDepartureRows() {
		val legacy = JsonObject(current - "departureRows")
		val decoded = NerdsCodec.decode(file(5, legacy))
		assertEquals(5, decoded.version)
		assertEquals(DepartureRowSettings(), decoded.settings.departureRows)
		for (version in 1..5) assertThrows("v$version with departureRows", SettingsException::class.java) { NerdsCodec.decode(file(version, withRows(rows()))) }
		assertThrows(SettingsException::class.java) { NerdsCodec.decode(file(7, current)) }
	}

	@Test fun strictValidationOfDepartureRowShape() {
		val bad = listOf(
			JsonNull,
			JsonPrimitive(true),
			JsonArray(emptyList()),
			JsonObject(emptyMap()),
			buildJsonObject { put("showTrackProvenance", false); put("combinePosition", true); put("showConsist", true) },
			JsonObject(rows() + ("extra" to JsonPrimitive(true))),
			rows(provenance = JsonPrimitive("false")),
			rows(combine = JsonPrimitive(1)),
			rows(consist = JsonNull),
			rows(headway = JsonArray(emptyList())),
		)
		for (value in bad) assertThrows(value.toString(), SettingsException::class.java) { NerdsCodec.validate(withRows(value)) }
		assertEquals(nonDefault, NerdsCodec.validate(withRows(rows(JsonPrimitive(true), JsonPrimitive(false), JsonPrimitive(false), JsonPrimitive(true)))).departureRows)
	}

	@Test fun mergeAppliesTheGenericPerKeyRule() {
		val base = Settings()
		val local = base.copy(departureRows = base.departureRows.copy(showConsist = false, combinePosition = false))
		val remote = base.copy(departureRows = base.departureRows.copy(showHeadway = false, combinePosition = true))
		val merged = SettingsMerge.merge(base, local, remote)
		// Each key merges on its own: local edits one key, remote another, and a key only one side moved follows that side.
		assertTrue(merged.conflicts.isEmpty())
		assertEquals(DepartureRowSettings(showTrackProvenance = false, combinePosition = false, showConsist = false, showHeadway = false), merged.settings.departureRows)
		// Equal edits on both sides merge to that value.
		val same = base.copy(departureRows = nonDefault)
		assertTrue(SettingsMerge.merge(base, same, same).conflicts.isEmpty())
		assertEquals(nonDefault, SettingsMerge.merge(base, same, same).settings.departureRows)
		// A legacy baseline without the block migrates to defaults before merging, so it never overrides a local change.
		val legacy = TransitJson.decodeFromJsonElement(Settings.serializer(), JsonObject(current - "departureRows"))
		assertEquals(DepartureRowSettings(), legacy.departureRows)
		assertEquals(nonDefault, SettingsMerge.merge(legacy, same, legacy).settings.departureRows)
		assertEquals(nonDefault, SettingsMerge.merge(legacy, legacy, same).settings.departureRows)
		assertEquals(listOf("departureRows / combinePosition"), SettingsMerge.changes(base, base.copy(departureRows = base.departureRows.copy(combinePosition = false))).map { it.path })
	}

	@Test fun canonicalVersionSixFixtureDecodesAndReencodes() {
		val text = javaClass.getResourceAsStream("/fixtures/departure-rows.nerds")!!.bufferedReader().use { it.readText() }
		val file = NerdsCodec.decode(text)
		assertEquals(6, file.version)
		assertEquals(nonDefault, file.settings.departureRows)
		// The fixture is the transfers fixture plus the new block, so transfers survive.
		assertTrue(file.settings.transfers.separateFilters)
		val again = NerdsCodec.decode(NerdsCodec.encode(file.settings, file.lastStation, Instant.parse(file.exportedAt)))
		assertEquals(file, again)
	}

	@Test fun boardingLabelProvenanceIsOptional() {
		val base = Departure("k", "t", "A", "Inwood", "NORTH", "A27N", "p", "Broadway - Brighton", null, null, pattern = "Local", patternSource = "reported", location = "", feed = "gtfs", timestamp = 0.0)
		val reported = base.copy(actualTrack = "A4", scheduledTrack = "A5")
		val scheduled = base.copy(scheduledTrack = "A5")
		assertEquals("Broadway - Brighton · Track A4 · reported", Display.boardingLabel(reported))
		assertEquals("Broadway - Brighton · Track A4", Display.boardingLabel(reported, provenance = false))
		assertEquals("Broadway - Brighton · Track A5 · scheduled", Display.boardingLabel(scheduled, provenance = true))
		assertEquals("Broadway - Brighton · Track A5", Display.boardingLabel(scheduled, provenance = false))
		assertEquals("Broadway - Brighton · Track unknown", Display.boardingLabel(base, provenance = false))
		assertEquals("Broadway - Brighton · Track unknown", Display.boardingLabel(base))
		val tracked = reported.copy(area = "Broadway - Brighton · Track A4")
		assertEquals("Broadway - Brighton · Track A4 · reported", Display.boardingLabel(tracked))
		assertEquals("Broadway - Brighton · Track A4", Display.boardingLabel(tracked, provenance = false))
	}

	@Test fun boardingLabelWithoutLineNameAreaDoesNotDuplicateTrack() {
		val base = Departure("k", "t", "G", "Church Av", "NORTH", "G05N", "p", "Northbound", null, null, pattern = "Crosstown–Culver", patternSource = "reported", location = "", feed = "gtfs", timestamp = 0.0)
		val withTrack = base.copy(area = "Northbound · Track B2", actualTrack = "B2", scheduledTrack = "B2")
		assertEquals("Northbound · Track B2", Display.boardingLabel(withTrack, provenance = false))
		assertEquals("Northbound · Track B2 · reported", Display.boardingLabel(withTrack, provenance = true))
		assertEquals("Northbound · Track B2 · scheduled", Display.boardingLabel(withTrack.copy(actualTrack = null), provenance = true))
		assertEquals("Northbound · Track B2", Display.boardingLabel(base.copy(scheduledTrack = "B2"), provenance = false))
		assertEquals("Northbound · Track B2 · scheduled", Display.boardingLabel(base.copy(scheduledTrack = "B2")))
		assertEquals("Northbound · Track unknown", Display.boardingLabel(base, provenance = false))
		val segment = base.copy(area = "Brighton · Manhattan · Track A4", actualTrack = "A4", scheduledTrack = "A4")
		assertEquals("Brighton · Manhattan · Track A4", Display.boardingLabel(segment, provenance = false))
		assertEquals("Brighton · Manhattan · Track A4 · reported", Display.boardingLabel(segment))
		assertEquals("Brighton · Manhattan · Track A4", Display.boardingLabel(segment.copy(area = "Brighton · Manhattan"), provenance = false))
	}
}
