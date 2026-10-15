package nyc.juliet.subwaysfornerds.core

import kotlinx.serialization.json.*

data class SettingsConflict(val path: String, val local: JsonElement?, val remote: JsonElement?)
data class SettingsMergeResult(val settings: Settings, val conflicts: List<SettingsConflict>)

object SettingsMerge {
	fun merge(base: Settings, local: Settings, remote: Settings, choices: Map<String, String> = emptyMap()): SettingsMergeResult {
		val b = NerdsCodec.validate(base); val l = NerdsCodec.validate(local); val r = NerdsCodec.validate(remote)
		val conflicts = mutableListOf<SettingsConflict>()
		fun mergeValue(prior: JsonElement?, left: JsonElement?, right: JsonElement?, path: String): JsonElement? {
			if (left == right || prior == right) return left
			if (prior == left) return right
			if (left is JsonObject && right is JsonObject && (prior == null || prior is JsonObject)) {
				val before = prior ?: JsonObject(emptyMap())
				return JsonObject((before.keys + left.keys + right.keys).associateWith { key ->
					mergeValue(before[key], left[key], right[key], path + "/" + key.replace("~", "~0").replace("/", "~1"))
				}.filterValues { it != null }.mapValues { it.value!! })
			}
			when (choices[path]) { "local" -> return left; "remote" -> return right }
			conflicts += SettingsConflict(path, left, right); return left
		}
		fun memberships(before: List<String>, left: List<String>, right: List<String>, path: String): List<String> = (right + left + before).distinct().filter { id ->
			mergeValue(JsonPrimitive(id in before), JsonPrimitive(id in left), JsonPrimitive(id in right), "$path/$id") == JsonPrimitive(true)
		}
		val favorites = memberships(b.favorites, l.favorites, r.favorites, "/favorites")
		val hidden = memberships(b.hiddenRoutes, l.hiddenRoutes, r.hiddenRoutes, "/hiddenRoutes").sorted()
		val cars = memberships(b.trainFavorites.cars, l.trainFavorites.cars, r.trainFavorites.cars, "/trainFavorites/cars")
		fun consistKeys(s: Settings) = s.trainFavorites.consists.map { JsonArray(it.map(::JsonPrimitive)).toString() }
		val consists = memberships(consistKeys(b), consistKeys(l), consistKeys(r), "/trainFavorites/consists").map { TransitJson.parseToJsonElement(it).jsonArray.map { value -> value.jsonPrimitive.content } }
		fun withoutMembership(s: Settings): JsonElement = TransitJson.encodeToJsonElement(Settings.serializer(), s.copy(favorites = emptyList(), hiddenRoutes = emptyList(), trainFavorites = s.trainFavorites.copy(cars = emptyList(), consists = emptyList())))
		val raw = mergeValue(withoutMembership(b), withoutMembership(l), withoutMembership(r), "")!!
		val merged = TransitJson.decodeFromJsonElement(Settings.serializer(), raw)
		return SettingsMergeResult(NerdsCodec.validate(merged.copy(favorites = favorites, hiddenRoutes = hidden, trainFavorites = merged.trainFavorites.copy(cars = cars, consists = consists))), conflicts)
	}
	fun changes(before: Settings, after: Settings): List<SettingsConflict> {
		val result = mutableListOf<SettingsConflict>()
		fun walk(left: JsonElement?, right: JsonElement?, path: String) {
			if (left == right) return
			if (left is JsonObject && right is JsonObject) for (key in left.keys + right.keys) walk(left[key], right[key], if (path.isEmpty()) key else "$path / $key")
			else result += SettingsConflict(path, left, right)
		}
		walk(TransitJson.encodeToJsonElement(Settings.serializer(), NerdsCodec.validate(before)), TransitJson.encodeToJsonElement(Settings.serializer(), NerdsCodec.validate(after)), "")
		return result
	}
}
