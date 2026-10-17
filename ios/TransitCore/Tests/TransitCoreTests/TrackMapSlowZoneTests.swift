import Foundation
import Testing
@testable import TransitCore

@Suite struct TrackMapSlowZoneTests {
	private func zone(_ id: String = "zone", routes: [String] = ["L"], paths: [[TrackMapPoint]]? = nil) -> TrackMapSlowZone {
		TrackMapSlowZone(id: id, routes: routes, paths: paths ?? [[TrackMapPoint(x: 100, y: 100), TrackMapPoint(x: 100, y: 1100)]],
			zone: SlowZone(from: "L03N", to: "L02N", segment: "14 St-Union Sq → 6 Av", kind: "disruption", since: "2026-08-10", through: "2026-09-02", extraSeconds: 42, baselineSeconds: 92, slowDays: 12))
	}

	private func snapshot(_ zones: [TrackMapSlowZone], expiresAt: TimeInterval? = 2000) -> TrackMapSnapshot {
		var value = TrackMapFixture.snapshot([])
		value.slowZones = TrackMapSlowZones(dataThrough: "2026-09-02", expiresAt: expiresAt, zones: zones, unmappedCount: 3)
		return value
	}

	@Test func oldSnapshotsDecodeWithoutZones() throws {
		let value = try JSONDecoder().decode(TrackMapSnapshot.self, from: Data(TrackMapFixture.snapshotJSON.utf8))
		#expect(value.slowZones == nil)
		#expect(TrackMapSlowZonePresenter.state(try TrackMapFixture.index().accept(value), now: 1000).zones.isEmpty)
	}

	@Test func flattenedWireFormatRoundTrips() throws {
		let value = snapshot([zone()])
		let data = try JSONEncoder().encode(value)
		let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
		let payload = try #require(object["slowZones"] as? [String: Any])
		let zones = try #require(payload["zones"] as? [[String: Any]])
		#expect(zones[0]["segment"] as? String == "14 St-Union Sq → 6 Av")
		#expect(zones[0]["zone"] == nil)
		#expect(try JSONDecoder().decode(TrackMapSnapshot.self, from: data) == value)
	}

	@Test func expiryIgnoresTrainEvidenceAndOutageFreeze() throws {
		let accepted = try TrackMapFixture.index().accept(snapshot([zone()]))
		let before = TrackMapSlowZonePresenter.state(accepted, now: 1999, frozenAt: 1000)
		#expect(before.zones.count == 1)
		#expect(before.cached)
		#expect(before.highlightedPaths.count == 1)
		let expired = TrackMapSlowZonePresenter.state(accepted, now: 2000, frozenAt: 1000)
		#expect(expired.zones.isEmpty)
		#expect(expired.highlightedPaths.isEmpty)
		#expect(expired.status == .expired)
		#expect(TrackMapRenderClock.mode(visible: true, foreground: true, hasSnapshot: true, animating: false, reduceMotion: true) == .seconds)
	}

	@Test func unknownOrInvalidDeadlineNeverHighlights() throws {
		for deadline: TimeInterval? in [nil, 0, -.infinity, .nan] {
			let accepted = try TrackMapFixture.index().accept(snapshot([zone()], expiresAt: deadline))
			#expect(TrackMapSlowZonePresenter.state(accepted, now: 1000).highlightedPaths.isEmpty)
		}
		let accepted = try TrackMapFixture.index().accept(snapshot([zone()]))
		#expect(TrackMapSlowZonePresenter.state(accepted, now: .nan).highlightedPaths.isEmpty)
	}

	@Test func filtersApplyToZonesWithoutTrainsAndEmptyRoutesOnlyMatchAll() throws {
		let accepted = try TrackMapFixture.index().accept(snapshot([zone("L"), zone("unknown", routes: []), zone("6", routes: ["6", "6X"])]))
		#expect(TrackMapSlowZonePresenter.state(accepted, now: 1000).zones.count == 3)
		#expect(TrackMapSlowZonePresenter.state(accepted, now: 1000, routes: ["L"]).zones.map(\.id) == ["L"])
		#expect(TrackMapSlowZonePresenter.state(accepted, now: 1000, routes: ["6X"]).zones.map(\.id) == ["6"])
		#expect(TrackMapSlowZonePresenter.state(accepted, now: 1000, routes: ["N"]).zones.isEmpty)
		#expect(TrackMapRoutes.routes(in: accepted, now: 1000) == ["6", "6X", "L"])
		#expect(TrackMapRoutes.routes(in: accepted, now: 2000).isEmpty)
	}

	@Test func invalidOrAmbiguousPathsAreListedButNeverDrawn() throws {
		let valid = [TrackMapPoint(x: 100, y: 100), TrackMapPoint(x: 200, y: 200)]
		let paths: [[[TrackMapPoint]]] = [[], [[]], [[valid[0]]], [[valid[0], valid[0]]], [[TrackMapPoint(x: -1, y: 1), valid[1]]],
			[[valid[0], TrackMapPoint(x: TrackMapContract.pageWidth + 1, y: 1)]], [[valid[0], TrackMapPoint(x: .nan, y: 1)]], [valid, [valid[0]]]]
		for path in paths {
			let accepted = try TrackMapFixture.index().accept(snapshot([zone(paths: path)]))
			let state = TrackMapSlowZonePresenter.state(accepted, now: 1000)
			#expect(state.zones.count == 1)
			#expect(state.highlightedPaths.isEmpty)
			#expect(state.zones[0].unplottedReason != nil)
			#expect(state.unmappedCount == 3)
		}
	}

	@Test func duplicateIDsDoNotDuplicateHighlightsAndTextExplainsEstimateAndSource() throws {
		let accepted = try TrackMapFixture.index().accept(snapshot([zone(), zone()]))
		let state = TrackMapSlowZonePresenter.state(accepted, now: 1000)
		#expect(state.zones.count == 1)
		#expect(state.zones[0].accessibilityLabel.contains("14 St-Union Sq → 6 Av"))
		#expect(state.zones[0].accessibilityLabel.contains("42s"))
		#expect(state.zones[0].accessibilityLabel.contains("Estimated major slowdown"))
		#expect(state.zones[0].accessibilityLabel.contains("Transit Lab"))
		var wrongMap = snapshot([zone()]); wrongMap.mapVersion = "other"
		#expect(throws: TrackMapError.self) { try TrackMapFixture.index().accept(wrongMap) }
	}
}
