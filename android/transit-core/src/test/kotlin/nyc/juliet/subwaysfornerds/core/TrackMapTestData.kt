package nyc.juliet.subwaysfornerds.core

/** A two-station directed rail on the real page size, small enough to reason about by hand. */
internal object TrackMapTestData {
	const val NOW = 1_788_656_340.0
	val page = TrackMapPage(7344.0, 11540.6)
	val a = TrackMapPoint(100.0, 100.0)
	val b = TrackMapPoint(200.0, 100.0)
	val c = TrackMapPoint(200.0, 300.0)

	fun topology(
		schemaVersion: Int = TrackMapContract.SCHEMA_VERSION,
		mapVersion: String = TrackMapContract.MAP_VERSION,
		pdfSha256: String = TrackMapContract.PDF_SHA256,
		edges: List<TrackMapEdge> = listOf(TrackMapEdge("e1", "n:a", "n:c", listOf(a, b, c), bidirectional = false, revenue = true)),
		stations: List<TrackMapStation> = listOf(
			TrackMapStation("station:L01", "618", "L01", "8 Av", a, listOf("L01N", "L01S")),
			TrackMapStation("station:L02", "601", "L02", "6 Av", c, listOf("L02N", "L02S")),
		),
	) = TrackMapTopology(
		schemaVersion = schemaVersion, mapVersion = mapVersion, pdfSha256 = pdfSha256, page = page,
		attribution = "New York City Track Map by vanshnookenraggen, version 2.6.8.", sourceURL = "https://www.vanshnookenraggen.com/_index/docs/NYC_full_trackmap.pdf",
		stations = stations, nodes = listOf(TrackMapNode("n:a", a), TrackMapNode("n:c", c)), edges = edges,
		platforms = listOf(TrackMapPlatform("platform:a", "L01S", listOf("1"), "n:a"), TrackMapPlatform("platform:c", "L02S", listOf("1"), "n:c")),
		coverage = TrackMapTopologyCoverage(listOf("L01S", "L02S"), listOf("A01N"), listOf("PARTIAL")),
	)

	fun source(feed: String = "gtfs-l", timestamp: Double? = NOW - 10, error: String? = null) = SourceState(feed, timestamp, NOW - 5, error)

	/** A live train moving a → c, observed 10 s ago, with motion bounded at its stale time. */
	fun train(
		key: String = "gtfs-l|20260905|122300_L..S|",
		route: String = "L",
		observedAt: Double? = NOW - 10,
		feedTimestamp: Double = NOW - 10,
		freshness: TrackMapFreshness = TrackMapFreshness.LIVE,
		placement: TrackMapPlacement = TrackMapPlacement.TRACK,
		point: TrackMapPoint? = a,
		motion: TrackMapMotion? = TrackMapMotion(listOf("e1"), listOf(a, b, c), 0.0, 0.5, NOW, NOW + 60),
		trackBasis: TrackMapTrackBasis = TrackMapTrackBasis.INFERRED,
		positionBasis: TrackMapPositionBasis = TrackMapPositionBasis.ESTIMATED,
		feed: String = "gtfs-l",
	) = TrackMapTrain(
		key = key, feed = feed, route = route, destination = "Canarsie-Rockaway Pkwy", direction = "S",
		stopId = "L02S", stationId = "601", status = "IN_TRANSIT_TO", trackCode = "1",
		trackBasis = trackBasis, positionBasis = positionBasis, placement = placement,
		point = point, motion = motion, observedAt = observedAt, feedTimestamp = feedTimestamp,
		staleAt = observedAt?.plus(90), expiresAt = observedAt?.plus(300), freshness = freshness,
	)

	fun snapshot(
		trains: List<TrackMapTrain> = listOf(train()),
		mapVersion: String = TrackMapContract.MAP_VERSION,
		pdfSha256: String = TrackMapContract.PDF_SHA256,
		schemaVersion: Int = TrackMapContract.SCHEMA_VERSION,
		sources: List<SourceState> = listOf(source()),
	) = TrackMapSnapshot(schemaVersion, mapVersion, pdfSha256, NOW, sources, trains, TrackMapSnapshotCoverage(trains.count { it.placement == TrackMapPlacement.TRACK }, trains.count { it.placement == TrackMapPlacement.NEAR_STOP }, trains.count { it.placement == TrackMapPlacement.UNPLACED }))
}
