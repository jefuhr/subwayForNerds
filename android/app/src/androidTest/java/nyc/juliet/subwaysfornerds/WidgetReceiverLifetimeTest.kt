package nyc.juliet.subwaysfornerds

import android.appwidget.AppWidgetManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import androidx.core.content.ContextCompat
import androidx.glance.GlanceId
import androidx.glance.action.actionParametersOf
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.work.impl.WorkManagerImpl
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import nyc.juliet.subwaysfornerds.widgets.ui.RefreshWidgetAction
import nyc.juliet.subwaysfornerds.widgets.ui.TransitWidgetReceiver
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Actual receiver PendingResult ownership, with WorkManager's operation executor held on purpose. */
@RunWith(AndroidJUnit4::class)
class WidgetReceiverLifetimeTest {
	private val instrumentation = InstrumentationRegistry.getInstrumentation()
	private val context = instrumentation.targetContext

	@Before fun dedicatedEmulatorOnly() {
		check(BuildConfig.DEBUG && Build.HARDWARE in setOf("ranchu", "goldfish")) { "Receiver lifetime tests require a dedicated debug emulator." }
		check(InstrumentationRegistry.getArguments().getString("SFN_DEDICATED_AVD") == "sfn-android31-native") { "Explicit API 31 test-device authorization is required." }
		val actual = instrumentation.uiAutomation.executeShellCommand("getprop ro.boot.qemu.avd_name").use { descriptor ->
			android.os.ParcelFileDescriptor.AutoCloseInputStream(descriptor).bufferedReader().readText().trim()
		}
		check(actual == "sfn-android31-native") { "Refusing WorkManager mutation on $actual." }
	}

	@Test fun finalRemovalKeepsBroadcastOpenUntilWorkManagerCancellationCompletes() {
		val executor = WorkManagerImpl.getInstance(context).workTaskExecutor.serialTaskExecutor
		val holding = CountDownLatch(1)
		val release = CountDownLatch(1)
		executor.execute { holding.countDown(); check(release.await(8, TimeUnit.SECONDS)) }
		assertTrue("WorkManager test gate started", holding.await(5, TimeUnit.SECONDS))
		try {
			withOrderedRemoval { entered, finished ->
				try {
					assertTrue("The real receiver was called", entered.await(5, TimeUnit.SECONDS))
					val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(3)
					while (!executor.hasPendingTasks() && System.nanoTime() < deadline) Thread.sleep(10)
					assertTrue("Runtime cancellation reached WorkManager", executor.hasPendingTasks())
					assertFalse("PendingResult.finish ran before the WorkManager operation completed", finished.await(250, TimeUnit.MILLISECONDS))
					release.countDown()
					assertTrue("The broadcast finishes after durable cancellation", finished.await(5, TimeUnit.SECONDS))
				} finally { release.countDown(); finished.await(5, TimeUnit.SECONDS) }
			}
		} finally { release.countDown() }
	}

	@Test fun runtimeFailureStillFinishesTheBroadcast() {
		val failed = CountDownLatch(1)
		val broken = object : ContextWrapper(context) {
			override fun getApplicationContext(): Context = this
			override fun getSystemServiceName(serviceClass: Class<*>): String? {
				failed.countDown()
				throw IllegalStateException("Injected runtime service failure")
			}
		}
		withOrderedRemoval(broken) { entered, finished ->
			assertTrue(entered.await(5, TimeUnit.SECONDS))
			assertTrue("The runtime operation failed", failed.await(5, TimeUnit.SECONDS))
			assertTrue("Failure must not leak the broadcast lifetime", finished.await(5, TimeUnit.SECONDS))
		}
	}

	@Test fun updateKeepsTheMainLooperResponsiveWhileWorkManagerIsDelayed() = assertResponsive(AppWidgetManager.ACTION_APPWIDGET_UPDATE)

	@Test fun deletionKeepsTheMainLooperResponsiveWhileWorkManagerIsDelayed() = assertResponsive(AppWidgetManager.ACTION_APPWIDGET_DELETED)

	@Test fun manualRefreshAwaitsTheWorkManagerOperation() = runBlocking {
		val executor = WorkManagerImpl.getInstance(context).workTaskExecutor.serialTaskExecutor
		val holding = CountDownLatch(1)
		val release = CountDownLatch(1)
		executor.execute { holding.countDown(); check(release.await(8, TimeUnit.SECONDS)) }
		assertTrue(holding.await(5, TimeUnit.SECONDS))
		try {
			val refresh = async(Dispatchers.Default) {
				RefreshWidgetAction().onAction(context, object : GlanceId {}, actionParametersOf())
			}
			awaitQueuedOperation()
			// A queue-delay regression must observe the callback's lifetime, not just that work was submitted.
			Thread.sleep(250)
			assertFalse("The refresh action returned before its WorkManager operation completed", refresh.isCompleted)
			release.countDown()
			refresh.await()
		} finally { release.countDown() }
	}

	private fun assertResponsive(widgetAction: String) {
		val manager = WorkManagerImpl.getInstance(context)
		val before = manager.getWorkInfosForUniqueWork("appWidget-$WIDGET_ID").get(5, TimeUnit.SECONDS).map { it.id }.toSet()
		val executor = manager.workTaskExecutor.serialTaskExecutor
		val holding = CountDownLatch(1)
		val release = CountDownLatch(1)
		executor.execute { holding.countDown(); check(release.await(8, TimeUnit.SECONDS)) }
		assertTrue(holding.await(5, TimeUnit.SECONDS))
		try {
			withOrderedWidgetAction(widgetAction, deliveredOnMain = true) { entered, finished ->
				try {
					assertTrue("The real receiver was called", entered.await(5, TimeUnit.SECONDS))
					awaitQueuedOperation()
					val responsive = CountDownLatch(1)
					Handler(Looper.getMainLooper()).post { responsive.countDown() }
					assertTrue("The main looper was blocked by the pending WorkManager operation", responsive.await(500, TimeUnit.MILLISECONDS))
					assertFalse("Glance released the broadcast before durable work completed", finished.await(250, TimeUnit.MILLISECONDS))
					release.countDown()
					assertTrue("Glance finishes once durable work completes", finished.await(5, TimeUnit.SECONDS))
					if (widgetAction == AppWidgetManager.ACTION_APPWIDGET_UPDATE) {
						val persisted = manager.getWorkInfosForUniqueWork("appWidget-$WIDGET_ID").get(5, TimeUnit.SECONDS)
						assertTrue("The update persisted a new Glance session worker", persisted.any { it.id !in before && "androidx.glance.session.SessionWorker" in it.tags })
					}
				} finally { release.countDown(); finished.await(5, TimeUnit.SECONDS) }
			}
		} finally { release.countDown() }
	}

	private fun awaitQueuedOperation() {
		val executor = WorkManagerImpl.getInstance(context).workTaskExecutor.serialTaskExecutor
		val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(3)
		while (!executor.hasPendingTasks() && System.nanoTime() < deadline) Thread.sleep(10)
		assertTrue("The receiver operation reached WorkManager", executor.hasPendingTasks())
	}

	private fun withOrderedRemoval(runtimeContext: Context = context, assertions: (CountDownLatch, CountDownLatch) -> Unit) =
		withOrderedWidgetAction(AppWidgetManager.ACTION_APPWIDGET_DISABLED, runtimeContext, assertions = assertions)

	private fun withOrderedWidgetAction(widgetAction: String, runtimeContext: Context = context, deliveredOnMain: Boolean = false, assertions: (CountDownLatch, CountDownLatch) -> Unit) {
		val entered = CountDownLatch(1)
		val finished = CountDownLatch(1)
		val thread = HandlerThread("receiver-lifetime-test").apply { start() }
		val handler = Handler(thread.looper)
		val action = "${context.packageName}.TEST_WIDGET_LIFETIME"
		// Remap a private test action to the platform action, preserving this actual receiver's
		// framework-provided PendingResult. No protected broadcast is spoofed from another app.
		val receiver = LifetimeReceiver(runtimeContext, widgetAction, entered)
		ContextCompat.registerReceiver(context, receiver, IntentFilter(action), null, if (deliveredOnMain) Handler(Looper.getMainLooper()) else handler, ContextCompat.RECEIVER_NOT_EXPORTED)
		try {
			context.sendOrderedBroadcast(Intent(action).setPackage(context.packageName), null, object : BroadcastReceiver() {
				override fun onReceive(context: Context?, intent: Intent?) { finished.countDown() }
			}, handler, 0, null, null)
			assertions(entered, finished)
		} finally {
			context.unregisterReceiver(receiver)
			thread.quitSafely()
		}
	}

	/** Named so Glance's real receiver registry has the canonical name it requires. */
	class LifetimeReceiver(private val runtimeContext: Context, private val widgetAction: String, private val entered: CountDownLatch) : TransitWidgetReceiver() {
		override fun onReceive(context: Context, intent: Intent) {
			entered.countDown()
			// No host is allocated: this reserved, unbound ID exercises dispatch ownership only.
			super.onReceive(runtimeContext, Intent(widgetAction)
				.putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, WIDGET_ID)
				.putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, intArrayOf(WIDGET_ID)))
		}
	}

	private companion object { const val WIDGET_ID = 2_147_000_000 }
}
