package nyc.juliet.subwaysfornerds

import android.appwidget.AppWidgetHost
import android.appwidget.AppWidgetHostView
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProviderInfo
import android.content.ComponentName
import android.content.Context
import android.os.Bundle
import android.os.Process
import android.util.SizeF
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.RemoteViews
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.ComposeTimeoutException
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.core.view.drawToBitmap
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import androidx.work.WorkInfo
import nyc.juliet.subwaysfornerds.core.Board
import nyc.juliet.subwaysfornerds.core.Departure
import nyc.juliet.subwaysfornerds.core.OfflineSettings
import nyc.juliet.subwaysfornerds.core.Settings
import nyc.juliet.subwaysfornerds.core.SourceState
import nyc.juliet.subwaysfornerds.core.Station
import nyc.juliet.subwaysfornerds.core.StationSettings
import nyc.juliet.subwaysfornerds.core.StopPrediction
import nyc.juliet.subwaysfornerds.core.Train
import nyc.juliet.subwaysfornerds.core.TripDetail
import nyc.juliet.subwaysfornerds.data.AndroidSettingsStore
import nyc.juliet.subwaysfornerds.data.AndroidTransitCache
import nyc.juliet.subwaysfornerds.ui.AppWidgetHooks
import nyc.juliet.subwaysfornerds.ui.DeepLink
import nyc.juliet.subwaysfornerds.ui.DeepLinks
import nyc.juliet.subwaysfornerds.ui.theme.AppTheme
import nyc.juliet.subwaysfornerds.widgets.runtime.WidgetRuntime
import nyc.juliet.subwaysfornerds.widgets.ui.TransitWidgetReceiver
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.runner.RunWith
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * The real home-screen widget in a real AppWidgetHost: this test hosts the app's own
 * TransitWidgetReceiver, binds a widget ID to it and reads the RemoteViews the system delivers,
 * then clicks the rendered views so their PendingIntents start the real refresh work and open
 * the real activity. Preview composables are not used.
 *
 * Synthetic boards and rides carry fresh source times relative to the device clock, because the
 * widget runtime always uses the device clock; they are reported as synthetic coverage. The one
 * recorded-HTTP case refreshes from the coordinator's fixture server and is skipped without it.
 * Every widget update is asserted on the next frames, without waiting out Glance sessions.
 */
@RunWith(AndroidJUnit4::class)
class WidgetHostAcceptanceTest {
	private val network = NativeNetworkAcceptanceRule()
	private val compose = createEmptyComposeRule()
	@get:Rule val rules: RuleChain = RuleChain.outerRule(network).around(compose)

	private val context: Context get() = network.context
	private val instrumentation get() = network.instrumentation
	private var host: RecordingHost? = null
	private var hostScenario: ActivityScenario<ComponentActivity>? = null
	/** Shell commands that granted bind permission, when one had to; revoked in teardown. */
	private val grantCommands = mutableListOf<String>()

	@After
	fun removeTestHost() {
		host?.let { owned ->
			val ids = runCatching { owned.appWidgetIds.toList() }.getOrDefault(emptyList())
			ids.forEach { id -> runCatching { owned.deleteAppWidgetId(id) } }
			runCatching { owned.stopListening() }
			runCatching { owned.deleteHost() }
			network.evidence.note("deleted test host $HOST_ID and its widget IDs $ids")
		}
		host = null
		hostScenario?.close()
		hostScenario = null
		grantCommands.forEach { command -> runCatching { network.shell("$command revokebind --package ${context.packageName} --user ${Process.myUid() / 100_000}") } }
		grantCommands.clear()
	}

	@Test
	fun hostedWidgetShowsBothDirectionsWithClocksAndSourceTimeThenOpensItsBoard() {
		val fixture = SyntheticTransit(network.deviceNow())
		network.evidence.note("coverage: synthetic boards with source time ${fixture.source} on the device clock (not recorded HTTP); closed endpoint")
		prepare(Settings(favorites = listOf(fixture.union.id)), lastStation = fixture.bedford.id, catalog = fixture.catalog, boards = listOf(fixture.unionBoard, fixture.bedfordBoard))
		network.installApp()
		val widget = bindWidget()
		settleRefreshWork()

		// The runtime reads the saved board as an offline copy: clocks, both directions, source age.
		val saved = awaitWidget(widget, "the saved board in both directions") { it.has(fixture.union.name) && it.showsUnionRows(fixture, cached = true) }
		assertTrue("Saved rows must carry an offline label with their source age: $saved", saved.texts.any { OFFLINE_REPORT.matches(it) })
		assertTrue("Both direction columns: $saved", saved.descriptions.containsAll(listOf("Northbound", "Southbound")))
		widget.save("01-saved-board")

		// The app's saved-board hook publishes fetched rows; the next frames show live clocks and the source time.
		network.io { WidgetRuntime.boardSaved(context, fixture.unionBoard) }
		val live = awaitWidget(widget, "the published board to render live") { it.has("As of ${fixture.clock(fixture.source, true)}") && it.showsUnionRows(fixture, cached = false) }
		assertFalse("Live rows must not keep offline labels: $live", live.texts.any { OFFLINE_REPORT.matches(it) })
		widget.save("02-live-board")
		network.screenshot("02-live-board-host")

		// The widget's own tap target opens the real activity on the widget's station, not the app's last station.
		widget.click(widget.openTarget())
		val activity = awaitMainActivity()
		assertEquals(DeepLink.Station(fixture.union.id), DeepLinks.parse(activity.intent?.data?.toString()))
		awaitCompose("the board for ${fixture.union.name}") { texts("selectedStation").contains(fixture.union.name) }
		network.screenshot("03-board-deep-link")
	}

	@Test
	fun themeFilterAndRefreshChangesRedrawTheHostedWidget() {
		val fixture = SyntheticTransit(network.deviceNow())
		network.evidence.note("coverage: synthetic board on the device clock (not recorded HTTP); closed endpoint so manual refresh cannot reach a server")
		val settings = Settings(favorites = listOf(fixture.union.id))
		prepare(settings, lastStation = fixture.union.id, catalog = fixture.catalog, boards = listOf(fixture.unionBoard))
		network.installApp()
		val widget = bindWidget()
		settleRefreshWork()
		network.io { WidgetRuntime.boardSaved(context, fixture.unionBoard) }
		awaitWidget(widget, "the live board") { it.showsUnionRows(fixture, cached = false) && it.descriptions.any { row -> row.startsWith("Q to ") } }
		assertColor(widget, "subway")
		widget.save("01-before-theme-filter")

		// The production settings hook: save, reschedule and redraw every placed widget.
		val changed = settings.copy(theme = "hello-kitty", widgets = settings.widgets.copy(stations = mapOf(fixture.union.id to StationSettings(routes = listOf("L"), view = "direction"))))
		network.io {
			AndroidSettingsStore(context).save(changed)
			AppWidgetHooks(context).settingsChanged()
		}
		val filtered = awaitWidget(widget, "the hello-kitty theme and the L-only filter") { rendered ->
			rendered.rows().isNotEmpty() && rendered.rows().none { it.startsWith("Q to ") } && rendered.showsUnionRows(fixture, cached = false, routes = setOf("L")) && widget.background() matches "hello-kitty"
		}
		assertTrue("Filtered widget keeps both directions: $filtered", filtered.rows().any { ", Northbound, " in it } && filtered.rows().any { ", Southbound, " in it })
		widget.save("02-theme-filter")

		// The refresh button runs the runtime's one-shot refresh; with no reachable server the rows become labeled estimates.
		val before = network.refreshWork().map { it.id }.toSet()
		widget.click(widget.refreshTarget())
		network.waitFor(30_000, "the refresh button's work to run") {
			network.refreshWork().any { it.id !in before && it.periodicityInfo == null && it.state == WorkInfo.State.SUCCEEDED }
		}
		network.evidence.note("refresh button work: ${network.describe(network.refreshWork().filter { it.id !in before })}")
		val refreshed = awaitWidget(widget, "the failed refresh to relabel rows as offline estimates") {
			it.texts.any { text -> OFFLINE_REPORT.matches(text) } && it.showsUnionRows(fixture, cached = true, routes = setOf("L")) && widget.background() matches "hello-kitty"
		}
		assertFalse("A failed refresh must not keep the live source label: $refreshed", refreshed.texts.any { it.startsWith("As of ") })
		widget.save("03-after-refresh-unreachable")
	}

	@Test
	fun refreshButtonLoadsTheRecordedBoardThroughTheWidgetRuntime() {
		val server = network.requireRecordedServer()
		val recordedBoard = network.io { network.client().board(server.station) }
		assertTrue("Station ${server.station} is not in the recorded catalog", network.io { network.client().stations() }.any { it.id == server.station })
		network.evidence.note("coverage: recorded-HTTP board ${server.station} (${recordedBoard.departures.size} rows) fetched by the widget runtime; widget clock is the device clock, not SFN_TEST_NOW")
		// Placed while the endpoint is closed, so the automatic refreshes on placement cannot load anything.
		network.selectEndpoint(NativeNetworkAcceptanceRule.CLOSED_ENDPOINT, null)
		prepare(Settings(favorites = listOf(server.station)), lastStation = server.station, catalog = emptyList(), boards = emptyList())
		network.installApp()
		val widget = bindWidget()
		settleRefreshWork()
		awaitWidget(widget, "the empty widget") { it.texts.any { text -> text == "Open the app to load your stations." } }
		widget.save("01-before-refresh")

		// The debug endpoint setting points the runtime at the fixture server; only the refresh button fetches.
		network.selectEndpoint(server.endpoint, server.now)
		val before = network.refreshWork().map { it.id }.toSet()
		widget.click(widget.refreshTarget())
		network.waitFor(30_000, "the refresh button's work to run") {
			network.refreshWork().any { it.id !in before && it.periodicityInfo == null && it.state == WorkInfo.State.SUCCEEDED }
		}
		val recordedDestinations = recordedBoard.departures.map { it.destination }.toSet()
		val rendered = awaitWidget(widget, "the recorded board", 30_000) { it.has(recordedBoard.station.name) && it.rows().isNotEmpty() }
		val rows = rendered.rows()
		assertTrue("Rows must come from the recorded board: $rows", rows.all { row -> recordedDestinations.any { row.contains(" to $it, ") } })
		assertTrue("Recorded rows are older than the device clock and must be labeled offline estimates: $rows", rows.all { it.contains(", offline estimate") })
		assertTrue("The report time must say these are last known times: ${rendered.texts}", rendered.texts.any { LAST_KNOWN_REPORT.matches(it) })
		assertFalse("Recorded data must never be labeled as a current report: ${rendered.texts}", rendered.texts.any { it.startsWith("As of ") })
		val saved = network.io { AndroidTransitCache(context, server.endpoint).boardSnapshot(server.station) } ?: throw AssertionError("The refresh did not save the recorded board.")
		val recordedByKey = recordedBoard.departures.associateBy { it.key }
		saved.board.departures.forEach { row -> assertEquals("Saved time for ${row.key}", recordedByKey[row.key]?.time, row.time) }
		widget.save("02-recorded-board")
	}

	@Test
	fun hostedRideWidgetShowsTheEstimatedNextStopAndOpensTheRide() {
		val fixture = SyntheticTransit(network.deviceNow())
		network.evidence.note("coverage: synthetic active ride with source time ${fixture.source} on the device clock (not recorded HTTP); closed endpoint")
		val settings = Settings(favorites = listOf(fixture.union.id), offline = OfflineSettings(widgetsFollowActiveRide = true))
		prepare(settings, lastStation = fixture.union.id, catalog = fixture.catalog, boards = listOf(fixture.unionBoard), ride = fixture.ride)
		network.installApp()
		val widget = bindWidget()
		settleRefreshWork()
		val next = fixture.ride.train.stops[1]
		val rendered = awaitWidget(widget, "the active ride") {
			it.has("Your ride") && it.has(fixture.ride.train.destination) && it.has("Estimated next stop") && it.has(next.name) && it.has(fixture.clock(next.arrival!!, false))
		}
		assertTrue("Ride times are estimates with their source age: $rendered", rendered.texts.any { OFFLINE_REPORT.matches(it) })
		assertFalse("The stop already passed is not shown as next: $rendered", rendered.has(fixture.ride.train.stops[0].name))
		widget.save("01-ride")

		widget.click(widget.openTarget())
		val activity = awaitMainActivity()
		assertEquals(DeepLink.Ride(fixture.ride.train.key), DeepLinks.parse(activity.intent?.data?.toString()))
		awaitCompose("the ride's train details") { texts("trainDetails").contains(fixture.ride.train.destination) && texts("trainDetails").any { "kept for your ride" in it } }
		assertTrue("Ride details opened from the widget are labeled offline estimates", texts("offlineEstimateLabel").isNotEmpty())
		network.screenshot("02-ride-deep-link")
	}

	// MARK: Fixture

	private fun prepare(settings: Settings, lastStation: String, catalog: List<Station>, boards: List<Board>, ride: TripDetail? = null) {
		network.persist(settings, lastStation)
		network.io {
			val cache = network.cache()
			cache.setPreferences(settings.offline)
			if (catalog.isNotEmpty()) cache.saveCatalog(catalog)
			boards.forEach { cache.saveBoard(it) }
			if (ride != null) { cache.saveTrip(ride); cache.setActiveRide(ride.train.key) }
		}
		network.evidence.note("prepared ${catalog.size} stations, ${boards.size} boards, ride ${ride?.train?.key} before placing the widget")
	}

	/** Synthetic stations, boards and a ride; source times are fresh on the device clock and named as synthetic. */
	private class SyntheticTransit(val now: Double) {
		val source = now - 5
		val union = Station("e2e-synthetic-union", "Synthetic Union Sq", "M", listOf("L", "Q"), 40.7359, -73.9906)
		val bedford = Station("e2e-synthetic-bedford", "Synthetic Bedford Av", "Bk", listOf("L"), 40.7172, -73.9567)
		val catalog = listOf(union, bedford)
		val unionRows = listOf(
			row(union, "L", "8 Av", "NORTH", 240), row(union, "Q", "96 St", "NORTH", 420), row(union, "L", "8 Av", "NORTH", 780),
			row(union, "L", "Canarsie-Rockaway Pkwy", "SOUTH", 300), row(union, "Q", "Coney Island-Stillwell Av", "SOUTH", 540),
		)
		val unionBoard = board(union, unionRows)
		val bedfordBoard = board(bedford, listOf(row(bedford, "L", "8 Av", "NORTH", 360), row(bedford, "L", "Canarsie-Rockaway Pkwy", "SOUTH", 480)))
		val ride = TripDetail(Train(
			key = "e2e-synthetic-ride|L|${now.toLong()}", feed = "gtfs-l", tripId = "e2e-synthetic-ride", route = "L", destination = "8 Av", direction = "NORTH",
			timestamp = source, staleAfter = 290.0, assigned = true,
			stops = listOf(
				StopPrediction("L08N", "Bedford Av", stationId = bedford.id, arrival = now - 120, departure = now - 90),
				StopPrediction("L06N", "1 Av", arrival = now + 180),
				StopPrediction("L03N", "Union Sq", stationId = union.id, arrival = now + 360),
				StopPrediction("L01N", "8 Av", arrival = now + 600),
			),
		))

		private fun row(station: Station, route: String, destination: String, direction: String, inSeconds: Int) = Departure(
			key = "e2e-synthetic|${station.id}|$route|$direction|$inSeconds", tripKey = "e2e-synthetic-trip|${station.id}|$route|$direction|$inSeconds",
			route = route, destination = destination, direction = direction, stopId = "${station.id}-${direction.first()}", partId = station.id,
			area = "Synthetic platform", time = now + inSeconds, arrival = now + inSeconds, pattern = "", patternSource = "reported", location = "",
			feed = feed(route), timestamp = source, staleAfter = 290.0,
		)

		private fun board(station: Station, rows: List<Departure>) = Board(
			station, generatedAt = source, departures = rows,
			sources = rows.map { feed(it.route) }.distinct().map { SourceState(it, timestamp = source, fetchedAt = source, staleAfter = 290.0) },
		)

		private fun feed(route: String) = if (route == "L") "gtfs-l" else "gtfs-nqrw"

		/** Widget arrival clocks drop AM/PM; report times keep it. New York time, like the app. */
		fun clock(seconds: Double, withPeriod: Boolean): String =
			DateTimeFormatter.ofPattern(if (withPeriod) "h:mm a" else "h:mm", Locale.US).withZone(ZoneId.of("America/New_York")).format(Instant.ofEpochMilli((seconds * 1000).toLong()))
	}

	/** Union Sq rows, optionally limited to routes, each with its arrival clock and live or offline label. */
	private fun Rendered.showsUnionRows(fixture: SyntheticTransit, cached: Boolean, routes: Set<String> = setOf("L", "Q")): Boolean {
		val expected = fixture.unionRows.filter { it.route in routes }
		val label = if (cached) ", offline estimate" else ", estimated arrival"
		return expected.all { row ->
			val direction = if (row.direction == "NORTH") "Northbound" else "Southbound"
			rows().any { it.startsWith("${row.route} to ${row.destination}, $direction, arriving ${fixture.clock(row.time!!, false)}$label") }
		} && expected.all { has(fixture.clock(it.time!!, false)) }
	}

	// MARK: Hosting

	/** Places the app's widget in this test's own AppWidgetHost, inside a plain host activity. */
	private fun bindWidget(): HostedWidget {
		val manager = AppWidgetManager.getInstance(context)
		val provider = ComponentName(context, TransitWidgetReceiver::class.java)
		assertTrue("TransitWidgetReceiver is not an installed widget provider", manager.getInstalledProvidersForPackage(context.packageName, null).any { it.provider == provider })
		val owned = RecordingHost(context, HOST_ID).also { host = it }
		owned.startListening()
		val id = owned.allocateAppWidgetId()
		val how = bindProvider(manager, id, provider)
		val info = manager.getAppWidgetInfo(id) ?: throw AssertionError("No provider info for bound widget $id")
		val scenario = ActivityScenario.launch(ComponentActivity::class.java).also { hostScenario = it }
		var view: RecordingHostView? = null
		scenario.onActivity { activity ->
			val density = activity.resources.displayMetrics.density
			val created = owned.createView(activity, id, info) as RecordingHostView
			activity.setContentView(FrameLayout(activity).apply {
				addView(created, FrameLayout.LayoutParams((WIDTH_DP * density).roundToInt(), (HEIGHT_DP * density).roundToInt()))
			})
			created.updateAppWidgetSize(Bundle(), listOf(SizeF(WIDTH_DP, HEIGHT_DP)))
			view = created
		}
		network.evidence.note("bound widget $id in test host $HOST_ID via $how; ${WIDTH_DP}x$HEIGHT_DP dp")
		return HostedWidget(id, view!!)
	}

	/** Binding needs BIND_APPWIDGET: the shell's identity for this call, or a grant that is revoked afterwards. */
	private fun bindProvider(manager: AppWidgetManager, id: Int, provider: ComponentName): String {
		if (manager.bindAppWidgetIdIfAllowed(id, provider)) return "an existing bind grant"
		val automation = instrumentation.uiAutomation
		automation.adoptShellPermissionIdentity("android.permission.BIND_APPWIDGET")
		try {
			if (runCatching { manager.bindAppWidgetIdIfAllowed(id, provider) }.getOrDefault(false)) return "the shell's BIND_APPWIDGET for this call"
		} finally {
			automation.dropShellPermissionIdentity()
		}
		for (command in listOf("cmd appwidget", "appwidget")) {
			network.shell("$command grantbind --package ${context.packageName} --user ${Process.myUid() / 100_000}")
			grantCommands += command
			if (manager.bindAppWidgetIdIfAllowed(id, provider)) return "$command grantbind (revoked after the test)"
		}
		throw AssertionError("Could not bind the widget: no BIND_APPWIDGET from the shell identity or appwidget grantbind")
	}

	/** Waits until the runtime's own refreshes started by placing the widget have finished. */
	private fun settleRefreshWork() {
		network.waitFor(60_000, "the runtime's placement refresh work to finish") {
			val work = network.refreshWork()
			work.any { it.periodicityInfo != null } && work.all {
				it.state.isFinished || it.periodicityInfo != null && it.state == WorkInfo.State.ENQUEUED && it.nextScheduleTimeMillis > System.currentTimeMillis() + 60_000
			}
		}
		network.evidence.note("placement refresh work settled: ${network.describe(network.refreshWork())}")
	}

	private fun awaitWidget(widget: HostedWidget, what: String, timeout: Long = 15_000, condition: (Rendered) -> Boolean): Rendered {
		var last: Rendered? = null
		try {
			network.waitFor(timeout, what) { widget.rendered().also { last = it }.let(condition) }
		} catch (error: AssertionError) {
			throw AssertionError("${error.message}; the hosted widget shows $last")
		}
		network.evidence.note("widget rendered $what after ${last?.updates} RemoteViews updates")
		return last!!
	}

	private fun assertColor(widget: HostedWidget, theme: String) {
		val color = widget.background()
		assertTrue("Widget background #${Integer.toHexString(color)} is not the $theme theme", color matches theme)
	}

	private infix fun Int.matches(theme: String): Boolean {
		val expected = AppTheme.forId(theme).background.toArgb()
		return this ushr 24 == 255 && listOf(16, 8, 0).all { shift -> abs((this shr shift and 255) - (expected shr shift and 255)) <= 3 }
	}

	private fun awaitMainActivity(): MainActivity {
		var found: MainActivity? = null
		network.waitFor(20_000, "the widget link to open MainActivity") {
			instrumentation.runOnMainSync { found = ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED).filterIsInstance<MainActivity>().firstOrNull() }
			found != null
		}
		network.evidence.note("MainActivity resumed with ${found?.intent?.data}")
		return found!!
	}

	private fun awaitCompose(what: String, condition: () -> Boolean) {
		try { compose.waitUntil(30_000, condition) } catch (_: ComposeTimeoutException) { throw AssertionError("Timed out waiting for $what") }
	}

	private fun texts(tag: String): List<String> = compose.onAllNodesWithTag(tag, useUnmergedTree = true).fetchSemanticsNodes(atLeastOneRootRequired = false).flatMap { allTexts(it) }

	private fun allTexts(node: SemanticsNode): List<String> = node.config.getOrNull(SemanticsProperties.Text).orEmpty().map { it.text } + node.children.flatMap { allTexts(it) }

	/** Text and spoken descriptions in a hosted widget, read from the applied RemoteViews. */
	private class Rendered(val texts: List<String>, val descriptions: List<String>, val updates: Int) {
		fun has(text: String) = text in texts
		/** Train rows describe route, destination, direction and arrival. */
		fun rows(): List<String> = descriptions.filter { ", arriving " in it || ", estimate passed" in it }
		override fun toString() = "texts=$texts descriptions=$descriptions updates=$updates"
	}

	private inner class HostedWidget(val id: Int, val view: RecordingHostView) {
		fun rendered(): Rendered {
			var value: Rendered? = null
			instrumentation.runOnMainSync {
				val texts = mutableListOf<String>()
				val descriptions = mutableListOf<String>()
				visible(view).forEach { child ->
					if (child is TextView) child.text?.toString()?.takeIf { it.isNotEmpty() }?.let { texts += it }
					child.contentDescription?.toString()?.takeIf { it.isNotEmpty() }?.let { descriptions += it }
				}
				value = Rendered(texts, descriptions, view.updates)
			}
			return value!!
		}

		/**
		 * The background just inside the widget root's top padding. The host view pads the root
		 * for the launcher grid, so the root (the largest tap target) is drawn and sampled itself.
		 */
		fun background(): Int {
			var color = 0
			instrumentation.runOnMainSync {
				color = runCatching {
					val root = visible(view).filter { it.hasOnClickListeners() }.maxByOrNull { it.width * it.height } ?: view
					val bitmap = root.drawToBitmap()
					bitmap.getPixel(bitmap.width / 2, (4 * root.resources.displayMetrics.density).roundToInt())
				}.getOrDefault(0)
			}
			return color
		}

		/** The whole widget's tap target: the largest clickable view. */
		fun openTarget(): View = onMain { visible(view).filter { it.hasOnClickListeners() }.maxByOrNull { it.width * it.height } } ?: throw AssertionError("The widget has no tap target: ${rendered()}")

		/** The refresh button, found by its spoken label. */
		fun refreshTarget(): View = onMain {
			val labeled = visible(view).firstOrNull { it.contentDescription?.toString() == "Refresh departures" } ?: return@onMain null
			generateSequence(labeled) { it.parent as? View }.takeWhile { it !== view }.firstOrNull { it.hasOnClickListeners() }
				?: visible(labeled).firstOrNull { it.hasOnClickListeners() }
		} ?: throw AssertionError("The widget has no refresh button: ${rendered()}")

		fun click(target: View) {
			var handled = false
			instrumentation.runOnMainSync { handled = target.performClick() }
			assertTrue("The widget view did not handle the click", handled)
			network.evidence.note("clicked widget view ${target.javaClass.simpleName} '${target.contentDescription ?: ""}'")
		}

		fun save(name: String) {
			var bitmap: android.graphics.Bitmap? = null
			instrumentation.runOnMainSync { bitmap = runCatching { view.drawToBitmap() }.getOrNull() }
			bitmap?.let { network.saveBitmap("widget-$name", it) }
		}

		private fun <T> onMain(block: () -> T): T {
			var value: Result<T>? = null
			instrumentation.runOnMainSync { value = runCatching(block) }
			return value!!.getOrThrow()
		}
	}

	private fun visible(root: View): List<View> = if (root.visibility != View.VISIBLE) emptyList() else
		listOf(root) + ((root as? ViewGroup)?.let { group -> (0 until group.childCount).flatMap { visible(group.getChildAt(it)) } } ?: emptyList())

	/** A host that hands out views counting the RemoteViews the system delivers. */
	private class RecordingHost(context: Context, id: Int) : AppWidgetHost(context, id) {
		override fun onCreateView(context: Context, appWidgetId: Int, appWidget: AppWidgetProviderInfo?): AppWidgetHostView = RecordingHostView(context)
	}

	private class RecordingHostView(context: Context) : AppWidgetHostView(context) {
		@Volatile var updates = 0; private set
		override fun updateAppWidget(remoteViews: RemoteViews?) {
			super.updateAppWidget(remoteViews)
			updates += 1
		}
	}

	private companion object {
		/** This test's own host; teardown deletes it and only its widget IDs. */
		const val HOST_ID = 0x53464E45
		const val WIDTH_DP = 320f
		const val HEIGHT_DP = 380f
		val OFFLINE_REPORT = Regex("^Offline estimate · \\d+[smh] ago$")
		val LAST_KNOWN_REPORT = Regex("^Last known times · \\d+[smh] ago$")
	}
}
