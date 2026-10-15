package nyc.juliet.subwaysfornerds.ui

/** User-visible names for the portable settings values, which core stores as strings. */
object Labels {
	val boardViews = listOf("track", "direction", "family", "corridor", "service")
	fun boardViewTitle(view: String): String = when (view) {
		"track" -> "Track"; "direction" -> "Direction"; "family" -> "Families"; "corridor" -> "Corridors"; "service" -> "Service"; else -> view
	}
	fun boardViewLabel(view: String): String = when (view) {
		"track" -> "By track"
		"direction" -> "By direction · all platforms"
		"family" -> "By direction · route families"
		"corridor" -> "By direction · station corridors"
		"service" -> "By service"
		else -> view
	}

	val distanceUnits = listOf("auto", "mi", "ft", "m", "km")
	fun distanceTitle(unit: String): String = when (unit) {
		"auto" -> "Automatic"; "mi" -> "Miles (mi)"; "ft" -> "Feet (ft)"; "m" -> "Meters (m)"; "km" -> "Kilometers (km)"; else -> unit
	}
	/** The editor unit for a favorite radius: automatic edits feet. */
	fun radiusUnit(unit: String): String = if (unit == "auto") "ft" else unit

	val timeFormats = listOf("12h", "24h")
	fun timeFormatTitle(format: String): String = if (format == "24h") "24-hour" else "12-hour"

	val stationModes = listOf("favorite", "closest", "nearbyFavorite")
	fun stationModeTitle(mode: String): String = when (mode) {
		"favorite" -> "Closest favorite"; "closest" -> "Closest station"; "nearbyFavorite" -> "Favorite within radius"; else -> mode
	}

	val trainMatches = listOf("exact", "anyCar")
	fun trainMatchTitle(match: String): String = if (match == "anyCar") "Any member car" else "Exact consist"

	val widgetFields = listOf("stationName", "destination", "track", "service", "carType", "carCount", "carNumbers", "location", "updatedAt", "refreshButton", "groupHeaders")
	val lockScreenFields = listOf("stationName", "destination", "track", "service", "carType", "carCount", "carNumbers", "location", "updatedAt")
	fun widgetFieldTitle(field: String): String = when (field) {
		"stationName" -> "Station name"
		"destination" -> "Destinations"
		"track" -> "Tracks"
		"service" -> "Service patterns"
		"carType" -> "Car types"
		"carCount" -> "Car counts"
		"carNumbers" -> "Car numbers"
		"location" -> "Train locations"
		"updatedAt" -> "Report time"
		"refreshButton" -> "Refresh button"
		"groupHeaders" -> "Grouping labels"
		else -> field
	}

	val timeStyles = listOf("countdown", "minutes", "clock")
	fun timeStyleTitle(style: String): String = when (style) {
		"countdown" -> "Minutes and seconds"; "minutes" -> "Minutes"; "clock" -> "Arrival clock time"; else -> style
	}

	val refreshIntervals = listOf(1, 2, 5, 10, 15, 30, 60)
	fun refreshTitle(minutes: Int): String = if (minutes == 1) "1 minute" else "$minutes minutes"

	val directionOrders = listOf("downtownLeft", "uptownLeft")
	fun directionOrderTitle(order: String): String = if (order == "uptownLeft") "Uptown left, downtown right" else "Downtown left, uptown right"

	fun borough(borough: String): String = mapOf(
		"NJ" to "New Jersey", "M" to "Manhattan", "B" to "Brooklyn", "Bk" to "Brooklyn", "Bx" to "Bronx", "Q" to "Queens", "SI" to "Staten Island",
	)[borough] ?: borough

	/** Labels for settings paths in import previews and account conflicts. */
	private val settingNames = mapOf(
		"combinedStations" to "Combined stations", "hiddenRoutes" to "Hidden lines", "stationIDs" to "Member stations", "name" to "Name",
		"offline" to "Offline transit", "departuresPerLineDirection" to "Departures per line and direction",
		"tripDetailsPerLineDirection" to "Full trips per line and direction", "saveOpenedTrips" to "Save opened trips",
		"nearbyRadiusFeet" to "Nearby station distance (ft)", "preloadOtherStationTrips" to "Preload trips at other stations",
		"estimateLimitMinutes" to "Offline estimate window (minutes)", "retentionHours" to "Automatic retention (hours)",
		"storageLimitMiB" to "Storage limit (MiB)", "widgetsFollowActiveRide" to "Widgets follow active ride",
		"units" to "Units", "distance" to "Distance units", "time" to "Time format", "favorites" to "Favorite stations",
		"trainFavorites" to "Favorite trains", "cars" to "Cars", "consists" to "Consists", "match" to "Consist matching",
		"stationSelection" to "Station selection", "mode" to "Mode", "radiusFeet" to "Radius (ft)", "followApp" to "Follow app",
		"selection" to "Station choice", "theme" to "Theme", "stations" to "Stations", "widgets" to "Widgets", "display" to "Display",
		"lockScreen" to "Lock Screen", "directionOrder" to "Direction order", "showService" to "Service icons", "fields" to "Shown information",
		"compact" to "Compact rows", "trainsPerDirection" to "Trains per direction", "timeStyle" to "Arrival display",
		"refreshInterval" to "Refresh interval", "matchAppFilters" to "Match app filters", "direction" to "Direction", "routes" to "Lines",
		"view" to "Board grouping",
	)

	fun settingPath(path: String, stationName: (String) -> String?): String =
		path.split("/").map { it.trim() }.filter { it.isNotEmpty() }.joinToString(" · ") { part ->
			val key = part.replace("~1", "/").replace("~0", "~")
			stationName(key) ?: settingNames[key] ?: key.replaceFirstChar { it.uppercase() }
		}.ifEmpty { "Settings" }
}
