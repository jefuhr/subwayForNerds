package nyc.juliet.subwaysfornerds.core

import kotlinx.serialization.builtins.ListSerializer
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant

class BehaviorTest {
	private val now = 1_800_000_000.0
	private val station = Station("one", "One", "M", listOf("4", "6X", "PATH-JSQ-33"), 40.7, -74.0, listOf(StationPart("lex", "lex", "Lex", "Lexington Av", listOf("4", "6X"), 40.7, -74.0, "1", north = "Uptown", south = "Downtown")))
	private fun row(key: String, route: String = "4", direction: String = "NORTH", time: Double? = now + 60, relationship: String? = null) = Departure(key, "gtfs|$key", route, "Destination", direction, "stop", "lex", "Lex · Track 0", time, time, pattern = "Local", patternSource = "inferred", location = "", feed = "gtfs", timestamp = now, scheduledTrack = "0", relationship = relationship)
	@Test fun allViewsKeepStableGroupsOrderingTracksAndUnknownDirections() {
		val board = Board(station, now, departures = listOf(row("later", "6X", time = now + 120), row("earlier", "4"), row("south", "4", "SOUTH"), row("unknown", "4", "futureDirection", time = null), row("missing", relationship = "NO_DATA"), row("passed", time = now - 31)))
		for (order in listOf("track", "direction", "family", "corridor", "service")) {
			val groups = groupDepartures(board, order = order, now = now)
			assertEquals(4, groups.sumOf { it.departures.size }); assertTrue(groups.any { it.direction == "UNKNOWN" })
			assertTrue(groups.all { it.departures == BoardOrdering.sorted(it.departures) })
		}
		val families = groupDepartures(board, order = "family", now = now); assertTrue(families.any { it.label == "4 / 5 / 6" && it.departures.size == 2 })
		assertEquals("0", groupDepartures(board, now = now).first().track)
		assertEquals("Lex · Track 0 · scheduled", Display.boardingLabel(board.departures.first()))
		val saved = groupDepartures(board, now = now, cached = true); assertEquals(5, saved.sumOf { it.departures.size })
	}
	@Test fun widgetCapacityReservesDirectionsAndNeverInventsCurrentCarReports() {
		val consist = Consist(listOf(ConsistCar("001", "R160")), now, now)
		val board = Board(station, now, departures = (1..10).map { row("north$it", time = now + it) } + row("south", direction = "SOUTH"))
		val groups = WidgetBoards.departures(board, StationSettings(direction = "NORTH", view = "direction"), 2, now)
		assertEquals(2, groups.first { it.direction == "NORTH" }.departures.size); assertEquals(1, groups.first { it.direction == "SOUTH" }.departures.size)
		val car = row("cars").copy(consist = consist)
		val options = WidgetDisplay(fields = listOf("carType", "carCount", "carNumbers"))
		assertEquals("R160 · 1 cars · 001", widgetTrainDetails(car, options, now)); assertEquals("", widgetTrainDetails(car, options, now, true))
		assertEquals("", widgetTrainDetails(car.copy(consist = consist.copy(updatedAt = now - 301)), options, now))
	}
	@Test fun globalHiddenRoutesApplyAliasesAndRetainUnscopedAlerts() {
		assertFalse(LineVisibility.isEnabled("6X", listOf("6"))); assertFalse(LineVisibility.isEnabled("GS", listOf("S")))
		val scoped = ServiceAlert("scoped", "Title", "Description", routes = listOf("6X"))
		val system = ServiceAlert("system", "Title", "Description")
		assertEquals(listOf(system), LineVisibility.alerts(listOf(scoped, system), listOf("6")))
		assertEquals(listOf("4", "PATH-JSQ-33"), LineVisibility.station(station, listOf("6"))!!.routes)
		assertNull(LineVisibility.station(station.copy(routes = listOf("6X")), listOf("6")))
	}
	@Test fun sourceSpecificBoundariesUnknownEquipmentAndSavedWithdrawalsStayHonest() {
		assertEquals(Freshness.STALE, Display.freshness(row("njt").copy(feed = "njt-g2", timestamp = now - 61), now))
		assertEquals(Freshness.LIVE, Display.freshness(row("mta").copy(timestamp = now - 90), now))
		assertEquals(Freshness.STALE, Display.freshness(row("mta").copy(timestamp = now - 91), now))
		assertEquals(Freshness.STALE, Display.freshness(now - 1, now, 0.0))
		val njt = Board(station.copy(id = "njt-one", routes = listOf("NJT-HBLR")), now, njt = NjtState(true, SourceState("njt-predictions", now, now, null), SourceState("njt-positions", now, now, null)))
		assertFalse(Display.hasLivePredictions(njt, now)); assertTrue(Display.njtPredictionMessage(njt, now)!!.startsWith("No arrival predictions"))
		for ((relationship, label) in listOf("CANCELED" to "canceled", "DELETED" to "canceled", "SKIPPED" to "skipped", "NO_DATA" to "no estimate")) assertEquals(label, OfflineDisplay.countdown(row("withdrawn", relationship = relationship), now, true, OfflineSettings()).unit)
		assertEquals(0, OfflineDisplay.estimatedNextStopIndex(listOf(StopPrediction("stop", "Stop", arrival = now)), now))
		assertNull(OfflineDisplay.estimatedNextStopIndex(listOf(StopPrediction("stop", "Stop", arrival = now, relationship = "SKIPPED")), now))
		assertTrue(StationContext().equipment.isEmpty())
	}
	@Test fun serviceChangesRankCurrentBoardingBeforeAheadAndExpiredEvidence() {
		val ahead = TripChange("ahead", "track", "unknown", "track 4", location = "Next", stopIndices = listOf(2), evidence = listOf(ChangeEvidence("feed", now - 91, 90.0)))
		val current = TripChange("current", "boarding", "planned", "boarding", stopIndices = listOf(1))
		val behind = TripChange("behind", "advisory", "unplanned", "behind", stopIndices = listOf(0))
		val changes = Display.changesAhead(listOf(ahead, current, behind), 1)
		assertEquals(listOf("current", "ahead"), changes.map { it.id }); assertEquals("track 4 · ahead at Next", changes[1].label)
		assertTrue(Display.changeStale(ahead, now)); assertTrue(Display.changeStale(current, now, true))
	}
	@Test fun EasternClocksAndRadiusEditorsRespectDstAndIntegerFootBoundaries() {
		fun seconds(value: String) = Instant.parse(value).epochSecond.toDouble()
		assertEquals("1:59 AM", Display.clockTime(seconds("2026-03-08T06:59:00Z")))
		assertEquals("3:00 AM", Display.clockTime(seconds("2026-03-08T07:00:00Z")))
		assertEquals("00:30", Display.clockTime(seconds("2026-10-13T04:30:00Z"), "24h"))
		assertEquals("10/13/2026 13:05", Display.publishedClockText("10/13/2026 1:05 PM", "24h"))
		assertEquals("ongoing", Display.publishedClockText("ongoing", "24h"))
		for (unit in listOf("auto", "mi", "ft", "m", "km")) for (feet in listOf(1, 5280, 26400)) assertEquals(feet, Units.radiusFeet(Units.radiusInput(feet, unit), unit))
		assertNull(Units.radiusFeet("-1", "ft")); assertNull(Units.radiusFeet("26401", "ft")); assertNull(Units.radiusFeet("NaN", "m"))
	}
	@Test fun everyGeneratedCrossLanguageFixtureDecodes() {
		fun text(name: String): String = javaClass.getResourceAsStream("/fixtures/$name")!!.bufferedReader().use { it.readText() }
		TransitJson.decodeFromString(ListSerializer(Station.serializer()), text("catalog.json"))
		for (name in listOf("board.json", "edge-board.json")) TransitJson.decodeFromString(Board.serializer(), text(name))
		for (name in listOf("trip.json", "edge-trip.json")) TransitJson.decodeFromString(TripDetail.serializer(), text(name))
		TransitJson.decodeFromString(TransferResult.serializer(), text("transfers.json")); TransitJson.decodeFromString(StationContext.serializer(), text("context.json"))
		TransitJson.decodeFromString(FleetPage.serializer(), text("fleet-page.json")); TransitJson.decodeFromString(FleetDetail.serializer(), text("fleet-detail.json")); TransitJson.decodeFromString(FleetOfflineManifest.serializer(), text("offline-manifest.json"))
		for (name in listOf("settings.nerds", "favorites.nerds", "offline.nerds", "combined-stations.nerds")) { val file = NerdsCodec.decode(text(name)); assertEquals(file.settings, NerdsCodec.decode(NerdsCodec.encode(file.settings, file.lastStation)).settings) }
	}
}
