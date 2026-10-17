package nyc.juliet.subwaysfornerds.core

/** Shared validation and rider wording; estimates are never promoted to live train evidence. */
object TrackMapSlowZoneDisplay {
	fun validate(value: TrackMapSlowZones, page: TrackMapPage): TrackMapSlowZones {
		val seen = HashSet<String>()
		var rejectedGeometry = 0
		val zones = value.zones.filter { zone ->
			zone.id.isNotBlank() && zone.segment.isNotBlank() && zone.extraSeconds.isFinite() && zone.extraSeconds >= 0 &&
				zone.baselineSeconds.isFinite() && zone.baselineSeconds > 0 && zone.slowDays >= 0 && seen.add(zone.id)
		}.map { zone ->
			// Reject an entire bad path. Filtering individual points would invent a straight line across a gap.
			val paths = zone.paths.filter { path -> path.size >= 2 && path.all(page::contains) && path.any { it != path.first() } }
			if (zone.paths.isNotEmpty() && paths.isEmpty()) rejectedGeometry += 1
			zone.copy(paths = paths, routes = zone.routes.filter { it.isNotBlank() }.distinct())
		}
		return value.copy(zones = zones, unmappedCount = (value.unmappedCount.coerceAtLeast(0).toLong() + rejectedGeometry).coerceAtMost(Int.MAX_VALUE.toLong()).toInt())
	}

	/** No known expiry means no active claim. A cached response can never extend this deadline. */
	fun isActive(value: TrackMapSlowZones?, now: Double): Boolean {
		val expires = value?.expiresAt ?: return false
		return now.isFinite() && expires.isFinite() && now < expires
	}

	fun active(value: TrackMapSlowZones?, now: Double, routes: Set<String> = emptySet()): List<TrackMapSlowZone> =
		if (!isActive(value, now)) emptyList() else value!!.zones.filter { zone -> routes.isEmpty() || zone.routes.any(routes::contains) }

	fun detail(zone: TrackMapSlowZone): String =
		"Estimated ${SlowZoneDisplay.label(zone)}: ${zone.segment}, typically +${SlowZoneDisplay.seconds(zone.extraSeconds)} on a ${SlowZoneDisplay.seconds(zone.baselineSeconds)} run. " +
			"Since ${SlowZoneDisplay.date(zone.since)}, through ${SlowZoneDisplay.date(zone.through)}. Source: Transit Lab (transitlab.nyc, CC BY 4.0)." +
			if (zone.paths.isEmpty()) " Location not highlighted: no reviewed map geometry." else ""
}
