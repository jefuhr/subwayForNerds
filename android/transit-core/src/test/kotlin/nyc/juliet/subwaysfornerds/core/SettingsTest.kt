package nyc.juliet.subwaysfornerds.core

import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant

class SettingsTest {
	private val combinedID = "combined:6d9542db-9ab7-422e-9548-fd66c1d4a384"
	private fun file(version: Int, settings: JsonObject): String = buildJsonObject {
		put("format", "subways-for-nerds"); put("version", version); put("exportedAt", "2026-10-13T12:00:00Z")
		put("lastStation", "unknown-station"); put("settings", settings)
	}.toString()
	@Test fun allPortablePreferencesRoundTripAndUnknownIDsSurvive() {
		val settings = Settings(theme = "future-theme", favorites = listOf("unknown-station"),
			combinedStations = mapOf(combinedID to CombinedStation("Downtown", listOf("628", "328"))), hiddenRoutes = listOf("NJT-HBLR", "A"),
			trainFavorites = TrainFavorites(listOf("nyct:R160:001"), listOf(listOf("sir:R44:401")), "anyCar"),
			offline = OfflineSettings(retentionHours = 24, widgetsFollowActiveRide = true),
			widgets = WidgetSettings(stationSelection = WidgetStationSelection(false, StationSelection("closest", 1)),
				lockScreen = LockScreenSettings(WidgetDisplay(listOf("carNumbers"), false, 0, "clock", 60), "uptownLeft", false)))
		val encoded = NerdsCodec.encode(settings, "unknown-station", Instant.parse("2026-10-13T12:00:00Z"))
		val decoded = NerdsCodec.decode(encoded)
		assertEquals(4, decoded.version); assertEquals("unknown-station", decoded.lastStation)
		assertEquals(NerdsCodec.validate(settings), decoded.settings)
		assertFalse(encoded.contains("activeRide")); assertFalse(encoded.contains("session"))
	}
	@Test fun legacyVersionsMigrateWithoutLosingNativeFields() {
		val current = TransitJson.encodeToJsonElement(Settings.serializer(), Settings()).jsonObject
		for (version in 1..4) {
			val values = current.toMutableMap()
			if (version < 4) { values.remove("combinedStations"); values.remove("hiddenRoutes") }
			if (version < 3) values.remove("offline")
			if (version < 2) { values.remove("trainFavorites"); values.remove("stationSelection"); values.remove("units")
				values["widgets"] = JsonObject(values.getValue("widgets").jsonObject.filterKeys { it != "stationSelection" }) }
			assertEquals(Settings(), NerdsCodec.decode(file(version, JsonObject(values))).settings)
		}
	}
	@Test fun strictValidationRejectsWrongVersionShapeDuplicatesNullsAndSize() {
		val current = TransitJson.encodeToJsonElement(Settings.serializer(), Settings()).jsonObject
		val bad = listOf(file(1, current), file(3, current), file(4, JsonObject(current - "offline")),
			file(4, JsonObject(current + ("favorites" to JsonArray(listOf(JsonPrimitive("a"), JsonPrimitive("a")))))),
			file(4, JsonObject(current + ("theme" to JsonNull))), file(4, JsonObject(current + ("deviceLocation" to JsonPrimitive(true)))))
		for (text in bad) assertThrows(SettingsException::class.java) { NerdsCodec.decode(text) }
		assertThrows(SettingsException::class.java) { NerdsCodec.decode(" ".repeat(1_048_577)) }
		assertThrows(SettingsException::class.java) { NerdsCodec.decode(file(9, current)) }
		assertThrows(SettingsException::class.java) { NerdsCodec.validate(Settings(offline = OfflineSettings(storageLimitMiB = 75))) }
		assertThrows(SettingsException::class.java) { NerdsCodec.validate(Settings(trainFavorites = TrainFavorites(cars = listOf("nyct:R160A:001")))) }
	}
	@Test fun mergeHandlesMembershipEditsAndEscapesConflictPaths() {
		val base = Settings(favorites = listOf("a", "b"), hiddenRoutes = listOf("A"), stations = mapOf("a/b~c" to StationSettings(view = "track")))
		val local = base.copy(favorites = listOf("a", "c"), hiddenRoutes = listOf("A", "F"), stations = mapOf("a/b~c" to StationSettings(view = "family")))
		val remote = base.copy(favorites = listOf("a", "b", "d"), hiddenRoutes = listOf("R"), stations = mapOf("a/b~c" to StationSettings(view = "service")))
		val merged = SettingsMerge.merge(base, local, remote)
		assertEquals(listOf("a", "d", "c"), merged.settings.favorites)
		assertEquals(listOf("F", "R"), merged.settings.hiddenRoutes)
		assertEquals(listOf("/stations/a~1b~0c/view"), merged.conflicts.map { it.path })
		val resolved = SettingsMerge.merge(base, local, remote, mapOf(merged.conflicts.single().path to "remote"))
		assertTrue(resolved.conflicts.isEmpty()); assertEquals("service", resolved.settings.stations.getValue("a/b~c").view)
		assertEquals(merged.conflicts, SettingsMerge.merge(base, local, remote, mapOf(merged.conflicts.single().path to "typo")).conflicts)
	}
	@Test fun removeVersusEditIsConflictAndPreviewsIncludeAdditions() {
		val base = Settings(stations = mapOf("one" to StationSettings()))
		val local = base.copy(stations = emptyMap())
		val remote = base.copy(stations = mapOf("one" to StationSettings(view = "service")))
		assertEquals("/stations/one", SettingsMerge.merge(base, local, remote).conflicts.single().path)
		assertTrue(SettingsMerge.changes(base, local).any { it.path == "stations / one" && it.remote == null })
	}
}
