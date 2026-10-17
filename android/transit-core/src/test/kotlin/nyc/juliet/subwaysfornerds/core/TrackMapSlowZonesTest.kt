package nyc.juliet.subwaysfornerds.core

import org.junit.Assert.*
import org.junit.Test

class TrackMapSlowZonesTest {
	private val now = TrackMapTestData.NOW
	private val path = listOf(TrackMapTestData.a, TrackMapTestData.b, TrackMapTestData.c)
	private fun zone(id: String = "zone", routes: List<String> = listOf("L"), paths: List<List<TrackMapPoint>> = listOf(path)) = TrackMapSlowZone(
		id, routes, paths, "L01S", "L02S", "8 Av → 6 Av", "slow", "2026-09-01", "2026-09-05", 42.0, 90.0, 3,
	)
	private fun validated(zones: List<TrackMapSlowZone>) = TrackMapContract.validateSnapshot(
		TrackMapTestData.snapshot(trains = emptyList()).copy(slowZones = TrackMapSlowZones("2026-09-05", now + 30, zones, 2)), TrackMapTestData.topology(),
	).slowZones!!

	@Test fun olderSnapshotsDecodeWithoutSlowZones() {
		val raw = TransitJson.encodeToString(TrackMapSnapshot.serializer(), TrackMapTestData.snapshot())
		assertFalse(raw.contains("slowZones"))
		val decoded = TransitJson.decodeFromString(TrackMapSnapshot.serializer(), raw)
		assertNull(decoded.slowZones)
		assertTrue(TrackMapSlowZoneDisplay.active(decoded.slowZones, now).isEmpty())
	}

	@Test fun missingExpiryDecodesAsUnavailableWithoutLosingTrains() {
		val raw = TransitJson.encodeToString(TrackMapSnapshot.serializer(), TrackMapTestData.snapshot().copy(slowZones = TrackMapSlowZones(null, null, listOf(zone()), 0)))
		val decoded = TransitJson.decodeFromString(TrackMapSnapshot.serializer(), raw.replace("\"expiresAt\":null,", ""))
		assertEquals(1, decoded.trains.size)
		assertNull(decoded.slowZones!!.expiresAt)
		assertTrue(TrackMapSlowZoneDisplay.active(decoded.slowZones, now).isEmpty())
	}

	@Test fun envelopeRoundTripsAndPreservesUnknownKinds() {
		val snapshot = TrackMapTestData.snapshot().copy(slowZones = TrackMapSlowZones("2026-09-05", now + 30, listOf(zone().copy(kind = "future-kind")), 2))
		assertEquals(snapshot, TransitJson.decodeFromString(TrackMapSnapshot.serializer(), TransitJson.encodeToString(TrackMapSnapshot.serializer(), snapshot)))
	}

	@Test fun invalidPolylinesAreRejectedWholeWithoutClippingOrJoiningAcrossGaps() {
		val bad = listOf(emptyList(), listOf(path[0]), listOf(path[0], path[0]), listOf(path[0], TrackMapPoint(-1.0, 100.0)), listOf(path[0], TrackMapPoint(7344.1, 100.0)), listOf(path[0], TrackMapPoint(100.0, 11540.7)), listOf(path[0], TrackMapPoint(Double.NaN, 1.0)), listOf(path[0], TrackMapPoint(1.0, Double.POSITIVE_INFINITY)))
		val value = validated(listOf(zone(paths = bad + listOf(path))))
		assertEquals(listOf(path), value.zones.single().paths)
		assertEquals(2, value.unmappedCount)
		val unmapped = validated(listOf(zone(paths = bad)))
		assertTrue(unmapped.zones.single().paths.isEmpty())
		assertEquals(3, unmapped.unmappedCount)
	}

	@Test fun duplicateIDsAndInvalidEstimatesDoNotBecomeVisibleZones() {
		val value = validated(listOf(zone(), zone(), zone("bad").copy(extraSeconds = Double.NaN), zone("negative").copy(extraSeconds = -5.0), zone("blank").copy(id = "")))
		assertEquals(listOf("zone"), value.zones.map { it.id })
	}

	@Test fun expiryIsStrictEvenWithoutTrainsAndMissingExpiryFailsClosed() {
		val value = validated(listOf(zone()))
		assertEquals(1, TrackMapSlowZoneDisplay.active(value, now + 29.999).size)
		for (clock in listOf(now + 30, now + 300, Double.NaN)) assertTrue(TrackMapSlowZoneDisplay.active(value, clock).isEmpty())
		for (expiry in listOf(null, Double.NaN, Double.POSITIVE_INFINITY)) assertTrue(TrackMapSlowZoneDisplay.active(value.copy(expiresAt = expiry), now).isEmpty())
	}

	@Test fun routesFilterZonesIndependentlyAndUnknownRoutesAppearOnlyWithoutAFilter() {
		val value = validated(listOf(zone("L"), zone("Q", listOf("Q")), zone("unknown", emptyList())))
		assertEquals(listOf("L", "Q", "unknown"), TrackMapSlowZoneDisplay.active(value, now).map { it.id })
		assertEquals(listOf("Q"), TrackMapSlowZoneDisplay.active(value, now, setOf("Q")).map { it.id })
		assertTrue(TrackMapSlowZoneDisplay.active(value, now, setOf("A")).isEmpty())
	}

	@Test fun spokenDetailsIdentifySegmentTypicalDelayKindAndSource() {
		val detail = TrackMapSlowZoneDisplay.detail(zone().copy(kind = "disruption"))
		assertTrue(detail, detail.contains("Estimated major slowdown"))
		assertTrue(detail, detail.contains("8 Av → 6 Av"))
		assertTrue(detail, detail.contains("typically +42s"))
		assertTrue(detail, detail.contains("Transit Lab"))
		assertTrue(TrackMapSlowZoneDisplay.detail(zone(paths = emptyList())).contains("not highlighted"))
	}
}
