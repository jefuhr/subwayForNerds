import SwiftUI
import TransitCore

/// What the board's detail column shows.
enum BoardDetail: Hashable {
	case train(String)
	case departure(String, String)
	case station
}

/// Regular widths keep the board beside train details or station info; compact widths push them.
struct BoardSplitView: View {
	@Environment(AppModel.self) private var app
	@Environment(\.horizontalSizeClass) private var sizeClass
	@State private var selection: BoardDetail?
	@State private var column = NavigationSplitViewColumn.sidebar
	var body: some View {
		NavigationSplitView(preferredCompactColumn: $column) {
			BoardView(selection: $selection) { detail in
				selection = detail
				column = .detail
			}
			.toolbar(removing: .sidebarToggle)
			.navigationSplitViewColumnWidth(400)
		} detail: {
			NavigationStack {
				if let selection { BoardDetailView(detail: selection) }
				// Side by side, station info fills the detail column until a train is chosen.
				else if let station = app.station, sizeClass == .regular { ContextView(station: station) }
			}
			.id(selection)
		}
		.navigationSplitViewStyle(.balanced)
		.background(app.theme.background)
		// A ride link opens its trip without changing the selected station.
		.task(id: app.openTripKey) {
			guard let key = app.openTripKey else { return }
			selection = .train(key)
			column = .detail
			app.openTripKey = nil
		}
	}
}

struct BoardDetailView: View {
	@Environment(AppModel.self) private var app
	let detail: BoardDetail
	var body: some View {
		switch detail {
		case .train(let key): TrainDetailView(tripKey: key)
		case .departure(let key, let row): TrainDetailView(tripKey: key, origin: app.departureOrigin(row))
		case .station: if let station = app.station { ContextView(station: station) }
		}
	}
}

/// The normal board pushed over a transfer. It uses the one app model, so the board
/// stays on this station; Back, the edge swipe, or popping returns to the transfer.
struct StationBoardScreen: View {
	@State private var shown: BoardDetail?
	var body: some View {
		BoardView(selection: .constant(nil)) { shown = $0 }
			.navigationDestination(for: BoardDetail.self) { BoardDetailView(detail: $0) }
			.navigationDestination(item: $shown) { BoardDetailView(detail: $0) }
			.accessibilityIdentifier("stationBoardScreen")
	}
}

struct BoardView: View {
	@Environment(AppModel.self) private var app
	@Binding var selection: BoardDetail?
	/// Shows a detail that has no row of its own, such as station info.
	let show: (BoardDetail) -> Void
	@State private var stationPicker: StationPickerMode?
	@State private var showAlerts = false
	@State private var showLines = false
	private var groups: [DepartureGroup] {
		guard let board = app.displayBoard else { return [] }
		return groupDepartures(board, direction: app.preference.direction, routes: app.preference.routes, order: app.preference.view, now: app.now, cached: app.boardIsCached, cachedDepartureKeys: app.cachedDepartureKeys)
	}
	private var trainSources: [SourceState] { app.board?.sources.filter { !["subway-alerts", "helium"].contains($0.id) } ?? [] }
	private var degraded: Bool { app.combinedBoard?.members.contains { $0.cached || $0.board == nil || $0.error != nil } == true || trainSources.contains { Display.freshness($0, now: app.now) != .live || $0.error != nil } }
	private var externalDepartures: Bool { app.board?.usesExternalDepartures ?? app.station.map { $0.departureMode == "external" || $0.isNjt } ?? false }
	private var configuredNJT: Bool { app.board?.njt?.configured == true }

	var body: some View {
		List(selection: $selection) {
			Section {
				stationHeading
					.listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 2, trailing: 8))
			}
			if let error = app.settingsError {
				Section { Notice(text: error).accessibilityIdentifier("boardSettingsError") }
			}
			if app.activeRide != nil {
				Section { ActiveRideBanner { show(.train($0)) } }
			}
			if !app.offlineFailures.isEmpty {
				Section {
					HStack(alignment: .firstTextBaseline) {
						Notice(text: "Offline save failed: " + (app.offlineFailures.last?.message ?? "storage unavailable") + (app.offlineFailures.count > 1 ? " (+\(app.offlineFailures.count - 1) more)" : "") + ". Saved data from before is unchanged.")
						Spacer(minLength: 4)
						Button("Dismiss") { Task { await app.dismissOfflineFailures() } }.buttonStyle(.borderless).actionStyle().font(.footnote)
					}
					.accessibilityIdentifier("offlineSaveFailure")
				}
			}
			if let station = app.station, !station.routes.isEmpty, LineVisibility.routes(station.routes, hiddenRoutes: app.hiddenRoutes).isEmpty {
				Section {
					Text("All lines at this station are hidden.")
					Button("Manage lines") { showLines = true }.actionStyle().accessibilityIdentifier("manageLines")
				}
			} else if externalDepartures, let station = app.station {
				NjtDeparturesSection(station: station)
			} else {
				if let error = app.boardError {
					Section {
						Notice(text: error).accessibilityIdentifier("boardError")
						if app.board == nil, !app.connected { deviceNetworkRows }
					}
				}
				else if degraded, !app.boardIsCached { Section { Notice(text: "Some feeds are stale or unavailable. Check source ages below.") } }
				if app.board != nil, app.boardIsCached { Section { offlineStatus } }
				Section {
					VStack(alignment: .leading, spacing: 0) {
						BoardFilterControls(station: app.station, routes: routeChoices, direction: app.preference.direction, selectedRoutes: app.preference.routes,
							setDirection: app.setDirection, toggleRoute: app.toggleRoute, clearRoutes: app.clearRoutes)
						boardViewChips
					}
					.listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 8))
				}
				if app.board == nil {
					Section {
						if app.boardError == nil {
							LoadingBar(title: "Loading departures", progress: app.boardLoad).accessibilityIdentifier("boardLoading")
							if !app.connected { deviceNetworkRows }
						}
						Button("Find a station") { stationPicker = .search }.actionStyle()
					}
				} else if groups.isEmpty {
					Section {
						ContentUnavailableView(configuredNJT && app.board?.departures.isEmpty == true ? "No arrival predictions" : "No departures match", systemImage: "tram", description: app.board.flatMap { Display.njtPredictionMessage($0, now: app.now, cached: app.boardIsCached) }.map { Text($0) })
							.accessibilityIdentifier("boardNoPredictions")
						Button("Reset filters") { app.resetFilters() }.actionStyle()
						if !app.hiddenRoutes.isEmpty {
							Button("Manage lines") { showLines = true }.actionStyle().accessibilityIdentifier("manageLines")
						}
					}
				}
				ForEach(groups) { group in
					PlatformSection(group: group, station: app.station, order: app.preference.view, now: app.now, cached: app.boardIsCached)
				}
				if configuredNJT, let board = app.displayBoard {
					NjtPositionsSection(board: board, now: app.now, cached: app.boardIsCached)
					NjtDeparturesSection(station: board.station, configured: true)
					if let error = board.njt?.cacheError { Section { Notice(text: "NJ Transit cache: " + error) } }
				}
				if let board = app.board {
					Section {
						SourcesView(sources: board.sources, now: app.now)
					} header: { ListHeader("Feed check") }
				}
			}
		}
		.themedList()
		.tint(app.theme.selection)
		.navigationTitle("Board")
		.navigationBarTitleDisplayMode(.inline)
		.toolbar {
			ToolbarItem(placement: .topBarLeading) {
				Button { stationPicker = .search } label: { Label("Find a station", systemImage: "magnifyingglass") }
					.keyboardShortcut("f", modifiers: .command)
					.accessibilityIdentifier("findStation")
			}
			ToolbarItem(placement: .topBarLeading) {
				Button { stationPicker = .nearby } label: { Label("Stations near me", systemImage: "location") }
					.accessibilityIdentifier("nearbyFromBoard")
			}
			ToolbarItem(placement: .topBarTrailing) {
				Button { Task { await app.refreshBoard() } } label: { Label("Refresh departures", systemImage: "arrow.clockwise") }
					.keyboardShortcut("r", modifiers: .command)
					.accessibilityIdentifier("refreshBoard")
			}
		}
		.refreshable { await app.refreshBoard() }
		.task(id: app.stationID) { await app.refreshBoard() }
		.sheet(item: $stationPicker) { mode in NavigationStack { StationPickerView(mode: mode) } }
		.sheet(isPresented: $showAlerts) { NavigationStack { AlertsView(alerts: app.displayBoard?.alerts ?? [], sources: app.board?.sources ?? [], cached: app.boardIsCached) } }
		.sheet(isPresented: $showLines) { NavigationStack { LineVisibilityView().toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showLines = false } } } } }
	}

	/// The station name opens the picker; station info, alerts and the favorite star are icons beside it.
	private var stationHeading: some View {
		HStack(alignment: .center, spacing: 0) {
			Button { stationPicker = .search } label: {
				// Inline so the chevron follows the last line of a wrapped name.
				Text("\(app.station?.name ?? "Your next train") \(Text(Image(systemName: "chevron.down")).font(.caption.bold()).foregroundStyle(.secondary))")
					.font(.headline).multilineTextAlignment(.leading)
					.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
			}.buttonStyle(.plain).accessibilityIdentifier("selectedStation")
			if app.station != nil {
				Button { show(.station) } label: { headingIcon("info.circle") }
					.buttonStyle(.borderless)
					.accessibilityLabel("Station info")
					.accessibilityIdentifier("stationInfo")
			}
			alertsButton
			Button { app.toggleFavorite(app.stationID) } label: { headingIcon(app.favorites.contains(app.stationID) ? "star.fill" : "star") }
				.buttonStyle(.borderless)
				.accessibilityLabel(app.favorites.contains(app.stationID) ? "Remove favorite station" : "Favorite this station")
				.accessibilityIdentifier("toggleFavorite")
		}
	}

	private func headingIcon(_ systemImage: String) -> some View {
		Image(systemName: systemImage).font(.body).frame(width: 44, height: 44).contentShape(Rectangle())
	}

	/// Alerts open the sheet; NJ Transit stations have no alerts feed here, so the icon links out instead.
	@ViewBuilder private var alertsButton: some View {
		if externalDepartures {
			Link(destination: TransitLinks.njtAlerts) { headingIcon("exclamationmark.triangle") }
				.buttonStyle(.borderless)
				.accessibilityLabel("NJ Transit alerts")
				.accessibilityIdentifier("stationAlerts")
		} else {
			let count = app.displayBoard?.alerts.count ?? 0
			Button { showAlerts = true } label: {
				headingIcon("exclamationmark.triangle")
					.foregroundStyle(count > 0 ? Color.orange : app.theme.ink)
					.overlay(alignment: .topTrailing) {
						if count > 0 {
							Text(count > 99 ? "99+" : "\(count)")
								.font(.caption2.bold()).foregroundStyle(.black)
								.padding(.horizontal, 4)
								.background(Color.orange, in: Capsule())
								.offset(x: -2, y: 4)
								.accessibilityHidden(true)
						}
					}
			}
			.buttonStyle(.borderless)
			.accessibilityLabel("Alerts, \(count)")
			.accessibilityIdentifier("stationAlerts")
		}
	}

	/// A saved board says it is an offline estimate and how old its source is; the card opens System status.
	private var offlineStatus: some View {
		// The oldest prediction, not the newest alerts or car-assignment report.
		let source = app.board.flatMap(AppModel.predictionSourceTimestamp)
		return Button { app.openSystemStatus() } label: {
			VStack(alignment: .leading, spacing: 2) {
				Label(OfflineDisplay.estimateLabel(timestamp: source, now: app.now, preferences: app.offlinePreferences), systemImage: "icloud.slash")
					.font(.caption.weight(.semibold))
					.accessibilityIdentifier("boardOfflineEstimate")
				DeviceNetworkLabel()
			}
			.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.accessibilityHint("Opens System status")
	}

	/// What the phone is doing and what the app waits to fetch, when there is no board to show.
	private var deviceNetworkRows: some View {
		VStack(alignment: .leading, spacing: 2) {
			DeviceNetworkLabel()
			Text(app.networkActivity)
				.font(.caption2).foregroundStyle(.secondary)
				.accessibilityIdentifier("deviceNetworkDetail")
		}
	}

	private var routeChoices: [String] {
		LineVisibility.routes(Array(Set(((app.station?.routes ?? []) + (app.board?.departures.map(\.route) ?? [])).map(Display.displayRoute))).sorted(), hiddenRoutes: app.hiddenRoutes)
	}

	private var boardViewChips: some View {
		ScrollView(.horizontal) {
			HStack(spacing: 6) {
				ForEach(BoardSortOrder.allCases) { order in
					let selected = app.preference.view == order
					Button { app.setBoardView(order) } label: { Text(order.title).chip(selected: selected) }
						.buttonStyle(.plain)
						.accessibilityLabel(order.label)
						.accessibilityIdentifier("boardView_\(order.rawValue)")
						.accessibilityAddTraits(selected ? .isSelected : [])
				}
			}
		}
		.scrollIndicators(.hidden)
		.accessibilityIdentifier("boardViews")
	}
}

/// Direction and multi-line filters shared by the board and transfers. Callers own
/// the values, so transfers can edit their own station rather than the board's.
struct BoardFilterControls: View {
	@Environment(AppModel.self) private var app
	let station: Station?
	let routes: [String]
	let direction: String
	let selectedRoutes: [String]
	let setDirection: (String) -> Void
	let toggleRoute: (String) -> Void
	let clearRoutes: () -> Void
	/// Prefixes accessibility identifiers so transfer controls stay distinct from the board's.
	var identifierPrefix = ""
	var body: some View {
		HStack(spacing: 0) {
			directionFilters
			Divider().frame(height: 24).padding(.horizontal, 6)
			routeFilters
		}
	}

	private func identifier(_ name: String) -> String { identifierPrefix.isEmpty ? name : identifierPrefix + name.prefix(1).uppercased() + name.dropFirst() }

	private var directionFilters: some View {
		let mixed = station?.isCombined == true && station?.routes.contains { $0.hasPrefix("PATH-") } == true && station?.routes.contains { !$0.hasPrefix("PATH-") } == true
		let regional = station?.routes.contains { $0.hasPrefix("PATH-") } == true
		let options = mixed ? [DirectionOption(id: "ALL", name: "All directions", icon: "arrow.left.arrow.right"), DirectionOption(id: "NORTH", name: "Northbound", icon: "arrow.up"), DirectionOption(id: "SOUTH", name: "Southbound", icon: "arrow.down"), DirectionOption(id: "TO_NY", name: "To New York", text: "NY"), DirectionOption(id: "TO_NJ", name: "To New Jersey", text: "NJ")] : regional
			? [DirectionOption(id: "ALL", name: "All directions", icon: "arrow.left.arrow.right"), DirectionOption(id: "TO_NY", name: "To New York", text: "NY"), DirectionOption(id: "TO_NJ", name: "To New Jersey", text: "NJ")]
			: [DirectionOption(id: "ALL", name: "All directions", icon: "arrow.up.arrow.down"), DirectionOption(id: "NORTH", name: "Northbound", icon: "arrow.up"), DirectionOption(id: "SOUTH", name: "Southbound", icon: "arrow.down")]
		return HStack(spacing: 6) {
			ForEach(options) { option in
				let selected = direction == option.id
				Button { setDirection(option.id) } label: {
					Group {
						if let icon = option.icon { Image(systemName: icon) } else { Text(option.text ?? "") }
					}
					.chip(selected: selected)
				}
				.buttonStyle(.plain)
				.accessibilityLabel(option.name)
				.accessibilityIdentifier(identifier("direction_\(option.id)"))
				.accessibilityAddTraits(selected ? .isSelected : [])
			}
		}
		.accessibilityElement(children: .contain)
		.accessibilityIdentifier(identifier("directionFilter"))
	}

	private var routeFilters: some View {
		ScrollView(.horizontal) {
			HStack(spacing: 0) {
				Button { clearRoutes() } label: { Text("All").chip(selected: selectedRoutes.isEmpty) }
					.padding(.trailing, 2)
					.buttonStyle(.plain)
					.accessibilityLabel("All lines")
					.accessibilityIdentifier(identifier("allLines"))
					.accessibilityAddTraits(selectedRoutes.isEmpty ? .isSelected : [])
				ForEach(routes, id: \.self) { route in
					let on = selectedRoutes.contains(route)
					Button { toggleRoute(route) } label: {
						RouteBullet(route: route, small: true)
							.padding(3)
							.overlay { Capsule().strokeBorder(app.theme.accent, lineWidth: 2).opacity(on ? 1 : 0) }
							.opacity(selectedRoutes.isEmpty || on ? 1 : 0.4)
							.frame(minWidth: 44, minHeight: 44)
							.contentShape(Rectangle())
					}
					.buttonStyle(.plain).accessibilityLabel("Filter line \(Display.routeLabel(route))")
					.accessibilityIdentifier(identifier("routeFilter_\(route)"))
					.accessibilityAddTraits(on ? .isSelected : [])
				}
			}
		}
		.scrollIndicators(.hidden)
	}
}

private struct DirectionOption: Identifiable {
	let id: String
	let name: String
	var icon: String?
	var text: String?
}

private struct PlatformSection: View {
	@Environment(AppModel.self) private var app
	let group: DepartureGroup
	let station: Station?
	let order: BoardSortOrder
	let now: TimeInterval
	let cached: Bool
	@State private var expanded = false
	private var part: StationPart? { station?.parts.first { $0.id == group.partId } }
	private var heading: String {
		if order == .service { return "Service \(Display.routeLabel(group.service ?? group.label))" }
		guard order == .track else { return Display.directionLabel(group.direction) }
		return group.direction == "NORTH" ? part?.north ?? "Northbound" : group.direction == "SOUTH" ? part?.south ?? "Southbound" : Display.directionLabel(group.direction)
	}
	private var subtitle: String {
		switch order {
		case .track: "\(part?.line ?? group.partId) · \(Display.trackGroupLabel(track: group.track, reported: group.reportedTrack, showProvenance: app.departureRows.showTrackProvenance))"
		case .direction: "All platforms"
		case .service: Display.directionLabel(group.direction)
		case .family, .corridor: group.label
		}
	}
	private var arrow: String {
		switch group.direction {
		case "NORTH": "arrow.up"
		case "SOUTH": "arrow.down"
		case "TO_NY": "arrow.right"
		case "TO_NJ": "arrow.left"
		default: "arrow.up.arrow.down"
		}
	}
	var body: some View {
		Section {
			ForEach(Array((expanded ? group.departures : Array(group.departures.prefix(5))).enumerated()), id: \.element.key) { index, departure in
				NavigationLink(value: BoardDetail.departure(departure.tripKey, departure.key)) {
					VStack(alignment: .leading, spacing: 3) {
						if station?.isCombined == true, let origin = app.departureOrigin(departure.key) {
							Text("Board at \(origin.station.name)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
						}
					DepartureRow(departure: departure, now: now, cached: app.departureIsCached(departure.key),
						previous: group.departures.prefix(index).last { candidate in
							Display.boardable(candidate) && candidate.direction == departure.direction && candidate.partId == departure.partId &&
							(candidate.actualTrack ?? candidate.scheduledTrack) == (departure.actualTrack ?? departure.scheduledTrack)
						}, showPlatform: order != .track)
					}
				}.accessibilityIdentifier("departure_\(departure.key)")
					.listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 14))
			}
			if group.departures.count > 5 {
				Button { expanded.toggle() } label: {
					HStack(spacing: 4) {
						Text(expanded ? "Show fewer trains" : "Show \(group.departures.count - 5) more trains")
						Image(systemName: expanded ? "chevron.up" : "chevron.down").imageScale(.small)
					}
					.font(.caption.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
				}
				.buttonStyle(.borderless).actionStyle()
				.listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 14))
			}
		} header: {
			HStack(alignment: .firstTextBaseline, spacing: 5) {
				Image(systemName: arrow).foregroundStyle(app.theme.accent).accessibilityHidden(true)
				Text("\(Text(heading).fontWeight(.semibold)) · \(subtitle)")
			}
			.font(.caption).textCase(nil).accessibilityElement(children: .combine).accessibilityIdentifier("departureGroup_\(group.id)")
		}
	}
}

private struct NjtDeparturesSection: View {
	let station: Station
	var configured = false
	var body: some View {
		Section {
			VStack(alignment: .leading, spacing: 3) {
				Text(station.routes.first.flatMap(Display.regionalRoute)?.name ?? "NJ Transit light rail").font(.headline)
				if let part = station.parts.first { Text("\(station.municipality.map { "\($0) · " } ?? "")NJ Transit station \(part.stationId)").font(.subheadline) }
				if !configured { Text("Live light rail departures are not connected in this app. Check NJ Transit for upcoming trains, schedules, and service changes.").font(.footnote).foregroundStyle(.secondary) }
			}
			Link("NJ Transit departures", destination: TransitLinks.njtDepartures).actionStyle().accessibilityIdentifier("njtDepartures")
			Link("Light rail schedules", destination: TransitLinks.njtSchedules).actionStyle()
			Link("Service alerts", destination: TransitLinks.njtAlerts).actionStyle()
		} header: { ListHeader("Official departure tools") }
	}
}

private struct NjtPositionsSection: View {
	let board: Board
	let now: TimeInterval
	let cached: Bool
	private var positions: [VehiclePosition] { Display.currentVehiclePositions(board.vehiclePositions ?? [], now: now) }
	var body: some View {
		Section {
			if positions.isEmpty { Text("No recent vehicle locations are reported.").font(.footnote).foregroundStyle(.secondary) }
			ForEach(positions) { position in
				HStack(alignment: .top, spacing: 8) {
					RouteBullet(route: position.route, small: true)
					VStack(alignment: .leading, spacing: 2) {
						Text("Vehicle \(position.vehicleId)").font(.subheadline.weight(.semibold))
						Text(Display.vehiclePositionLabel(position, now: now, cached: cached)).font(.caption).foregroundStyle(.secondary)
					}
				}.accessibilityElement(children: .combine).accessibilityIdentifier("njtPosition_" + position.id)
			}
		} header: { ListHeader("Reported vehicle locations") } footer: { Text("Locations over five minutes old are hidden.") }
	}
}

struct DepartureRow: View {
	@Environment(AppModel.self) private var app
	let departure: Departure
	let now: TimeInterval
	var cached = false
	var previous: Departure?
	var showPlatform = false
	/// Cached rows count down the saved prediction on the device clock and say so.
	private var countdown: Countdown {
		// An unassigned train has no saved prediction to count down from.
		if cached, departure.assigned == false, Display.boardable(departure) { return Countdown(value: Display.clockTime(departure.time, format: app.units.time), unit: "not assigned") }
		return OfflineDisplay.countdown(departure: departure, now: now, cached: cached, preferences: app.offlinePreferences, timeFormat: app.units.time)
	}
	private var historical: Bool { cached || Display.freshness(departure, now: now) != .live || departure.locationTimestamp.map { now - $0 > 90 } == true }
	/// Only live boards say the train is in a zone; an older position report keeps it.
	private var slowZone: SlowZone? { cached ? nil : departure.slowZone }
	private var favoriteMatch: TrainFavoriteMatch? { app.trainFavorites.match(departure.consist, feed: departure.feed, now: now, cached: cached) }
	private var gap: Int? {
		guard !cached, Display.boardable(departure), let previous, Display.freshness(previous, now: now) == .live,
			  Display.freshness(departure, now: now) == .live, let before = previous.time, let after = departure.time else { return nil }
		return Int(((after - before) / 60).rounded())
	}
	private var positionDetail: String { Display.stopDetail(stopsAway: departure.stopsAway, reportedAt: departure.locationTimestamp, now: now) }
	private var rows: DepartureRowSettings { app.departureRows }
	/// GPS vehicle rows and NJ Transit rows keep their own position rendering and the gap beside it.
	private var combinesPosition: Bool { rows.combinePosition && departure.vehiclePosition == nil && !departure.feed.hasPrefix("njt-") }
	var body: some View {
		HStack(alignment: .top, spacing: 8) {
			RouteBullet(route: departure.route, small: true)
			VStack(alignment: .leading, spacing: 2) {
				HStack(alignment: .top, spacing: 6) {
					VStack(alignment: .leading, spacing: 1) {
						Text(departure.destination).font(.subheadline.weight(.semibold))
							.strikethrough(!Display.boardable(departure))
						HStack(alignment: .firstTextBaseline, spacing: 5) {
							Text(departure.pattern + (departure.patternSource == "inferred" ? " · est." : "")).foregroundStyle(.secondary)
								.fixedSize(horizontal: false, vertical: true)
							ChangeIcons(changes: departure.changes ?? [], alerts: departure.alerts, now: now, cached: cached)
						}
						.font(.caption2)
					}
					Spacer(minLength: 4)
					countdownColumn
				}
				if showPlatform {
					Text(Display.boardingLabel(departure, showProvenance: rows.showTrackProvenance))
						.font(.caption2).foregroundStyle(.secondary).accessibilityIdentifier("boardingPlatform_\(departure.key)")
				}
				if combinesPosition {
					combinedPosition
				} else {
					splitPosition
				}
				if rows.showConsist, !cached, Display.currentConsist(departure.consist, now: now), let consist = departure.consist {
					Text("\(Array(Set(consist.cars.compactMap(\.type))).sorted().joined(separator: " / ")) · \(Display.consistSummary(consist.cars))\(Display.freshness(consist.updatedAt, now: now) == .live ? "" : " · last reported")")
						.font(.caption2).foregroundStyle(.secondary).lineLimit(1)
				}
				if let match = favoriteMatch {
					Label(match.exactConsist ? "Favorite consist" : "Favorite cars: " + match.carIDs.map(TrainFavorites.label).joined(separator: ", "), systemImage: "star.fill")
						.font(.caption2.weight(.semibold)).foregroundStyle(app.theme.ink).fixedSize(horizontal: false, vertical: true)
				}
				if departure.assigned == false { Text("Not yet assigned").font(.caption2.weight(.semibold)) }
				if !Display.boardable(departure) { Text(departure.relationship?.lowercased() ?? "Not boarding").font(.caption.bold()) }
			}
		}
		.padding(.vertical, favoriteMatch == nil ? 0 : 2).padding(.horizontal, favoriteMatch == nil ? 0 : 4)
		.background(favoriteMatch == nil ? Color.clear : app.theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
		.accessibilityElement(children: .combine)
	}

	/// Location, stops away, and age as one wrapping line, with the slow-zone tag after it.
	@ViewBuilder private var combinedPosition: some View {
		let line = Display.positionLine(location: departure.location, historical: historical, stopsAway: departure.stopsAway, reportedAt: departure.locationTimestamp, now: now)
		HStack(alignment: .firstTextBaseline, spacing: 6) {
			if line.location.isEmpty {
				Text(line.detail).font(.caption2).foregroundStyle(.secondary)
			} else if line.detail.isEmpty {
				Text(line.location).font(.caption)
			} else {
				Text(line.location).font(.caption) + Text(" · " + line.detail).font(.caption2).foregroundStyle(.secondary)
			}
			if let slowZone { SlowZoneTag(zone: slowZone) }
		}
		.accessibilityIdentifier("positionLine_\(departure.key)")
	}

	/// Today's layout: the location on one line, stops and age on the next, and the gap beside them.
	@ViewBuilder private var splitPosition: some View {
		if let position = departure.vehiclePosition {
			if let current = Display.currentVehiclePositions([position], now: now).first {
				Text(Display.vehiclePositionLabel(current, now: now, cached: cached)).font(.caption)
			}
		} else if !departure.feed.hasPrefix("njt-"), !departure.location.isEmpty || slowZone != nil {
			HStack(alignment: .firstTextBaseline, spacing: 6) {
				if !departure.location.isEmpty { Text((historical ? "Last report: " : "") + departure.location) }
				if let slowZone { SlowZoneTag(zone: slowZone) }
			}
			.font(.caption)
		}
		HStack(alignment: .firstTextBaseline) {
			if !departure.feed.hasPrefix("njt-") { Text(positionDetail) }
			Spacer(minLength: 4)
			if rows.showHeadway, let gap, gap > 0 { Text(Display.splitHeadwayLabel(gap)) }
		}
		.font(.caption2).foregroundStyle(.secondary)
	}

	private var countdownColumn: some View {
		VStack(alignment: .trailing, spacing: 0) {
			if Display.boardable(departure) {
				HStack(alignment: .firstTextBaseline, spacing: 2) {
					Text(countdown.value).font(.title2.weight(.bold).monospacedDigit())
					if countdown.unit == "min" { Text("min").font(.caption2.weight(.semibold)) }
				}
				Text(countdown.unit == "min" ? (cached ? "offline est. " : "") + Display.clockTime(departure.time, format: app.units.time) : countdown.unit)
					.font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
				if combinesPosition, rows.showHeadway, let gap, gap > 0 {
					Text(Display.headwayLabel(gap)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
						.accessibilityLabel(Display.headwayAccessibilityLabel(gap))
				}
			} else {
				Text("—").font(.title2.weight(.bold))
				Text("not boarding").font(.caption2).foregroundStyle(.secondary)
			}
		}
	}
}

/// The extra time a train in an estimated slow zone typically loses, beside its location.
private struct SlowZoneTag: View {
	let zone: SlowZone
	var body: some View {
		HStack(spacing: 2) {
			SlowZoneIcon(disruption: SlowZoneDisplay.isDisruption(zone))
			Text(SlowZoneDisplay.boardTag(zone)).monospacedDigit()
		}
		.font(.caption2.weight(.semibold))
		.padding(.horizontal, 4)
		.background((SlowZoneDisplay.isDisruption(zone) ? Color.unplanned : .orange).opacity(0.16), in: Capsule())
		.fixedSize()
		.accessibilityElement(children: .ignore)
		.accessibilityLabel(SlowZoneDisplay.accessibilityLabel(zone))
	}
}
