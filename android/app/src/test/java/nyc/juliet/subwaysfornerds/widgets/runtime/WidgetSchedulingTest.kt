package nyc.juliet.subwaysfornerds.widgets.runtime

import androidx.work.impl.utils.futures.SettableFuture
import androidx.lifecycle.LiveData
import androidx.work.Operation
import com.google.common.util.concurrent.ListenableFuture
import java.io.IOException
import kotlinx.coroutines.async
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class WidgetSchedulingTest {
	@Test fun lifetimeWaitsUntilEverySubmittedOperationCommits() = runTest {
		val periodic = PendingOperation()
		val manual = PendingOperation()
		var completed = false
		launch { awaitWidgetOperations(listOf(periodic, manual)); completed = true }
		runCurrent()
		assertFalse(completed)
		periodic.future.set(Operation.SUCCESS)
		runCurrent()
		assertFalse("One cancellation is still pending", completed)
		manual.future.set(Operation.SUCCESS)
		runCurrent()
		assertTrue(completed)
	}

	@Test fun failedSubmissionCannotReportSuccessfulCompletion() = runTest {
		val operation = PendingOperation()
		val failure = IOException("WorkManager database write failed")
		val outcome = async { runCatching { awaitWidgetOperations(listOf(operation)) } }
		runCurrent()
		assertFalse(outcome.isCompleted)
		operation.future.setException(failure)
		val error = outcome.await().exceptionOrNull()
		assertTrue(error is IOException)
		assertEquals(failure.message, error?.message)
		// Coroutine stack-trace recovery can copy the exception and retain it as the cause.
		assertTrue(generateSequence(error) { it.cause }.any { it === failure })
	}

	@Test fun cancellationDoesNotPublishCompletionOrBlockTheCaller() = runTest {
		val operation = PendingOperation()
		var completed = false
		val waiting = launch { awaitWidgetOperations(listOf(operation)); completed = true }
		runCurrent()
		waiting.cancel()
		runCurrent()
		assertTrue(waiting.isCancelled)
		assertFalse(completed)
	}

	@Test fun aFailedFirstOperationStillWaitsForTheOtherSubmittedWrite() = runTest {
		val periodic = PendingOperation()
		val manual = PendingOperation()
		val outcome = async { runCatching { awaitWidgetOperations(listOf(periodic, manual)) } }
		runCurrent()
		periodic.future.setException(IOException("Periodic cancellation failed"))
		runCurrent()
		assertFalse("The manual cancellation has not committed yet", outcome.isCompleted)
		manual.future.set(Operation.SUCCESS)
		assertTrue(outcome.await().isFailure)
	}

	@Test fun aCancelledOperationStillWaitsForTheOtherSubmittedWrite() = runTest {
		val periodic = PendingOperation()
		val manual = PendingOperation()
		val outcome = async { runCatching { awaitWidgetOperations(listOf(periodic, manual)) } }
		runCurrent()
		periodic.future.cancel(false)
		runCurrent()
		assertFalse("A cancelled operation is separate from cancelling the receiver", outcome.isCompleted)
		manual.future.set(Operation.SUCCESS)
		assertTrue(outcome.await().isFailure)
	}

	private class PendingOperation : Operation {
		val future = SettableFuture.create<Operation.State.SUCCESS>()
		override fun getResult(): ListenableFuture<Operation.State.SUCCESS> = future
		override fun getState(): LiveData<Operation.State> = error("Completion must use the durable result, not observed state")
	}
}
