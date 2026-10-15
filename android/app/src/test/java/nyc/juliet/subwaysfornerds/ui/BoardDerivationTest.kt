package nyc.juliet.subwaysfornerds.ui

import kotlinx.coroutines.launch
import nyc.juliet.subwaysfornerds.core.CombinedStation
import nyc.juliet.subwaysfornerds.core.Board
import nyc.juliet.subwaysfornerds.core.Station
import nyc.juliet.subwaysfornerds.core.TransitJson
import nyc.juliet.subwaysfornerds.data.AndroidTransitCache
import nyc.juliet.subwaysfornerds.ui.data.TransitService
import nyc.juliet.subwaysfornerds.ui.data.TransferSink
import nyc.juliet.subwaysfornerds.ui.board.DepartureFormat
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.concurrent.atomic.AtomicReference

/** Cache regressions: reuse unchanged inputs without retaining old visibility or station definitions. */
class BoardDerivationTest {
	private val harness = ModelHarness()
	private lateinit var model: AppModel

	@After fun tearDown() = harness.close()

	private fun start(service: TransitService = harness.transit, clock: () -> Double = { NOW }) {
		model = harness.onModel {
			AppModel(harness.scope, AppDependencies(
				settingsStore = harness.storage,
				cache = { endpoint -> AndroidTransitCache(File(harness.directory, "cache"), endpoint, clock) },
				transit = { service },
				fleet = null,
				location = harness.location,
				widgets = harness.widgets,
				clock = clock,
			))
		}
		harness.model = model
		harness.waitFor("settings to load") { model.loaded }
		harness.onModel { model.refreshCatalog(force = true) }
	}

	private fun activate() {
		harness.scope.launch { model.runWhileActive() }
		harness.waitFor("the live board") { model.board != null && !model.boardIsCached }
	}

	@Test fun repeatedReadsReuseCatalogFavoritesAndPages() {
		start()
		harness.onModel {
			model.toggleFavorite(STATION)
			model.toggleFavorite("119")
			assertSame(model.allStations, model.allStations)
			assertSame(model.visibleStations, model.visibleStations)
			assertSame(model.favoriteStations, model.favoriteStations)
			assertSame(model.stationPages, model.stationPages)
		}
	}

	@Test fun repeatedReadsReuseTheVisibilityFilteredBoard() {
		start()
		activate()
		harness.onModel {
			assertSame(model.displayBoard, model.displayBoard)
			assertEquals(CoreBridge.visibleBoard(model.board!!, model.hiddenRoutes), model.displayBoard)
		}
	}

	@Test fun hiddenLinesInvalidateVisibleCombinedStationsFavoritesPagesAndBoard() {
		start()
		activate()
		val combinedID = "combined:00000000-0000-0000-0000-000000000001"
		harness.onModel {
			model.acceptSettings(sync = null) { it.copy(
				combinedStations = mapOf(combinedID to CombinedStation("L pair", listOf("119", "118"))),
				favorites = listOf("119", combinedID, STATION),
			) }
			val original = model.visibleStations
			val board = model.displayBoard
			assertTrue(model.visibleStations.any { it.id == combinedID })
			assertTrue(model.displayBoard!!.departures.any { it.route == "L" })
			model.acceptSettings(sync = null) { it.copy(hiddenRoutes = listOf("L")) }
			assertNotSame(original, model.visibleStations)
			assertNotSame(board, model.displayBoard)
			assertFalse(model.visibleStations.any { it.id == "119" || it.id == combinedID })
			assertTrue(model.allStations.any { it.id == "119" })
			assertTrue(model.allStations.any { it.id == combinedID })
			assertEquals(listOf(STATION), model.favoriteStations.map { it.id })
			assertEquals(listOf(STATION), model.stationPages)
			assertFalse(model.displayBoard!!.departures.any { it.route == "L" })
			model.acceptSettings(sync = null) { it.copy(hiddenRoutes = emptyList()) }
			assertTrue(model.visibleStations.any { it.id == combinedID })
			assertEquals(listOf("119", combinedID, STATION), model.favoriteStations.map { it.id })
			assertTrue(model.displayBoard!!.departures.any { it.route == "L" })
		}
	}

	@Test fun combinedDefinitionEditsAndDeletionInvalidateTheCatalog() {
		start()
		harness.onModel {
			val id = model.saveCombinedStation(null, "First name", listOf("119", "118"))
			val first = model.allStations.first { it.id == id }
			model.toggleFavorite(id)
			assertEquals("First name", model.stationName(id))
			model.saveCombinedStation(id, "New name", listOf(STATION, "610"))
			val updated = model.allStations.first { it.id == id }
			assertNotSame(first, updated)
			assertEquals("New name", model.stationName(id))
			assertEquals("New name", model.favoriteStations.single().name)
			assertTrue(updated.routes.contains("4"))
			assertEquals(CoreBridge.combinedStation(id, "New name", listOf(STATION, "610"), model.stations), updated)
			model.deleteCombinedStation(id)
			assertFalse(model.allStations.any { it.id == id })
			assertFalse(model.visibleStations.any { it.id == id })
			assertTrue(model.favoriteStations.isEmpty())
			assertFalse(id in model.stationPages)
		}
	}

	@Test fun aRefreshedCatalogInvalidatesNamesAndCombinedMembers() {
		var catalog = TransitJson.decodeFromString(kotlinx.serialization.builtins.ListSerializer(Station.serializer()), fixture("catalog.json"))
		val service = object : TransitService by harness.transit {
			override suspend fun stations(progress: TransferSink?): List<Station> = catalog
		}
		start(service)
		harness.onModel {
			val id = model.saveCombinedStation(null, "Catalog pair", listOf("119", "118"))
			val before = model.allStations
			catalog = catalog.map { if (it.id == "119") it.copy(name = "Renamed member", routes = listOf("G")) else it }
			model.refreshCatalog(force = true)
			assertNotSame(before, model.allStations)
			assertEquals("Renamed member", model.stationName("119"))
			assertTrue("G" in model.visibleStations.first { it.id == id }.routes)
		}
	}

	@Test fun clockTicksReuseCollectionsButStillApplyCountdownAndExactLiveCutoffs() {
		val clock = AtomicReference(NOW)
		val recorded = TransitJson.decodeFromString(Board.serializer(), fixture("board.json"))
		val boundary = recorded.departures.first().copy(key = "boundary", time = NOW - 29, timestamp = NOW, relationship = null)
		val future = boundary.copy(key = "future", time = NOW + 121)
		val stale = boundary.copy(key = "stale", time = NOW - 200, timestamp = NOW - 91)
		harness.transit.boardOverride = { recorded.copy(departures = listOf(boundary, future, stale)) }
		start(clock = { clock.get() })
		activate()
		val original = harness.onModel { listOf(model.allStations, model.visibleStations, model.favoriteStations, model.stationPages, model.displayBoard, model.departureGroups) }
		assertEquals("2", DepartureFormat.countdown(future, NOW, false, model.offlinePreferences, model.timeFormat).value)
		clock.set(NOW + 1)
		harness.waitFor("the first clock tick") { model.now == NOW + 1 }
		harness.onModel {
			val after = listOf(model.allStations, model.visibleStations, model.favoriteStations, model.stationPages, model.displayBoard, model.departureGroups)
			original.zip(after).forEach { (before, next) -> assertSame(before, next) }
			assertTrue(model.departureGroups.flatMap { it.departures }.any { it.key == "boundary" })
		}
		clock.set(NOW + 2)
		harness.waitFor("the live departure cutoff") { model.now == NOW + 2 }
		harness.onModel {
			val keys = model.departureGroups.flatMap { it.departures }.map { it.key }
			assertFalse("boundary" in keys)
			assertTrue("stale" in keys)
			assertEquals("1", DepartureFormat.countdown(future, model.now, false, model.offlinePreferences, model.timeFormat).value)
		}
		clock.set(NOW + 90)
		harness.waitFor("the inclusive live freshness boundary") { model.now == NOW + 90 }
		assertFalse(harness.onModel { model.departureGroups.flatMap { it.departures }.any { it.key == "boundary" } })
		clock.set(NOW + 90.001)
		harness.waitFor("stale prediction retention after the freshness boundary") { model.now == NOW + 90.001 }
		harness.onModel {
			assertTrue(model.departureGroups.flatMap { it.departures }.any { it.key == "boundary" })
			assertEquals("last estimate", DepartureFormat.countdown(boundary, model.now, false, model.offlinePreferences, model.timeFormat).unit)
			assertEquals(CoreBridge.groups(model.displayBoard!!, now = model.now), model.departureGroups)
		}
	}

	@Test fun groupSnapshotsInvalidateForEveryViewDirectionRouteAndHiddenLineFilter() {
		start()
		activate()
		harness.onModel {
			for (view in listOf("track", "direction", "family", "corridor", "service")) {
				model.setBoardView(view)
				for (direction in listOf("ALL", "NORTH", "SOUTH", "TO_NY", "TO_NJ")) {
					model.setDirection(direction)
					for (route in listOf(null, "L", "6")) {
						model.clearRoutes()
						if (route != null) model.toggleRoute(route)
						val selected = model.preference
						assertEquals(CoreBridge.groups(model.displayBoard!!, selected.direction, selected.routes, selected.view, model.now, model.boardIsCached, model.cachedDepartureKeys), model.departureGroups)
					}
				}
			}
			model.acceptSettings(sync = null) { it.copy(hiddenRoutes = listOf("L")) }
			model.setDirection("ALL")
			model.clearRoutes()
			assertFalse(model.departureGroups.flatMap { it.departures }.any { it.route == "L" })
		}
	}

	@Test fun unrelatedSettingsKeepCatalogAndPageIdentity() {
		start()
		harness.onModel {
			model.toggleFavorite(STATION)
			val before = listOf(model.allStations, model.visibleStations, model.favoriteStations, model.stationPages)
			model.setTheme("night")
			val after = listOf(model.allStations, model.visibleStations, model.favoriteStations, model.stationPages)
			before.zip(after).forEach { (original, updated) -> assertSame(original, updated) }
		}
	}

	@Test fun cachedCombinedKeysAndOriginsFollowConnectivity() {
		start()
		harness.onModel { model.saveCombinedStation(null, "Union and Grand Central", listOf(STATION, "610")) }
		activate()
		harness.waitFor("the combined live member") { model.combinedBoard?.origins?.isNotEmpty() == true && !model.boardIsCached }
		harness.onModel {
			assertSame(model.cachedDepartureKeys, model.cachedDepartureKeys)
			model.board!!.departures.forEach { departure ->
				assertEquals(STATION, model.departureOrigin(departure.key)?.station?.id)
				assertFalse(model.departureIsCached(departure.key))
			}
			model.setNetworkConnected(false)
		}
		harness.waitFor("the cached combined member") { !model.connected && model.boardIsCached }
		harness.onModel {
			assertEquals(model.combinedBoard!!.board.departures.map { it.key }.toSet(), model.cachedDepartureKeys)
			assertSame(model.cachedDepartureKeys, model.cachedDepartureKeys)
			assertTrue(model.departureGroups.flatMap { it.departures }.all { model.departureIsCached(it.key) })
		}
	}

	@Test fun aReplacedBoardInvalidatesTheDisplayAndGroupedRows() {
		val recorded = TransitJson.decodeFromString(Board.serializer(), fixture("board.json"))
		val clock = AtomicReference(NOW)
		start(clock = { clock.get() })
		activate()
		val before = harness.onModel { model.displayBoard }
		val updated = recorded.copy(generatedAt = NOW + 15, departures = recorded.departures.map { it.copy(destination = "Updated destination", timestamp = NOW + 15) })
		harness.transit.boardOverride = { id -> updated.takeIf { id == STATION } }
		clock.set(NOW + 15)
		harness.onModel { model.refreshBoard() }
		harness.waitFor("the replacement board") { model.board?.departures?.all { it.destination == "Updated destination" } == true }
		harness.onModel {
			assertNotSame(before, model.displayBoard)
			assertTrue(model.departureGroups.flatMap { it.departures }.isNotEmpty())
			assertTrue(model.departureGroups.flatMap { it.departures }.all { it.destination == "Updated destination" })
			assertEquals(CoreBridge.visibleBoard(model.board!!, model.hiddenRoutes), model.displayBoard)
		}
	}
}
