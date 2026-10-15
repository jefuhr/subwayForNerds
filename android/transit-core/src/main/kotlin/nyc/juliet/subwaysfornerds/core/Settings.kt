@file:OptIn(kotlinx.serialization.ExperimentalSerializationApi::class)

package nyc.juliet.subwaysfornerds.core

import kotlinx.serialization.EncodeDefault
import kotlinx.serialization.EncodeDefault.Mode.NEVER
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*
import java.time.Instant
import java.time.OffsetDateTime

const val MAX_SETTINGS_BYTES = 1_048_576
@Serializable data class UnitSettings(val distance: String = "auto", val time: String = "12h")
@Serializable data class TrainFavorites(val cars: List<String> = emptyList(), val consists: List<List<String>> = emptyList(), val match: String = "exact") {
	fun match(consist: Consist?, feed: String, now: Double, cached: Boolean = false): TrainFavoriteMatch? = TrainFavoriteRules.match(consist, feed, this, now, cached)
	fun containsConsist(ids: List<String>): Boolean = consists.any { TrainFavoriteRules.consistKey(it) == TrainFavoriteRules.consistKey(ids) }
	companion object {
		fun validCarID(id: String): Boolean = id.length <= 128 && Regex("^(nyct|sir):[A-Za-z0-9._-]+:[A-Za-z0-9._-]+$").matches(id) && id.split(':')[1] !in listOf("R160A", "R160B")
		fun carID(number: String, type: String?, feed: String): String? = TrainFavoriteRules.carID(number, type, feed)
		fun consistIDs(consist: Consist?, feed: String): List<String>? = TrainFavoriteRules.consistIDs(consist, feed)
		fun consistKey(ids: List<String>): String = TrainFavoriteRules.consistKey(ids)
	}
}
@Serializable data class StationSelection(val mode: String = "favorite", val radiusFeet: Int = 5280) {
	fun includesFavorite(distanceMeters: Double): Boolean = distanceMeters.isFinite() && distanceMeters >= 0 && distanceMeters < radiusFeet * 0.3048
	fun select(stations: List<Station>, favorites: List<String>, location: StationLocation?, previous: String? = null, now: Double = System.currentTimeMillis() / 1000.0): Station? = StationSelectionRules.select(stations, favorites, this, location, previous, now)
}
@Serializable data class OfflineSettings(
	val departuresPerLineDirection: Int = 5, val tripDetailsPerLineDirection: Int = 2, val saveOpenedTrips: Boolean = true,
	val nearbyRadiusFeet: Int = 2640, val preloadOtherStationTrips: Boolean = false, val estimateLimitMinutes: Int = 30,
	val retentionHours: Int = 6, val storageLimitMiB: Int = 50, val widgetsFollowActiveRide: Boolean = false,
) {
	val effectiveTripDetailsPerLineDirection: Int get() = minOf(tripDetailsPerLineDirection, departuresPerLineDirection)
	val estimateLimit: Double get() = estimateLimitMinutes * 60.0
	val retention: Double get() = retentionHours * 3600.0
	val storageLimitBytes: Long get() = storageLimitMiB * 1_048_576L
	val nearbyRadiusMeters: Double get() = nearbyRadiusFeet * 0.3048
}
@Serializable data class StationSettings(val direction: String = "ALL", val routes: List<String> = emptyList(), val view: String = "track")
/** A transfer station's own direction and lines. Transfers keep arrival-relative grouping, so there is no view. */
@Serializable data class TransferFilter(val direction: String = "ALL", val routes: List<String> = emptyList())
/** Shared mode reads and writes `Settings.stations`; separate mode uses `stations` here, which survives turning it off. */
@Serializable data class TransferSettings(val separateFilters: Boolean = false, val stations: Map<String, TransferFilter> = emptyMap())
@Serializable data class WidgetDisplay(
	val fields: List<String> = listOf("stationName", "destination", "track", "carType", "updatedAt", "refreshButton", "groupHeaders").sorted(),
	val compact: Boolean = true, val trainsPerDirection: Int = 0, val timeStyle: String = "countdown",
	@EncodeDefault(NEVER) val refreshInterval: Int? = null,
) {
	fun candidateCounts(maximum: Int): List<Int> = maxOf(1, if (trainsPerDirection == 0) maximum else minOf(maximum, trainsPerDirection)).downTo(1).toList()
}
@Serializable data class LockScreenSettings(
	val display: WidgetDisplay = WidgetDisplay(listOf("carType", "stationName"), true, 2, "minutes"),
	val directionOrder: String = "downtownLeft", val showService: Boolean = true,
) {
	fun orderedDirections(regional: Boolean = false): List<String> = (if (regional) listOf("TO_NJ", "TO_NY") else listOf("SOUTH", "NORTH")).let { if (directionOrder == "uptownLeft") it.reversed() else it }
}
@Serializable data class WidgetStationSelection(val followApp: Boolean = true, val selection: StationSelection = StationSelection())
@Serializable data class WidgetSettings(
	val stationSelection: WidgetStationSelection = WidgetStationSelection(), val matchAppFilters: Boolean = false,
	val stations: Map<String, StationSettings> = emptyMap(), val display: WidgetDisplay = WidgetDisplay(),
	val lockScreen: LockScreenSettings = LockScreenSettings(),
)
@Serializable data class CombinedStation(val name: String, val stationIDs: List<String>)
@Serializable data class Settings(
	val combinedStations: Map<String, CombinedStation> = emptyMap(), val hiddenRoutes: List<String> = emptyList(),
	val favorites: List<String> = emptyList(), val theme: String = "subway", val stations: Map<String, StationSettings> = emptyMap(),
	val trainFavorites: TrainFavorites = TrainFavorites(), val stationSelection: StationSelection = StationSelection(),
	val units: UnitSettings = UnitSettings(), val offline: OfflineSettings = OfflineSettings(), val widgets: WidgetSettings = WidgetSettings(),
	val transfers: TransferSettings = TransferSettings(),
)
@Serializable data class NerdsFile(val format: String = "subways-for-nerds", val version: Int = NerdsCodec.VERSION, val exportedAt: String, val lastStation: String, val settings: Settings)
@Serializable data class SettingsRevision(val revision: Long, val settings: Settings? = null)
class SettingsException(message: String = "This is not a valid Subway Nerds settings file.") : IllegalArgumentException(message)

/** Strict portable format boundary. Device location, sessions, cached data and active rides never enter it. */
object NerdsCodec {
	const val VERSION = 5
	val directions = listOf("ALL", "NORTH", "SOUTH", "TO_NY", "TO_NJ", "UNKNOWN")
	val widgetFields = listOf("stationName", "destination", "track", "service", "carType", "carCount", "carNumbers", "location", "updatedAt", "refreshButton", "groupHeaders")
	private val strict = Json(TransitJson) { ignoreUnknownKeys = false; prettyPrint = true }
	private fun invalid(): Nothing = throw SettingsException()
	private fun size(text: String) { if (text.toByteArray(Charsets.UTF_8).size > MAX_SETTINGS_BYTES) throw SettingsException("Settings files must be smaller than 1 MiB.") }
	private fun obj(value: JsonElement?): JsonObject = value as? JsonObject ?: invalid()
	private fun keys(value: JsonObject, required: Set<String>, optional: Set<String> = emptySet()) {
		if (!value.keys.containsAll(required) || !value.keys.all { it in required || it in optional }) invalid()
	}
	private fun string(value: JsonElement?): String {
		val primitive = value as? JsonPrimitive ?: invalid()
		if (!primitive.isString || primitive.content.isEmpty() || primitive.content.length > 128 || primitive.content.any { it.code < 32 }) invalid()
		return primitive.content
	}
	private fun strings(value: JsonElement?, max: Int = 2000): List<String> {
		val array = value as? JsonArray ?: invalid()
		if (array.size > max) invalid()
		return array.map(::string).also { if (it.distinct().size != it.size) invalid() }
	}
	private fun bool(value: JsonElement?): Boolean = (value as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull ?: invalid()
	private fun integer(value: JsonElement?, range: IntRange): Int {
		val primitive = value as? JsonPrimitive ?: invalid()
		val number = primitive.takeIf { !it.isString }?.doubleOrNull ?: invalid()
		if (!number.isFinite() || number % 1.0 != 0.0 || number < range.first || number > range.last) invalid()
		return number.toInt()
	}
	private fun choice(value: JsonElement?, choices: List<String>): String = string(value).also { if (it !in choices) invalid() }
	private fun selection(value: JsonElement?): StationSelection {
		val v = obj(value); keys(v, setOf("mode", "radiusFeet"))
		return StationSelection(choice(v["mode"], listOf("favorite", "closest", "nearbyFavorite")), integer(v["radiusFeet"], 1..26400))
	}
	private fun <T> stationMap(value: JsonElement?, entry: (JsonObject) -> T): Map<String, T> {
		val entries = obj(value); if (entries.size > 2000) invalid()
		return entries.mapValues { (id, raw) ->
			string(JsonPrimitive(id)); if (id in listOf("__proto__", "constructor", "prototype")) invalid()
			entry(obj(raw))
		}
	}
	private fun stations(value: JsonElement?): Map<String, StationSettings> = stationMap(value) { v ->
		keys(v, setOf("direction", "routes", "view"))
		StationSettings(choice(v["direction"], directions), strings(v["routes"], 128).sorted(), choice(v["view"], listOf("track", "direction", "family", "corridor", "service")))
	}
	/** Same direction and line limits as station filters; a view is never part of a transfer entry. */
	private fun transfers(value: JsonElement?): TransferSettings {
		val v = obj(value); keys(v, setOf("separateFilters", "stations"))
		return TransferSettings(bool(v["separateFilters"]), stationMap(v["stations"]) { entry ->
			keys(entry, setOf("direction", "routes"))
			TransferFilter(choice(entry["direction"], directions), strings(entry["routes"], 128).sorted())
		})
	}
	private fun display(value: JsonElement?): WidgetDisplay {
		val v = obj(value); keys(v, setOf("fields", "compact", "trainsPerDirection", "timeStyle"), setOf("refreshInterval"))
		val fields = strings(v["fields"], widgetFields.size).sorted(); if (!widgetFields.containsAll(fields)) invalid()
		val refresh = if (v.containsKey("refreshInterval")) integer(v["refreshInterval"], 1..60).also { if (it !in listOf(1, 2, 5, 10, 15, 30, 60)) invalid() } else null
		return WidgetDisplay(fields, bool(v["compact"]), integer(v["trainsPerDirection"], 0..8), choice(v["timeStyle"], listOf("countdown", "minutes", "clock")), refresh)
	}
	fun validate(settings: Settings): Settings = validate(TransitJson.encodeToJsonElement(Settings.serializer(), settings))
	fun validate(value: JsonElement): Settings {
		size(value.toString())
		val v = obj(value); keys(v, setOf("favorites", "theme", "stations", "widgets"), setOf("trainFavorites", "stationSelection", "units", "offline", "combinedStations", "hiddenRoutes", "transfers"))
		val w = obj(v["widgets"]); keys(w, setOf("matchAppFilters", "stations", "display"), setOf("lockScreen", "stationSelection"))
		val d = display(w["display"])
		val lock = if (!w.containsKey("lockScreen")) LockScreenSettings(WidgetDisplay(d.fields.filter { it in listOf("stationName", "carType", "carCount") }, true, 2, d.timeStyle)) else {
			val l = obj(w["lockScreen"]); keys(l, setOf("display", "directionOrder", "showService"))
			LockScreenSettings(display(l["display"]), choice(l["directionOrder"], listOf("downtownLeft", "uptownLeft")), bool(l["showService"]))
		}
		val widgetSelection = if (!w.containsKey("stationSelection")) WidgetStationSelection() else {
			val s = obj(w["stationSelection"]); keys(s, setOf("followApp", "selection")); WidgetStationSelection(bool(s["followApp"]), selection(s["selection"]))
		}
		val favorites = if (!v.containsKey("trainFavorites")) TrainFavorites() else {
			val t = obj(v["trainFavorites"]); keys(t, setOf("cars", "consists", "match"))
			val cars = strings(t["cars"]).sorted(); if (cars.any { !TrainFavorites.validCarID(it) }) invalid()
			val groups = t["consists"] as? JsonArray ?: invalid(); if (groups.size > 2000) invalid()
			val consists = groups.map { raw -> strings(raw, 20).sorted().also { if (it.isEmpty() || it.any { id -> !TrainFavorites.validCarID(id) }) invalid() } }
			if (consists.distinct().size != consists.size) invalid()
			TrainFavorites(cars, consists.sortedBy { JsonArray(it.map(::JsonPrimitive)).toString() }, choice(t["match"], listOf("exact", "anyCar")))
		}
		val units = if (!v.containsKey("units")) UnitSettings() else {
			val u = obj(v["units"]); keys(u, setOf("distance", "time")); UnitSettings(choice(u["distance"], listOf("auto", "mi", "ft", "m", "km")), choice(u["time"], listOf("12h", "24h")))
		}
		val offline = if (!v.containsKey("offline")) OfflineSettings() else {
			val o = obj(v["offline"]); keys(o, setOf("departuresPerLineDirection", "tripDetailsPerLineDirection", "saveOpenedTrips", "nearbyRadiusFeet", "preloadOtherStationTrips", "estimateLimitMinutes", "retentionHours", "storageLimitMiB", "widgetsFollowActiveRide"))
			fun pick(name: String, options: List<Int>) = integer(o[name], 0..250).also { if (it !in options) invalid() }
			OfflineSettings(integer(o["departuresPerLineDirection"], 1..20), integer(o["tripDetailsPerLineDirection"], 0..20), bool(o["saveOpenedTrips"]), integer(o["nearbyRadiusFeet"], 0..26400), bool(o["preloadOtherStationTrips"]), pick("estimateLimitMinutes", listOf(5, 15, 30, 60, 120)), pick("retentionHours", listOf(1, 6, 12, 24)), pick("storageLimitMiB", listOf(25, 50, 100, 250)), bool(o["widgetsFollowActiveRide"]))
		}
		val combined = if (!v.containsKey("combinedStations")) emptyMap() else {
			val c = obj(v["combinedStations"]); if (c.size > 2000) invalid()
			c.mapValues { (id, raw) ->
				if (!Regex("combined:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}").matches(id)) invalid()
				val s = obj(raw); keys(s, setOf("name", "stationIDs")); val name = string(s["name"])
				if (name.trim().isEmpty() || name != name.trim()) invalid()
				val ids = strings(s["stationIDs"]).sorted(); if (ids.size < 2 || ids.any { it.startsWith("combined:") }) invalid()
				CombinedStation(name, ids)
			}
		}
		return Settings(combined, if (v.containsKey("hiddenRoutes")) strings(v["hiddenRoutes"], 128).sorted() else emptyList(), strings(v["favorites"]), string(v["theme"]), stations(v["stations"]), favorites,
			if (v.containsKey("stationSelection")) selection(v["stationSelection"]) else StationSelection(), units, offline, WidgetSettings(widgetSelection, bool(w["matchAppFilters"]), stations(w["stations"]), d, lock),
			// Device and account settings saved before transfer filters existed use shared filters.
			if (v.containsKey("transfers")) transfers(v["transfers"]) else TransferSettings())
	}
	fun decode(text: String): NerdsFile {
		size(text)
		val v = try { obj(strict.parseToJsonElement(text)) } catch (e: SettingsException) { throw e } catch (_: Exception) { invalid() }
		keys(v, setOf("format", "version", "exportedAt", "lastStation", "settings"))
		if (v["format"] != JsonPrimitive("subways-for-nerds")) invalid()
		val version = (v["version"] as? JsonPrimitive)?.takeIf { !it.isString }?.intOrNull ?: throw SettingsException("This settings version is not supported. Update Subway Nerds and try again.")
		if (version !in 1..VERSION) throw SettingsException("This settings version is not supported. Update Subway Nerds and try again.")
		val exported = (v["exportedAt"] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: invalid()
		if (!Regex("\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(?:\\.\\d{1,9})?(?:Z|[+-]\\d{2}:\\d{2})").matches(exported)) invalid()
		try { OffsetDateTime.parse(exported) } catch (_: Exception) { invalid() }
		val s = obj(v["settings"])
		if (listOf("combinedStations", "hiddenRoutes").any { s.containsKey(it) != (version >= 4) } || s.containsKey("offline") != (version >= 3)) invalid()
		if (s.containsKey("transfers") != (version >= 5)) invalid()
		if (version >= 2 && (!s.containsKey("trainFavorites") || !s.containsKey("stationSelection") || !obj(s["widgets"]).containsKey("stationSelection"))) invalid()
		return NerdsFile(version = version, exportedAt = exported, lastStation = string(v["lastStation"]), settings = validate(s))
	}
	fun encode(settings: Settings, lastStation: String, exportedAt: Instant = Instant.now()): String {
		val file = NerdsFile(exportedAt = exportedAt.toString(), lastStation = string(JsonPrimitive(lastStation)), settings = validate(settings))
		val text = strict.encodeToString(NerdsFile.serializer(), file); decode(text); return text
	}
}
