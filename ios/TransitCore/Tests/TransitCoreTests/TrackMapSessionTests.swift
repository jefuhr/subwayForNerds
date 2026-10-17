import Foundation
import Testing
@testable import TransitCore

/// Failure modes: a polling loop that outlives its view or sleeps the wrong interval,
/// a late response from an earlier endpoint overwriting the current map, a rejected
/// snapshot leaving old markers plotted, a failed poll discarding the last good data
/// or still animating it, cancellation reported as an outage, and responses moving the
/// viewport. Also station search and initial focus.
@MainActor
struct TrackMapSessionTests {
	private struct Offline: Error {}

	@Test func refreshAcceptsAMatchingSnapshot() async throws {
		let session = TrackMapSession(index: try TrackMapFixture.index())
		await session.refresh(now: 1001) { TrackMapFixture.snapshot() }
		#expect(session.status == .ready)
		#expect(session.snapshot?.trains.count == 1)
		#expect(session.receivedAt == 1001)
		#expect(session.frozenAt == nil)
	}

	@Test func refreshRejectsAMismatchedSnapshotAndClearsMarkers() async throws {
		let session = TrackMapSession(index: try TrackMapFixture.index())
		await session.refresh(now: 1001) { TrackMapFixture.snapshot() }
		await session.refresh(now: 1016) { TrackMapFixture.snapshot(mapVersion: "nyc-2.7.0-v1") }
		#expect(session.status == .rejected(.mapVersionMismatch("nyc-2.7.0-v1")))
		#expect(session.snapshot == nil)
		await session.refresh(now: 1031) { throw TrackMapError.unsupportedSchema(2) }
		#expect(session.status == .rejected(.unsupportedSchema(2)))
		#expect(session.snapshot == nil)
	}

	@Test func failuresKeepTheLastSnapshotFrozenWhereItFailed() async throws {
		let session = TrackMapSession(index: try TrackMapFixture.index())
		await session.refresh(now: 1001) { TrackMapFixture.snapshot() }
		await session.refresh(now: 1016) { throw Offline() }
		#expect(session.snapshot != nil)
		#expect(session.frozenAt == 1016)
		if case .failed = session.status {} else { Issue.record("Expected a failed status, got \(session.status)") }
		// A second failure keeps the first freeze time.
		await session.refresh(now: 1031) { throw Offline() }
		#expect(session.frozenAt == 1016)
		#expect(session.conditions(now: 1040, reduceMotion: false).frozenAt == 1016)
		await session.refresh(now: 1046) { TrackMapFixture.snapshot(generatedAt: 1045) }
		#expect(session.frozenAt == nil)
		#expect(session.status == .ready)
	}

	@Test func disconnectingFreezesUntilTheNextGoodResponse() async throws {
		let session = TrackMapSession(index: try TrackMapFixture.index())
		await session.refresh(now: 1001) { TrackMapFixture.snapshot() }
		session.setConnected(false, now: 1020)
		#expect(session.frozenAt == 1020)
		#expect(session.status == .offline)
		session.setConnected(false, now: 1030)
		#expect(session.frozenAt == 1020)
		session.setConnected(true, now: 1040)
		#expect(session.frozenAt == 1020)
		#expect(session.status == .ready)
		await session.refresh(now: 1041) { TrackMapFixture.snapshot(generatedAt: 1040) }
		#expect(session.frozenAt == nil)
	}

	@Test func reconnectingWithoutDataReturnsToIdle() throws {
		let session = TrackMapSession(index: try TrackMapFixture.index())
		session.setConnected(false, now: 1000)
		#expect(session.status == .offline)
		session.setConnected(true, now: 1010)
		#expect(session.status == .idle)
	}

	@Test func reducedMotionDisablesAnimation() throws {
		let session = TrackMapSession(index: try TrackMapFixture.index())
		#expect(session.conditions(now: 5, reduceMotion: true).animationAllowed == false)
		#expect(session.conditions(now: 5, reduceMotion: false).animationAllowed == true)
	}

	@Test func cancellationIsNotAnOutage() async throws {
		let session = TrackMapSession(index: try TrackMapFixture.index())
		await session.refresh(now: 1001) { TrackMapFixture.snapshot() }
		await session.refresh(now: 1016) { throw CancellationError() }
		await session.refresh(now: 1017) { throw URLError(.cancelled) }
		#expect(session.status == .ready)
		#expect(session.frozenAt == nil)
	}

	@Test func responsesNeverMoveTheViewportOrFilters() async throws {
		let session = TrackMapSession(index: try TrackMapFixture.index())
		let viewport = TrackMapViewport(center: TrackMapPoint(x: 300, y: 400), zoom: 2.5)
		session.viewport = viewport
		session.selectedRoutes = ["4"]
		await session.refresh(now: 1001) { TrackMapFixture.snapshot() }
		await session.refresh(now: 1016) { throw Offline() }
		await session.refresh(now: 1031) { TrackMapFixture.snapshot(mapVersion: "other") }
		#expect(session.viewport == viewport)
		#expect(session.selectedRoutes == ["4"])
	}

	@Test func aResponseFromBeforeAResetIsDropped() async throws {
		let session = TrackMapSession(index: try TrackMapFixture.index())
		await session.refresh(now: 1001) {
			await session.reset()
			return TrackMapFixture.snapshot()
		}
		#expect(session.snapshot == nil)
		#expect(session.status == .idle)
	}

	@Test func pollsEveryFifteenSecondsAndStopsWhenCancelled() async throws {
		let session = TrackMapSession(index: try TrackMapFixture.index())
		let recorder = SleepRecorder()
		let counter = FetchCounter()
		await session.run(now: { 1001 }, sleep: { try await recorder.sleep($0, stopAfter: 3) }) {
			await counter.increment()
			return TrackMapFixture.snapshot()
		}
		#expect(await counter.count == 3)
		#expect(await recorder.intervals == [.seconds(15), .seconds(15), .seconds(15)])
		#expect(session.status == .ready)
	}

	@Test func aCancelledPollingTaskEndsWithoutAnotherFetch() async throws {
		let session = TrackMapSession(index: try TrackMapFixture.index())
		let counter = FetchCounter()
		let task = Task { @MainActor in
			await session.run(now: { 1001 }) {
				await counter.increment()
				return TrackMapFixture.snapshot()
			}
		}
		while await counter.count == 0 { await Task.yield() }
		task.cancel()
		await task.value
		#expect(await counter.count == 1)
	}

	@Test func pollingOnlyWhileTheMapIsOnScreenAndActive() {
		#expect(TrackMapSession.shouldPoll(mapTabSelected: true, mapOnScreen: true, sceneActive: true))
		#expect(!TrackMapSession.shouldPoll(mapTabSelected: false, mapOnScreen: true, sceneActive: true))
		#expect(!TrackMapSession.shouldPoll(mapTabSelected: true, mapOnScreen: false, sceneActive: true))
		#expect(!TrackMapSession.shouldPoll(mapTabSelected: true, mapOnScreen: true, sceneActive: false))
	}

	// MARK: Search and focus

	@Test func searchesStationNamesIgnoringCasePunctuationAndAccents() throws {
		let index = try TrackMapFixture.index()
		let union = index.searchStations("union")
		#expect(union.count == 1)
		#expect(union.first?.name == "14 St-Union Sq")
		#expect(union.first?.stationId == "602")
		#expect(Set(union.first?.stations.map(\.partId) ?? []) == ["635", "L03"])
		#expect(index.searchStations("TIMES sq 42").first?.name == "Times Sq-42 St")
		#expect(index.searchStations("jamaica center parsons").first?.name == "Jamaica Center–Parsons/Archer")
		#expect(index.searchStations("bédford").first?.name == "Bedford Av")
		#expect(index.searchStations("  ").isEmpty)
		#expect(index.searchStations("zzz").isEmpty)
	}

	@Test func searchRanksNamePrefixesFirst() throws {
		let index = try TrackMapFixture.index()
		// "st" starts a later word in these names, which then sort by name; "14" starts one name.
		#expect(index.searchStations("st").map(\.name) == ["14 St-Union Sq", "23 St", "23 St", "Times Sq-42 St"])
		#expect(index.searchStations("14").map(\.name) == ["14 St-Union Sq"])
	}

	@Test func focusesSelectedStationsWithPaddingInsideThePage() throws {
		let index = try TrackMapFixture.index()
		// Both parts of the Union Sq complex share its station ID.
		let rect = try #require(index.focusRect(stationIDs: ["602"], padding: 300))
		#expect(rect == TrackMapRect(x: 0, y: 800, width: 440, height: 600))
		let combined = try #require(index.focusRect(stationIDs: ["602", "L08"], padding: 100))
		#expect(combined == TrackMapRect(x: 0, y: 1000, width: 1200, height: 200))
		#expect(index.focusRect(stationIDs: ["nope"]) == nil)
	}
}

private actor SleepRecorder {
	var intervals: [Duration] = []
	func sleep(_ interval: Duration, stopAfter: Int) throws {
		intervals.append(interval)
		if intervals.count >= stopAfter { throw CancellationError() }
	}
}

private actor FetchCounter {
	var count = 0
	func increment() { count += 1 }
}
