package nyc.juliet.subwaysfornerds.ui.board

import nyc.juliet.subwaysfornerds.core.Board
import nyc.juliet.subwaysfornerds.core.Display
import nyc.juliet.subwaysfornerds.core.Freshness
import nyc.juliet.subwaysfornerds.core.Station
import nyc.juliet.subwaysfornerds.ui.CombinedView
import nyc.juliet.subwaysfornerds.ui.DepartureSection
import nyc.juliet.subwaysfornerds.ui.Labels

/** A direction filter chip: an arrow icon or a short text label, with its spoken name. */
data class DirectionOption(val id: String, val name: String, val text: String? = null)

/** Board-level presentation rules from the iOS board, as pure functions for tests. */
object BoardLogic {
	private val ancillary = setOf("subway-alerts", "helium")

	fun directionOptions(station: Station?): List<DirectionOption> {
		val routes = station?.routes.orEmpty()
		val hasPath = routes.any { it.startsWith("PATH-") }
		val mixed = station?.isCombined == true && hasPath && routes.any { !it.startsWith("PATH-") }
		val all = DirectionOption("ALL", "All directions")
		val north = DirectionOption("NORTH", "Northbound")
		val south = DirectionOption("SOUTH", "Southbound")
		val ny = DirectionOption("TO_NY", "To New York", "NY")
		val nj = DirectionOption("TO_NJ", "To New Jersey", "NJ")
		return when {
			mixed -> listOf(all, north, south, ny, nj)
			hasPath -> listOf(all, ny, nj)
			else -> listOf(all, north, south)
		}
	}

	/** Lines a station's route chips offer: catalog and departure routes minus hidden lines. */
	fun routeChoices(station: Station?, board: Board?, hiddenRoutes: List<String>, visible: (List<String>, List<String>) -> List<String>): List<String> {
		val routes = ((station?.routes.orEmpty()) + (board?.departures?.map { it.route }.orEmpty())).map(Display::displayRoute).distinct().sorted()
		return visible(routes, hiddenRoutes)
	}

	fun trainSources(board: Board?) = board?.sources.orEmpty().filter { it.id !in ancillary }

	fun live(board: Board?, combined: CombinedView?, connected: Boolean, cached: Boolean, now: Double): Boolean {
		if (combined != null) return connected && combined.members.any { !it.cached && it.board?.let { member -> Display.hasLivePredictions(member, now) } == true }
		return board?.let { Display.hasLivePredictions(it, now, cached) } ?: false
	}

	fun degraded(board: Board?, combined: CombinedView?, now: Double): Boolean =
		combined?.members?.any { it.cached || it.board == null || it.error != null } == true ||
			trainSources(board).any { Display.freshness(it, now) != Freshness.LIVE || it.error != null }

	fun externalDepartures(board: Board?, station: Station?): Boolean =
		board?.usesExternalDepartures ?: (station?.let { it.departureMode == "external" || it.isNjt } ?: false)

	fun freshnessLabel(external: Boolean, live: Boolean, degraded: Boolean, cached: Boolean, hasBoard: Boolean, savedAt: Double?): String = when {
		external -> "Station directory"
		live -> if (degraded) "Partial live data" else "Live feed"
		cached && hasBoard -> if (savedAt == null) "Last board" else "Saved board · offline"
		else -> "Awaiting live data"
	}

	/** A group's heading and subtitle, by board view. */
	fun heading(section: DepartureSection, station: Station?, view: String): Pair<String, String> {
		val part = station?.parts?.firstOrNull { it.id == section.partId }
		val heading = when (view) {
			"service" -> "Service " + Display.routeLabel(section.service ?: section.label)
			"track" -> when (section.direction) {
				"NORTH" -> part?.north ?: "Northbound"
				"SOUTH" -> part?.south ?: "Southbound"
				else -> Display.directionLabel(section.direction)
			}
			else -> Display.directionLabel(section.direction)
		}
		val subtitle = when (view) {
			"track" -> "${part?.line ?: section.partId} · " + (section.track?.let { "Track $it · ${if (section.reportedTrack) "reported" else "scheduled"}" } ?: "Track unknown")
			"direction" -> "All platforms"
			"service" -> Display.directionLabel(section.direction)
			else -> section.label
		}
		return heading to subtitle
	}

	fun metadata(station: Station?, stationID: String, combinedCount: Int?): String =
		if (combinedCount != null) "Combined station · $combinedCount stations"
		else (station?.municipality?.let { "$it, " } ?: "") + Labels.borough(station?.borough ?: "NYC") + " · Station $stationID"

	/** Readiness for offline use, or the saved board's provenance when it is cached. */
	fun readinessLabel(failed: Boolean, saved: Boolean, savedCount: Int, wanted: Int, partial: Int): String {
		val trips = if (wanted == 0) "" else " · $savedCount of $wanted next trips" + (if (partial == 0) "" else ", $partial partial")
		return when {
			failed -> "Offline copy failed to save"
			saved -> "Saved for offline$trips"
			else -> "Saving for offline…"
		}
	}
}
