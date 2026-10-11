import SwiftUI
import TransitCore

/// What the board's detail column shows.
enum BoardDetail: Hashable {
	case train(String)
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
				switch selection {
				case .train(let key): TrainDetailView(tripKey: key)
				// Side by side, station info fills the detail column until a train is chosen.
				case .station, nil:
					if let station = app.station, selection != nil || sizeClass == .regular { ContextView(station: station) }
				}
			}
			.id(selection)
		}
		.navigationSplitViewStyle(.balanced)
		.background(app.theme.background)
	}
}

struct BoardView: View {
	@Environment(AppModel.self) private var app
	@Binding var selection: BoardDetail?
	/// Shows a detail that has no row of its own, such as station info.
	let show: (BoardDetail) -> Void
	@State private var stationPicker: StationPickerMode?
	@State private var showAlerts = false
	private var groups: [DepartureGroup] {
		guard let board = app.board else { return [] }
		return groupDepartures(board, direction: app.preference.direction, routes: app.preference.routes, order: app.preference.view, now: app.now, cached: app.boardIsCached)
	}
	private var trainSources: [SourceState] { app.board?.sources.filter { !["subway-alerts", "helium"].contains($0.id) } ?? [] }
	private var live: Bool { !app.boardIsCached && trainSources.contains { Display.freshness($0.timestamp, now: app.now) == .live } }
	private var degraded: Bool { trainSources.contains { Display.freshness($0.timestamp, now: app.now) != .live || $0.error != nil } }
	private var externalDepartures: Bool { app.station?.departureMode == "external" }

	var body: some View {
		List(selection: $selection) {
			Section {
				stationHeading
					.listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 2, trailing: 8))
			}
			if let error = app.settingsError {
				Section { Notice(text: error).accessibilityIdentifier("boardSettingsError") }
			}
			if externalDepartures, let station = app.station {
				NjtDeparturesSection(station: station)
			} else {
				if let error = app.boardError { Section { Notice(text: error) } }
				else if degraded { Section { Notice(text: "Some feeds are stale or unavailable. Check source ages below.") } }
				Section {
					VStack(alignment: .leading, spacing: 0) {
						HStack(spacing: 0) {
							directionFilters
							Divider().frame(height: 24).padding(.horizontal, 6)
							routeFilters
						}
						boardViewChips
					}
					.listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 8))
				}
				if app.board == nil {
					Section {
						if app.boardError == nil { ProgressView("Connecting to your station…") }
						Button("Find a station") { stationPicker = .search }.actionStyle()
					}
				} else if groups.isEmpty {
					Section {
						ContentUnavailableView("No departures match", systemImage: "tram", description: Text("An empty board does not mean service is suspended. Try all directions and lines, or refresh the feed."))
						Button("Reset filters") { app.resetFilters() }.actionStyle()
					}
				}
				ForEach(groups) { group in
					PlatformSection(group: group, station: app.station, order: app.preference.view, now: app.now, cached: app.boardIsCached)
				}
				if let board = app.board {
					Section {
						SourcesView(sources: board.sources, now: app.now)
					} header: { ListHeader("Feed check") } footer: { Text("Times are predictions, not promises. Track labels are feed-reported. Times shown in New York time.") }
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
		.sheet(isPresented: $showAlerts) { NavigationStack { AlertsView(alerts: app.board?.alerts ?? [], sources: app.board?.sources ?? [], cached: app.boardIsCached) } }
	}

	private var stationHeading: some View {
		VStack(alignment: .leading, spacing: 0) {
			HStack(alignment: .center, spacing: 4) {
				Button { stationPicker = .search } label: {
					// Inline so the chevron follows the last line of a wrapped name.
					Text("\(app.station?.name ?? "Your next train") \(Text(Image(systemName: "chevron.down")).font(.caption.bold()).foregroundStyle(.secondary))")
						.font(.headline).multilineTextAlignment(.leading)
						.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
				}.buttonStyle(.plain).accessibilityIdentifier("selectedStation")
				Button { app.toggleFavorite(app.stationID) } label: {
					Image(systemName: app.favorites.contains(app.stationID) ? "star.fill" : "star")
						.font(.body).frame(width: 44, height: 44).contentShape(Rectangle())
				}
				.buttonStyle(.borderless)
				.accessibilityLabel(app.favorites.contains(app.stationID) ? "Remove favorite station" : "Favorite this station")
				.accessibilityIdentifier("toggleFavorite")
			}
			ViewThatFits(in: .horizontal) {
				HStack(spacing: 8) { stationMetadata; Spacer(minLength: 4); freshnessLabel }
				VStack(alignment: .leading, spacing: 3) { stationMetadata; freshnessLabel }
			}
			.padding(.trailing, 10)
			stationActions
		}
	}

	private var stationMetadata: some View {
		Text("\(app.station?.municipality.map { "\($0), " } ?? "")\(boroughName(app.station?.borough ?? "NYC")) · Station \(app.stationID)")
			.font(.caption2).foregroundStyle(.secondary)
	}

	private var freshnessLabel: some View {
		Label(externalDepartures ? "Station directory" : live ? (degraded ? "Partial live data" : "Live feed") : app.boardIsCached && app.board != nil ? "Cached board" : "Awaiting live data", systemImage: externalDepartures ? "map" : live ? "dot.radiowaves.left.and.right" : "clock")
			.font(.caption2.weight(.semibold)).foregroundStyle(live ? app.theme.accent : app.theme.ink.opacity(0.7))
			.accessibilityIdentifier("boardFreshness")
	}

	/// Station actions and other favorites sit in one scrolling row rather than behind a menu.
	private var stationActions: some View {
		ScrollView(.horizontal) {
			HStack(spacing: 6) {
				if app.station != nil {
					Button { show(.station) } label: {
						HStack(spacing: 4) { Image(systemName: "info.circle"); Text("Station info") }.chip()
					}
					.buttonStyle(.plain).accessibilityIdentifier("stationInfo")
				}
				if externalDepartures {
					Link(destination: TransitLinks.njtAlerts) {
						HStack(spacing: 4) { Image(systemName: "arrow.up.right"); Text("Alerts") }.chip()
					}
					.buttonStyle(.plain)
				} else {
					let count = app.board?.alerts.count ?? 0
					Button { showAlerts = true } label: {
						HStack(spacing: 4) {
							Image(systemName: "exclamationmark.triangle").foregroundStyle(count > 0 ? Color.orange : app.theme.ink)
							Text("Alerts (\(count))")
						}.chip()
					}
					.buttonStyle(.plain).accessibilityIdentifier("stationAlerts")
				}
				ForEach(app.favoriteStations.filter { $0.id != app.stationID }) { station in
					Button { app.selectStation(station.id) } label: {
						HStack(spacing: 4) { Image(systemName: "star.fill").foregroundStyle(app.theme.accent); Text(station.name) }
							.frame(maxWidth: 170).chip()
					}
					.buttonStyle(.plain)
					.accessibilityLabel("Favorite station \(station.name)")
					.accessibilityIdentifier("favoriteStation_\(station.id)")
				}
			}
		}
		.scrollIndicators(.hidden)
	}

	private var directionFilters: some View {
		let options = app.stationID.hasPrefix("path-")
			? [DirectionOption(id: "ALL", name: "All directions", icon: "arrow.left.arrow.right"), DirectionOption(id: "TO_NY", name: "To New York", text: "NY"), DirectionOption(id: "TO_NJ", name: "To New Jersey", text: "NJ")]
			: [DirectionOption(id: "ALL", name: "All directions", icon: "arrow.up.arrow.down"), DirectionOption(id: "NORTH", name: "Northbound", icon: "arrow.up"), DirectionOption(id: "SOUTH", name: "Southbound", icon: "arrow.down")]
		return HStack(spacing: 6) {
			ForEach(options) { option in
				let selected = app.preference.direction == option.id
				Button { app.setDirection(option.id) } label: {
					Group {
						if let icon = option.icon { Image(systemName: icon) } else { Text(option.text ?? "") }
					}
					.chip(selected: selected)
				}
				.buttonStyle(.plain)
				.accessibilityLabel(option.name)
				.accessibilityIdentifier("direction_\(option.id)")
				.accessibilityAddTraits(selected ? .isSelected : [])
			}
		}
		.accessibilityElement(children: .contain)
		.accessibilityIdentifier("directionFilter")
	}

	private var routeFilters: some View {
		let routes = Array(Set(((app.station?.routes ?? []) + (app.board?.departures.map(\.route) ?? [])).map(Display.displayRoute))).sorted()
		let selected = app.preference.routes
		return ScrollView(.horizontal) {
			HStack(spacing: 0) {
				Button { app.clearRoutes() } label: { Text("All").chip(selected: selected.isEmpty) }
					.padding(.trailing, 2)
					.buttonStyle(.plain)
					.accessibilityLabel("All lines")
					.accessibilityAddTraits(selected.isEmpty ? .isSelected : [])
				ForEach(routes, id: \.self) { route in
					let on = selected.contains(route)
					Button { app.toggleRoute(route) } label: {
						RouteBullet(route: route, small: true)
							.padding(3)
							.overlay { Capsule().strokeBorder(app.theme.accent, lineWidth: 2).opacity(on ? 1 : 0) }
							.opacity(selected.isEmpty || on ? 1 : 0.4)
							.frame(minWidth: 44, minHeight: 44)
							.contentShape(Rectangle())
					}
					.buttonStyle(.plain).accessibilityLabel("Filter line \(Display.routeLabel(route))")
					.accessibilityAddTraits(on ? .isSelected : [])
				}
			}
		}
		.scrollIndicators(.hidden)
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
		case .track: "\(part?.line ?? group.partId) · \(group.track.map { "Track \($0) · \(group.reportedTrack ? "reported" : "scheduled")" } ?? "Track unknown")"
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
				NavigationLink(value: BoardDetail.train(departure.tripKey)) {
					DepartureRow(departure: departure, now: now, cached: cached,
						previous: group.departures.prefix(index).last { candidate in
							Display.boardable(candidate) && candidate.direction == departure.direction && candidate.partId == departure.partId &&
							(candidate.actualTrack ?? candidate.scheduledTrack) == (departure.actualTrack ?? departure.scheduledTrack)
						}, showPlatform: order != .track)
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
	var body: some View {
		Section {
			VStack(alignment: .leading, spacing: 3) {
				Text(station.routes.first.flatMap(Display.regionalRoute)?.name ?? "NJ Transit light rail").font(.headline)
				if let part = station.parts.first { Text("\(station.municipality.map { "\($0) · " } ?? "")NJ Transit station \(part.stationId)").font(.subheadline) }
				Text("Live light rail departures are not connected in this app. Check NJ Transit for upcoming trains, schedules, and service changes.").font(.footnote).foregroundStyle(.secondary)
			}
			Link("NJ Transit departures", destination: TransitLinks.njtDepartures).actionStyle().accessibilityIdentifier("njtDepartures")
			Link("Light rail schedules", destination: TransitLinks.njtSchedules).actionStyle()
			Link("Service alerts", destination: TransitLinks.njtAlerts).actionStyle()
		} header: { ListHeader("Official departure tools") }
	}
}

struct DepartureRow: View {
	@Environment(AppModel.self) private var app
	let departure: Departure
	let now: TimeInterval
	var cached = false
	var previous: Departure?
	var showPlatform = false
	private var countdown: Countdown { Display.countdown(departure.time, timestamp: departure.timestamp, now: now, cached: cached, timeFormat: app.units.time) }
	private var historical: Bool { cached || Display.freshness(departure.timestamp, now: now) != .live || departure.locationTimestamp.map { now - $0 > 90 } == true }
	private var favoriteMatch: TrainFavoriteMatch? { app.trainFavorites.match(departure.consist, feed: departure.feed, now: now, cached: cached) }
	private var gap: Int? {
		guard !cached, Display.boardable(departure), let previous, Display.freshness(previous.timestamp, now: now) == .live,
			  Display.freshness(departure.timestamp, now: now) == .live, let before = previous.time, let after = departure.time else { return nil }
		return Int(((after - before) / 60).rounded())
	}
	// Built in steps: as one expression this exceeded CI's type-checking time limit.
	private var positionDetail: String {
		var detail = "Stop-relative position"
		if let stops = departure.stopsAway, stops >= 0 { detail = "\(stops) \(stops == 1 ? "stop" : "stops") away" }
		if let reported = departure.locationTimestamp { detail += " · \(Display.ageLabel(reported, now: now))" }
		return detail
	}
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
					Text(Display.boardingLabel(departure))
						.font(.caption2).foregroundStyle(.secondary).accessibilityIdentifier("boardingPlatform_\(departure.key)")
				}
				Text((historical ? "Last report: " : "") + departure.location).font(.caption)
				HStack(alignment: .firstTextBaseline) {
					Text(positionDetail)
					Spacer(minLength: 4)
					if let gap, gap > 0 { Text("+\(gap)m after previous") }
				}
				.font(.caption2).foregroundStyle(.secondary)
				if !cached, Display.currentConsist(departure.consist, now: now), let consist = departure.consist {
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

	private var countdownColumn: some View {
		VStack(alignment: .trailing, spacing: 0) {
			if Display.boardable(departure) {
				HStack(alignment: .firstTextBaseline, spacing: 2) {
					Text(countdown.value).font(.title2.weight(.bold).monospacedDigit())
					if countdown.unit == "min" { Text("min").font(.caption2.weight(.semibold)) }
				}
				Text(countdown.unit == "min" ? Display.clockTime(departure.time, format: app.units.time) : countdown.unit)
					.font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
			} else {
				Text("—").font(.title2.weight(.bold))
				Text("not boarding").font(.caption2).foregroundStyle(.secondary)
			}
		}
	}
}
