import SwiftUI
import TransitCore

private enum CarTarget: Hashable {
	case car(String)
	case search(String)
}

struct TrainDetailView: View {
	let tripKey: String
	@Environment(AppModel.self) private var app
	@Environment(\.scenePhase) private var phase
	@State private var data: TripDetail?
	@State private var error: String?
	@State private var requestGeneration = 0
	@State private var carTarget: CarTarget?
	private var now: TimeInterval { app.now }

	var body: some View {
		List {
			if let error { Section { Notice(text: error) } }
			if let train = data?.train {
				let consist = app.connected && error == nil && Display.currentConsist(train.consist, now: now) ? train.consist : nil
				Section {
					VStack(alignment: .leading, spacing: 12) {
						HStack(alignment: .center, spacing: 10) {
							RouteBullet(route: train.route)
							VStack(alignment: .leading, spacing: 1) {
								Text(train.destination).font(.title3.bold())
								Text(Display.directionLabel(train.direction)).font(.caption).foregroundStyle(.secondary)
							}
							Spacer(minLength: 4)
							Text("\(Display.freshness(train.timestamp, now: now).rawValue) · \(Display.ageLabel(train.timestamp, now: now))")
								.font(.caption.weight(.semibold).monospacedDigit())
								.foregroundStyle(Display.freshness(train.timestamp, now: now) == .live ? app.theme.accent : app.theme.ink.opacity(0.7))
								.accessibilityLabel("Feed \(Display.freshness(train.timestamp, now: now).rawValue), \(Display.ageLabel(train.timestamp, now: now))")
						}
						FactGrid(facts: facts(train, consist: consist))
					}
					.listRowInsets(.vertical, 12)
				}
				if let consist { consistSection(consist, feed: train.feed) }
				if !train.alerts.isEmpty {
					Section { ForEach(Array(train.alerts.enumerated()), id: \.offset) { _, alert in Notice(text: alert) } } header: { ListHeader("Alerts") }
				}
				ChangesSection(changes: Display.changesAhead(train.changes, index: 0), now: now, cached: error != nil || !app.connected)
				Section {
					ForEach(Array(train.stops.enumerated()), id: \.offset) { _, stop in
						Group {
							if stop.relationship != "SKIPPED", stop.stationId != nil, (stop.arrival ?? stop.departure ?? .infinity) >= now {
								NavigationLink { TransferView(tripKey: tripKey, stop: stop) } label: { StopRow(stop: stop, now: now) }
									.accessibilityLabel("Connections at \(stop.name)")
							} else {
								// A disabled link keeps the chevron column so every time lines up.
								NavigationLink { EmptyView() } label: { StopRow(stop: stop, now: now) }.disabled(true)
							}
						}
						.listRowInsets(.vertical, 6)
					}
				} header: { ListHeader("Remaining stopping pattern") } footer: {
					Text("Arrival / departure · Eastern. Patterns reflect remaining feed predictions. Future track fields describe that stop, not the current train position. Operations IDs identify trips, not physical cars.")
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
				if let data { Section { RawJSONView(value: data) } }
			} else if error == nil { ProgressView("Loading train details…") }
		}
		.themedList().navigationTitle("Train details").navigationBarTitleDisplayMode(.inline)
		.navigationDestination(item: $carTarget) { target in
			switch target {
			case .car(let id): FleetDetailView(id: id, kind: "cars")
			case .search(let number): FleetView(initialSearch: number)
			}
		}
		.refreshable { await refresh() }
		.task(id: "\(phase)|\(app.endpoint)|\(app.connected)") { if phase == .active { await poll(every: 10) { await refresh() } } }
		.accessibilityIdentifier("trainDetails")
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
			("Position report", train.position.map { "\($0.name) · \(Display.ageLabel($0.timestamp, now: now))" } ?? "Not reported")
		]
		if consist == nil { facts.append(("Car numbers", "Not currently available")) }
		return facts
	}

	private func refresh() async {
		let requestedEndpoint = app.endpoint
		requestGeneration += 1
		let generation = requestGeneration
		do {
			let value = try await app.api.trip(key: tripKey)
			try Task.checkCancellation()
			guard requestedEndpoint == app.endpoint, generation == requestGeneration else { return }
			data = value
			error = nil
		} catch {
			if !Task.isCancelled, requestedEndpoint == app.endpoint, generation == requestGeneration { self.error = data == nil ? error.localizedDescription : "Train update unavailable. Previous reports may be stale." }
		}
	}
}

private struct StopRow: View {
	let stop: StopPrediction
	let now: TimeInterval
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
			}
			Spacer(minLength: 4)
			VStack(alignment: .trailing, spacing: 1) {
				Text(Display.clockTime(stop.arrival)).font(.subheadline.monospacedDigit())
				if let departure = stop.departure, departure != stop.arrival { Text("dep \(Display.clockTime(departure))").font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
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
		return !app.connected || Display.freshness(data.originTimestamp, now: app.now) != .live || data.arrival.map { $0 < app.now } == true
	}
	private var groups: [ConnectionGroup] {
		guard let data, !stale, error == nil else { return [] }
		let usable = data.connections.filter { Display.freshness($0.timestamp, now: app.now) == .live && ($0.time ?? -.infinity) >= app.now }
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
						Text("Your train: \(Display.clockTime(data.arrival)) estimated \(data.basis)\(data.basis == "departure" ? " (arrival unavailable)" : "")").font(.subheadline.weight(.semibold))
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
									Text(Display.clockTime(departure.time)).font(.subheadline.monospacedDigit())
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
