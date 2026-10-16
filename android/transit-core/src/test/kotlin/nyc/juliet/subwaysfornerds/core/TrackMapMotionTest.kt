package nyc.juliet.subwaysfornerds.core

import nyc.juliet.subwaysfornerds.core.TrackMapTestData.NOW
import nyc.juliet.subwaysfornerds.core.TrackMapTestData.a
import nyc.juliet.subwaysfornerds.core.TrackMapTestData.b
import nyc.juliet.subwaysfornerds.core.TrackMapTestData.c
import nyc.juliet.subwaysfornerds.core.TrackMapTestData.source
import nyc.juliet.subwaysfornerds.core.TrackMapTestData.train
import org.junit.Assert.*
import org.junit.Test
import kotlin.math.PI

class TrackMapMotionTest {
	private fun assertPoint(expected: TrackMapPoint, actual: TrackMapPoint?) {
		assertNotNull(actual); assertEquals(expected.x, actual!!.x, 1e-6); assertEquals(expected.y, actual.y, 1e-6)
	}

	@Test fun progressIsArcLengthAlongTheRealRailNotTheChord() {
		val path = TrackMapPolyline(listOf(a, b, c))
		assertEquals(300.0, path.length, 1e-9)
		assertPoint(TrackMapPoint(200.0, 150.0), path.pointAt(0.5))
		assertPoint(a, path.pointAt(-1.0)); assertPoint(c, path.pointAt(2.0))
		assertEquals(0.0, path.headingAt(0.1), 1e-9)
		assertEquals(PI / 2, path.headingAt(0.9), 1e-9)
		// A zero-length path never divides by zero or invents a direction.
		val point = TrackMapPolyline(listOf(a, a)); assertPoint(a, point.pointAt(0.5)); assertNull(point.headingOrNull(0.5))
	}

	@Test fun motionProgressIsClampedToTheServerWindow() {
		val motion = TrackMapMotion(listOf("e1"), listOf(a, b, c), 0.2, 0.6, NOW, NOW + 40)
		assertEquals(0.2, TrackMapMotionMath.progress(motion, NOW - 100), 1e-9)
		assertEquals(0.4, TrackMapMotionMath.progress(motion, NOW + 20), 1e-9)
		assertEquals(0.6, TrackMapMotionMath.progress(motion, NOW + 4000), 1e-9)
		assertEquals(0.2, TrackMapMotionMath.progress(motion.copy(endTime = NOW), NOW + 1), 1e-9)
	}

	@Test fun liveMotionAnimatesAlongTheRailWithItsHeading() {
		val now = NOW + 30
		val evidence = TrackMapEvidence.evaluate(train(), listOf(source()), now)
		assertEquals(TrackMapFreshness.LIVE, evidence.freshness)
		val shown = TrackMapMotionMath.display(train(), evidence, now, motionClock = now, reducedMotion = false)!!
		assertPoint(TrackMapPoint(175.0, 100.0), shown.point)
		assertTrue(shown.animating); assertEquals(0.0, shown.heading!!, 1e-9)
	}

	@Test fun reducedMotionShowsTheServerSampleWithoutExtrapolating() {
		val now = NOW + 30
		val shown = TrackMapMotionMath.display(train(), TrackMapEvidence.evaluate(train(), listOf(source()), now), now, now, reducedMotion = true)!!
		assertPoint(a, shown.point); assertFalse(shown.animating)
		assertEquals(0.0, shown.heading!!, 1e-9)
	}

	@Test fun offlineFreezesAtTheMomentTheConnectionDropped() {
		val now = NOW + 50
		val shown = TrackMapMotionMath.display(train(), TrackMapEvidence.evaluate(train(), listOf(source()), now), now, motionClock = NOW + 12, reducedMotion = false)!!
		assertPoint(TrackMapPoint(130.0, 100.0), shown.point); assertFalse(shown.animating)
	}

	@Test fun staleEvidenceStopsMotionAtTheStaleBoundNeverBeyondTheServerWindow() {
		// Observed 10 s ago: stale at NOW+80, motion ends at NOW+60 with progress 0.5.
		val now = NOW + 85
		val evidence = TrackMapEvidence.evaluate(train(), listOf(source()), now)
		assertEquals(TrackMapFreshness.STALE, evidence.freshness)
		val shown = TrackMapMotionMath.display(train(), evidence, now, now, reducedMotion = false)!!
		assertPoint(TrackMapPoint(200.0, 150.0), shown.point); assertFalse(shown.animating)
		// A motion window the server bounded later than stale time is still cut at stale time.
		val long = train(motion = TrackMapMotion(listOf("e1"), listOf(a, b, c), 0.0, 1.0, NOW, NOW + 200))
		val cut = TrackMapMotionMath.display(long, TrackMapEvidence.evaluate(long, listOf(source()), NOW + 150), NOW + 150, NOW + 150, false)!!
		assertPoint(TrackMapPoint(200.0, 100.0 + (80.0 / 200 * 300 - 100)), cut.point)
	}

	@Test fun expiredEvidenceIsNotPlottedEvenFromACachedSnapshot() {
		val now = NOW + 290
		assertEquals(TrackMapFreshness.UNAVAILABLE, TrackMapEvidence.evaluate(train(), listOf(source()), now).freshness)
		assertNull(TrackMapMotionMath.display(train(), TrackMapEvidence.evaluate(train(), listOf(source()), now), now, now, false))
	}

	@Test fun evidenceUsesOriginalVehicleAndSourceTimesNeverTheReadTime() {
		// A snapshot generated or read just now cannot refresh a 100 s old vehicle observation.
		val old = train(observedAt = NOW - 100, feedTimestamp = NOW - 1)
		assertEquals(TrackMapFreshness.STALE, TrackMapEvidence.evaluate(old, listOf(source(timestamp = NOW - 1)), NOW).freshness)
		// The oldest of vehicle, feed and source clocks decides.
		assertEquals(TrackMapFreshness.STALE, TrackMapEvidence.evaluate(train(), listOf(source(timestamp = NOW - 95)), NOW).freshness)
		assertEquals(NOW - 95 + 90, TrackMapEvidence.evaluate(train(), listOf(source(timestamp = NOW - 95)), NOW).staleAt!!, 1e-9)
		// Source health: an erroring source is never live; a missing source clock is unavailable.
		assertEquals(TrackMapFreshness.STALE, TrackMapEvidence.evaluate(train(), listOf(source(error = "HTTP 503")), NOW).freshness)
		assertEquals(TrackMapFreshness.UNAVAILABLE, TrackMapEvidence.evaluate(train(), listOf(source(timestamp = null)), NOW).freshness)
		assertEquals(TrackMapFreshness.UNAVAILABLE, TrackMapEvidence.evaluate(train(), emptyList(), NOW).freshness)
		assertEquals(TrackMapFreshness.UNAVAILABLE, TrackMapEvidence.evaluate(train(observedAt = null), listOf(source()), NOW).freshness)
		// The server's own verdict is never upgraded.
		assertEquals(TrackMapFreshness.STALE, TrackMapEvidence.evaluate(train(freshness = TrackMapFreshness.STALE), listOf(source()), NOW).freshness)
		assertEquals(TrackMapFreshness.UNAVAILABLE, TrackMapEvidence.evaluate(train(freshness = TrackMapFreshness.UNAVAILABLE), listOf(source()), NOW).freshness)
	}

	@Test fun evidenceFromTheFutureIsNotTrustedBeyondASmallClockSkew() {
		// Both native clients allow at most five seconds of device/server clock skew.
		val skew = 5.0
		assertEquals(TrackMapFreshness.LIVE, TrackMapEvidence.evaluate(train(observedAt = NOW + skew, feedTimestamp = NOW + skew), listOf(source(timestamp = NOW + skew)), NOW).freshness)
		assertEquals(TrackMapFreshness.UNAVAILABLE, TrackMapEvidence.evaluate(train(observedAt = NOW + 6), listOf(source()), NOW).freshness)
		assertEquals(TrackMapFreshness.UNAVAILABLE, TrackMapEvidence.evaluate(train(feedTimestamp = NOW + 6), listOf(source()), NOW).freshness)
		assertEquals(TrackMapFreshness.UNAVAILABLE, TrackMapEvidence.evaluate(train(), listOf(source(timestamp = NOW + 6)), NOW).freshness)
		for (bad in listOf(Double.NaN, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY)) {
			val state = TrackMapEvidence.evaluate(train(), listOf(source()), bad)
			assertEquals(TrackMapFreshness.UNAVAILABLE, state.freshness)
			assertNull(TrackMapMotionMath.display(train(), state, bad, bad, false))
		}
	}

	@Test fun aSourceErrorHoldsTheServerSampleInsteadOfMovingAlongStaleMotion() {
		val failing = listOf(source(error = "HTTP 503"))
		val first = TrackMapMotionMath.display(train(), TrackMapEvidence.evaluate(train(), failing, NOW + 5), NOW + 5, NOW + 5, false)!!
		val later = TrackMapMotionMath.display(train(), TrackMapEvidence.evaluate(train(), failing, NOW + 20), NOW + 20, NOW + 20, false)!!
		assertPoint(a, first.point); assertPoint(a, later.point)
		assertFalse(first.animating); assertFalse(later.animating)
		assertEquals(0.0, later.heading!!, 1e-9)
		// Ordinary age staleness without an error still clamps at the original stale time, as before.
		val aged = TrackMapMotionMath.display(train(), TrackMapEvidence.evaluate(train(), listOf(source()), NOW + 85), NOW + 85, NOW + 85, false)!!
		assertPoint(TrackMapPoint(200.0, 150.0), aged.point)
	}

	@Test fun nearStopTrainsAreShownAtTheStationWithoutHeading() {
		val near = train(placement = TrackMapPlacement.NEAR_STOP, point = c, motion = null, trackBasis = TrackMapTrackBasis.UNKNOWN, positionBasis = TrackMapPositionBasis.UNKNOWN)
		val shown = TrackMapMotionMath.display(near, TrackMapEvidence.evaluate(near, listOf(source()), NOW), NOW, NOW, false)!!
		assertPoint(c, shown.point); assertNull(shown.heading); assertFalse(shown.animating)
		assertNull(TrackMapMotionMath.display(train(placement = TrackMapPlacement.UNPLACED, point = null, motion = null), TrackMapEvidence.evaluate(train(), listOf(source()), NOW), NOW, NOW, false))
	}

	@Test fun certaintyTextKeepsTrackAndPositionSeparate() {
		val reported = train(trackBasis = TrackMapTrackBasis.REPORTED, positionBasis = TrackMapPositionBasis.ESTIMATED)
		val track = TrackMapCertainty.track(reported); val position = TrackMapCertainty.position(reported)
		assertEquals("Track 1 reported", track); assertEquals("Position estimated", position)
		assertNotEquals(track, position)
		val near = train(placement = TrackMapPlacement.NEAR_STOP, trackBasis = TrackMapTrackBasis.UNKNOWN, positionBasis = TrackMapPositionBasis.UNKNOWN)
		assertEquals("Track unknown", TrackMapCertainty.track(near)); assertEquals("Position unknown · shown near station", TrackMapCertainty.position(near))
		assertEquals("Track from schedule", TrackMapCertainty.track(train(trackBasis = TrackMapTrackBasis.SCHEDULED).copy(trackCode = null)))
		assertEquals("Track inferred", TrackMapCertainty.track(train(trackBasis = TrackMapTrackBasis.INFERRED).copy(trackCode = null)))
	}

	@Test fun stoppedTrainAtACornerFacesAlongTheRailItArrivedOnLikeItsBody() {
		val path = TrackMapPolyline(listOf(a, b, c))
		// At the corner b the arrow follows a → b, the segment the body trails along, never the one ahead.
		assertEquals(0.0, path.headingAt(100.0 / 300), 1e-9)
		assertEquals(0.0, path.headingAt(0.0), 1e-9)
		assertEquals(PI / 2, path.headingAt(1.0), 1e-9)
		// A zero-length segment at the corner never decides the direction.
		val doubled = TrackMapPolyline(listOf(a, b, b, c))
		assertEquals(0.0, doubled.headingAt(100.0 / 300), 1e-9)
		val stopped = train(motion = TrackMapMotion(listOf("e1"), listOf(a, b, c), 1.0 / 3, 1.0 / 3, NOW - 20, NOW - 10))
		val shown = TrackMapMotionMath.display(stopped, TrackMapEvidence.evaluate(stopped, listOf(source()), NOW), NOW, NOW, false)!!
		assertPoint(b, shown.point); assertEquals(0.0, shown.heading!!, 1e-9); assertFalse(shown.animating)
	}

	@Test fun motionRunningBackwardsIsNeverDrawn() {
		// validateSnapshot drops it; display also refuses to interpolate it if one reaches it.
		val backwards = train(motion = TrackMapMotion(listOf("e1"), listOf(a, b, c), 0.6, 0.2, NOW, NOW + 40))
		val shown = TrackMapMotionMath.display(backwards, TrackMapEvidence.evaluate(backwards, listOf(source()), NOW + 20), NOW + 20, NOW + 20, false)!!
		assertPoint(a, shown.point); assertNull(shown.path); assertNull(shown.heading); assertFalse(shown.animating)
	}

	@Test fun trainBodyFollowsTheRailBehindTheHead() {
		val path = TrackMapPolyline(listOf(a, b, c))
		// Head 30 points past the corner; a 50 point body bends around it.
		val body = path.trail(130.0, 50.0)
		assertPoint(TrackMapPoint(180.0, 100.0), body.first()); assertPoint(b, body[1]); assertPoint(TrackMapPoint(200.0, 130.0), body.last())
		// Never extends before the start of known rail.
		assertPoint(a, path.trail(10.0, 50.0).first())
	}
}
