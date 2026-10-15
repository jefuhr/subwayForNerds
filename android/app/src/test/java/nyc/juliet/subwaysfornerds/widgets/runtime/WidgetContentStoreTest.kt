package nyc.juliet.subwaysfornerds.widgets.runtime

import java.nio.file.Files
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runTest
import nyc.juliet.subwaysfornerds.core.*
import nyc.juliet.subwaysfornerds.data.ActiveRideRecord
import nyc.juliet.subwaysfornerds.data.CachedTrip
import org.junit.Assert.*
import org.junit.Test

class WidgetContentStoreTest {
	private val station = Station("station", "Station", "M", listOf("A"), 40.7, -74.0)
	private fun board(station: Station = this.station, time: Double): Board = Board(station, time, listOf(SourceState("gtfs-a", time)), listOf(
		Departure("trip", "trip", "A", "Uptown", "NORTH", "stop", "part", "Area", time + 300, pattern = "Local", patternSource = "reported", location = "", feed = "gtfs-a", timestamp = time)))
	private fun content(time: Double) = WidgetContent(endpoint = "fixture/", stationID = station.id, board = board(time = time), cached = false, refreshedAt = time)

	@Test fun delayedWidgetFetchCannotOverwriteNewerForegroundPublication() = runTest {
		val root = Files.createTempDirectory("sfn-widget-activation").toFile()
		try {
			val store = WidgetContentStore(root)
			val fetched = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
			val delayed = async { val candidate = content(100.0); fetched.complete(Unit); release.await(); store.activate(candidate.copy(refreshedAt = 300.0)) }
			fetched.await(); store.activate(content(200.0)); release.complete(Unit); delayed.await()
			assertEquals(200.0, store.read()!!.board!!.departures.single().timestamp, 0.0)
			assertEquals(200.0, WidgetContentStore(root).read()!!.board!!.sources.single().timestamp!!, 0.0)
		} finally { root.deleteRecursively() }
	}

	@Test fun combinedActivationMergesEachMemberInsteadOfReplacingNewerSourceGroups() {
		val root = Files.createTempDirectory("sfn-widget-member-activation").toFile()
		try {
			val store = WidgetContentStore(root); val other = station.copy(id = "other")
			val definition = CombinedStation("Combined", listOf(station.id, other.id))
			store.activate(WidgetContent(endpoint = "fixture/", stationID = "combined:test", definition = definition, refreshedAt = 200.0,
				members = listOf(SavedWidgetMember(station, board(time = 200.0), false), SavedWidgetMember(other, board(other, 100.0), false))))
			store.activate(WidgetContent(endpoint = "fixture/", stationID = "combined:test", definition = definition, refreshedAt = 300.0,
				members = listOf(SavedWidgetMember(station, board(time = 100.0), false), SavedWidgetMember(other, board(other, 300.0), false))))
			assertEquals(listOf(200.0, 300.0), store.read()!!.members.map { it.board!!.departures.single().timestamp })
		} finally { root.deleteRecursively() }
	}

	@Test fun rejectedFinalGuardPreservesThePreviouslyActivatedSnapshot() {
		val root = Files.createTempDirectory("sfn-widget-guard").toFile()
		try {
			val store = WidgetContentStore(root); store.activate(content(200.0))
			assertFalse(store.activate(content(300.0)) { false })
			assertEquals(200.0, store.read()!!.board!!.sources.single().timestamp!!, 0.0)
		} finally { root.deleteRecursively() }
	}

	@Test fun unsupportedPATHAndUnavailableActiveRideStillAllowStationFallback() {
		val settings = Settings(offline = OfflineSettings(widgetsFollowActiveRide = true))
		val path = ActiveRideRecord("path|unstable", startedAt = 100.0)
		val partialPATH = CachedTrip(path.key, departure = board(time = 100.0).departures.single().copy(tripKey = path.key), savedAt = 100.0, accessedAt = 100.0)
		assertNull(supportedWidgetRide(settings, path, partialPATH))
		assertTrue(acceptsWidgetContent(content(100.0), WidgetPublicationState("fixture/", station.id, null, supportedWidgetRide(settings, path, partialPATH))))
		val missing = ActiveRideRecord("trip", startedAt = 100.0)
		assertNull(supportedWidgetRide(settings, missing, null))
		assertTrue(acceptsWidgetContent(content(100.0), WidgetPublicationState("fixture/", station.id, null, supportedWidgetRide(settings, missing, null))))
	}

	@Test fun supportedRideSuppressesBoardsAndAChangedRideSessionRejectsDelayedRidePublication() {
		val settings = Settings(offline = OfflineSettings(widgetsFollowActiveRide = true))
		val active = ActiveRideRecord("trip", startedAt = 100.0, id = "first")
		val trip = CachedTrip("trip", departure = board(time = 100.0).departures.single(), savedAt = 100.0, accessedAt = 100.0)
		assertEquals(active, supportedWidgetRide(settings, active, trip))
		val latest = WidgetPublicationState("fixture/", station.id, null, active)
		assertFalse(acceptsWidgetContent(content(100.0), latest))
		val rideContent = content(100.0).copy(rideKey = active.key, rideID = active.id)
		assertTrue(acceptsWidgetContent(rideContent, latest))
		assertFalse(acceptsWidgetContent(rideContent, latest.copy(activeRide = active.copy(id = "second"))))
		assertNull(supportedWidgetRide(settings.copy(offline = settings.offline.copy(widgetsFollowActiveRide = false)), active, trip))
	}

	@Test fun endpointSelectionAndCombinedDefinitionChangesRejectDelayedPublication() {
		val candidate = content(100.0)
		val current = WidgetPublicationState("fixture/", station.id, null, null)
		assertTrue(acceptsWidgetContent(candidate, current))
		assertFalse(acceptsWidgetContent(candidate, current.copy(endpoint = "other/")))
		assertFalse(acceptsWidgetContent(candidate, current.copy(stationID = "other")))
		assertFalse(acceptsWidgetContent(candidate, current.copy(definition = CombinedStation("Changed", listOf("other")))))
	}
}
