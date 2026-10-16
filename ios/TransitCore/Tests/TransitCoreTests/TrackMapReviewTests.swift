import Foundation
import Testing
@testable import TransitCore

/// Failure modes from review: unrelated stations merged because they share a name,
/// held markers looking live during an outage, stopped trains given a guessed
/// direction, motion that runs backwards, an unstable viewport description, and
/// render timers running while the map is hidden or the app is in the background.
struct TrackMapReviewTests {
	private func live(_ now: TimeInterval) -> TrackMapConditions { TrackMapConditions(now: now) }

	// MARK: Search groups by station

	@Test func searchKeepsSameNamedStationsApartAndLabelsThem() throws {
		let results = try TrackMapFixture.index().searchStations("23 st")
		#expect(results.map(\.stationId).sorted() == ["D18", "R19"])
		#expect(results.allSatisfy { $0.sharesName })
		#expect(results.allSatisfy { $0.stations.count == 1 })
		// Subtitles come from the app's station catalog, never from opaque IDs.
		let subtitles = Set(results.map { $0.subtitle(routes: $0.stationId == "R19" ? ["N", "R", "W"] : ["F", "M"], borough: "M") })
		#expect(subtitles == ["N R W · Manhattan", "F M · Manhattan"])
		#expect(results[0].subtitle(routes: ["GS"], borough: "Bk") == "S · Brooklyn")
		let fallback = try #require(results[0].subtitle(routes: [], borough: nil))
		#expect(!fallback.contains("R19") && !fallback.contains("D18"))
		#expect(results.map(\.id).count == Set(results.map(\.id)).count)
	}

	@Test func searchMergesOnlyPartsOfOneStation() throws {
		let union = try TrackMapFixture.index().searchStations("union")
		#expect(union.count == 1)
		#expect(union[0].stationId == "602")
		#expect(union[0].stations.count == 2)
		#expect(!union[0].sharesName)
		#expect(union[0].subtitle(routes: ["4", "L"], borough: "M") == nil)
	}

	// MARK: Outages fade markers at once

	@Test func frozenMarkersAreStaleImmediately() throws {
		let state = TrackMapPresenter.state(for: TrackMapFixture.train(), in: try TrackMapFixture.accepted(), conditions: TrackMapConditions(now: 1012, frozenAt: 1010))
		#expect(state.isPlotted)
		#expect(state.freshness == .stale)
		#expect(!state.animating)
		#expect(state.accessibilityLabel.contains("Stale"))
		// Expiry still follows the original evidence, not the outage.
		#expect(TrackMapPresenter.state(for: TrackMapFixture.train(), in: try TrackMapFixture.accepted(), conditions: TrackMapConditions(now: 1289, frozenAt: 1010)).isPlotted)
		#expect(!TrackMapPresenter.state(for: TrackMapFixture.train(), in: try TrackMapFixture.accepted(), conditions: TrackMapConditions(now: 1290, frozenAt: 1010)).isPlotted)
	}

	// MARK: Evidence clocks

	@Test func staleAndExpiryFollowTheEarliestEvidenceClock() throws {
		// The source last succeeded at 900, so a later server staleAt cannot keep the train live.
		let train = TrackMapFixture.train(staleAt: 1080, expiresAt: 1290)
		let accepted = try TrackMapFixture.accepted([train], sources: [SourceState(id: "gtfs", timestamp: 900, fetchedAt: 998)])
		let deadlines = try #require(TrackMapPresenter.evidenceDeadlines(train, sources: accepted.snapshot.sources))
		#expect(deadlines.staleAt == 990)
		#expect(deadlines.expiresAt == 1200)
		let state = TrackMapPresenter.state(for: train, in: accepted, conditions: live(1010))
		#expect(state.freshness == .stale)
		#expect(!state.animating)
		// Held where the evidence went stale, before the motion window opened.
		#expect(state.point == TrackMapPoint(x: 100, y: 100))
		#expect(!TrackMapPresenter.state(for: train, in: accepted, conditions: live(1200)).isPlotted)
	}

	@Test func trainsNeedEveryEvidenceClock() throws {
		let train = TrackMapFixture.train()
		for sources in [[], [SourceState(id: "gtfs", timestamp: nil, fetchedAt: 998)], [SourceState(id: "gtfs", timestamp: 0, fetchedAt: 998)], [SourceState(id: "other", timestamp: 995)]] {
			let accepted = try TrackMapFixture.accepted([train], sources: sources)
			#expect(TrackMapPresenter.evidenceDeadlines(train, sources: sources) == nil)
			#expect(!TrackMapPresenter.state(for: train, in: accepted, conditions: live(1010)).isPlotted)
		}
		let noHeader = TrackMapFixture.train(feedTimestamp: 0)
		let accepted = try TrackMapFixture.accepted([noHeader])
		#expect(!TrackMapPresenter.state(for: noHeader, in: accepted, conditions: live(1010)).isPlotted)
	}

	@Test func deadlinesDoNotDependOnWhenTheSnapshotWasRead() throws {
		// The same evidence read later gives the same deadlines; only device time changes the state.
		let early = try TrackMapFixture.accepted(generatedAt: 1000)
		let late = try TrackMapFixture.accepted(generatedAt: 1250)
		let train = TrackMapFixture.train()
		#expect(TrackMapPresenter.evidenceDeadlines(train, sources: early.snapshot.sources) == TrackMapPresenter.evidenceDeadlines(train, sources: late.snapshot.sources))
		#expect(!TrackMapPresenter.state(for: train, in: late, conditions: live(1295)).isPlotted)
	}

	@Test func clocksAheadOfTheDeviceAreNeverPlotted() throws {
		let futureHeader = TrackMapFixture.train("h", feedTimestamp: 1100)
		let accepted = try TrackMapFixture.accepted([futureHeader])
		#expect(!TrackMapPresenter.state(for: futureHeader, in: accepted, conditions: live(1010)).isPlotted)
		let futureSource = try TrackMapFixture.accepted(sources: [SourceState(id: "gtfs", timestamp: 1100, fetchedAt: 998)])
		#expect(!TrackMapPresenter.state(for: TrackMapFixture.train(), in: futureSource, conditions: live(1010)).isPlotted)
		// A device clock behind the observation, beyond the tolerance.
		#expect(!TrackMapPresenter.state(for: TrackMapFixture.train(), in: try TrackMapFixture.accepted(), conditions: live(980)).isPlotted)
		#expect(TrackMapPresenter.state(for: TrackMapFixture.train(), in: try TrackMapFixture.accepted(), conditions: live(992)).isPlotted)
		#expect(!TrackMapPresenter.state(for: TrackMapFixture.train(), in: try TrackMapFixture.accepted(), conditions: live(.nan)).isPlotted)
	}

	@Test func failedSourcesHoldTheServerPointExactly() throws {
		// The server's sampled point is deliberately off the motion path, so recomputing would move it.
		let train = TrackMapFixture.train(point: TrackMapPoint(x: 100, y: 250))
		let accepted = try TrackMapFixture.accepted([train], sources: [SourceState(id: "gtfs", timestamp: 995, fetchedAt: 998, error: "timeout")])
		let first = TrackMapPresenter.state(for: train, in: accepted, conditions: live(1020))
		let later = TrackMapPresenter.state(for: train, in: accepted, conditions: live(1060))
		#expect(first.point == TrackMapPoint(x: 100, y: 250))
		#expect(later.point == first.point)
		#expect(!first.animating)
	}

	// MARK: Topology geometry

	@Test func rejectsMotionOverNonRevenueTrack() throws {
		let yard = TrackMapEdge(id: "yard", from: "n3", to: "n1", points: [TrackMapPoint(x: 1100, y: 1100), TrackMapPoint(x: 100, y: 100)], bidirectional: true, revenue: false)
		let base = TrackMapFixture.topology()
		let index = try TrackMapFixture.index(TrackMapFixture.topology(edges: base.edges + [yard]))
		var motion = TrackMapFixture.motion
		motion.edgeIds = ["e1", "yard"]
		let accepted = try index.accept(TrackMapFixture.snapshot([TrackMapFixture.train("yard", motion: motion), TrackMapFixture.train("main")]))
		#expect(accepted.invalidGeometry["yard"] != nil)
		#expect(accepted.invalidGeometry["main"] == nil)
	}

	@Test func rejectsEdgesThatDoNotMeetTheirNodesOrHaveNoLength() {
		let gap = [TrackMapEdge(id: "e1", from: "n1", to: "n2", points: [TrackMapPoint(x: 100, y: 120), TrackMapPoint(x: 100, y: 1100)], bidirectional: true, revenue: true)]
		#expect(throws: TrackMapError.self) { try TrackMapFixture.index(TrackMapFixture.topology(edges: gap)) }
		let same = TrackMapPoint(x: 100, y: 100)
		let nodes = [TrackMapNode(id: "n1", point: same), TrackMapNode(id: "n2", point: same), TrackMapNode(id: "n3", point: TrackMapPoint(x: 1100, y: 1100))]
		let flat = [TrackMapEdge(id: "e1", from: "n1", to: "n2", points: [same, same, same], bidirectional: true, revenue: true)]
		#expect(throws: TrackMapError.self) { try TrackMapFixture.index(TrackMapFixture.topology(nodes: nodes, edges: flat)) }
	}

	// MARK: Backwards motion

	@Test func rejectsMotionThatRunsBackwards() throws {
		var backwards = TrackMapFixture.motion
		backwards.fromProgress = 0.7; backwards.toProgress = 0.3
		var still = TrackMapFixture.motion
		still.fromProgress = 0.4; still.toProgress = 0.4
		let accepted = try TrackMapFixture.accepted([TrackMapFixture.train("back", motion: backwards), TrackMapFixture.train("still", motion: still)])
		#expect(accepted.invalidGeometry["back"] != nil)
		#expect(accepted.invalidGeometry["still"] == nil)
		#expect(!TrackMapPresenter.state(for: accepted.trains[0], in: accepted, conditions: live(1010)).isPlotted)
	}

	// MARK: Stopped trains on directed rail

	/// A straight southbound track a → b → c with platform P at b on track 1, and a
	/// bidirectional siding at x.
	private func railTopology(extraEdges: [TrackMapEdge] = [], revenue: Bool = true) -> TrackMapTopology {
		let a = TrackMapPoint(x: 500, y: 500), b = TrackMapPoint(x: 500, y: 1500), c = TrackMapPoint(x: 500, y: 2500)
		let d = TrackMapPoint(x: 1500, y: 1500), x = TrackMapPoint(x: 2000, y: 500), y = TrackMapPoint(x: 3000, y: 500)
		return TrackMapFixture.topology(
			nodes: [TrackMapNode(id: "a", point: a), TrackMapNode(id: "b", point: b), TrackMapNode(id: "c", point: c), TrackMapNode(id: "d", point: d), TrackMapNode(id: "x", point: x), TrackMapNode(id: "y", point: y)],
			edges: [
				TrackMapEdge(id: "ab", from: "a", to: "b", points: [a, TrackMapPoint(x: 500, y: 1000), b], bidirectional: false, revenue: revenue),
				TrackMapEdge(id: "bc", from: "b", to: "c", points: [b, c], bidirectional: false, revenue: revenue),
				TrackMapEdge(id: "xy", from: "x", to: "y", points: [x, y], bidirectional: true, revenue: true)
			] + extraEdges,
			platforms: [
				TrackMapPlatform(id: "P", stopId: "S1S", trackCodes: ["1"], nodeId: "b"),
				TrackMapPlatform(id: "X", stopId: "S2N", trackCodes: ["3"], nodeId: "x")
			])
	}

	private func stopped(_ key: String, stopId: String = "S1S", trackCode: String? = "1", point: TrackMapPoint = TrackMapPoint(x: 500, y: 1500), placement: TrackMapPlacement = .track) -> TrackMapTrain {
		var train = TrackMapFixture.train(key, placement: placement, positionBasis: .reported, trackCode: trackCode, point: point, motion: nil)
		train.stopId = stopId
		return train
	}

	private func heading(_ train: TrackMapTrain, _ topology: TrackMapTopology) throws -> Double? {
		let accepted = try TrackMapFixture.index(topology).accept(TrackMapFixture.snapshot([train]))
		return TrackMapPresenter.state(for: train, in: accepted, conditions: live(1010)).heading
	}

	@Test func stoppedTrainsFollowTheirDirectedRail() throws {
		let value = try #require(try heading(stopped("t"), railTopology()))
		// Southbound on the page: +y, which is π/2 in top-left map space.
		#expect(abs(value - Double.pi / 2) < 1e-9)
	}

	@Test func stoppedTrainsWithoutAClearDirectionStayDiscs() throws {
		// A second directed rail leaving the platform eastward makes the direction ambiguous.
		let branch = TrackMapEdge(id: "bd", from: "b", to: "d", points: [TrackMapPoint(x: 500, y: 1500), TrackMapPoint(x: 1500, y: 1500)], bidirectional: false, revenue: true)
		#expect(try heading(stopped("t"), railTopology(extraEdges: [branch])) == nil)
		// Bidirectional track has no direction of travel.
		#expect(try heading(stopped("x", stopId: "S2N", trackCode: "3", point: TrackMapPoint(x: 2000, y: 500)), railTopology()) == nil)
		// Away from the platform node, near-stop, a different track, or an unknown stop.
		#expect(try heading(stopped("t", point: TrackMapPoint(x: 500, y: 1400)), railTopology()) == nil)
		#expect(try heading(stopped("t", placement: .nearStop), railTopology()) == nil)
		#expect(try heading(stopped("t", trackCode: "2"), railTopology()) == nil)
		#expect(try heading(stopped("t", stopId: "Z9S"), railTopology()) == nil)
		// Non-revenue track never sets the direction of a passenger train.
		#expect(try heading(stopped("t"), railTopology(revenue: false)) == nil)
	}

	@Test func stoppedTrainsWithUnknownTrackUseTheOnlyPlatform() throws {
		#expect(try heading(stopped("t", trackCode: nil), railTopology()) != nil)
	}

	@Test func movingTrainsKeepTheirMotionHeading() throws {
		var train = TrackMapFixture.train("m", motion: TrackMapMotion(edgeIds: ["xy"], points: [TrackMapPoint(x: 2000, y: 500), TrackMapPoint(x: 3000, y: 500)], fromProgress: 0, toProgress: 1, startTime: 1000, endTime: 1100))
		train.stopId = "S1S"
		let value = try #require(try heading(train, railTopology()))
		#expect(abs(value) < 1e-9)
	}

	// MARK: Viewport description and render clock

	@Test func viewportDescriptionIsRoundedAndStable() {
		let a = TrackMapViewport(center: TrackMapPoint(x: 1279.5367, y: 5997.2525), zoom: 0.123456)
		#expect(a.accessibilityValue == "Center 1280, 5997; zoom 0.123")
		let b = TrackMapViewport(center: TrackMapPoint(x: 1279.6, y: 5997.4), zoom: 0.12349)
		#expect(a.accessibilityValue == b.accessibilityValue)
	}

	@Test func renderClockRunsOnlyWhileVisibleAndForeground() {
		#expect(TrackMapRenderClock.mode(visible: true, foreground: true, hasSnapshot: true, animating: true, reduceMotion: false) == .frames)
		#expect(TrackMapRenderClock.mode(visible: true, foreground: true, hasSnapshot: true, animating: false, reduceMotion: false) == .seconds)
		#expect(TrackMapRenderClock.mode(visible: true, foreground: true, hasSnapshot: true, animating: true, reduceMotion: true) == .seconds)
		#expect(TrackMapRenderClock.mode(visible: false, foreground: true, hasSnapshot: true, animating: true, reduceMotion: false) == .stopped)
		#expect(TrackMapRenderClock.mode(visible: true, foreground: false, hasSnapshot: true, animating: true, reduceMotion: false) == .stopped)
		#expect(TrackMapRenderClock.mode(visible: true, foreground: true, hasSnapshot: false, animating: false, reduceMotion: false) == .stopped)
	}
}
