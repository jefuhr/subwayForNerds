package nyc.juliet.subwaysfornerds.ui.train

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.CloudOff
import androidx.compose.material.icons.filled.DownloadForOffline
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.Train
import androidx.compose.material.icons.outlined.StarOutline
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import nyc.juliet.subwaysfornerds.core.Consist
import nyc.juliet.subwaysfornerds.core.Display
import nyc.juliet.subwaysfornerds.core.Freshness
import nyc.juliet.subwaysfornerds.core.OfflineDisplay
import nyc.juliet.subwaysfornerds.core.OfflineIdentity
import nyc.juliet.subwaysfornerds.core.StopPrediction
import nyc.juliet.subwaysfornerds.core.Train
import nyc.juliet.subwaysfornerds.core.TrainFavoriteRules
import nyc.juliet.subwaysfornerds.core.TrainFavorites
import nyc.juliet.subwaysfornerds.core.TransitJson
import nyc.juliet.subwaysfornerds.core.TripDetail
import nyc.juliet.subwaysfornerds.data.CachedTrip
import nyc.juliet.subwaysfornerds.ui.AppModel
import nyc.juliet.subwaysfornerds.ui.TripFailure
import nyc.juliet.subwaysfornerds.ui.components.ActionChip
import nyc.juliet.subwaysfornerds.ui.components.ChangeIcons
import nyc.juliet.subwaysfornerds.ui.components.ChangeRow
import nyc.juliet.subwaysfornerds.ui.components.ChipRow
import nyc.juliet.subwaysfornerds.ui.components.FactGrid
import nyc.juliet.subwaysfornerds.ui.components.FavoriteStar
import nyc.juliet.subwaysfornerds.ui.components.ListHeader
import nyc.juliet.subwaysfornerds.ui.components.ListScreen
import nyc.juliet.subwaysfornerds.ui.components.LoadingBar
import nyc.juliet.subwaysfornerds.ui.components.Notice
import nyc.juliet.subwaysfornerds.ui.components.RawJsonDisclosure
import nyc.juliet.subwaysfornerds.ui.components.RouteBullet
import nyc.juliet.subwaysfornerds.ui.components.RowContainer
import nyc.juliet.subwaysfornerds.ui.components.ScreenExit
import nyc.juliet.subwaysfornerds.ui.components.section
import nyc.juliet.subwaysfornerds.ui.navigation.Route
import nyc.juliet.subwaysfornerds.ui.theme.TextRoles
import nyc.juliet.subwaysfornerds.ui.theme.palette

/** What train details show: live data while connected, otherwise whichever copy has the newer source. */
data class TrainPresentation(
	val train: Train?,
	val detail: TripDetail?,
	val cached: Boolean,
	val showingSnapshot: Boolean,
	val sourceTimestamp: Double?,
	val noEstimate: String?,
	val nextStopIndex: Int?,
	val error: String?,
) {
	companion object {
		fun of(live: TripDetail?, failure: TripFailure?, saved: CachedTrip?, savedLoaded: Boolean, snapshotOnly: Boolean, connected: Boolean, now: Double): TrainPresentation {
			val data = if (snapshotOnly) null else live
			val cached = data == null || failure != null || !connected
			val savedTime = saved?.sourceTimestamp
			val memoryIsNewer = data != null && (saved == null || !saved.isComplete || savedTime == null || data.train.timestamp > savedTime)
			val showingSnapshot = cached && !memoryIsNewer && saved != null
			val train = if (showingSnapshot) saved.train else data?.train
			val detail = if (showingSnapshot) saved.asDetail() else data
			val source = if (showingSnapshot) saved.sourceTimestamp else data?.train?.timestamp
			val noEstimate = train?.let {
				when {
					it.relationship == "NO_DATA" -> "no estimate"
					it.relationship in setOf("CANCELED", "DELETED") -> "canceled when saved"
					it.assigned == false -> "not assigned when saved"
					else -> null
				}
			}
			val next = if (cached && noEstimate == null) train?.let { OfflineDisplay.estimatedNextStopIndex(it.stops, now) } else null
			val hasSnapshot = saved != null || data != null
			val error = when {
				snapshotOnly -> if (savedLoaded && saved == null) "This saved arrival is no longer stored on this device." else null
				failure is TripFailure.NotFound -> if (hasSnapshot) "No longer in the current feed. Showing the last report, which may be out of date." else "This train is no longer in the current feed."
				failure is TripFailure.Unavailable -> if (hasSnapshot) (if (connected) "Train update unavailable. Showing offline estimates." else "No connection. Showing offline estimates.") else failure.message
				!connected -> if (hasSnapshot) "No connection. Showing offline estimates." else "No connection, and this train was not saved offline."
				else -> null
			}
			return TrainPresentation(train, detail, cached, showingSnapshot, source, noEstimate, next, error)
		}
	}
}

@Composable
fun TrainDetailScreen(model: AppModel, route: Route.Train, exit: ScreenExit, close: () -> Unit, open: (Route) -> Unit) {
	val key = route.tripKey
	val snapshotOnly = route.snapshotOnly
	val origin = remember(route) { route.origin?.let { model.departureOrigin(it) } }
	var saved by remember(key) { mutableStateOf<CachedTrip?>(null) }
	var savedLoaded by remember(key) { mutableStateOf(false) }
	var working by remember { mutableStateOf(false) }
	val scope = rememberCoroutineScope()
	val live = if (snapshotOnly) null else model.liveTrips[key]
	val now = model.now

	// Registered for the screen's lifetime; the coordinator refreshes open trips on the shared cadence.
	DisposableEffect(key, snapshotOnly) {
		if (!snapshotOnly) model.openTrip(key)
		onDispose { if (!snapshotOnly) model.closeTrip(key) }
	}
	LaunchedEffect(key, model.endpoint) {
		saved = model.cachedTrip(key)
		savedLoaded = true
		if (!snapshotOnly) model.refreshTrip(key)
	}
	LaunchedEffect(live?.detail?.train?.timestamp) { if (live?.detail != null) saved = model.cachedTrip(key) }
	LaunchedEffect(model.activeRideTrip) { model.activeRideTrip?.takeIf { it.key == key }?.let { saved = it } }

	val shown = TrainPresentation.of(live?.detail, live?.failure, saved, savedLoaded, snapshotOnly, model.connected, now)
	val train = shown.train

	ListScreen(
		"Train details", exit = exit, onExit = close, tag = "trainDetails",
		onRefresh = { if (!snapshotOnly) model.refreshTrip(key); saved = model.cachedTrip(key) },
	) {
		shown.error?.let { error -> section("error") { row { RowContainer { Notice(error) } } } }
		if (train == null) {
			if (shown.error == null) section("loading") {
				row {
					val load = if (snapshotOnly) nyc.juliet.subwaysfornerds.core.LoadProgress(null, "Reading the saved train from this device…") else model.tripLoad(key)
					RowContainer { LoadingBar("Loading train details", load.fraction?.toFloat(), load.percentLabel, load.spokenPercent, load.detail, Modifier.testTag("tripLoading")) }
				}
			}
			return@ListScreen
		}
		val consist = if (OfflineDisplay.currentConsist(train.consist, now, shown.cached)) train.consist else null
		if (shown.cached) section("offline") { row { OfflineProvenance(model, shown, saved, snapshotOnly, key) } }
		section("summary") {
			row {
				RowContainer {
					Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
						Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
							RouteBullet(train.route)
							Column(Modifier.weight(1f)) {
								Text(train.destination, style = TextRoles.title3)
								Text(Display.directionLabel(train.direction), style = TextRoles.caption, color = palette.muted)
							}
							// Saved data is never labeled live, however recent its source time.
							val freshness = if (shown.cached) "offline" else Display.freshness(train, now).id
							val age = Display.ageLabel(train.timestamp, now)
							Text(
								"$freshness · $age",
								style = TextRoles.caption.copy(fontWeight = FontWeight.SemiBold),
								color = if (freshness == "live") palette.action else palette.muted,
								modifier = Modifier.semantics { contentDescription = "Feed $freshness, $age" },
							)
						}
						FactGrid(trainFacts(train, consist, shown.cached, now))
						origin?.let { Text("Boarding at ${it.station.name}", style = TextRoles.subheadline, modifier = Modifier.testTag("boardingStation")) }
					}
				}
			}
		}
		if (consist != null) consistSection(model, consist, train.feed, now, open)
		if (train.alerts.isNotEmpty()) section("alerts", header = "Alerts") { train.alerts.forEachIndexed { index, alert -> row(index) { RowContainer { Notice(alert) } } } }
		section("actions") {
			row {
				RideActions(model, key, snapshotOnly, working, { working = it }, { saved = it }, live?.detail, origin)
			}
		}
		val changes = Display.changesAhead(train.changes, 0)
		if (changes.isNotEmpty()) section(
			"changes", header = "Different from normal",
			footer = "Compared with weekday daytime service. Scheduled variations differ from disruptions; advisory notices may not affect every train.",
		) { changes.forEach { change -> row(change.id) { ChangeRow(change, now, shown.cached, model.timeFormat) } } }
		section(
			"stops",
			header = if (shown.cached) "Saved stopping pattern" else "Remaining stopping pattern",
			footer = if (shown.cached) "Offline estimates count down the saved predictions on this device's clock. They are not observed positions; delays, reroutes and cancellations after the source time are unknown. Connections need a live feed."
			else "Arrival / departure · Eastern. Patterns reflect remaining feed predictions. Future track fields describe that stop, not the current train position. Operations IDs identify trips, not physical cars.",
		) {
			train.stops.forEachIndexed { index, stop ->
				row("stop$index") {
					val connectable = !shown.cached && Display.freshness(train, now) == Freshness.LIVE && stop.relationship !in setOf("SKIPPED", "NO_DATA") &&
						stop.stationId != null && (stop.arrival ?: stop.departure ?: Double.POSITIVE_INFINITY) >= now
					StopRow(
						model, stop, now,
						offline = if (shown.cached) OfflineStop(shown.sourceTimestamp, index == shown.nextStopIndex, shown.noEstimate) else null,
						onClick = if (connectable) ({ open(Route.Transfers(key, stop.id, stop.name, stop.sequence)) }) else null,
					)
				}
			}
		}
		train.scheduledPattern?.let { pattern ->
			section("pattern") {
				row {
					var expanded by rememberSaveable { mutableStateOf(false) }
					Column {
						Row(
							Modifier.fillMaxWidth().heightIn(min = 48.dp).clickable(role = Role.Button) { expanded = !expanded }.padding(horizontal = 16.dp),
							verticalAlignment = Alignment.CenterVertically,
						) { Text("Matching scheduled pattern · ${pattern.headsign}", style = TextRoles.subheadline, color = palette.action) }
						if (expanded) Column(Modifier.padding(start = 16.dp, end = 16.dp, bottom = 12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
							Text("Shape ${pattern.shape} · ${pattern.source}", style = TextRoles.caption)
							Text(pattern.stops.joinToString(" → "), style = TextRoles.caption)
							Text("Static context only; live predictions take precedence.", style = TextRoles.caption, color = palette.muted)
						}
					}
				}
			}
		}
		shown.detail?.let { detail -> section("raw") { row { RawJsonDisclosure("Decoded feed & identifiers", TransitJson.encodeToJsonElement(TripDetail.serializer(), detail)) } } }
	}
}

private fun trainFacts(train: Train, consist: Consist?, cached: Boolean, now: Double): List<Pair<String, String>> {
	val facts = mutableListOf(
		"Operations ID" to (train.trainId ?: "Not reported"),
		"Assignment" to (train.assigned?.let { if (it) "Assigned to a train" else "Not yet assigned" } ?: "Not reported"),
		"Service date" to (train.serviceDate ?: "Not reported"),
	)
	val position = train.vehiclePosition
	when {
		position != null -> {
			facts += "Vehicle" to position.vehicleId
			facts += "GPS report" to (Display.currentVehiclePositions(listOf(position), now).firstOrNull()?.let { Display.vehiclePositionLabel(it, now, cached) } ?: "No recent vehicle location reported")
		}
		train.feed.startsWith("njt-") -> facts += "GPS report" to "Not reported"
		else -> facts += (if (cached) "Last position report" else "Position report") to (train.position?.let { "${it.name} · ${Display.ageLabel(it.timestamp, now)}" } ?: "Not reported")
	}
	if (consist == null) facts += "Car numbers" to (if (cached) "Not shown offline" else "Not currently available")
	return facts
}

/** Provenance for every cached time: offline estimate, source age, and completeness. */
@Composable
private fun OfflineProvenance(model: AppModel, shown: TrainPresentation, saved: CachedTrip?, snapshotOnly: Boolean, key: String) {
	val now = model.now
	RowContainer {
		Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
			Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp), modifier = Modifier.testTag("offlineEstimateLabel").semantics(mergeDescendants = true) {}) {
				Icon(Icons.Filled.CloudOff, contentDescription = null, tint = palette.warning, modifier = Modifier.size(16.dp))
				Text(OfflineDisplay.estimateLabel(shown.sourceTimestamp, now, model.offlinePreferences), style = TextRoles.subheadlineBold)
			}
			if (snapshotOnly) Text(
				"Saved PATH arrival · historical. PATH reports name a station arrival, not one train, so this copy is never refreshed.",
				style = TextRoles.caption.copy(fontWeight = FontWeight.SemiBold), modifier = Modifier.testTag("savedPathSnapshot"),
			)
			if (!shown.showingSnapshot) {
				Text(if (saved == null) "Last report from this visit · not saved offline" else "Last report from this visit · newer than the saved copy", style = TextRoles.caption, color = palette.muted)
			} else if (saved != null) {
				val kept = if (saved.manual) " · kept until you remove it" else if (model.activeRide?.key == key) " · kept for your ride" else ""
				Text("Saved ${Display.ageLabel(saved.savedAt, now)}$kept", style = TextRoles.caption, color = palette.muted)
				OfflineDisplay.completenessLabel(saved.isComplete)?.let { Text(it, style = TextRoles.caption.copy(fontWeight = FontWeight.SemiBold), modifier = Modifier.testTag("partialTripLabel")) }
			}
			Text("Car numbers and the train's current position are not shown offline.", style = TextRoles.caption2, color = palette.muted)
		}
	}
}

/** "Save trip offline" keeps a snapshot; "I'm on this train" also keeps it current and shows it on the board. */
@Composable
private fun RideActions(
	model: AppModel, key: String, snapshotOnly: Boolean, working: Boolean, setWorking: (Boolean) -> Unit,
	setSaved: (CachedTrip?) -> Unit, detail: TripDetail?, origin: nyc.juliet.subwaysfornerds.ui.BoardOrigin?,
) {
	val scope = rememberCoroutineScope()
	var confirmRemove by rememberSaveable { mutableStateOf(false) }
	var confirmReplace by rememberSaveable { mutableStateOf(false) }
	val isSaved = model.isTripSaved(key)
	val isRide = model.activeRide?.key == key
	val positional = OfflineIdentity.isPositionalTrip(key)
	fun startRide() = scope.launch {
		setWorking(true)
		model.startRide(key, detail, origin)
		setSaved(model.cachedTrip(key))
		setWorking(false)
	}
	Column(Modifier.padding(start = 12.dp, end = 12.dp, top = 4.dp, bottom = 6.dp)) {
		ChipRow {
			if (isSaved) ActionChip("Saved offline", { confirmRemove = true }, Modifier.testTag("removeSavedTrip"), icon = Icons.Filled.CheckCircle, selected = true)
			else if (!snapshotOnly) ActionChip("Save trip offline", {
				scope.launch { setWorking(true); model.saveTripOffline(key, detail, origin); setSaved(model.cachedTrip(key)); setWorking(false) }
			}, Modifier.testTag("saveTripOffline"), icon = Icons.Filled.DownloadForOffline, enabled = !working)
			if (!snapshotOnly) {
				if (isRide) ActionChip("End ride", { scope.launch { model.endRide() } }, Modifier.testTag("endRide"), icon = Icons.Filled.Cancel, selected = true)
				else if (!positional) ActionChip("I'm on this train", { if (model.activeRide != null) confirmReplace = true else startRide() }, Modifier.testTag("startRide"), icon = Icons.Filled.Train, enabled = !working)
			}
		}
		if (positional) Text("PATH reports identify a station arrival, not one train, so rides can't follow them.", style = TextRoles.caption2, color = palette.muted)
		model.offlineActionError?.let { Notice(it, Modifier.testTag("offlineActionError")) }
	}
	if (confirmRemove) AlertDialog(
		onDismissRequest = { confirmRemove = false },
		title = { Text(if (snapshotOnly) "Remove this saved arrival?" else "Remove this saved train?") },
		text = { Text("Its offline snapshot may then expire with other cached trips.") },
		confirmButton = { TextButton(onClick = { confirmRemove = false; scope.launch { model.removeSavedTrip(key) } }, modifier = Modifier.testTag("confirmRemoveSavedTrip")) { Text(if (snapshotOnly) "Remove saved arrival" else "Remove saved train", color = palette.danger) } },
		dismissButton = { TextButton(onClick = { confirmRemove = false }) { Text("Cancel", color = palette.action) } },
	)
	if (confirmReplace) AlertDialog(
		onDismissRequest = { confirmReplace = false },
		title = { Text("Replace your current ride?") },
		text = { Text("Only one ride is followed at a time. The other train stays saved only if you saved it.") },
		confirmButton = { TextButton(onClick = { confirmReplace = false; startRide() }, modifier = Modifier.testTag("confirmReplaceRide")) { Text("Ride this train instead", color = palette.action) } },
		dismissButton = { TextButton(onClick = { confirmReplace = false }) { Text("Cancel", color = palette.action) } },
	)
}

private fun androidx.compose.foundation.lazy.LazyListScope.consistSection(model: AppModel, consist: Consist, feed: String, now: Double, open: (Route) -> Unit) {
	section(
		"consist",
		header = "Car numbers · Helium · reported ${Display.ageLabel(consist.updatedAt, now)}",
		footer = "Tap a car for its fleet history. Reported order does not confirm the front of the train.",
	) {
		TrainFavorites.consistIDs(consist, feed)?.let { ids -> row("favoriteConsist") { FavoriteConsistRow(model, ids) } }
		row("cars") {
			FlowRow(Modifier.fillMaxWidth().padding(12.dp), horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
				val match = model.trainFavorites.match(consist, feed, now)
				consist.cars.forEach { car ->
					val id = TrainFavorites.carID(car.number, car.type, feed)
					val highlighted = id != null && match?.carIDs?.contains(id) == true
					Row(verticalAlignment = Alignment.CenterVertically) {
						Column(
							Modifier
								.widthIn(min = 104.dp)
								.heightIn(min = 48.dp)
								.background(if (highlighted) palette.accentTint else palette.raised, RoundedCornerShape(8.dp))
								.clickable(role = Role.Button) { open(if (id != null) Route.FleetDetail(id, "cars") else Route.FleetSearch(car.number)) }
								.padding(horizontal = 8.dp, vertical = 4.dp)
								.semantics(mergeDescendants = true) { contentDescription = "Car ${car.number}, ${car.type ?: "type not reported"}${if (highlighted) ", favorite" else ""}" },
							horizontalAlignment = Alignment.CenterHorizontally,
						) {
							Text(car.number, style = TextRoles.subheadlineBold)
							Text(car.type ?: "Type not reported", style = TextRoles.caption2, color = palette.muted, maxLines = 1)
							if (highlighted) Row(verticalAlignment = Alignment.CenterVertically) {
								Icon(Icons.Filled.Star, contentDescription = null, tint = palette.action, modifier = Modifier.size(11.dp))
								Text(" Favorite", style = TextRoles.caption2)
							}
						}
						if (id != null) FavoriteCarStar(model, id)
					}
				}
			}
		}
	}
}

@Composable
fun FavoriteCarStar(model: AppModel, id: String) {
	val saved = id in model.trainFavorites.cars
	FavoriteStar(saved, "Favorite car ${TrainFavoriteRules.label(id)}", { model.toggleFavoriteCar(id) }, Modifier.testTag("favoriteCar_$id"))
}

@Composable
fun FavoriteConsistRow(model: AppModel, ids: List<String>) {
	val saved = model.trainFavorites.containsConsist(ids)
	Row(
		Modifier.fillMaxWidth().heightIn(min = 48.dp)
			.clickable(role = Role.Checkbox) { model.toggleFavoriteConsist(ids) }
			.padding(horizontal = 16.dp)
			.semantics(mergeDescendants = true) { contentDescription = "Favorite consist, ${ids.size} cars"; selected = saved }
			.testTag("favoriteConsist"),
		verticalAlignment = Alignment.CenterVertically,
		horizontalArrangement = Arrangement.spacedBy(8.dp),
	) {
		Icon(if (saved) Icons.Filled.Star else Icons.Outlined.StarOutline, contentDescription = null, tint = palette.action)
		Text("Favorite consist", style = TextRoles.subheadline, color = palette.action)
	}
}

/** Offline context for one saved stop. */
data class OfflineStop(val sourceTimestamp: Double?, val estimatedNext: Boolean, val noEstimate: String?)

@Composable
private fun StopRow(model: AppModel, stop: StopPrediction, now: Double, offline: OfflineStop?, onClick: (() -> Unit)?) {
	val format = model.timeFormat
	val details = buildList {
		add(stop.id)
		stop.scheduledTrack?.let { add("scheduled track $it") }
		stop.actualTrack?.let { add("reported track $it") }
		if (stop.relationship == "SKIPPED") add("skipped")
	}.joinToString(" · ")
	Row(
		Modifier.fillMaxWidth().heightIn(min = 48.dp)
			.then(if (onClick != null) Modifier.clickable(role = Role.Button, onClickLabel = "Connections at ${stop.name}", onClick = onClick) else Modifier)
			.padding(start = 16.dp, end = 8.dp, top = 6.dp, bottom = 6.dp)
			.semantics(mergeDescendants = true) {},
		verticalAlignment = Alignment.CenterVertically,
		horizontalArrangement = Arrangement.spacedBy(8.dp),
	) {
		Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
			Row(horizontalArrangement = Arrangement.spacedBy(5.dp), verticalAlignment = Alignment.CenterVertically) {
				Text(stop.name, style = TextRoles.subheadlineBold, textDecoration = if (stop.relationship == "SKIPPED") TextDecoration.LineThrough else null)
				ChangeIcons(stop.changes.orEmpty(), now)
			}
			Text(details, style = TextRoles.caption2, color = palette.muted)
			if (offline?.estimatedNext == true) Text(OfflineDisplay.estimatedNextStopLabel, style = TextRoles.caption2.copy(fontWeight = FontWeight.SemiBold), modifier = Modifier.testTag("estimatedNextStop"))
		}
		Column(horizontalAlignment = Alignment.End) {
			when {
				offline?.noEstimate != null -> {
					Text(Display.clockTime(stop.arrival ?: stop.departure, format), style = TextRoles.subheadline)
					Text(offline.noEstimate, style = TextRoles.caption2, color = palette.muted)
				}
				offline != null -> {
					val countdown = OfflineDisplay.countdown(stop, offline.sourceTimestamp, now, true, model.offlinePreferences, format)
					Text(if (countdown.unit == "min") "${countdown.value} min" else countdown.value, style = TextRoles.subheadline)
					Text(if (countdown.unit == "min") "offline est. ${Display.clockTime(stop.arrival ?: stop.departure, format)}" else countdown.unit, style = TextRoles.caption2, color = palette.muted, textAlign = TextAlign.End)
				}
				else -> {
					Text(Display.clockTime(stop.arrival, format), style = TextRoles.subheadline)
					val departure = stop.departure
					if (departure != null && departure != stop.arrival) Text("dep ${Display.clockTime(departure, format)}", style = TextRoles.caption2, color = palette.muted)
				}
			}
		}
		// Every row keeps the chevron column so times line up; only connectable stops are active.
		Icon(
			Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null,
			tint = if (onClick != null) palette.muted else androidx.compose.ui.graphics.Color.Transparent,
			modifier = Modifier.width(20.dp),
		)
	}
}
