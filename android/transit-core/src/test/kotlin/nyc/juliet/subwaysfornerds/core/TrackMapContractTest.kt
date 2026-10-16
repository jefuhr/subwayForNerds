package nyc.juliet.subwaysfornerds.core

import kotlinx.serialization.json.*
import nyc.juliet.subwaysfornerds.core.TrackMapTestData.NOW
import nyc.juliet.subwaysfornerds.core.TrackMapTestData.a
import nyc.juliet.subwaysfornerds.core.TrackMapTestData.snapshot
import nyc.juliet.subwaysfornerds.core.TrackMapTestData.topology
import nyc.juliet.subwaysfornerds.core.TrackMapTestData.train
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File

class TrackMapContractTest {
	private val sharedTopology = File("../../data/track-map/nyc-2.6.8-v1.json")

	@Test fun theReviewedTopologyDecodesAndValidatesAgainstTheFrozenContract() {
		assumeTrue("Coordinator topology dependency ${sharedTopology.path} is not present", sharedTopology.exists())
		val decoded = TransitJson.decodeFromString(TrackMapTopology.serializer(), sharedTopology.readText())
		val valid = TrackMapContract.validateTopology(decoded, pdfSha256 = TrackMapContract.PDF_SHA256)
		assertEquals("nyc-2.6.8-v1", valid.mapVersion)
		assertEquals(7344.0, valid.page.width, 0.0); assertEquals(11540.6, valid.page.height, 0.0)
		assertTrue(valid.stations.isNotEmpty() && valid.edges.isNotEmpty())
		// Every coordinate is already top-left PDF points inside the crop box.
		assertTrue(valid.stations.all { it.point.x in 0.0..valid.page.width && it.point.y in 0.0..valid.page.height })
	}

	@Test fun topologyRejectsSchemaVersionAndArtworkMismatchBeforeAnythingIsPlotted() {
		assertThrows(TrackMapContractException.Schema::class.java) { TrackMapContract.validateTopology(topology(schemaVersion = 2), TrackMapContract.PDF_SHA256) }
		assertThrows(TrackMapContractException.MapVersion::class.java) { TrackMapContract.validateTopology(topology(mapVersion = "nyc-2.6.9-v1"), TrackMapContract.PDF_SHA256) }
		assertThrows(TrackMapContractException.Artwork::class.java) { TrackMapContract.validateTopology(topology(pdfSha256 = "0".repeat(64)), TrackMapContract.PDF_SHA256) }
		// The bundled PDF's own digest must match too; a matching JSON with other artwork is still rejected.
		assertThrows(TrackMapContractException.Artwork::class.java) { TrackMapContract.validateTopology(topology(), "f".repeat(64)) }
		assertThrows(TrackMapContractException.Artwork::class.java) { TrackMapContract.validateTopology(topology(), null) }
	}

	@Test fun topologyGeometryOutsideThePageOrDetachedFromNodesIsRejectedNotRepaired() {
		val bottomLeft = TrackMapStation("station:X", "1", "X", "Flipped", TrackMapPoint(100.0, -5.0), listOf("X"))
		assertThrows(TrackMapContractException.Geometry::class.java) { TrackMapContract.validateTopology(topology(stations = listOf(bottomLeft)), TrackMapContract.PDF_SHA256) }
		val detached = TrackMapEdge("e1", "n:a", "n:c", listOf(TrackMapPoint(101.0, 100.0), TrackMapTestData.c), false, true)
		assertThrows(TrackMapContractException.Geometry::class.java) { TrackMapContract.validateTopology(topology(edges = listOf(detached)), TrackMapContract.PDF_SHA256) }
		val nan = TrackMapEdge("e1", "n:a", "n:c", listOf(a, TrackMapPoint(Double.NaN, 1.0), TrackMapTestData.c), false, true)
		assertThrows(TrackMapContractException.Geometry::class.java) { TrackMapContract.validateTopology(topology(edges = listOf(nan)), TrackMapContract.PDF_SHA256) }
	}

	@Test fun snapshotsForAnotherSchemaMapOrArtworkAreRejected() {
		val valid = TrackMapContract.validateTopology(topology(), TrackMapContract.PDF_SHA256)
		assertEquals(1, TrackMapContract.validateSnapshot(snapshot(), valid).trains.size)
		assertThrows(TrackMapContractException.Schema::class.java) { TrackMapContract.validateSnapshot(snapshot(schemaVersion = 2), valid) }
		assertThrows(TrackMapContractException.MapVersion::class.java) { TrackMapContract.validateSnapshot(snapshot(mapVersion = "nyc-2.6.8-v2"), valid) }
		assertThrows(TrackMapContractException.Artwork::class.java) { TrackMapContract.validateSnapshot(snapshot(pdfSha256 = "1".repeat(64)), valid) }
	}

	@Test fun aRailWithNoLengthIsRejectedEvenWhenBothEndpointsMatch() {
		val collapsed = TrackMapEdge("zero", "n:a", "n:a", listOf(a, a), false, true)
		assertThrows(TrackMapContractException.Geometry::class.java) {
			TrackMapContract.validateTopology(topology(edges = listOf(collapsed)), TrackMapContract.PDF_SHA256)
		}
	}

	@Test fun invalidTrainGeometryIsUnplacedWithoutDroppingTheRestOfTheSnapshot() {
		val valid = TrackMapContract.validateTopology(topology(), TrackMapContract.PDF_SHA256)
		val outside = train(key = "outside", point = TrackMapPoint(8000.0, 10.0), motion = null)
		val badMotion = train(key = "motion", motion = TrackMapMotion(listOf("e1"), listOf(a, TrackMapTestData.c), 0.7, 0.2, NOW, NOW + 10))
		val inverted = train(key = "time", motion = TrackMapMotion(listOf("e1"), listOf(a, TrackMapTestData.c), 0.0, 0.5, NOW + 10, NOW))
		val result = TrackMapContract.validateSnapshot(snapshot(listOf(outside, badMotion, inverted, train(key = "ok"))), valid).trains.associateBy { it.key }
		assertEquals(TrackMapPlacement.UNPLACED, result.getValue("outside").placement); assertNull(result.getValue("outside").point)
		assertNull(result.getValue("motion").motion); assertNotNull(result.getValue("motion").point)
		assertNull(result.getValue("time").motion)
		assertNotNull(result.getValue("ok").motion)
		// Duplicate opaque keys cannot both be plotted or addressed.
		assertEquals(1, TrackMapContract.validateSnapshot(snapshot(listOf(train(key = "k"), train(key = "k"))), valid).trains.size)
	}

	@Test fun motionAlongRailTheInstalledMapDoesNotHaveIsRefused() {
		val yard = TrackMapEdge("yard", "n:c", "n:a", listOf(TrackMapTestData.c, a), bidirectional = false, revenue = false)
		val valid = TrackMapContract.validateTopology(topology(edges = topology().edges + yard), TrackMapContract.PDF_SHA256)
		fun along(vararg ids: String) = train(key = ids.joinToString("+").ifEmpty { "none" }, motion = TrackMapMotion(ids.toList(), listOf(a, TrackMapTestData.b, TrackMapTestData.c), 0.0, 0.5, NOW, NOW + 60))
		val result = TrackMapContract.validateSnapshot(snapshot(listOf(along("e1"), along("e9"), along("e1", "e9"), along("yard"), along())), valid).trains.associateBy { it.key }
		assertNotNull(result.getValue("e1").motion)
		// Unknown, non-revenue or missing rail: the sampled point stays, the arbitrary in-bounds path does not.
		for (key in listOf("e9", "e1+e9", "yard", "none")) {
			assertNull(key, result.getValue(key).motion); assertEquals(key, a, result.getValue(key).point)
		}
	}

	@Test fun snapshotJsonMirrorsTheSharedContractIncludingRequiredNulls() {
		val raw = """{"schemaVersion":1,"mapVersion":"nyc-2.6.8-v1","pdfSha256":"${TrackMapContract.PDF_SHA256}","generatedAt":$NOW,
			"sources":[{"id":"gtfs-l","timestamp":${NOW - 3},"fetchedAt":${NOW - 2},"error":null}],
			"trains":[{"key":"gtfs-l|20260905|1|","feed":"gtfs-l","route":"L","destination":"8 Av","direction":"N","trackBasis":"unknown","positionBasis":"unknown","placement":"unplaced","observedAt":null,"feedTimestamp":0,"staleAt":null,"expiresAt":null,"freshness":"unavailable","reason":"No vehicle observation"},
			{"key":"k2","feed":"gtfs-l","route":"L","destination":"Canarsie","direction":"S","stopId":"L02S","stationId":"601","status":"STOPPED_AT","trackCode":"1","trackBasis":"reported","positionBasis":"reported","placement":"track","point":{"x":200,"y":300},"observedAt":${NOW - 4},"feedTimestamp":${NOW - 4},"staleAt":${NOW + 86},"expiresAt":${NOW + 296},"freshness":"live","futureField":true}],
			"coverage":{"placed":1,"uncertain":0,"unplaced":1}}"""
		val decoded = TransitJson.decodeFromString(TrackMapSnapshot.serializer(), raw)
		assertEquals(TrackMapFreshness.UNAVAILABLE, decoded.trains[0].freshness); assertNull(decoded.trains[0].observedAt)
		assertEquals(TrackMapTrackBasis.REPORTED, decoded.trains[1].trackBasis); assertEquals(TrackMapPositionBasis.REPORTED, decoded.trains[1].positionBasis)
		val encoded = TransitJson.encodeToJsonElement(TrackMapTrain.serializer(), decoded.trains[0]).jsonObject
		assertEquals(JsonNull, encoded["observedAt"]); assertEquals(JsonNull, encoded["staleAt"]); assertFalse(encoded.containsKey("point"))
		// An unknown certainty is not silently mapped to a known one.
		assertThrows(Exception::class.java) { TransitJson.decodeFromString(TrackMapSnapshot.serializer(), raw.replace("\"reported\",\"positionBasis\"", "\"guessed\",\"positionBasis\"")) }
	}

	@Test fun pdfNativeBottomLeftCoordinatesConvertToTheTopLeftContract() {
		val page = TrackMapTestData.page
		assertEquals(TrackMapPoint(10.0, 11540.6 - 20.0), TrackMapCoordinates.fromPdfNative(10.0, 20.0, page))
		assertEquals(TrackMapPoint(0.0, 0.0), TrackMapCoordinates.fromPdfNative(0.0, 11540.6, page))
		val round = TrackMapCoordinates.toPdfNative(TrackMapPoint(1279.5367, 5997.2525), page)
		assertEquals(1279.5367, round.x, 1e-9); assertEquals(11540.6 - 5997.2525, round.y, 1e-9)
	}
}
