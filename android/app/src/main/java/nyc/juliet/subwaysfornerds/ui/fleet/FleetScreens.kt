package nyc.juliet.subwaysfornerds.ui.fleet

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Train
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import nyc.juliet.subwaysfornerds.core.Display
import nyc.juliet.subwaysfornerds.core.Evidence
import nyc.juliet.subwaysfornerds.core.FleetCar
import nyc.juliet.subwaysfornerds.core.FleetDetail
import nyc.juliet.subwaysfornerds.core.FleetOfflineManifest
import nyc.juliet.subwaysfornerds.core.FleetPage
import nyc.juliet.subwaysfornerds.core.FleetRow
import nyc.juliet.subwaysfornerds.core.LoadProgress
import nyc.juliet.subwaysfornerds.core.TrainFavorites
import nyc.juliet.subwaysfornerds.core.TransitJson
import nyc.juliet.subwaysfornerds.ui.AppModel
import nyc.juliet.subwaysfornerds.ui.components.ChipRow
import nyc.juliet.subwaysfornerds.ui.components.ChoiceChip
import nyc.juliet.subwaysfornerds.ui.components.EmptyState
import nyc.juliet.subwaysfornerds.ui.components.FactGrid
import nyc.juliet.subwaysfornerds.ui.components.ListScreen
import nyc.juliet.subwaysfornerds.ui.components.LoadingBar
import nyc.juliet.subwaysfornerds.ui.components.NavigationRow
import nyc.juliet.subwaysfornerds.ui.components.Notice
import nyc.juliet.subwaysfornerds.ui.components.RawJsonDisclosure
import nyc.juliet.subwaysfornerds.ui.components.RowContainer
import nyc.juliet.subwaysfornerds.ui.components.ScreenExit
import nyc.juliet.subwaysfornerds.ui.components.openLink
import nyc.juliet.subwaysfornerds.ui.components.section
import nyc.juliet.subwaysfornerds.ui.counted
import nyc.juliet.subwaysfornerds.ui.easternDate
import nyc.juliet.subwaysfornerds.ui.navigation.Route
import nyc.juliet.subwaysfornerds.ui.theme.TextRoles
import nyc.juliet.subwaysfornerds.ui.theme.palette
import nyc.juliet.subwaysfornerds.ui.train.FavoriteCarStar
import nyc.juliet.subwaysfornerds.ui.train.FavoriteConsistRow
import nyc.juliet.subwaysfornerds.ui.waitingLoad

/** The fleet query, as the web and iOS browsers send it. */
data class FleetFilters(
	val q: String = "",
	val view: String = "groups",
	val category: String = "",
	val status: String = "",
	val equipment: String = "",
	val route: String = "",
	val yard: String = "",
	val retired: Boolean = false,
	val page: Int = 1,
) {
	val query: Map<String, String> get() = mapOf(
		"q" to q, "view" to view, "category" to category, "status" to status, "equipment" to equipment,
		"route" to route, "yard" to yard, "retired" to if (retired) "true" else "", "page" to page.toString(),
	)
	/** Everything but the page; changing a filter starts again at page 1. */
	val filterKey: String get() = query.filterKeys { it != "page" }.toSortedMap().entries.joinToString("&") { "${it.key}=${it.value}" }
	val moreActive: Int get() = listOf(equipment, route, yard).count { it.isNotEmpty() } + if (retired) 1 else 0
}

object FleetRules {
	/** Reporting now means a report within the 90-second live limit. */
	fun observedNow(car: FleetCar, now: Double): Boolean = car.reporting == true && car.last?.let { now - it.timestamp <= 90 } == true

	fun savedScope(manifest: FleetOfflineManifest, timeFormat: String): String {
		val scope = manifest.pack?.selection?.scopeDescription ?: "All cars · Previously saved retained history"
		val linked = manifest.pack?.let { " ${counted(it.counts.linkedCars)} linked cars are included for fixed sets and recent formations." } ?: ""
		return "Saved fleet · ${easternDate(manifest.generatedAt, timeFormat)}. Saved scope: $scope.$linked Every report is historical."
	}

	/** Roster facts arrive as raw strings; trim midnight timestamps and whole-number decimals. */
	fun carFacts(car: FleetCar): List<Pair<String, String>> {
		val facts = mutableListOf("Roster" to car.lifecycle)
		if (car.aliases.isNotEmpty()) facts += "Aliases" to car.aliases.joinToString(", ")
		car.facts.orEmpty().keys.sorted().forEach { key ->
			var value = car.facts?.get(key).orEmpty()
			val midnight = Regex("^(\\d{4}-\\d{2}-\\d{2})T00:00:00(\\.0+)?Z?$").matchEntire(value)
			value = when {
				midnight != null -> midnight.groupValues[1]
				Regex("^\\d+\\.0+$").matches(value) -> value.substringBefore('.')
				else -> value
			}
			val label = key.replace('_', ' ')
			facts += label.replaceFirstChar { it.uppercase() } to value
		}
		return facts
	}

	fun rowSummary(row: FleetRow): String =
		"${row.cars.map { it.equipment }.distinct().sorted().joinToString(" / ")} · ${row.cars.size} ${if (row.cars.size == 1) "car" else "cars"}${if (row.id.startsWith("set:")) " · documented link" else ""}"

	fun facetOptions(options: List<String>): List<Pair<String, String>> =
		listOf("" to "All") + options.filter { it != "unknown" }.map { it to it } + listOf("unknown" to "Unknown / unreported")
}

/** The fleet list. Wide windows show the chosen car beside it; narrow ones push details. */
@Composable
fun FleetScreen(model: AppModel, initialSearch: String, exit: ScreenExit, close: () -> Unit, open: (Route) -> Unit, selected: Route?) {
	var filters by rememberSaveable(stateSaver = FleetFiltersSaver) { mutableStateOf(FleetFilters(q = initialSearch)) }
	var data by remember { mutableStateOf<FleetPage?>(null) }
	var error by remember { mutableStateOf<String?>(null) }
	var progress by remember { mutableStateOf<LoadProgress?>(null) }
	var usingSaved by remember { mutableStateOf(false) }
	var generation by remember { mutableIntStateOf(0) }
	var moreFilters by rememberSaveable { mutableStateOf(false) }
	val fleet = model.fleet
	val lifecycle = LocalLifecycleOwner.current.lifecycle
	val loadKey = "${filters.filterKey}|${filters.page}|${fleet.useSavedFleet}|${fleet.offlineManifest?.id ?: "none"}|${model.endpoint}|${model.connected}"

	suspend fun refresh() {
		val identity = loadKey
		val query = filters.query
		generation += 1
		val current = generation
		val waiting = data == null
		if (waiting) progress = null
		val store = fleet.store
		try {
			val savedMode = (fleet.useSavedFleet || !model.connected) && fleet.offlineManifest != null && store != null
			val value = if (savedMode) {
				// A local query reports nothing measurable while it runs, so no percent is shown.
				if (waiting) progress = LoadProgress(null, "Searching the saved fleet database on this device…")
				store.page(query)
			} else model.service.fleet(query, if (waiting) { update -> if (current == generation) progress = update.load("the fleet inventory") } else null)
			if (identity != loadKey || current != generation) return
			usingSaved = savedMode
			data = value
			error = null
		} catch (failure: CancellationException) { throw failure }
		catch (_: Exception) {
			if (identity != loadKey || current != generation) return
			val saved = if (store != null && fleet.offlineManifest != null) runCatching { store.page(query) }.getOrNull() else null
			if (saved != null) {
				data = saved; usingSaved = true
				error = "Live fleet unavailable. Showing the saved fleet download."
			} else error = "Fleet data unavailable. Previous reports are not current; departures are unaffected."
		}
	}

	LaunchedEffect(loadKey) {
		data = null; error = null; progress = null
		delay(180)
		lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) { while (true) { refresh(); delay(10_000) } }
	}
	fun update(next: FleetFilters) { filters = if (next.filterKey != filters.filterKey) next.copy(page = 1) else next }

	ListScreen("The fleet", exit = exit, onExit = close, onRefresh = { refresh() }, tag = "fleetBrowser") {
		item("search") {
			OutlinedTextField(
				value = filters.q,
				onValueChange = { update(filters.copy(q = it)) },
				placeholder = { Text("Car number, alias, or equipment") },
				leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
				trailingIcon = { if (filters.q.isNotEmpty()) IconButton(onClick = { update(filters.copy(q = "")) }) { Icon(Icons.Filled.Clear, contentDescription = "Clear search") } },
				singleLine = true,
				keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false, imeAction = ImeAction.Search),
				colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = palette.accent, unfocusedBorderColor = palette.line, cursorColor = palette.action),
				modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp).testTag("fleetSearch"),
			)
		}
		if (fleet.offlineManifest != null) section("savedToggle") {
			row { SwitchRow("Browse saved fleet", fleet.useSavedFleet, { fleet.useSavedFleet = it }, Modifier.testTag("browseSavedFleet")) }
		}
		section("filters") {
			row { GroupingButtons(filters.view) { update(filters.copy(view = it)) } }
			row {
				ChipRow(Modifier.padding(horizontal = 12.dp).testTag("fleetCategory")) {
					listOf("" to "All", "passenger" to "Passenger", "work" to "Work", "museum" to "Museum", "sir" to "SIR").forEach { (id, name) ->
						ChoiceChip(name, filters.category == id, { update(filters.copy(category = id)) })
					}
				}
			}
			row {
				ChipRow(Modifier.padding(horizontal = 12.dp).testTag("fleetStatus")) {
					listOf("" to "Any status", "reporting" to "Reporting now", "unreported" to "Not reporting now").forEach { (id, name) ->
						ChoiceChip(name, filters.status == id, { update(filters.copy(status = id)) })
					}
				}
			}
			row {
				Row(
					Modifier.fillMaxWidth().heightIn(min = 48.dp).clickable(role = Role.Button) { moreFilters = !moreFilters }.padding(horizontal = 16.dp)
						.semantics(mergeDescendants = true) { stateDescription = if (moreFilters) "Expanded" else "Collapsed" },
					verticalAlignment = Alignment.CenterVertically,
				) {
					Text(if (filters.moreActive == 0) "More filters" else "More filters · ${filters.moreActive} active", style = TextRoles.subheadline, modifier = Modifier.weight(1f))
					Icon(if (moreFilters) Icons.Filled.KeyboardArrowUp else Icons.Filled.KeyboardArrowDown, contentDescription = null, tint = palette.muted)
				}
			}
			if (moreFilters) {
				row { FacetRow("Car type", filters.equipment, data?.facets?.equipment.orEmpty()) { update(filters.copy(equipment = it)) } }
				row { FacetRow("Route", filters.route, data?.facets?.route.orEmpty()) { update(filters.copy(route = it)) } }
				row { FacetRow("Yard", filters.yard, data?.facets?.yard.orEmpty()) { update(filters.copy(yard = it)) } }
				row { SwitchRow("Include retired / scrapped", filters.retired, { update(filters.copy(retired = it)) }) }
				row { TextButton(onClick = { filters = FleetFilters() }, modifier = Modifier.padding(start = 4.dp)) { Text("Reset filters", color = palette.action) } }
			}
		}
		error?.let { message -> section("error") { row { RowContainer { Notice(message) } } } }
		val manifest = fleet.offlineManifest
		if (usingSaved && manifest != null) section("scope") { row { RowContainer { Notice(FleetRules.savedScope(manifest, model.timeFormat)) } } }
		val current = data
		if (current == null) {
			if (error == null) section("loading") {
				row {
					val load = progress ?: LoadProgress(null, "Starting the fleet search…")
					RowContainer { LoadingBar("Loading fleet inventory", load.fraction?.toFloat(), load.percentLabel, load.spokenPercent, load.detail, Modifier.testTag("fleetLoading")) }
				}
			}
			return@ListScreen
		}
		val historical = !model.connected || usingSaved || error != null || current.error != null
		section(
			"rows",
			header = "${counted(current.total)} matching ${if (filters.view == "cars") "cars" else "groups"}",
			footer = "Missing from a feed does not mean inactive.",
		) {
			current.error?.let { message -> row { RowContainer { Notice(message) } } }
			current.rows.forEach { row ->
				row(row.id) {
					val route = Route.FleetDetail(row.id, if (row.kind == "car") "cars" else "consists", fleet.useSavedFleet)
					val isSelected = selected is Route.FleetDetail && selected.id == row.id
					Column(
						Modifier.fillMaxWidth()
							.background(if (isSelected) palette.accentTint else Color.Transparent)
							.clickable(role = Role.Button) { open(route) }
							.semantics(mergeDescendants = true) { this.selected = isSelected }
							.testTag("fleet_${row.id}")
							.padding(horizontal = 16.dp, vertical = 8.dp),
						verticalArrangement = Arrangement.spacedBy(2.dp),
					) {
						Row(verticalAlignment = Alignment.Top) {
							Text(row.cars.joinToString(" · ") { it.number }, style = TextRoles.subheadlineBold, modifier = Modifier.weight(1f))
							Text(FleetRules.rowSummary(row), style = TextRoles.caption2, color = palette.muted)
						}
						row.cars.firstOrNull()?.let { CarReport(it, model.now, historical) }
					}
				}
			}
			if (current.rows.isEmpty()) row {
				EmptyState(
					"No matching cars",
					if (usingSaved && filters.status == "reporting") "Saved reports are historical. Choose any reporting status to browse this download." else "Try another car number or change the filters.",
					Modifier.fillMaxWidth().padding(16.dp),
				)
			}
		}
		section("pages") {
			row {
				Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
					TextButton(onClick = { filters = filters.copy(page = maxOf(1, current.page - 1)) }, enabled = current.page > 1) { Text("Previous", color = if (current.page > 1) palette.action else palette.muted) }
					Text("${current.page} / ${maxOf(1, current.pages)}", style = TextRoles.subheadline, modifier = Modifier.weight(1f), textAlign = androidx.compose.ui.text.style.TextAlign.Center)
					TextButton(onClick = { filters = filters.copy(page = current.page + 1) }, enabled = current.page < current.pages) { Text("Next", color = if (current.page < current.pages) palette.action else palette.muted) }
				}
			}
		}
		section("coverage") {
			row {
				var expanded by rememberSaveable { mutableStateOf(false) }
				Column {
					Text(
						"Coverage & sources",
						style = TextRoles.subheadline, color = palette.action,
						modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).clickable(role = Role.Button) { expanded = !expanded }.padding(horizontal = 16.dp, vertical = 14.dp),
					)
					if (expanded) Column(Modifier.padding(start = 16.dp, end = 16.dp, bottom = 12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
						current.coverage.forEach { Text("${it.category}: ${counted(it.count)} cars. ${it.note}", style = TextRoles.caption) }
						current.sources.forEach { EvidenceView(it) }
						Text(
							if (usingSaved) "Inventory and coverage refer to this saved scope, including linked cars. Historical formations can mention other cars whose details are outside the pack."
							else "“All” covers the imported inventory, not every vehicle ever built. Collection starts when the server runs; historical movements cannot be reconstructed from a missing feed.",
							style = TextRoles.caption, color = palette.muted,
						)
					}
				}
			}
		}
	}
}

private val FleetFiltersSaver = androidx.compose.runtime.saveable.listSaver<FleetFilters, Any>(
	save = { listOf(it.q, it.view, it.category, it.status, it.equipment, it.route, it.yard, it.retired, it.page) },
	restore = { FleetFilters(it[0] as String, it[1] as String, it[2] as String, it[3] as String, it[4] as String, it[5] as String, it[6] as String, it[7] as Boolean, it[8] as Int) },
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun GroupingButtons(view: String, select: (String) -> Unit) {
	SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp).testTag("fleetGrouping")) {
		listOf("groups" to "Grouped consists", "cars" to "Individual cars").forEachIndexed { index, (id, label) ->
			SegmentedButton(
				selected = view == id,
				onClick = { select(id) },
				shape = SegmentedButtonDefaults.itemShape(index, 2),
				colors = SegmentedButtonDefaults.colors(activeContainerColor = palette.accentTint, activeContentColor = palette.ink, inactiveContainerColor = Color.Transparent, inactiveContentColor = palette.ink, activeBorderColor = palette.accent, inactiveBorderColor = palette.line),
			) { Text(label, style = TextRoles.caption) }
		}
	}
}

@Composable
private fun FacetRow(title: String, value: String, options: List<String>, select: (String) -> Unit) {
	Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 8.dp).semantics(mergeDescendants = false) { contentDescription = title }, verticalAlignment = Alignment.CenterVertically) {
		Text(title, style = TextRoles.caption, color = palette.muted, modifier = Modifier.width(60.dp))
		ChipRow { FleetRules.facetOptions(options).forEach { (id, name) -> ChoiceChip(name, value == id, { select(id) }) } }
	}
}

@Composable
fun SwitchRow(title: String, checked: Boolean, onChange: (Boolean) -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true, subtitle: String? = null) {
	Row(
		modifier.fillMaxWidth().heightIn(min = 52.dp).toggleable(value = checked, enabled = enabled, role = Role.Switch, onValueChange = onChange).padding(horizontal = 16.dp, vertical = 6.dp),
		verticalAlignment = Alignment.CenterVertically,
	) {
		Column(Modifier.weight(1f)) {
			Text(title, style = TextRoles.subheadline, color = if (enabled) palette.ink else palette.muted)
			if (subtitle != null) Text(subtitle, style = TextRoles.caption, color = palette.muted)
		}
		Switch(checked = checked, onCheckedChange = null, enabled = enabled, colors = SwitchDefaults.colors(checkedTrackColor = palette.selection, checkedThumbColor = Color.White, checkedBorderColor = palette.selection))
	}
}

@Composable
private fun CarReport(car: FleetCar, now: Double, historical: Boolean) {
	val live = !historical && FleetRules.observedNow(car, now)
	val status = if (live) "${car.last?.route.orEmpty()} · currently reporting" else if (car.last == null) "Never observed" else "Last seen"
	Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
		Text(
			androidx.compose.ui.text.buildAnnotatedString {
				pushStyle(androidx.compose.ui.text.SpanStyle(fontWeight = FontWeight.SemiBold)); append(status); pop()
				append(" · " + (car.last?.location ?: "No location report collected"))
			},
			style = TextRoles.caption,
		)
		car.last?.let { Text("Position ${Display.ageLabel(it.locationTimestamp, now)} · association ${Display.ageLabel(it.timestamp, now)}", style = TextRoles.caption2, color = palette.muted) }
		if (!live) Text("Est. home yard: ${car.estimatedYard?.name ?: "unknown"}", style = TextRoles.caption2, color = palette.muted)
	}
}

@Composable
private fun EvidenceView(evidence: Evidence) {
	val context = LocalContext.current
	Column {
		if (evidence.url.startsWith("http")) Text("Source · ${evidence.date}", style = TextRoles.caption, color = palette.action, modifier = Modifier.heightIn(min = 48.dp).clickable(role = Role.Button) { openLink(context, evidence.url) }.padding(vertical = 14.dp))
		else Text("Source · ${evidence.date}", style = TextRoles.caption)
		Text(evidence.note, style = TextRoles.caption, color = palette.muted)
	}
}

/** A car or consist: current next stop, car reports, roster facts, home yard, and movement history. */
@Composable
fun FleetDetailScreen(model: AppModel, route: Route.FleetDetail, exit: ScreenExit, close: () -> Unit, open: (Route) -> Unit) {
	val id = route.id
	val kind = route.kind
	var data by remember(route) { mutableStateOf<FleetDetail?>(null) }
	var error by remember(route) { mutableStateOf<String?>(null) }
	var progress by remember(route) { mutableStateOf<LoadProgress?>(null) }
	var usingSaved by remember(route) { mutableStateOf(false) }
	var loadingMore by remember(route) { mutableStateOf(false) }
	var hasMore by remember(route) { mutableStateOf(false) }
	var generation by remember(route) { mutableIntStateOf(0) }
	val fleet = model.fleet
	val scope = rememberCoroutineScope()
	val lifecycle = LocalLifecycleOwner.current.lifecycle
	val loadKey = "$id|${fleet.useSavedFleet}|${fleet.offlineManifest?.id ?: "none"}|${model.endpoint}|${model.connected}"

	suspend fun refresh(force: Boolean = false) {
		val store = fleet.store
		if (usingSaved && (route.preferSaved || fleet.useSavedFleet || !model.connected) && data != null && !force) return
		val identity = loadKey
		generation += 1
		val current = generation
		val waiting = data == null
		if (waiting) progress = null
		try {
			val savedMode = (route.preferSaved || fleet.useSavedFleet || !model.connected) && fleet.offlineManifest != null && store != null
			val value = if (savedMode) {
				if (waiting) progress = LoadProgress(null, "Reading this car's saved history on this device…")
				store.detail(kind, id, 0, 200)
			} else model.service.fleetDetail(kind, id, if (waiting) { update -> if (current == generation) progress = update.load("this car's history") } else null)
			if (identity != loadKey || current != generation) return
			usingSaved = savedMode
			data = value
			hasMore = savedMode && value.history.size == 200
			error = null
		} catch (failure: CancellationException) { throw failure }
		catch (_: Exception) {
			if (identity != loadKey || current != generation) return
			val saved = if (store != null && fleet.offlineManifest != null) runCatching { store.detail(kind, id, 0, 200) }.getOrNull() else null
			if (saved != null) {
				val previous = data
				if (!force && usingSaved && previous != null && previous.generatedAt == saved.generatedAt) data = FleetDetail(saved.cars, previous.history, saved.generatedAt)
				else { data = saved; hasMore = saved.history.size == 200 }
				usingSaved = true
				error = "Live fleet unavailable. Showing saved historical reports."
			} else error = "Car history unavailable. Previous reports are not current."
		}
	}

	suspend fun loadMore() {
		val store = fleet.store ?: return
		val previous = data ?: return
		if (loadingMore) return
		val identity = loadKey
		val current = generation
		loadingMore = true
		try {
			val next = store.detail(kind, id, previous.history.size, 200)
			if (identity != loadKey || current != generation || data?.history?.size != previous.history.size) return
			data = FleetDetail(previous.cars, previous.history + next.history, previous.generatedAt)
			hasMore = next.history.size == 200
		} catch (failure: CancellationException) { throw failure }
		catch (_: Exception) { error = "Could not load more saved history. Try again." }
		finally { loadingMore = false }
	}

	LaunchedEffect(loadKey) {
		data = null; progress = null
		lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) { while (true) { refresh(); delay(10_000) } }
	}

	ListScreen("Car & consist details", exit = exit, onExit = close, onRefresh = { refresh(force = true) }, tag = "fleetDetails") {
		error?.let { message -> section("error") { row { RowContainer { Notice(message) } } } }
		val manifest = fleet.offlineManifest
		if (usingSaved && manifest != null) section("scope") { row { RowContainer { Notice(FleetRules.savedScope(manifest, model.timeFormat)) } } }
		val current = data
		if (current == null) {
			if (error == null) section("loading") {
				row {
					val load = progress ?: LoadProgress(null, "Waiting to request this car's history…")
					RowContainer { LoadingBar("Loading car history", load.fraction?.toFloat(), load.percentLabel, load.spokenPercent, load.detail, Modifier.testTag("fleetDetailLoading")) }
				}
			}
			return@ListScreen
		}
		val now = model.now
		val live = if (model.connected && !usingSaved && error == null) current.cars.firstOrNull { FleetRules.observedNow(it, now) && (!id.startsWith("observed:") || it.last?.consistId == id) }?.last else null
		section("now", footer = "Reported order does not establish the leading end. Historical formations are not confirmed current links.") {
			if (kind != "cars" && current.cars.isNotEmpty() && current.cars.size <= 20 && current.cars.all { TrainFavorites.validCarID(it.id) }) {
				row("favoriteConsist") { FavoriteConsistRow(model, current.cars.map { it.id }) }
			}
			if (live != null) {
				val next = live.next
				val upcoming = next != null && (next.time?.let { it >= now } ?: true)
				row("next") {
					RowContainer {
						if (upcoming) Column {
							Row { Text("Next stop: ${next.name}", style = TextRoles.subheadlineBold, modifier = Modifier.weight(1f)); Text(Display.clockTime(next.time, model.timeFormat), style = TextRoles.subheadline) }
							Text("Estimated · ${live.route}", style = TextRoles.caption2, color = palette.muted)
						} else Text("Next stop unavailable", style = TextRoles.subheadline)
					}
				}
				row("liveActions") {
					ChipRow(Modifier.padding(horizontal = 12.dp)) {
						val stationID = next?.stationId
						if (upcoming && stationID != null) nyc.juliet.subwaysfornerds.ui.components.ActionChip("Open station board", { model.selectStation(stationID) }, icon = Icons.Filled.Train)
						nyc.juliet.subwaysfornerds.ui.components.ActionChip("Open live train details", { open(Route.Train(live.tripKey)) }, icon = Icons.AutoMirrored.Filled.ArrowForward)
					}
				}
			} else row("next") { RowContainer { Text("Next stop unavailable", style = TextRoles.subheadline, color = palette.muted) } }
		}
		val historical = !model.connected || usingSaved || error != null
		current.cars.forEach { car ->
			section("car:${car.id}", headerContent = { Text("${car.number} · ${car.equipment}", style = TextRoles.footnote.copy(fontWeight = FontWeight.SemiBold), color = palette.muted) }) {
				row("report") {
					Row(verticalAlignment = Alignment.CenterVertically) {
						Column(
							Modifier.weight(1f).then(if (kind != "cars") Modifier.clickable(role = Role.Button, onClickLabel = "${car.number} · ${car.equipment} car details") { open(Route.FleetDetail(car.id, "cars", usingSaved)) } else Modifier)
								.padding(start = 16.dp, top = 8.dp, bottom = 8.dp),
						) { CarReport(car, now, historical) }
						if (TrainFavorites.validCarID(car.id)) FavoriteCarStar(model, car.id)
					}
				}
				row("facts") { RowContainer { FactGrid(FleetRules.carFacts(car)) } }
				val last = car.last
				if (last != null && kind == "cars" && last.consistId.isNotEmpty()) row("consist") {
					NavigationRow(if (!usingSaved && error == null && FleetRules.observedNow(car, now)) "Current consist" else "Last observed consist", { open(Route.FleetDetail(last.consistId, "consists", usingSaved)) })
				}
				car.estimatedYard?.let { yard ->
					row("yard") {
						RowContainer {
							Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
								Text("Est. home yard: ${yard.name}", style = TextRoles.subheadline)
								EvidenceView(Evidence(yard.url, yard.date, yard.note))
							}
						}
					}
				}
				car.conflicts.orEmpty().forEachIndexed { index, conflict -> row("conflict$index") { RowContainer { Notice(conflict) } } }
				if (car.evidence.isNotEmpty()) row("evidence") { RowContainer { Column(verticalArrangement = Arrangement.spacedBy(6.dp)) { car.evidence.forEach { EvidenceView(it) } } } }
			}
		}
		section(
			"history",
			header = if (usingSaved) "Downloaded movement history" else "Observed changes · last 30 days",
			footer = if (usingSaved) "All changes included in this saved history window are available using Load more history. Historical events can mention cars outside the saved scope. Times are observation times, not inferred movement times."
			else "Latest 200 changes. Prepare a fleet pack in Settings to save 7 or 30 days of history. Times are observation times, not inferred movement times.",
		) {
			current.history.forEachIndexed { index, observation ->
				row("event$index") {
					Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
						Text("${observation.route} · ${observation.location}", style = TextRoles.subheadlineBold)
						Text(easternDate(observation.timestamp, model.timeFormat), style = TextRoles.caption2, color = palette.muted)
						Text("Cars " + observation.cars.joinToString(" · ") { it.substringAfterLast(':') }, style = TextRoles.caption2, color = palette.muted)
						if (observation.consistId.isNotEmpty() && observation.consistId != id) {
							Text(
								"Observed consist", style = TextRoles.caption, color = palette.action,
								modifier = Modifier.heightIn(min = 48.dp).clickable(role = Role.Button) { open(Route.FleetDetail(observation.consistId, "consists", usingSaved)) }.padding(vertical = 14.dp),
							)
						}
					}
				}
			}
			if (current.history.isEmpty()) row { RowContainer { Text("No movement history collected for this period.", style = TextRoles.subheadline, color = palette.muted) } }
			if (usingSaved && hasMore) row("more") {
				if (loadingMore) RowContainer { LoadingBar("Loading more history", null, null, null, "Reading more saved movements on this device…", Modifier.testTag("loadMoreFleetHistory")) }
				else TextButton(onClick = { scope.launch { loadMore() } }, modifier = Modifier.padding(start = 4.dp).testTag("loadMoreFleetHistory")) { Text("Load more history", color = palette.action) }
			}
		}
		section("raw") { row { RawJsonDisclosure("Fleet identifiers & reports", TransitJson.encodeToJsonElement(FleetDetail.serializer(), current)) } }
	}
}
