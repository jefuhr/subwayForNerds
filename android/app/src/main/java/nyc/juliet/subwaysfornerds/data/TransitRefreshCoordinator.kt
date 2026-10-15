package nyc.juliet.subwaysfornerds.data

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.isActive

sealed interface OfflineFetchTarget {
	data class Board(val stationID: String) : OfflineFetchTarget
	data class Trip(val key: String) : OfflineFetchTarget
}
enum class OfflineFetchPriority { EXPLICIT, ACTIVE_RIDE, SELECTED, BACKGROUND;
	val interval: Double get() = if (this == BACKGROUND) 30.0 else 10.0
}
data class OfflineFetchRequest(val endpoint: String, val target: OfflineFetchTarget, val priority: OfflineFetchPriority = OfflineFetchPriority.BACKGROUND) {
	val identity: OfflineFetchIdentity get() = OfflineFetchIdentity(AndroidTransitCache.endpointKey(endpoint), target)
}
data class OfflineFetchIdentity(val endpoint: String, val target: OfflineFetchTarget)
enum class OfflineFetchOutcome { COMPLETED, PAUSED }
data class OfflineFetchState(val foreground: Boolean, val connected: Boolean, val inFlight: Set<OfflineFetchIdentity>, val tracked: List<OfflineFetchRequest>)
data class OfflineFetchFailure(val identity: OfflineFetchIdentity, val message: String)

/** Pure Swift-equivalent priority/fairness policy. The runtime owns actual tasks. */
class OfflineFetchQueue {
	var foreground = true; private set
	var connected = true; private set
	val isPaused: Boolean get() = !foreground || !connected
	private val active = mutableSetOf<OfflineFetchIdentity>()
	private val backgroundActive = mutableSetOf<OfflineFetchIdentity>()
	private var tracked = emptyList<OfflineFetchRequest>()
	private val oneShots = mutableListOf<OfflineFetchRequest>()
	private val lastStarted = mutableMapOf<OfflineFetchIdentity, Double>()
	private val sequence = mutableMapOf<OfflineFetchIdentity, Long>()
	private var nextSequence = 0L
	val state: OfflineFetchState get() = OfflineFetchState(foreground, connected, active.toSet(), tracked.toList())
	fun setForeground(value: Boolean) { foreground = value }
	fun setConnected(value: Boolean) { if (value && !connected) lastStarted.clear(); connected = value }
	fun track(requests: List<OfflineFetchRequest>) {
		tracked = requests.groupBy { it.identity }.values.map { values -> values.minBy { it.priority.ordinal } }
		val identities = (tracked.map { it.identity } + oneShots.map { it.identity } + active).toSet()
		lastStarted.keys.retainAll(identities); sequence.keys.retainAll(identities)
	}
	fun request(request: OfflineFetchRequest) {
		if (request.identity in active) return
		val index = oneShots.indexOfFirst { it.identity == request.identity }
		if (index < 0) oneShots += request else if (request.priority < oneShots[index].priority) oneShots[index] = request
	}
	fun cancelPending(): List<OfflineFetchIdentity> = oneShots.map { it.identity }.also { oneShots.clear() }
	fun next(now: Double): List<OfflineFetchRequest> {
		if (isPaused) return emptyList()
		val merged = oneShots.map { it to true }.toMutableList()
		for (request in tracked.filter { lastStarted[it.identity]?.let { last -> now - last >= it.priority.interval } ?: true }) {
			val index = merged.indexOfFirst { it.first.identity == request.identity }
			if (index < 0) merged += request to false
			else if (request.priority < merged[index].first.priority) merged[index] = request to merged[index].second
		}
		val ready = merged.withIndex().sortedWith(compareBy<IndexedValue<Pair<OfflineFetchRequest, Boolean>>> { it.value.first.priority.ordinal }
			.thenBy { if (it.value.second) 0 else 1 }.thenBy { sequence[it.value.first.identity] ?: 0L }.thenBy { it.index })
		val started = mutableListOf<OfflineFetchRequest>()
		for ((_, pair) in ready) {
			val request = pair.first
			if (active.size >= 3) break
			if (request.identity in active || request.priority == OfflineFetchPriority.BACKGROUND && backgroundActive.size >= 2) continue
			active += request.identity
			if (request.priority == OfflineFetchPriority.BACKGROUND) backgroundActive += request.identity
			lastStarted[request.identity] = now; sequence[request.identity] = ++nextSequence
			oneShots.removeAll { it.identity == request.identity }; started += request
		}
		return started
	}
	fun finish(request: OfflineFetchRequest) { active -= request.identity; backgroundActive -= request.identity }
	fun nextDue(now: Double): Double? {
		if (isPaused || active.size >= 3) return null
		fun eligible(request: OfflineFetchRequest) = request.identity !in active && (request.priority != OfflineFetchPriority.BACKGROUND || backgroundActive.size < 2)
		if (oneShots.any(::eligible)) return now
		return tracked.filter(::eligible).map { (lastStarted[it.identity]?.plus(it.priority.interval) ?: now).coerceAtLeast(now) }.minOrNull()
	}
}

/** UI supplies fetch+save+apply; all manual/selected/prefetch requests share the same three slots. */
class TransitRefreshCoordinator(
	private val scope: CoroutineScope,
	private val fetch: suspend (OfflineFetchRequest) -> Unit,
	private val clock: () -> Double = { System.currentTimeMillis() / 1000.0 },
) {
	private val mutex = Mutex()
	private val queue = OfflineFetchQueue()
	private val waiters = mutableMapOf<OfflineFetchIdentity, MutableList<CompletableDeferred<OfflineFetchOutcome>>>()
	private var wake: Job? = null
	private val _state = MutableStateFlow(queue.state)
	val state: StateFlow<OfflineFetchState> = _state
	private val _failures = MutableStateFlow<List<OfflineFetchFailure>>(emptyList())
	val failures: StateFlow<List<OfflineFetchFailure>> = _failures

	suspend fun request(request: OfflineFetchRequest): OfflineFetchOutcome {
		val waiter = CompletableDeferred<OfflineFetchOutcome>()
		mutex.withLock {
			if (queue.isPaused) return OfflineFetchOutcome.PAUSED
			waiters.getOrPut(request.identity) { mutableListOf() }.add(waiter)
			queue.request(request); pump()
		}
		try { return waiter.await() }
		finally { kotlinx.coroutines.withContext(kotlinx.coroutines.NonCancellable) { mutex.withLock { waiters[request.identity]?.let { values -> values.remove(waiter); if (values.isEmpty()) waiters.remove(request.identity) } } } }
	}
	suspend fun updatePlan(requests: List<OfflineFetchRequest>) { mutex.withLock { queue.track(requests); pump() } }
	suspend fun setForeground(value: Boolean) { mutex.withLock { queue.setForeground(value); pausePending(); pump() } }
	suspend fun setConnected(value: Boolean) { mutex.withLock { queue.setConnected(value); pausePending(); pump() } }
	suspend fun stop() { mutex.withLock { queue.track(emptyList()); queue.setForeground(false); pausePending(); pump() } }
	private fun pausePending() {
		if (!queue.isPaused) return
		queue.cancelPending().forEach { identity -> waiters.remove(identity)?.forEach { it.complete(OfflineFetchOutcome.PAUSED) } }
	}
	private fun pump() {
		wake?.cancel(); wake = null
		if (!scope.isActive) { queue.setForeground(false); pausePending(); _state.value = queue.state; return }
		queue.next(clock()).forEach { request ->
			scope.launch {
				try { TransitFetchSlots.run(request.priority) { fetch(request) } }
				catch (error: CancellationException) { throw error }
				catch (error: Exception) { _failures.value = (_failures.value + OfflineFetchFailure(request.identity, error.message ?: "Transit refresh failed.")).takeLast(32) }
				finally {
					// Release capacity even when the caller's scope is being cancelled.
					kotlinx.coroutines.withContext(kotlinx.coroutines.NonCancellable) {
						mutex.withLock {
							queue.finish(request)
							waiters.remove(request.identity)?.forEach { it.complete(OfflineFetchOutcome.COMPLETED) }
							pump()
						}
					}
				}
			}
		}
		_state.value = queue.state
		queue.nextDue(clock())?.let { due ->
			if (due > clock()) wake = scope.launch { delay(((due - clock()).coerceAtLeast(0.001) * 1000).toLong()); mutex.withLock { pump() } }
		}
	}
}

/** App foreground, manual and widget work all share this process-wide capacity. */
object TransitFetchSlots {
	private val all = Semaphore(3)
	private val prefetch = Semaphore(2)
	suspend fun <T> run(priority: OfflineFetchPriority, operation: suspend () -> T): T =
		if (priority == OfflineFetchPriority.BACKGROUND) prefetch.withPermit { all.withPermit { operation() } }
		else all.withPermit { operation() }
}
