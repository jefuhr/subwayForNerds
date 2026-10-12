import SwiftUI
import TransitCore

private enum CarTarget: Hashable {
	case car(String)
	case search(String)
}

struct TrainDetailView: View {
	let tripKey: String
	/// Shows only the saved snapshot and never fetches. Saved PATH keys name a station
	/// arrival, so fetching them again would show whichever train holds that slot now.
	var snapshotOnly = false
	@Environment(AppModel.self) private var app
	/// The stored snapshot, shown whenever live data is unavailable.
	@State private var saved: CachedTrip?
	@State private var carTarget: CarTarget?
	@State private var confirmRemove = false
	@State private var confirmReplaceRide = false
	@State private var working = false
	@State private var registration: OpenTripRegistration?
	@State private var savedLoaded = false
	private var now: TimeInterval { app.now }
	private var live: LiveTrip? { snapshotOnly ? nil : app.liveTrips[tripKey] }
	/// The latest details fetched while this view was open; kept after the connection drops.
	private var data: TripDetail? { live?.detail }
	/// Live data only while connected and the last request succeeded; otherwise every
	/// time is an offline estimate counted down from a stored source prediction.
	private var cached: Bool { data == nil || live?.failure != nil || !app.connected }
	/// Offline, whichever copy has the newer source wins: the details in memory or the saved snapshot.
	private var memoryIsNewer: Bool {
		guard let data else { return false }
		guard let saved, saved.isComplete, let savedTime = saved.sourceTimestamp else { return true }
		return data.train.timestamp > savedTime
	}
	private var showingSnapshot: Bool { cached && !memoryIsNewer && saved != nil }
	private var train: Train? { showingSnapshot ? saved?.train : data?.train }
	private var shownDetail: TripDetail? { showingSnapshot ? saved?.detail : data }
	private var sourceTimestamp: TimeInterval? { showingSnapshot ? saved?.sourceTimestamp : data?.train.timestamp }
	private var isRide: Bool { app.activeRide?.tripKey == tripKey }
	private var isSaved: Bool { app.isTripSaved(tripKey) }
	/// A canceled or unassigned train never gets a countdown from saved data.
	private var noEstimate: String? {
		guard let train else { return nil }
		if train.relationship == "NO_DATA" { return "no estimate" }
		if ["CANCELED", "DELETED"].contains(train.relationship ?? "") { return "canceled when saved" }
		return train.assigned == false ? "not assigned when saved" : nil
	}
	private var nextStopIndex: Int? { cached && noEstimate == nil ? train.flatMap { OfflineDisplay.estimatedNextStopIndex($0.stops, now: now) } : nil }
	private var error: String? {
		if snapshotOnly { return savedLoaded && saved == nil ? "This saved arrival is no longer stored on this device." : nil }
		let hasSnapshot = saved != nil || data != nil
		// A trip missing from the feed is not reported as canceled; any snapshot stays.
		switch live?.failure {
		case .notFound?: return hasSnapshot ? "No longer in the current feed. Showing the last report, which may be out of date." : "This train is no longer in the current feed."
		case .unavailable(let message)?: return hasSnapshot ? (app.connected ? "Train update unavailable. Showing offline estimates." : "No connection. Showing offline estimates.") : message
		case nil: break
		}
		if !app.connected { return hasSnapshot ? "No connection. Showing offline estimates." : "No connection, and this train was not saved offline." }
		return nil
	}

	var body: some View {
		List {
			if let error { Section { Notice(text: error) } }
			if let train {
				let consist = OfflineDisplay.currentConsist(train.consist, now: now, cached: cached) ? train.consist : nil
				if cached { offlineSection }
				Section {
					VStack(alignment: .leading, spacing: 12) {
						HStack(alignment: .center, spacing: 10) {
							RouteBullet(route: train.route)
							VStack(alignment: .leading, spacing: 1) {
								Text(train.destination).font(.title3.bold())
								Text(Display.directionLabel(train.direction)).font(.caption).foregroundStyle(.secondary)
							}
							Spacer(minLength: 4)
							// Saved data is never labeled live, however recent its source time.
							let freshness = cached ? "offline" : Display.freshness(train, now: now).rawValue
							Text("\(freshness) · \(Display.ageLabel(train.timestamp, now: now))")
								.font(.caption.weight(.semibold).monospacedDigit())
								.foregroundStyle(freshness == "live" ? app.theme.accent : app.theme.ink.opacity(0.7))
								.accessibilityLabel("Feed \(freshness), \(Display.ageLabel(train.timestamp, now: now))")
						}
						FactGrid(facts: facts(train, consist: consist))
					}
					.listRowInsets(.vertical, 12)
				}
				if let consist { consistSection(consist, feed: train.feed) }
				if !train.alerts.isEmpty {
					Section { ForEach(Array(train.alerts.enumerated()), id: \.offset) { _, alert in Notice(text: alert) } } header: { ListHeader("Alerts") }
				}
				rideActions
				ChangesSection(changes: Display.changesAhead(train.changes, index: 0), now: now, cached: cached)
				Section {
					ForEach(Array(train.stops.enumerated()), id: \.offset) { index, stop in
						let row = StopRow(stop: stop, now: now, offline: cached ? OfflineStopEstimate(sourceTimestamp: sourceTimestamp, estimatedNext: index == nextStopIndex, noEstimate: noEstimate) : nil)
						Group {
							if !cached, Display.freshness(train, now: now) == .live, !["SKIPPED", "NO_DATA"].contains(stop.relationship ?? ""), stop.stationId != nil, (stop.arrival ?? stop.departure ?? .infinity) >= now {
								NavigationLink { TransferView(tripKey: tripKey, stop: stop) } label: { row }
									.accessibilityLabel("Connections at \(stop.name)")
							} else {
								// A disabled link keeps the chevron column so every time lines up.
								NavigationLink { EmptyView() } label: { row }.disabled(true)
							}
						}
						.listRowInsets(.vertical, 6)
					}
				} header: { ListHeader(cached ? "Saved stopping pattern" : "Remaining stopping pattern") } footer: {
					Text(cached
						? "Offline estimates count down the saved predictions on this device's clock. They are not observed positions; delays, reroutes and cancellations after the source time are unknown. Connections need a live feed."
						: "Arrival / departure · Eastern. Patterns reflect remaining feed predictions. Future track fields describe that stop, not the current train position. Operations IDs identify trips, not physical cars.")
				}
				if let pattern = train.scheduledPattern {
					Section {
						DisclosureGroup("Matching scheduled pattern · \(pattern.headsign)") {
							VStack(alignment: .leading, spacing: 4) {
								Text("Shape \(pattern.shape) · \(pattern.source)")
								Text(pattern.stops.joined(separator: " → "))
								Text("Static context only; live predictions take precedence.").foregroundStyle(.secondary)
							}
							.font(.caption)
						}
					}
				}
				if let shownDetail { Section { RawJSONView(value: shownDetail) } }
			} else if error == nil { ProgressView("Loading train details…") }
		}
		.themedList().navigationTitle("Train details").navigationBarTitleDisplayMode(.inline)
		.navigationDestination(item: $carTarget) { target in
			switch target {
			case .car(let id): FleetDetailView(id: id, kind: "cars")
			case .search(let number): FleetView(initialSearch: number)
			}
		}
		.refreshable {
			if !snapshotOnly { await app.refreshTrip(tripKey) }
			saved = await app.cachedTrip(tripKey)
		}
		// Registered for the view's lifetime; the prefetcher refreshes open trips on the
		// selected cadence and pauses itself offline or in the background.
		.onAppear { if !snapshotOnly, registration == nil { registration = OpenTripRegistration(app: app, tripKey: tripKey) } }
		.task(id: app.endpoint) {
			saved = await app.cachedTrip(tripKey)
			savedLoaded = true
			// Opening details is an explicit request: it joins a matching fetch and
			// returns at once without a connection.
			if !snapshotOnly { await app.refreshTrip(tripKey) }
		}
		.onChange(of: data?.train.timestamp) { Task { saved = await app.cachedTrip(tripKey) } }
		.onChange(of: app.activeRideTrip) { _, trip in if trip?.tripKey == tripKey { saved = trip } }
		.accessibilityIdentifier("trainDetails")
	}

	/// Provenance for every cached time: offline estimate, source age, and completeness.
	private var offlineSection: some View {
		Section {
			VStack(alignment: .leading, spacing: 3) {
				Label(OfflineDisplay.estimateLabel(timestamp: sourceTimestamp, now: now, preferences: app.offlinePreferences), systemImage: "icloud.slash")
					.font(.subheadline.weight(.semibold))
					.accessibilityIdentifier("offlineEstimateLabel")
				if snapshotOnly {
					Text("Saved PATH arrival · historical. PATH reports name a station arrival, not one train, so this copy is never refreshed.")
						.font(.caption.weight(.semibold)).accessibilityIdentifier("savedPathSnapshot")
				}
				if !showingSnapshot {
					Text(saved == nil ? "Last report from this visit · not saved offline" : "Last report from this visit · newer than the saved copy")
						.font(.caption).foregroundStyle(.secondary)
				} else if let saved {
					Text("Saved \(Display.ageLabel(saved.savedAt, now: now))\(saved.manuallySaved ? " · kept until you remove it" : isRide ? " · kept for your ride" : "")")
						.font(.caption).foregroundStyle(.secondary)
					if let label = OfflineDisplay.completenessLabel(saved) {
						Text(label).font(.caption.weight(.semibold)).accessibilityIdentifier("partialTripLabel")
					}
				}
				Text("Car numbers and the train's current position are not shown offline.").font(.caption2).foregroundStyle(.secondary)
			}
		}
	}

	/// "Save trip offline" and "I'm on this train" are separate: saving keeps a snapshot;
	/// a ride also keeps it current while connected and shows it on the board.
	private var rideActions: some View {
		Section {
			HStack(spacing: 8) {
				if snapshotOnly {
					// A frozen arrival can only be kept or removed.
					if isSaved {
						Button { confirmRemove = true } label: { Label("Saved offline", systemImage: "checkmark.circle.fill").chip(selected: true) }
							.buttonStyle(.plain).accessibilityIdentifier("removeSavedTrip")
							.confirmationDialog("Remove this saved arrival?", isPresented: $confirmRemove, titleVisibility: .visible) {
								Button("Remove saved arrival", role: .destructive) { Task { await app.removeSavedTrip(tripKey) } }
								Button("Cancel", role: .cancel) {}
							} message: { Text("Its offline snapshot may then expire with other cached trips.") }
					}
				} else if isSaved {
					Button { confirmRemove = true } label: { Label("Saved offline", systemImage: "checkmark.circle.fill").chip(selected: true) }
						.buttonStyle(.plain).accessibilityIdentifier("removeSavedTrip")
						.accessibilityHint("Removes this train from saved trips")
						.confirmationDialog("Remove this saved train?", isPresented: $confirmRemove, titleVisibility: .visible) {
							Button("Remove saved train", role: .destructive) { Task { await app.removeSavedTrip(tripKey) } }
							Button("Cancel", role: .cancel) {}
						} message: { Text("Its offline snapshot may then expire with other cached trips.") }
				} else {
					Button { Task { working = true; await app.saveTripOffline(tripKey, detail: data); saved = await app.cachedTrip(tripKey); working = false } } label: {
						Label("Save trip offline", systemImage: "arrow.down.circle").chip()
					}
					.buttonStyle(.plain).disabled(working).accessibilityIdentifier("saveTripOffline")
				}
				if isRide {
					Button { Task { await app.endRide() } } label: { Label("End ride", systemImage: "xmark.circle").chip(selected: true) }
						.buttonStyle(.plain).accessibilityIdentifier("endRide")
				} else if !OfflineIdentity.isPositionalTrip(tripKey) {
					Button {
						if app.activeRide != nil { confirmReplaceRide = true }
						else { Task { await startRide() } }
					} label: { Label("I'm on this train", systemImage: "tram.fill").chip() }
						.buttonStyle(.plain).disabled(working).accessibilityIdentifier("startRide")
						.confirmationDialog("Replace your current ride?", isPresented: $confirmReplaceRide, titleVisibility: .visible) {
							Button("Ride this train instead") { Task { await startRide() } }
							Button("Cancel", role: .cancel) {}
						} message: { Text("Only one ride is followed at a time. The other train stays saved only if you saved it.") }
				}
				Spacer(minLength: 0)
			}
			if OfflineIdentity.isPositionalTrip(tripKey) {
				Text("PATH reports identify a station arrival, not one train, so rides can't follow them.").font(.caption2).foregroundStyle(.secondary)
			}
			if let message = app.offlineActionError { Notice(text: message).accessibilityIdentifier("offlineActionError") }
		}
	}

	private func startRide() async {
		working = true
		await app.startRide(tripKey, detail: data)
		saved = await app.cachedTrip(tripKey)
		working = false
	}

	private func consistSection(_ consist: Consist, feed: String) -> some View {
		Section {
			if let ids = TrainFavorites.consistIDs(consist, feed: feed) { FavoriteConsistButton(ids: ids) }
			LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 6)], alignment: .leading, spacing: 6) {
				ForEach(Array(consist.cars.enumerated()), id: \.offset) { _, car in
					let id = TrainFavorites.carID(number: car.number, type: car.type, feed: feed)
					let highlighted = id.map { app.trainFavorites.match(consist, feed: feed, now: now)?.carIDs.contains($0) == true } ?? false
					HStack(spacing: 0) {
					Button { carTarget = id.map { .car($0) } ?? .search(car.number) } label: {
						VStack(spacing: 0) {
							Text(car.number).font(.subheadline.weight(.semibold).monospacedDigit())
							Text(car.type ?? "Type not reported").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
							if highlighted { Label("Favorite", systemImage: "star.fill").font(.caption2).foregroundStyle(app.theme.ink) }
						}
						.frame(maxWidth: .infinity, minHeight: 44)
						.background(highlighted ? app.theme.accent.opacity(0.16) : app.theme.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
						.contentShape(Rectangle())
					}
					.buttonStyle(.plain)
					.accessibilityLabel("Car \(car.number), \(car.type ?? "type not reported")\(highlighted ? ", favorite" : "")")
					if let id { FavoriteCarButton(id: id) }
					}
				}
			}
			.listRowInsets(.vertical, 8)
		} header: { ListHeader("Car numbers · Helium · reported \(Display.ageLabel(consist.updatedAt, now: now))") } footer: {
			Text("Tap a car for its fleet history. Reported order does not confirm the front of the train.")
		}
	}

	private func facts(_ train: Train, consist: Consist?) -> [(label: String, value: String)] {
		var facts: [(label: String, value: String)] = [
			("Operations ID", train.trainId ?? "Not reported"),
			("Assignment", train.assigned.map { $0 ? "Assigned to a train" : "Not yet assigned" } ?? "Not reported"),
			("Service date", train.serviceDate ?? "Not reported"),
			(cached ? "Last position report" : "Position report", train.position.map { "\($0.name) · \(Display.ageLabel($0.timestamp, now: now))" } ?? "Not reported")
		]
		if let position = train.vehiclePosition {
			facts.removeAll { $0.label == "Position report" || $0.label == "Last position report" }
			facts.append(("Vehicle", position.vehicleId))
			facts.append(("GPS report", Display.currentVehiclePositions([position], now: now).first.map { Display.vehiclePositionLabel($0, now: now, cached: cached) } ?? "No recent vehicle location reported"))
		} else if train.feed.hasPrefix("njt-") {
			facts.removeAll { $0.label == "Position report" || $0.label == "Last position report" }
			facts.append(("GPS report", "Not reported"))
		}
		if consist == nil { facts.append(("Car numbers", cached ? "Not shown offline" : "Not currently available")) }
		return facts
	}
}

/// Keeps a trip open in the model while its details view exists, so pushing
/// connections over it or losing the connection keeps its fetched details.
@MainActor
final class OpenTripRegistration {
	private weak var app: AppModel?
	private let tripKey: String
	init(app: AppModel, tripKey: String) {
		self.app = app
		self.tripKey = tripKey
		app.openTrip(tripKey)
	}
	isolated deinit { app?.closeTrip(tripKey) }
}

/// Offline context for one saved stop.
struct OfflineStopEstimate {
	let sourceTimestamp: TimeInterval?
	/// The first saved stop still ahead: an estimate, never the observed position.
	let estimatedNext: Bool
	/// Why saved times get no countdown, such as a train canceled when saved.
	var noEstimate: String?
}

private struct StopRow: View {
	@Environment(AppModel.self) private var app
	let stop: StopPrediction
	let now: TimeInterval
	var offline: OfflineStopEstimate?
	private var details: String {
		var parts = [stop.id]
		if let scheduled = stop.scheduledTrack { parts.append("scheduled track \(scheduled)") }
		if let actual = stop.actualTrack { parts.append("reported track \(actual)") }
		if stop.relationship == "SKIPPED" { parts.append("skipped") }
		return parts.joined(separator: " · ")
	}
	var body: some View {
		HStack(alignment: .firstTextBaseline, spacing: 8) {
			VStack(alignment: .leading, spacing: 1) {
				HStack(alignment: .firstTextBaseline, spacing: 5) {
					Text(stop.name).font(.subheadline.weight(.semibold)).strikethrough(stop.relationship == "SKIPPED")
					ChangeIcons(changes: stop.changes ?? [], now: now)
				}
				Text(details).font(.caption2).foregroundStyle(.secondary)
				if offline?.estimatedNext == true {
					Text(OfflineDisplay.estimatedNextStopLabel).font(.caption2.weight(.semibold)).accessibilityIdentifier("estimatedNextStop")
				}
			}
			Spacer(minLength: 4)
			VStack(alignment: .trailing, spacing: 1) {
				if let offline, let reason = offline.noEstimate {
					Text(Display.clockTime(stop.arrival ?? stop.departure, format: app.units.time)).font(.subheadline.monospacedDigit())
					Text(reason).font(.caption2).foregroundStyle(.secondary)
				} else if let offline {
					let countdown = OfflineDisplay.countdown(stop: stop, sourceTimestamp: offline.sourceTimestamp, now: now, cached: true, preferences: app.offlinePreferences, timeFormat: app.units.time)
					Text(countdown.unit == "min" ? "\(countdown.value) min" : countdown.value).font(.subheadline.monospacedDigit())
					Text(countdown.unit == "min" ? "offline est. \(Display.clockTime(stop.arrival ?? stop.departure, format: app.units.time))" : countdown.unit)
						.font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
				} else {
					Text(Display.clockTime(stop.arrival, format: app.units.time)).font(.subheadline.monospacedDigit())
					if let departure = stop.departure, departure != stop.arrival { Text("dep \(Display.clockTime(departure, format: app.units.time))").font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
				}
			}
		}
		.accessibilityElement(children: .combine)
	}
}

private struct ConnectionGroup: Identifiable {
	let id: String
	let route: String
	let direction: String
	let area: String
	let departures: [Departure]
}

struct TransferView: View {
	let tripKey: String
	let stop: StopPrediction
	@Environment(AppModel.self) private var app
	@Environment(\.scenePhase) private var phase
	@State private var data: TransferResult?
	@State private var error: String?
	@State private var requestGeneration = 0
	private var stale: Bool {
		guard let data else { return true }
		return !app.connected || Display.freshness(data.originTimestamp, now: app.now, staleAfter: data.originStaleAfter) != .live || data.arrival.map { $0 < app.now } == true
	}
	private var groups: [ConnectionGroup] {
		guard let data, !stale, error == nil else { return [] }
		let usable = data.connections.filter { Display.freshness($0, now: app.now) == .live && ($0.time ?? -.infinity) >= app.now }
		return Dictionary(grouping: usable) { "\(Display.routeLabel($0.route)) · \(Display.directionLabel($0.direction)) · \($0.area)" }
			.map { key, departures in
				let sorted = departures.sorted { ($0.time ?? 0) < ($1.time ?? 0) }
				return ConnectionGroup(id: key, route: sorted[0].route, direction: sorted[0].direction, area: sorted[0].area, departures: sorted)
			}
			.sorted { $0.id < $1.id }
	}
	var body: some View {
		List {
			if let error { Section { Notice(text: error) } }
			if let data {
				Section {
					VStack(alignment: .leading, spacing: 2) {
						Text("Your train: \(Display.clockTime(data.arrival, format: app.units.time)) estimated \(data.basis)\(data.basis == "departure" ? " (arrival unavailable)" : "")").font(.subheadline.weight(.semibold))
						Text("Updated \(Display.ageLabel(data.originTimestamp, now: app.now))").font(.caption).foregroundStyle(.secondary)
					}
					if stale { Notice(text: "Predictions are stale or the arrival estimate has passed. Awaiting an update.") }
					if let message = data.message { Notice(text: message) }
				} footer: { Text("Next 30 minutes · raw time gaps, no walking allowance. Boarding areas may require stairs, passageways, or different platform access. Connections are not guaranteed.") }
				ForEach(groups) { group in
					Section {
						ForEach(group.departures) { departure in
							NavigationLink { TrainDetailView(tripKey: departure.tripKey) } label: {
								HStack(alignment: .firstTextBaseline, spacing: 8) {
									VStack(alignment: .leading, spacing: 1) {
										HStack(alignment: .firstTextBaseline, spacing: 5) {
											Text(departure.destination).font(.subheadline.weight(.semibold))
											ChangeIcons(changes: departure.changes ?? [], now: app.now)
										}
										Text(departure.actualTrack.map { "Reported track \($0)" } ?? departure.scheduledTrack.map { "Scheduled track \($0)" } ?? "Track not reported")
											.font(.caption2).foregroundStyle(.secondary)
										if let gap = departure.gap {
											Text("\(gap < 60 ? "<1" : String(Int(gap / 60))) min after arrival · \(departure.basis ?? "departure")\(departure.basis == "arrival" ? " fallback" : "")")
												.font(.caption2).foregroundStyle(.secondary)
										}
									}
									Spacer(minLength: 4)
									Text(Display.clockTime(departure.time, format: app.units.time)).font(.subheadline.monospacedDigit())
								}
								.accessibilityElement(children: .combine)
							}
							.listRowInsets(.vertical, 6)
						}
					} header: {
						HStack(spacing: 6) {
							RouteBullet(route: group.route, small: true)
							Text("\(Display.directionLabel(group.direction)) · \(group.area)").font(.caption.weight(.semibold))
						}
						.textCase(nil).accessibilityElement(children: .combine)
					}
				}
				if groups.isEmpty && !stale && data.message == nil && error == nil { Text("No matching connecting departures are currently reported.").foregroundStyle(.secondary) }
				Section { SourcesView(sources: data.sources, now: app.now) } header: { ListHeader("Prediction sources") }
			} else if error == nil { ProgressView("Checking connecting departures…") }
		}.themedList().navigationTitle(stop.name).navigationBarTitleDisplayMode(.inline)
			.refreshable { await refresh() }
			.task(id: "\(phase)|\(app.endpoint)|\(app.connected)") { if phase == .active { await poll(every: 10) { await refresh() } } }
	}
	private func refresh() async {
		// Connections need live predictions; offline there is nothing honest to show.
		guard app.connected else { error = "Connections need a live feed. Reconnect for current estimates."; return }
		let requestedEndpoint = app.endpoint
		requestGeneration += 1
		let generation = requestGeneration
		do {
			let value = try await app.api.transfers(key: tripKey, stopID: stop.id, sequence: stop.sequence)
			try Task.checkCancellation()
			guard requestedEndpoint == app.endpoint, generation == requestGeneration else { return }
			data = value; error = nil
		} catch { if !Task.isCancelled, requestedEndpoint == app.endpoint, generation == requestGeneration { self.error = "Transfer predictions unavailable. Reconnect for current estimates." } }
	}
}
