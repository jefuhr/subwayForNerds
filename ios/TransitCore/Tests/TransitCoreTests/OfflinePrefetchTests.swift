import Foundation
import Testing
@testable import TransitCore

struct OfflinePrefetchTests {
	let endpoint = OfflineFixtures.endpoint
	func request(_ target: OfflineFetchTarget, _ priority: OfflineFetchPriority) -> OfflineFetchRequest { OfflineFetchRequest(endpoint: endpoint, target: target, priority: priority) }

	@Test func atMostThreeRunAndExplicitAndRideWorkGoesFirst() {
		var queue = OfflineFetchQueue()
		queue.track([
			request(.board(stationID: "near1"), .background), request(.board(stationID: "near2"), .background),
			request(.board(stationID: "selected"), .selected), request(.trip(key: "ride"), .activeRide),
		])
		queue.request(request(.trip(key: "opened"), .explicit))
		let first = queue.next(now: 0)
		#expect(first.map(\.target) == [.trip(key: "opened"), .trip(key: "ride"), .board(stationID: "selected")])
		#expect(queue.next(now: 0).isEmpty)
		queue.finish(first[0], now: 1)
		#expect(queue.next(now: 1).map(\.target) == [.board(stationID: "near1")])
	}

	@Test func identitiesAreDeduplicatedInFlightAndAcrossSources() {
		var queue = OfflineFetchQueue()
		queue.track([request(.board(stationID: "a"), .background), request(.board(stationID: "a"), .selected)])
		#expect(queue.trackedRequests.map(\.priority) == [.selected])
		let started = queue.next(now: 0)
		#expect(started.count == 1)
		queue.request(request(.board(stationID: "a"), .explicit))
		#expect(queue.next(now: 0).isEmpty)
		// The same station on another endpoint is a different identity.
		queue.request(OfflineFetchRequest(endpoint: "http://127.0.0.1:8092/api/v1/", target: .board(stationID: "a"), priority: .explicit))
		#expect(queue.next(now: 0).count == 1)
		queue.finish(started[0], now: 1)
		// The in-flight fetch satisfied the explicit request: it is not fetched again.
		#expect(queue.next(now: 1).isEmpty)
	}

	@Test func selectedAndRideRefreshEveryTenSecondsAndSurroundingEveryThirty() {
		var queue = OfflineFetchQueue()
		let selected = request(.board(stationID: "selected"), .selected), nearby = request(.board(stationID: "near"), .background)
		queue.track([selected, nearby])
		for started in queue.next(now: 0) { queue.finish(started, now: 2) }
		#expect(queue.next(now: 9.9).isEmpty)
		#expect(queue.nextDue(now: 9.9) == 10)
		#expect(queue.next(now: 10).map(\.target) == [selected.target])
		queue.finish(selected, now: 11)
		#expect(queue.next(now: 19.9).isEmpty)
		#expect(queue.nextDue(now: 19.9) == 20)
		#expect(queue.next(now: 20).map(\.target) == [selected.target])
		queue.finish(selected, now: 21)
		#expect(queue.next(now: 29.9).isEmpty)
		#expect(queue.next(now: 30).map(\.target) == [selected.target, nearby.target])
	}

	@Test func everythingPausesOfflineOrInBackgroundAndRecoveryRefreshesAtOnce() {
		var queue = OfflineFetchQueue()
		let selected = request(.board(stationID: "selected"), .selected)
		queue.track([selected, request(.board(stationID: "near"), .background)])
		for started in queue.next(now: 0) { queue.finish(started, now: 0) }
		queue.setForeground(false)
		queue.request(request(.trip(key: "explicit"), .explicit))
		#expect(queue.next(now: 100).isEmpty && queue.nextDue(now: 100) == nil)
		queue.setForeground(true)
		queue.setConnected(false)
		#expect(queue.next(now: 100).isEmpty)
		queue.setConnected(true)
		#expect(queue.next(now: 1).count == 3)
	}

	@Test func trackingANewSetDropsStaleTargets() {
		var queue = OfflineFetchQueue()
		queue.track([request(.board(stationID: "old"), .selected)])
		_ = queue.next(now: 0).map { queue.finish($0, now: 0) }
		queue.track([request(.board(stationID: "new"), .selected)])
		#expect(queue.next(now: 1).map(\.target) == [.board(stationID: "new")])
		#expect(queue.next(now: 100).isEmpty)
	}

	@Test func surroundingStationsRotateSoEveryOneIsFetchedBeforeAnyRepeats() {
		var queue = OfflineFetchQueue()
		let stations = (1...15).map { request(.board(stationID: "near\($0)"), .background) }
		let selected = request(.board(stationID: "selected"), .selected)
		queue.track([selected] + stations)
		// Slow network on a fake clock: every fetch takes 12 s, 3 at a time.
		var running: [(request: OfflineFetchRequest, finishes: TimeInterval)] = []
		var starts: [(target: OfflineFetchTarget, at: TimeInterval)] = []
		for tick in 0...240 {
			let now = TimeInterval(tick)
			for done in running.filter({ $0.finishes <= now }) { queue.finish(done.request, now: now) }
			running.removeAll { $0.finishes <= now }
			for started in queue.next(now: now) {
				running.append((started, now + 12))
				starts.append((started.target, now))
			}
			#expect(running.count <= OfflineFetchQueue.maxConcurrent)
			#expect(Set(running.map(\.request.identity)).count == running.count)
		}
		let background = starts.filter { $0.target != selected.target }.map(\.target)
		// Every surrounding station gets its first fetch before any of them repeats,
		// in the caller's (nearest-first) order, and later rounds keep that rotation.
		#expect(Array(background.prefix(15)) == stations.map(\.target))
		#expect(background.count >= 30)
		#expect((0...(background.count - 15)).allSatisfy { Set(background[$0..<($0 + 15)]).count == 15 })
		// Minimum intervals still hold: 30 s for surrounding stations, 10 s for the selected one.
		for target in stations.map(\.target) + [selected.target] {
			let times = starts.filter { $0.target == target }.map(\.at)
			let interval = target == selected.target ? OfflineFetchQueue.liveInterval : OfflineFetchQueue.backgroundInterval
			#expect(zip(times, times.dropFirst()).allSatisfy { $1 - $0 >= interval }, "\(target)")
		}
		// The selected board keeps its priority: it starts first and every slot it needs.
		#expect(starts.first?.target == selected.target)
		#expect(starts.filter { $0.target == selected.target }.count >= 10)
	}

	@Test func oneShotsLeadEqualPriorityRecurringWorkAndHigherPrioritiesStillLead() {
		var queue = OfflineFetchQueue()
		queue.track([request(.board(stationID: "near1"), .background), request(.board(stationID: "near2"), .background), request(.board(stationID: "selected"), .selected)])
		queue.request(request(.trip(key: "late"), .background))
		queue.request(request(.trip(key: "opened"), .explicit))
		#expect(queue.next(now: 0).map(\.target) == [.trip(key: "opened"), .board(stationID: "selected"), .trip(key: "late")])
	}

	@Test func backgroundWorkLeavesOneSlotForExplicitRideAndSelectedWork() throws {
		var queue = OfflineFetchQueue()
		queue.track((1...4).map { request(.board(stationID: "near\($0)"), .background) })
		queue.request(request(.trip(key: "late"), .background))
		// Two surrounding fetches hang; neither later surrounding work nor a background one-shot takes the third slot.
		let hung = queue.next(now: 0)
		#expect(hung.map(\.target) == [.trip(key: "late"), .board(stationID: "near1")])
		#expect(queue.next(now: 100).isEmpty)
		queue.request(request(.trip(key: "opened"), .explicit))
		let explicit = queue.next(now: 100)
		#expect(explicit.map(\.target) == [.trip(key: "opened")])
		#expect(queue.inFlight.count == OfflineFetchQueue.maxConcurrent)
		// The cap still holds for ride and selected work while the reserved slot is busy.
		queue.track((1...4).map { request(.board(stationID: "near\($0)"), .background) } + [request(.trip(key: "ride"), .activeRide)])
		#expect(queue.next(now: 100).isEmpty)
		queue.finish(try #require(explicit.first), now: 101)
		#expect(queue.next(now: 101).map(\.target) == [.trip(key: "ride")])
		// A finished background fetch frees a background slot again.
		queue.finish(try #require(hung.first), now: 102)
		#expect(queue.next(now: 102).map(\.target) == [.board(stationID: "near2")])
	}

	@Test func capacityBlockedBackgroundWorkDoesNotHideTheNextSelectedRefresh() {
		var queue = OfflineFetchQueue()
		let selected = request(.board(stationID: "selected"), .selected)
		queue.track([selected] + (1...3).map { request(.board(stationID: "near\($0)"), .background) })
		#expect(queue.next(now: 0).map(\.target) == [selected.target, .board(stationID: "near1"), .board(stationID: "near2")])
		queue.finish(selected, now: 1)
		// near3 is due but held back by the background cap; the selected board is next due at 10.
		#expect(queue.nextDue(now: 1) == 10)
		#expect(queue.next(now: 10).map(\.target) == [selected.target])
		queue.finish(selected, now: 11)
		// A held-back background one-shot does not count as due either.
		queue.request(request(.trip(key: "late"), .background))
		#expect(queue.nextDue(now: 11) == 20)
		// Work that may use the reserved slot is due at once.
		queue.request(request(.trip(key: "opened"), .explicit))
		#expect(queue.nextDue(now: 11) == 11)
		#expect(queue.next(now: 11).map(\.target) == [.trip(key: "opened")])
		#expect(queue.inFlight.count == OfflineFetchQueue.maxConcurrent)
	}

	@Test func prefetcherStartsExplicitWorkWhileBackgroundFetchesHang() async throws {
		actor Probe {
			var running = 0, peak = 0, started: [OfflineFetchTarget] = []
			private var held: [CheckedContinuation<Void, Never>] = []
			private var released = false
			func begin(_ target: OfflineFetchTarget) { running += 1; peak = max(peak, running); started.append(target) }
			func end() { running -= 1 }
			func hold() async {
				guard !released else { return }
				await withCheckedContinuation { held.append($0) }
			}
			func release() { released = true; held.forEach { $0.resume() }; held.removeAll() }
		}
		let probe = Probe()
		let prefetcher = OfflinePrefetcher(clock: { 0 }) { request in
			await probe.begin(request.target)
			if request.priority == .background { await probe.hold() }
			await probe.end()
		}
		await prefetcher.track((1...3).map { request(.board(stationID: "near\($0)"), .background) })
		// Establish the hung-fetch precondition before submitting foreground work.
		for _ in 0..<200 {
			if await probe.started.count == 2 { break }
			try await Task.sleep(nanoseconds: 10_000_000)
		}
		#expect(await probe.started.count == 2)
		let explicit = Task { await prefetcher.request(request(.trip(key: "opened"), .explicit)) }
		// Poll instead of awaiting, so a regression fails here rather than hanging the suite.
		var explicitStarted = false
		for _ in 0..<200 where !explicitStarted {
			explicitStarted = await probe.started.contains(.trip(key: "opened"))
			if !explicitStarted { try await Task.sleep(nanoseconds: 10_000_000) }
		}
		#expect(explicitStarted)
		#expect(await probe.started.filter { $0 != .trip(key: "opened") }.count == 2)
		await probe.release()
		#expect(await explicit.value == .completed)
		#expect(await probe.peak <= OfflineFetchQueue.maxConcurrent)
		await prefetcher.stop()
	}

	@Test func prefetcherNeverRunsMoreThanThreeFetches() async throws {
		actor Probe {
			var running = 0, peak = 0, finished: [OfflineFetchTarget] = []
			func begin() { running += 1; peak = max(peak, running) }
			func end(_ target: OfflineFetchTarget) { running -= 1; finished.append(target) }
		}
		let probe = Probe()
		let prefetcher = OfflinePrefetcher(clock: { 0 }) { request in
			await probe.begin()
			try? await Task.sleep(nanoseconds: 20_000_000)
			await probe.end(request.target)
		}
		let requests = (0..<7).map { request(.trip(key: "t\($0)"), .explicit) }
		let outcomes = await withTaskGroup(of: OfflineFetchOutcome.self) { group in
			for item in requests { group.addTask { await prefetcher.request(item) } }
			return await group.reduce(into: []) { $0.append($1) }
		}
		#expect(outcomes == Array(repeating: .completed, count: 7))
		#expect(await probe.finished.count == 7)
		#expect(await probe.peak == 3)
		await prefetcher.stop()
	}
}
