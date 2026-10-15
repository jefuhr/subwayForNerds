package nyc.juliet.subwaysfornerds.widgets.runtime

import androidx.work.Operation
import androidx.work.await
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/** Enqueue/cancel return before their database transaction; receiver lifetimes wait for it. */
internal suspend fun awaitWidgetOperations(operations: List<Operation>) {
	var failure: Throwable? = null
	for (operation in operations) {
		try { operation.await() }
		catch (error: Throwable) {
			// A cancelled caller stops waiting. A failed/cancelled operation still leaves other
			// submitted database writes to finish before the receiver releases its lifetime.
			currentCoroutineContext().ensureActive()
			if (failure == null) failure = error
			else if (failure !== error) failure.addSuppressed(error)
		}
	}
	failure?.let { throw it }
}
