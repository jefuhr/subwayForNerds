package nyc.juliet.subwaysfornerds.data

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.test.*
import org.junit.Assert.*
import org.junit.Test

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class OfflineFetchQueueTest {
	private fun request(id: String, priority: OfflineFetchPriority = OfflineFetchPriority.BACKGROUND) = OfflineFetchRequest("fixture", OfflineFetchTarget.Board(id), priority)

	@Test fun backgroundLeavesOneSlotAndFairlyRotates() {
		val queue = OfflineFetchQueue()
		queue.track((1..10).map { request("$it") })
		val first = queue.next(0.0)
		assertEquals(2, first.size)
		queue.request(request("selected", OfflineFetchPriority.SELECTED))
		assertEquals("selected", (queue.next(0.0).single().target as OfflineFetchTarget.Board).stationID)
		first.forEach { queue.finish(it) }
		assertEquals(listOf("3", "4"), queue.next(31.0).map { (it.target as OfflineFetchTarget.Board).stationID })
	}

	@Test fun duplicateIdentityKeepsHighestPriorityAndInFlightJoins() {
		val queue = OfflineFetchQueue()
		queue.track(listOf(request("a"), request("a", OfflineFetchPriority.SELECTED)))
		assertEquals(1, queue.next(0.0).size)
		queue.request(request("a", OfflineFetchPriority.EXPLICIT))
		assertTrue(queue.next(1.0).isEmpty())
	}

	@Test fun backgroundCapDoesNotSuppressSelectedWakeTime() {
		val queue = OfflineFetchQueue()
		queue.track(listOf(request("a"), request("b"), request("c"), request("selected", OfflineFetchPriority.SELECTED)))
		val started = queue.next(0.0)
		queue.finish(started.first { it.priority == OfflineFetchPriority.SELECTED })
		assertEquals(10.0, queue.nextDue(1.0)!!, 0.0)
	}

	@Test fun reconnectMakesRecurringRequestsDueAndPausingStopsNewStarts() {
		val queue = OfflineFetchQueue()
		queue.track(listOf(request("a")))
		val first = queue.next(0.0).single(); queue.finish(first)
		queue.setConnected(false)
		assertTrue(queue.next(1.0).isEmpty())
		queue.setConnected(true)
		assertEquals(1, queue.next(1.0).size)
	}

	@Test fun coordinatorJoinsManualRequestsAndReturnsPausedWithoutNetwork() = runTest {
		val latch = CompletableDeferred<Unit>()
		var calls = 0
		val coordinator = TransitRefreshCoordinator(backgroundScope, fetch = { calls++; latch.await() }, clock = { testScheduler.currentTime / 1000.0 })
		val first = async { coordinator.request(request("a", OfflineFetchPriority.EXPLICIT)) }
		runCurrent()
		val second = async { coordinator.request(request("a", OfflineFetchPriority.EXPLICIT)) }
		runCurrent()
		assertEquals(1, calls)
		latch.complete(Unit); runCurrent()
		assertEquals(OfflineFetchOutcome.COMPLETED, first.await())
		assertEquals(OfflineFetchOutcome.COMPLETED, second.await())
		coordinator.setForeground(false)
		assertEquals(OfflineFetchOutcome.PAUSED, coordinator.request(request("b")))
		assertEquals(1, calls)
		coordinator.stop()
	}
}
