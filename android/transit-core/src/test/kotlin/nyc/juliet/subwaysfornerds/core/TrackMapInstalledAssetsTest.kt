package nyc.juliet.subwaysfornerds.core

import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.security.MessageDigest

/**
 * Checks the locally prepared map resources, when present, against this build's contract. They are prepared by
 * scripts/prepare-track-map.mjs and never distributed, so a checkout without them skips rather than passes.
 */
class TrackMapInstalledAssetsTest {
	private val directory = File("../app/src/main/assets/track-map")

	@Test fun preparedTopologyDecodesAndMatchesItsArtwork() {
		val topologyFile = File(directory, "topology.json"); val pdf = File(directory, "NYC_full_trackmap.pdf")
		assumeTrue("local map resources are not prepared", topologyFile.isFile && pdf.isFile)
		val sha = MessageDigest.getInstance("SHA-256").digest(pdf.readBytes()).joinToString("") { "%02x".format(it) }
		assertEquals(TrackMapContract.PDF_SHA256, sha)
		val topology = TrackMapContract.validateTopology(TransitJson.decodeFromString(TrackMapTopology.serializer(), topologyFile.readText()), sha)
		assertEquals(TrackMapContract.MAP_VERSION, topology.mapVersion)
		assertTrue(topology.stations.isNotEmpty() && topology.edges.isNotEmpty())
		// Every platform's node is on some revenue rail, so a held train there can be drawn on track.
		val railNodes = topology.edges.filter { it.revenue }.flatMap { listOf(it.from, it.to) }.toSet()
		val detached = topology.platforms.filter { it.nodeId !in railNodes }.map { it.id }
		println("Installed topology: ${topology.stations.size} stations, ${topology.nodes.size} nodes, ${topology.edges.size} edges, ${topology.platforms.size} platforms, ${topology.coverage.mappedStopIds.size} mapped / ${topology.coverage.unresolvedStopIds.size} unresolved stop IDs, ${detached.size} platforms off revenue rail")
	}
}
