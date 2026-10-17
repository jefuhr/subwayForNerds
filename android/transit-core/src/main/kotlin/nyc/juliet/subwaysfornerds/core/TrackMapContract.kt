package nyc.juliet.subwaysfornerds.core

import kotlin.math.abs

/** Why a topology or snapshot cannot be drawn on the bundled artwork. Nothing is plotted after one of these. */
sealed class TrackMapContractException(message: String) : Exception(message) {
	class Schema(found: Int) : TrackMapContractException("Track map schema $found is not supported by this app.")
	class MapVersion(expected: String, found: String) : TrackMapContractException("Track map version $found does not match the installed map $expected.")
	class Artwork : TrackMapContractException("Track map artwork does not match the reviewed map data.")
	class Geometry(detail: String) : TrackMapContractException("Track map geometry is invalid: $detail.")
}

/** The frozen map contract this build was reviewed against. */
object TrackMapContract {
	const val SCHEMA_VERSION = 1
	const val MAP_VERSION = "nyc-2.6.8-v1"
	const val PDF_SHA256 = "b28f75397b2e7b6ba0b67db6ea2181800baa0254a48261252f3d55c4f2b17c71"
	val PAGE = TrackMapPage(7344.0, 11540.6)
	/** Evidence windows, from the original vehicle, feed and source clocks. */
	const val LIVE_SECONDS = 90.0
	const val EXPIRE_SECONDS = 300.0
	/** Evidence stamped further than this ahead of the device clock is not trusted. */
	const val CLOCK_SKEW_SECONDS = 5.0
	/** Snapshots are requested this often, only while the map is visible and the app is in the foreground. */
	const val POLL_MILLIS = 15_000L

	/**
	 * Accepts reviewed topology only for this contract, and only when [pdfSha256], the bundled artwork's own
	 * digest, matches it. Geometry is never repaired: a point off the page or an edge detached from its nodes
	 * means the data was produced for different coordinates.
	 */
	fun validateTopology(topology: TrackMapTopology, pdfSha256: String?): TrackMapTopology {
		if (topology.schemaVersion != SCHEMA_VERSION) throw TrackMapContractException.Schema(topology.schemaVersion)
		if (topology.mapVersion != MAP_VERSION) throw TrackMapContractException.MapVersion(MAP_VERSION, topology.mapVersion)
		if (!topology.pdfSha256.equals(PDF_SHA256, ignoreCase = true) || pdfSha256 == null || !pdfSha256.equals(PDF_SHA256, ignoreCase = true)) throw TrackMapContractException.Artwork()
		val page = topology.page
		if (abs(page.width - PAGE.width) > 0.01 || abs(page.height - PAGE.height) > 0.01) throw TrackMapContractException.Geometry("page size ${page.width} x ${page.height}")
		val nodes = HashMap<String, TrackMapPoint>()
		for (node in topology.nodes) {
			if (!page.contains(node.point)) throw TrackMapContractException.Geometry("node ${node.id} is outside the page")
			if (nodes.put(node.id, node.point) != null) throw TrackMapContractException.Geometry("duplicate node ${node.id}")
		}
		for (station in topology.stations) if (!page.contains(station.point)) throw TrackMapContractException.Geometry("station ${station.id} is outside the page")
		for (edge in topology.edges) {
			val from = nodes[edge.from]; val to = nodes[edge.to]
			if (from == null || to == null) throw TrackMapContractException.Geometry("edge ${edge.id} references a missing node")
			if (edge.points.size < 2 || !edge.points.all(page::contains)) throw TrackMapContractException.Geometry("edge ${edge.id} has points outside the page")
			if (edge.points.first() != from || edge.points.last() != to) throw TrackMapContractException.Geometry("edge ${edge.id} is detached from its nodes")
			if (edge.points.all { it == edge.points.first() }) throw TrackMapContractException.Geometry("edge ${edge.id} has no length")
		}
		for (platform in topology.platforms) if (platform.nodeId !in nodes) throw TrackMapContractException.Geometry("platform ${platform.id} references a missing node")
		return topology
	}

	/**
	 * Rejects a snapshot made for another schema, map or artwork. Individual rows with geometry outside the
	 * page lose their marker (and any motion) instead of being moved; rows sharing an opaque key keep the first.
	 */
	fun validateSnapshot(snapshot: TrackMapSnapshot, topology: TrackMapTopology): TrackMapSnapshot {
		if (snapshot.schemaVersion != SCHEMA_VERSION) throw TrackMapContractException.Schema(snapshot.schemaVersion)
		if (snapshot.mapVersion != topology.mapVersion) throw TrackMapContractException.MapVersion(topology.mapVersion, snapshot.mapVersion)
		if (!snapshot.pdfSha256.equals(topology.pdfSha256, ignoreCase = true)) throw TrackMapContractException.Artwork()
		val page = topology.page
		val revenue = topology.edges.filter { it.revenue }.mapTo(HashSet()) { it.id }
		val seen = HashSet<String>()
		val trains = snapshot.trains.filter { seen.add(it.key) }.map { train ->
			val point = train.point
			if (point != null && !page.contains(point)) {
				train.copy(point = null, motion = null, placement = TrackMapPlacement.UNPLACED, reason = "Position outside the installed map was not drawn")
			} else if (train.motion != null && !validMotion(train.motion, page, revenue)) train.copy(motion = null)
			else train
		}
		return snapshot.copy(trains = trains, slowZones = snapshot.slowZones?.let { TrackMapSlowZoneDisplay.validate(it, page) })
	}

	/** Motion must run forward, inside the page and its window, along revenue rail the installed map has. */
	private fun validMotion(motion: TrackMapMotion, page: TrackMapPage, revenue: Set<String>): Boolean =
		motion.edgeIds.isNotEmpty() && motion.edgeIds.all(revenue::contains) && motion.points.size >= 2 && motion.points.all(page::contains) &&
			motion.fromProgress.isFinite() && motion.toProgress.isFinite() && motion.fromProgress in 0.0..1.0 && motion.toProgress in 0.0..1.0 &&
			motion.fromProgress <= motion.toProgress && motion.startTime.isFinite() && motion.endTime.isFinite() && motion.endTime > motion.startTime
}

/** The PDF's native user space has its origin at the bottom left; the contract's is the top left of the crop box. */
object TrackMapCoordinates {
	fun fromPdfNative(x: Double, y: Double, page: TrackMapPage): TrackMapPoint = TrackMapPoint(x, page.height - y)
	fun toPdfNative(point: TrackMapPoint, page: TrackMapPage): TrackMapPoint = TrackMapPoint(point.x, page.height - point.y)
}
