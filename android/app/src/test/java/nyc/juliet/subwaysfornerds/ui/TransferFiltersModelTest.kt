package nyc.juliet.subwaysfornerds.ui

import kotlinx.coroutines.launch
import nyc.juliet.subwaysfornerds.core.StationSettings
import nyc.juliet.subwaysfornerds.core.TransferFilter
import nyc.juliet.subwaysfornerds.core.TransferSettings
import nyc.juliet.subwaysfornerds.ui.navigation.AppTab
import nyc.juliet.subwaysfornerds.ui.navigation.Route
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException

/** Transfer filters keyed by the transfer station, and opening its board without losing the way back. */
class TransferFiltersModelTest {
	private val harness = ModelHarness()
	private lateinit var model: AppModel
	private val target = "601"

	@After fun tearDown() = harness.close()

	private fun start() { model = harness.create() }
	private fun <T> onModel(block: suspend () -> T): T = harness.onModel(block)
	private fun waitFor(message: String, condition: () -> Boolean) = harness.waitFor(message, condition = condition)
	/** Polls the settings file from the test thread; the model thread must stay free to save. */
	private fun waitForSaved(message: String, condition: (nyc.juliet.subwaysfornerds.core.Settings) -> Boolean) {
		val deadline = System.currentTimeMillis() + 30_000
		while (!condition(kotlinx.coroutines.runBlocking { harness.storage.store.load() })) {
			if (System.currentTimeMillis() > deadline) org.junit.Assert.fail("Timed out waiting for $message")
			Thread.sleep(20)
		}
	}
	private suspend fun edit(change: (nyc.juliet.subwaysfornerds.core.Settings) -> nyc.juliet.subwaysfornerds.core.Settings) = model.acceptSettings(sync = model.syncBaseline, compute = change)

	@Test fun sharedModeEditsTheTransferStationsBoardFiltersAndKeepsItsView() {
		start()
		onModel {
			model.setDirection("NORTH")
			edit { it.copy(stations = it.stations + (target to StationSettings("ALL", listOf("F"), "service"))) }
		}
		assertEquals(TransferFilter("ALL", listOf("F")), model.transferFilter(target))
		onModel { model.setTransferDirection(target, "SOUTH"); model.toggleTransferRoute(target, "L") }
		// The selected main station is never read or written.
		assertEquals(STATION, model.stationID)
		assertEquals("NORTH", model.preference.direction)
		assertEquals(StationSettings("SOUTH", listOf("F", "L"), "service"), model.settings.stations.getValue(target))
		assertEquals(TransferFilter("SOUTH", listOf("F", "L")), model.transferFilter(target))
		onModel { model.clearTransferRoutes(target) }
		assertEquals(emptyList<String>(), model.settings.stations.getValue(target).routes)
		onModel { model.toggleTransferRoute(target, "1"); model.resetTransferFilters(target) }
		assertEquals(StationSettings(view = "service"), model.settings.stations.getValue(target))
		assertTrue(model.settings.transfers.stations.isEmpty())
		waitForSaved("the shared edit to save") { it.stations[target] == StationSettings(view = "service") }
	}

	@Test fun separateModeSeedsOnceFromTheBoardAndThenEditsIndependently() {
		start()
		onModel {
			edit { it.copy(stations = it.stations + (target to StationSettings("SOUTH", listOf("L"), "family"))) }
			model.setSeparateTransferFilters(true)
		}
		assertTrue(model.settings.transfers.separateFilters)
		// Viewing a transfer station copies its board filters once.
		onModel { model.useTransferFilter(target) }
		assertEquals(TransferFilter("SOUTH", listOf("L")), model.settings.transfers.stations.getValue(target))
		// Later board edits no longer change the transfer's filters, and a second view does not reseed.
		onModel { edit { it.copy(stations = it.stations + (target to StationSettings("NORTH", emptyList(), "family"))) }; model.useTransferFilter(target) }
		assertEquals(TransferFilter("SOUTH", listOf("L")), model.transferFilter(target))
		onModel { model.setTransferDirection(target, "ALL"); model.toggleTransferRoute(target, "F") }
		assertEquals(TransferFilter("ALL", listOf("F", "L")), model.transferFilter(target))
		assertEquals(StationSettings("NORTH", emptyList(), "family"), model.settings.stations.getValue(target))
		waitForSaved("the separate entry to save") { it.transfers.stations[target] == TransferFilter("ALL", listOf("F", "L")) }
	}

	@Test fun sharedModeNeverSeedsAndEditingWithoutAViewSeedsFromTheBoard() {
		start()
		onModel { model.useTransferFilter(target) }
		assertTrue(model.settings.transfers.stations.isEmpty())
		onModel {
			edit { it.copy(stations = it.stations + (target to StationSettings("TO_NJ", listOf("1"), "track"))) }
			model.setSeparateTransferFilters(true)
			model.toggleTransferRoute(target, "2")
		}
		assertEquals(TransferFilter("TO_NJ", listOf("1", "2")), model.settings.transfers.stations.getValue(target))
	}

	@Test fun disablingSeparateModeRetainsEntriesAndReenablingReusesThem() {
		start()
		onModel { model.setSeparateTransferFilters(true); model.useTransferFilter(target); model.setTransferDirection(target, "SOUTH") }
		onModel { model.setSeparateTransferFilters(false) }
		assertEquals(TransferFilter(), model.transferFilter(target))
		assertEquals(TransferFilter("SOUTH"), model.settings.transfers.stations.getValue(target))
		onModel { model.setTransferDirection(target, "NORTH") }
		assertEquals("NORTH", model.settings.stations.getValue(target).direction)
		onModel { model.setSeparateTransferFilters(true) }
		assertEquals(TransferFilter("SOUTH"), model.transferFilter(target))
		waitForSaved("the map to persist") { it.transfers == TransferSettings(true, mapOf(target to TransferFilter("SOUTH"))) }
	}

	@Test fun aFailedSaveRollsBackTransferFiltersAndSaysSo() {
		start()
		onModel { model.setSeparateTransferFilters(true) }
		waitForSaved("separate mode to save") { it.transfers.separateFilters }
		harness.storage.failSave = IOException("disk full")
		onModel { model.useTransferFilter(target); model.setTransferDirection(target, "SOUTH") }
		waitFor("the rollback") { model.settingsError?.startsWith("Settings could not be saved") == true }
		assertTrue(model.settings.transfers.stations.isEmpty())
		assertEquals(TransferFilter(), model.transferFilter(target))
		harness.storage.failSave = null
		onModel { model.setTransferDirection(target, "SOUTH") }
		waitForSaved("the retry to save") { it.transfers.stations[target] == TransferFilter("SOUTH") }
		assertNull(model.settingsError)
	}

	@Test fun openingTheTransferStationBoardKeepsTheTrainAndTransferToReturnTo() {
		start()
		harness.scope.launch { model.runWhileActive() }
		waitFor("the live board") { model.board?.station?.id == STATION && !model.boardIsCached }
		val row = model.board!!.departures.first { it.tripKey == TRIP }
		val train = Route.Train(TRIP, origin = row.key)
		val transfers = Route.Transfers(TRIP, "L02N", "6 Av", 22, stationID = target)
		onModel { model.navigator.push(train); model.navigator.push(transfers) }
		assertEquals(STATION, model.departureOrigin(row.key)!!.station.id)

		onModel { model.openTransferStationBoard(target) }
		assertEquals(target, model.stationID)
		assertEquals(AppTab.BOARD, model.navigator.tab)
		assertEquals(listOf(train, transfers, Route.StationBoard(target, AppTab.BOARD)), model.navigator.stack(AppTab.BOARD))
		// The train keeps boarding at the original station although the board changed.
		assertEquals(STATION, model.departureOrigin(row.key)!!.station.id)
		assertEquals(row.key, model.departureOrigin(row.key)!!.departure.key)

		onModel { model.navigator.back() }
		assertEquals(listOf(train, transfers), model.navigator.stack(AppTab.BOARD))
		onModel { model.navigator.back() }
		assertEquals(listOf<Route>(train), model.navigator.stack(AppTab.BOARD))
		assertEquals(target, model.stationID)
		assertEquals(STATION, model.departureOrigin(row.key)!!.station.id)
		assertNull(model.activeRide)
	}

	@Test fun anotherStationChoiceStillClearsTheBoardStack() {
		start()
		onModel {
			model.navigator.push(Route.Train(TRIP))
			model.navigator.push(Route.Transfers(TRIP, "L02N", "6 Av", 22, stationID = target))
			model.openTransferStationBoard(target)
			model.selectStation("618")
		}
		assertEquals("618", model.stationID)
		assertTrue(model.navigator.stack(AppTab.BOARD).isEmpty())
	}

	@Test fun pagerSwipesOnAnOpenedBoardKeepTheWayBack() {
		start()
		onModel {
			model.navigator.push(Route.Train(TRIP))
			model.navigator.push(Route.Transfers(TRIP, "L02N", "6 Av", 22, stationID = target))
			model.openTransferStationBoard(target)
			model.selectStation(STATION, fromPager = true)
		}
		assertEquals(STATION, model.stationID)
		assertEquals(3, model.navigator.stack(AppTab.BOARD).size)
	}

	@Test fun openingFromAnotherTabReturnsToThatTab() {
		start()
		onModel {
			model.navigator.push(Route.Train("gtfs|old"))
			model.navigator.select(AppTab.FLEET)
			model.navigator.push(Route.Train(TRIP))
			model.navigator.push(Route.Transfers(TRIP, "L02N", "6 Av", 22, stationID = target))
			model.openTransferStationBoard(target)
		}
		assertEquals(AppTab.BOARD, model.navigator.tab)
		assertEquals(listOf<Route>(Route.StationBoard(target, AppTab.FLEET)), model.navigator.stack(AppTab.BOARD))
		onModel { model.navigator.back() }
		assertEquals(AppTab.FLEET, model.navigator.tab)
		assertEquals(2, model.navigator.current.size)
		assertTrue(model.navigator.stack(AppTab.BOARD).isEmpty())
		assertEquals(target, model.stationID)
	}

	@Test fun transferResultsAreKeptOnlyForOpenTransfers() {
		start()
		val route = Route.Transfers(TRIP, "L02N", "6 Av", 22, stationID = target)
		val result = nyc.juliet.subwaysfornerds.core.TransitJson.decodeFromString(nyc.juliet.subwaysfornerds.core.TransferResult.serializer(), fixture("transfers.json"))
		onModel { model.navigator.push(Route.Train(TRIP)); model.navigator.push(route); model.rememberTransfers(route, result) }
		assertNotNull(model.rememberedTransfers(route))
		onModel { model.navigator.back(); model.rememberTransfers(Route.Transfers(TRIP, "L01N", "8 Av", 23), result) }
		assertNull(model.rememberedTransfers(route))
		assertFalse(model.navigator.current.contains(route))
	}

	@Test fun importedRouteAliasesToggleThroughTheirDisplayedLine() {
		start()
		onModel {
			edit { it.copy(transfers = TransferSettings(true, mapOf(target to TransferFilter(routes = listOf("GS", "L", "SI"))))) }
			model.toggleTransferRoute(target, "S")
		}
		assertEquals(listOf("L", "SI"), model.transferFilter(target).routes)
		onModel { model.toggleTransferRoute(target, "SIR") }
		assertEquals(listOf("L"), model.transferFilter(target).routes)
		onModel { model.toggleTransferRoute(target, "S") }
		assertEquals(listOf("L", "S"), model.transferFilter(target).routes)
		// Shared mode normalizes the same way on the station's board filters.
		onModel { model.setSeparateTransferFilters(false); edit { it.copy(stations = it.stations + (target to StationSettings(routes = listOf("FS")))) }; model.toggleTransferRoute(target, "S") }
		assertEquals(emptyList<String>(), model.settings.stations.getValue(target).routes)
	}

	private fun boardAt(id: String, name: String): nyc.juliet.subwaysfornerds.core.Board {
		val recorded = nyc.juliet.subwaysfornerds.core.TransitJson.decodeFromString(nyc.juliet.subwaysfornerds.core.Board.serializer(), fixture("board.json"))
		return recorded.copy(station = recorded.station.copy(id = id, name = name))
	}

	@Test fun aTrainWithoutAnOriginKeepsItsOriginalBoardingAfterTheTransferBoardOpens() {
		start()
		harness.transit.boardOverride = { id -> if (id == target) boardAt(target, "6 Av / 14 St") else null }
		harness.scope.launch { model.runWhileActive() }
		waitFor("the live board") { model.board?.station?.id == STATION && !model.boardIsCached }
		onModel { model.navigator.push(Route.Train(TRIP)); model.navigator.push(Route.Transfers(TRIP, "L02N", "6 Av", 22, stationID = target)) }
		onModel { model.openTransferStationBoard(target) }
		waitFor("the transfer station's board, which also lists the train") { model.board?.station?.id == target && model.board!!.departures.any { it.tripKey == TRIP } }
		onModel { model.navigator.back(); model.navigator.back() }
		// Rides and saved trains of this train still board at the original station, not the new board.
		val boarding = onModel { model.boardingOrigin(TRIP, null) }!!
		assertEquals(STATION, boarding.station.id)
		assertEquals(TRIP, boarding.departure.tripKey)
		// Once the train is no longer open, ordinary board inference applies again.
		onModel { model.navigator.back(); model.selectStation(target) }
		assertEquals(target, onModel { model.boardingOrigin(TRIP, null) }!!.station.id)
	}

	@Test fun aCapturedAbsenceIsNeverReplacedByTheNewBoard() {
		start()
		harness.transit.boardOverride = { id -> if (id == target) boardAt(target, "6 Av / 14 St") else null }
		// No board is on screen when the transfer board opens, so the train has no known boarding row.
		onModel { model.navigator.push(Route.Train(TRIP)); model.navigator.push(Route.Transfers(TRIP, "L02N", "6 Av", 22, stationID = target)) }
		onModel { model.openTransferStationBoard(target) }
		harness.scope.launch { model.runWhileActive() }
		waitFor("the transfer station's board, which also lists the train") { model.board?.station?.id == target && model.board!!.departures.any { it.tripKey == TRIP } }
		onModel { model.navigator.back(); model.navigator.back() }
		assertNull(onModel { model.boardingOrigin(TRIP, null) })
	}
}
