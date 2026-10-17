import CoreGraphics
import Foundation
import Testing
@testable import TransitCore

/// Failure modes: progress measured by vertex count instead of arc length, motion
/// extrapolated past its window or past freshness, frozen or reduced-motion estimates
/// that still move, markers outliving their oldest evidence because a cache was read
/// recently, evidence from the future, and track and position certainty collapsing
/// into one label.
struct TrackMapMotionTests {
	private func close(_ a: TrackMapPoint?, _ b: TrackMapPoint, _ tolerance: Double = 1e-6) -> Bool {
		guard let a else { return false }
		return abs(a.x - b.x) < tolerance && abs(a.y - b.y) < tolerance
	}
	private func live(_ now: TimeInterval) -> TrackMapConditions { TrackMapConditions(now: now) }

	// MARK: Arc length

	@Test func samplesByArcLengthNotVertexCount() {
		// Uneven segments: 10 down, then 30 across. Vertex-count sampling would put 0.5 at the corner.
		let line = TrackMapPolyline([TrackMapPoint(x: 0, y: 0), TrackMapPoint(x: 0, y: 10), TrackMapPoint(x: 30, y: 10)])
		#expect(line.length == 40)
		#expect(close(line.sample(0.5).point, TrackMapPoint(x: 10, y: 10)))
		#expect(close(line.sample(0.125).point, TrackMapPoint(x: 0, y: 5)))
		// Headings are in top-left map space: +y points down the page.
		#expect(abs((line.sample(0.125).heading ?? 0) - Double.pi / 2) < 1e-9)
		#expect(abs(line.sample(0.5).heading ?? 1) < 1e-9)
	}

	@Test func clampsProgressToTheLine() {
		let line = TrackMapPolyline([TrackMapPoint(x: 0, y: 0), TrackMapPoint(x: 10, y: 0)])
		#expect(close(line.sample(-0.5).point, TrackMapPoint(x: 0, y: 0)))
		#expect(close(line.sample(7).point, TrackMapPoint(x: 10, y: 0)))
		#expect(close(line.sample(.nan).point, TrackMapPoint(x: 0, y: 0)))
	}

	@Test func degenerateLinesHaveNoHeading() {
		let line = TrackMapPolyline([TrackMapPoint(x: 5, y: 5), TrackMapPoint(x: 5, y: 5)])
		#expect(line.length == 0)
		#expect(close(line.sample(0.5).point, TrackMapPoint(x: 5, y: 5)))
		#expect(line.sample(0.5).heading == nil)
		// Zero-length segments inside a line are skipped for heading.
		let repeated = TrackMapPolyline([TrackMapPoint(x: 0, y: 0), TrackMapPoint(x: 0, y: 0), TrackMapPoint(x: 10, y: 0)])
		#expect(abs(repeated.sample(0).heading ?? 1) < 1e-9)
	}

	@Test func motionProgressIsClampedToItsTimeWindow() {
		var motion = TrackMapFixture.motion
		motion.fromProgress = 0.2; motion.toProgress = 0.6
		#expect(TrackMapMotionMath.progress(motion, at: 900) == 0.2)
		#expect(TrackMapMotionMath.progress(motion, at: 1000) == 0.2)
		#expect(abs(TrackMapMotionMath.progress(motion, at: 1050) - 0.4) < 1e-9)
		#expect(TrackMapMotionMath.progress(motion, at: 1100) == 0.6)
		#expect(TrackMapMotionMath.progress(motion, at: 5000) == 0.6)
		motion.endTime = motion.startTime
		#expect(TrackMapMotionMath.progress(motion, at: 999) == 0.2)
		#expect(TrackMapMotionMath.progress(motion, at: 1000) == 0.6)
	}

	// MARK: Live motion

	@Test func liveTrainsMoveAlongTheirTrackAtTheCurrentTime() throws {
		let state = TrackMapPresenter.state(for: TrackMapFixture.train(), in: try TrackMapFixture.accepted(), conditions: live(1025))
		#expect(state.isPlotted)
		#expect(state.freshness == .live)
		#expect(state.animating)
		#expect(close(state.point, TrackMapPoint(x: 100, y: 600)))
		#expect(abs((state.heading ?? 0) - Double.pi / 2) < 1e-9)
		let later = TrackMapPresenter.state(for: TrackMapFixture.train(), in: try TrackMapFixture.accepted(), conditions: live(1075))
		#expect(close(later.point, TrackMapPoint(x: 600, y: 1100)))
		#expect(abs(later.heading ?? 1) < 1e-9)
	}

	@Test func motionNeverProjectsPastFreshness() throws {
		// The fixture's motion window runs past staleAt (1080); the marker stops there.
		let state = TrackMapPresenter.state(for: TrackMapFixture.train(), in: try TrackMapFixture.accepted(), conditions: live(1095))
		#expect(state.freshness == .stale)
		#expect(!state.animating)
		#expect(close(state.point, TrackMapPoint(x: 700, y: 1100)))
		let much = TrackMapPresenter.state(for: TrackMapFixture.train(), in: try TrackMapFixture.accepted(), conditions: live(1250))
		#expect(close(much.point, TrackMapPoint(x: 700, y: 1100)))
	}

	@Test func motionStopsAtTheEndOfItsWindow() throws {
		// Fresh evidence at 1080 keeps the train live until 1170, past its motion window.
		let train = TrackMapFixture.train(observedAt: 1080, feedTimestamp: 1080, staleAt: 1170, expiresAt: 1380)
		let accepted = try TrackMapFixture.accepted([train], generatedAt: 1100, sources: [SourceState(id: "gtfs", timestamp: 1080, fetchedAt: 1090)])
		let state = TrackMapPresenter.state(for: train, in: accepted, conditions: live(1150))
		#expect(state.freshness == .live)
		#expect(!state.animating)
		#expect(close(state.point, TrackMapPoint(x: 1100, y: 1100)))
	}

	@Test func trainsWithoutMotionStayAtTheirPointWithoutHeading() throws {
		let train = TrackMapFixture.train(point: TrackMapPoint(x: 400, y: 1100), motion: nil)
		let state = TrackMapPresenter.state(for: train, in: try TrackMapFixture.accepted([train]), conditions: live(1050))
		#expect(close(state.point, TrackMapPoint(x: 400, y: 1100)))
		#expect(state.heading == nil)
		#expect(!state.animating)
	}

	// MARK: Frozen estimates

	@Test func reducedMotionShowsTheGeneratedEstimateWithoutAnimating() throws {
		let state = TrackMapPresenter.state(for: TrackMapFixture.train(), in: try TrackMapFixture.accepted(), conditions: TrackMapConditions(now: 1050, animationAllowed: false))
		#expect(!state.animating)
		#expect(state.freshness == .live)
		#expect(close(state.point, TrackMapPoint(x: 100, y: 100)))
	}

	@Test func offlineOrFailedFeedsFreezeWhereTheyStopped() throws {
		let accepted = try TrackMapFixture.accepted()
		let first = TrackMapPresenter.state(for: TrackMapFixture.train(), in: accepted, conditions: TrackMapConditions(now: 1050, frozenAt: 1010))
		let second = TrackMapPresenter.state(for: TrackMapFixture.train(), in: accepted, conditions: TrackMapConditions(now: 1070, frozenAt: 1010))
		#expect(!first.animating && !second.animating)
		#expect(close(first.point, TrackMapPoint(x: 100, y: 300)))
		#expect(first.point == second.point)
	}

	@Test func failedSourcesStaleAndFreezeTheirTrains() throws {
		let accepted = try TrackMapFixture.accepted(sources: [SourceState(id: "gtfs", timestamp: 995, fetchedAt: 998, error: "timeout")])
		let state = TrackMapPresenter.state(for: TrackMapFixture.train(), in: accepted, conditions: live(1040))
		#expect(state.freshness == .stale)
		#expect(!state.animating)
		#expect(close(state.point, TrackMapPoint(x: 100, y: 100)))
	}

	@Test func serverStaleTrainsAreNeverLive() throws {
		let train = TrackMapFixture.train(freshness: .stale)
		let state = TrackMapPresenter.state(for: train, in: try TrackMapFixture.accepted([train]), conditions: live(1020))
		#expect(state.freshness == .stale)
		#expect(!state.animating)
	}

	// MARK: Expiry and evidence

	@Test func markersExpireThreeHundredSecondsAfterEvidence() throws {
		let accepted = try TrackMapFixture.accepted()
		#expect(TrackMapPresenter.state(for: TrackMapFixture.train(), in: accepted, conditions: live(1289)).isPlotted)
		let expired = TrackMapPresenter.state(for: TrackMapFixture.train(), in: accepted, conditions: live(1290))
		#expect(!expired.isPlotted)
		#expect(expired.point == nil)
		#expect(expired.unplottedReason != nil)
	}

	@Test func expiryUsesOriginalEvidenceNotWhenTheCacheWasRead() throws {
		// A long server expiry cannot extend a marker beyond its observation plus 300 seconds.
		let train = TrackMapFixture.train(expiresAt: 9999)
		let accepted = try TrackMapFixture.accepted([train])
		#expect(TrackMapPresenter.effectiveExpiry(train, sources: accepted.snapshot.sources) == 1290)
		#expect(!TrackMapPresenter.state(for: train, in: accepted, conditions: live(1300)).isPlotted)
		// Nor beyond an old feed header or source health timestamp.
		let oldFeed = TrackMapFixture.train(feedTimestamp: 900, expiresAt: 9999)
		#expect(TrackMapPresenter.effectiveExpiry(oldFeed, sources: accepted.snapshot.sources) == 1200)
		let oldSource = try TrackMapFixture.accepted([train], sources: [SourceState(id: "gtfs", timestamp: 850, fetchedAt: 998)])
		#expect(TrackMapPresenter.effectiveExpiry(train, sources: oldSource.snapshot.sources) == 1150)
		#expect(!TrackMapPresenter.state(for: train, in: oldSource, conditions: live(1160)).isPlotted)
	}

	@Test func missingEvidenceIsNeverPlotted() throws {
		let noObservation = TrackMapFixture.train("a", observedAt: nil)
		let noExpiry = TrackMapFixture.train("b", expiresAt: nil)
		let accepted = try TrackMapFixture.accepted([noObservation, noExpiry])
		#expect(!TrackMapPresenter.state(for: noObservation, in: accepted, conditions: live(1010)).isPlotted)
		#expect(!TrackMapPresenter.state(for: noExpiry, in: accepted, conditions: live(1010)).isPlotted)
	}

	@Test func futureEvidenceIsNeverPlotted() throws {
		let future = TrackMapFixture.train("future", observedAt: 1010)
		let skew = TrackMapFixture.train("skew", observedAt: 1004)
		let accepted = try TrackMapFixture.accepted([future, skew])
		let rejected = TrackMapPresenter.state(for: future, in: accepted, conditions: live(1020))
		#expect(!rejected.isPlotted)
		#expect(rejected.unplottedReason?.contains("future") == true)
		#expect(TrackMapPresenter.state(for: skew, in: accepted, conditions: live(1020)).isPlotted)
	}

	@Test func unavailableUnplacedOrInvalidTrainsAreNotPlotted() throws {
		let unavailable = TrackMapFixture.train("u", freshness: .unavailable)
		let unplaced = TrackMapFixture.train("p", placement: .unplaced)
		let pointless = TrackMapFixture.train("n", point: nil, motion: nil)
		let invalid = TrackMapFixture.train("i", point: TrackMapPoint(x: -10, y: 10), motion: nil)
		let accepted = try TrackMapFixture.accepted([unavailable, unplaced, pointless, invalid])
		for train in accepted.trains { #expect(!TrackMapPresenter.state(for: train, in: accepted, conditions: live(1010)).isPlotted, "\(train.key)") }
	}

	// MARK: Certainty

	@Test func trackAndPositionCertaintyAreSeparate() throws {
		let state = TrackMapPresenter.state(for: TrackMapFixture.train(), in: try TrackMapFixture.accepted(), conditions: live(1010))
		#expect(state.trackCertainty == .reported("1"))
		#expect(state.positionCertainty == .estimated)
		#expect(state.trackCertainty.label == "Track 1 reported")
		#expect(state.positionCertainty.label == "Position estimated")
		#expect(state.accessibilityLabel.contains("Track 1 reported"))
		#expect(state.accessibilityLabel.contains("Position estimated"))
		#expect(state.isUncertain)

		let near = TrackMapFixture.train(placement: .nearStop, positionBasis: .reported, trackBasis: .unknown, trackCode: nil, motion: nil)
		let nearState = TrackMapPresenter.state(for: near, in: try TrackMapFixture.accepted([near]), conditions: live(1010))
		#expect(nearState.trackCertainty == .unknown)
		#expect(nearState.trackCertainty.label == "Track unknown")
		#expect(nearState.positionCertainty == .nearStop)
		#expect(nearState.positionCertainty.label == "Near stop, exact position unknown")

		let exact = TrackMapFixture.train(positionBasis: .reported)
		let exactState = TrackMapPresenter.state(for: exact, in: try TrackMapFixture.accepted([exact]), conditions: live(1010))
		#expect(exactState.positionCertainty == .reported)
		#expect(!exactState.isUncertain)
		#expect(TrackMapTrackCertainty(basis: .scheduled, code: "M").label == "Track M scheduled")
		#expect(TrackMapTrackCertainty(basis: .inferred, code: nil).label == "Track inferred")
	}

	@Test func staleTrainsSayStaleInTheirLabel() throws {
		let state = TrackMapPresenter.state(for: TrackMapFixture.train(), in: try TrackMapFixture.accepted(), conditions: live(1100))
		#expect(state.accessibilityLabel.contains("Stale"))
	}

	// MARK: Lists, routes and overlap

	@Test func filtersRoutesAndKeepsOnlySubwayService() throws {
		let trains = [TrackMapFixture.train("a", route: "4"), TrackMapFixture.train("b", route: "GS"), TrackMapFixture.train("c", route: "SI"),
			TrackMapFixture.train("d", route: "PATH-HOB-33"), TrackMapFixture.train("e", route: "A"), TrackMapFixture.train("f", route: "1")]
		let accepted = try TrackMapFixture.accepted(trains)
		#expect(TrackMapRoutes.routes(in: accepted) == ["1", "4", "A", "GS"])
		let all = TrackMapPresenter.states(accepted, conditions: live(1010))
		#expect(all.map(\.id) == ["a", "b", "e", "f"])
		let filtered = TrackMapPresenter.states(accepted, conditions: live(1010), routes: ["4", "GS"])
		#expect(filtered.map(\.id) == ["a", "b"])
	}

	@Test func routeColorsMatchTheBullets() {
		#expect(TrackMapRoutes.color("4") == 0x00933C)
		#expect(TrackMapRoutes.color("GS") == 0x62666B)
		#expect(TrackMapRoutes.color("Q") == 0xFCCC0A)
		#expect(TrackMapRoutes.darkInk("Q"))
		#expect(!TrackMapRoutes.darkInk("A"))
	}

	@Test func overlapHitsAreSortedByDistanceWithinTheRadius() {
		let hits = TrackMapOverlap.hits(at: CGPoint(x: 100, y: 100), candidates: [("far", CGPoint(x: 140, y: 100)), ("near", CGPoint(x: 103, y: 104)), ("mid", CGPoint(x: 110, y: 100))], radius: 22)
		#expect(hits == ["near", "mid"])
		#expect(TrackMapOverlap.hits(at: .zero, candidates: [("x", CGPoint(x: 50, y: 50))], radius: 22).isEmpty)
	}
}
