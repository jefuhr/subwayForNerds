import SwiftUI
import TransitCore

/// Screens pushed over the map. Back returns to the map where it was.
enum TrackMapDestination: Hashable {
	case train(String)
	case stationBoard
}

/// The Map tab: the original track map PDF with live trains drawn over it.
struct TrackMapScreen: View {
	@Environment(AppModel.self) private var app
	@Environment(TrackMapStore.self) private var store
	/// Untyped, because the reused board pushes its own `BoardDetail` values onto this stack.
	@State private var path = NavigationPath()

	var body: some View {
		NavigationStack(path: $path) {
			content
				.navigationTitle("Map")
				.navigationBarTitleDisplayMode(.inline)
				.navigationDestination(for: TrackMapDestination.self) { destination in
					switch destination {
					case .train(let key): TrainDetailView(tripKey: key)
					case .stationBoard: StationBoardScreen()
					}
				}
		}
		.task { await store.loadIfNeeded() }
	}

	@ViewBuilder private var content: some View {
		switch store.state {
		case .notLoaded, .loading:
			ProgressView("Loading the track map…")
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.background(app.theme.background)
				.foregroundStyle(app.theme.ink)
				.accessibilityIdentifier("track-map-status")
		case .unavailable(let message):
			ContentUnavailableView {
				Label("Map unavailable", systemImage: "map")
			} description: {
				Text("\(message) Boards, fleet and settings still work.")
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.background(app.theme.background)
			.foregroundStyle(app.theme.ink)
			.accessibilityElement(children: .combine)
			.accessibilityIdentifier("track-map-status")
		case .ready(let assets):
			TrackMapContent(assets: assets, path: $path)
		}
	}
}

private struct TrackMapPollKey: Hashable {
	var active: Bool
	var connected: Bool
	var endpoint: String
}

struct TrackMapContent: View {
	let assets: TrackMapAssets
	@Binding var path: NavigationPath
	@Environment(AppModel.self) private var app
	@Environment(TrackMapStore.self) private var store
	@Environment(\.scenePhase) private var phase
	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@State private var controller = TrackMapCanvasController()
	@State private var query = ""
	@FocusState private var searching: Bool
	@State private var station: TrackMapStationMatch?
	@State private var showTrains = false
	@State private var trainsInView: TrackMapRect?
	@State private var pendingTrain: String?
	@State private var overlap: [TrackMapTrainState] = []
	@State private var showOverlap = false
	@State private var onScreen = false
	private var session: TrackMapSession { assets.session }
	private var index: TrackMapIndex { session.index }

	private var pollKey: TrackMapPollKey {
		TrackMapPollKey(active: TrackMapSession.shouldPoll(mapTabSelected: app.selectedTab == 3, mapOnScreen: onScreen, sceneActive: phase == .active),
			connected: app.connected, endpoint: app.endpoint)
	}

	private var input: TrackMapOverlayInput {
		TrackMapOverlayInput(snapshot: session.snapshot, routes: session.selectedRoutes, frozenAt: session.frozenAt, reduceMotion: reduceMotion, visible: pollKey.active,
			highlights: station?.stations.map(\.point) ?? [], background: UIColor(app.theme.background), accent: UIColor(app.theme.accent))
	}

	var body: some View {
		ZStack {
			TrackMapCanvas(assets: assets, controller: controller, input: input, initialFocus: index.focusRect(stationIDs: app.selectedMemberIDs),
				now: { [store] in store.now() }, onSelect: select)
				.ignoresSafeArea(.container, edges: [.horizontal, .bottom])
			VStack(spacing: 6) {
				searchBar
				if searching, !results.isEmpty { searchResults }
				routeFilters
				Spacer(minLength: 0)
				if let station { stationCard(station) }
				if let banner { statusBanner(banner) }
				bottomBar
			}
			.padding(.horizontal, 12)
			.padding(.vertical, 8)
		}
		.background(app.theme.background)
		.onAppear { onScreen = true }
		.onDisappear { onScreen = false }
		// Polls only while the map is on screen in the selected tab and the app is active.
		// Leaving cancels the loop and the request in flight; responses never move the map.
		.task(id: pollKey) {
			let key = pollKey
			store.prepare(endpoint: key.endpoint)
			session.setConnected(key.connected, now: store.now())
			guard key.active, key.connected else { return }
			let api = app.api
			await session.run(now: { [store] in store.now() }) { try await api.trackMapSnapshot(mapVersion: TrackMapContract.mapVersion) }
		}
		.sheet(isPresented: $showTrains, onDismiss: openPendingTrain) {
			TrackMapTrainsList(session: session, visibleRect: trainsInView) { key in
				pendingTrain = key
				showTrains = false
			}
		}
		.confirmationDialog("Choose a train", isPresented: $showOverlap, titleVisibility: .visible) {
			ForEach(overlap) { state in
				Button("\(Display.displayRoute(state.train.route)) to \(state.train.destination) · \(state.positionCertainty.label)") { path.append(TrackMapDestination.train(state.id)) }
			}
		} message: { Text("Several trains are drawn here.") }
	}

	// MARK: Search

	private var results: [TrackMapStationMatch] { Array(index.searchStations(query).prefix(6)) }

	private var searchBar: some View {
		HStack(spacing: 8) {
			Image(systemName: "magnifyingglass").foregroundStyle(app.theme.ink.opacity(0.6)).accessibilityHidden(true)
			TextField("Search stations", text: $query)
				.focused($searching)
				.textInputAutocapitalization(.never)
				.autocorrectionDisabled()
				.submitLabel(.search)
				.onSubmit { if let first = results.first { choose(first) } }
				.accessibilityIdentifier("track-map-search")
			if !query.isEmpty {
				Button { query = "" } label: { Image(systemName: "xmark.circle.fill").frame(minWidth: 44, minHeight: 44) }
					.foregroundStyle(app.theme.ink.opacity(0.6))
					.accessibilityLabel("Clear search")
			}
		}
		.padding(.leading, 12)
		.frame(minHeight: 44)
		.foregroundStyle(app.theme.ink)
		.background(app.theme.background.opacity(0.94), in: Capsule())
		.overlay { Capsule().strokeBorder(app.theme.ink.opacity(0.15)) }
	}

	private var searchResults: some View {
		VStack(alignment: .leading, spacing: 0) {
			ForEach(Array(results.enumerated()), id: \.element.id) { offset, match in
				Button { choose(match) } label: {
					VStack(alignment: .leading, spacing: 1) {
						Text(match.name)
						if let subtitle = subtitle(match) { Text(subtitle).font(.caption).foregroundStyle(app.theme.ink.opacity(0.7)) }
					}
					.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
				}
				.padding(.horizontal, 14)
				.foregroundStyle(app.theme.ink)
				.accessibilityIdentifier("track-map-search-result-\(offset)")
				if offset < results.count - 1 { Divider() }
			}
		}
		.background(app.theme.background.opacity(0.96), in: RoundedRectangle(cornerRadius: 14))
		.overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(app.theme.ink.opacity(0.15)) }
	}

	/// The app's catalog entry for a map station, when it has one.
	private func catalogStation(_ match: TrackMapStationMatch) -> Station? { app.allStations.first { $0.id == match.stationId } }

	/// Only same-named results get one: their lines and borough from the station catalog.
	private func subtitle(_ match: TrackMapStationMatch) -> String? {
		let station = catalogStation(match)
		return match.subtitle(routes: station?.routes ?? [], borough: station?.borough)
	}

	private func choose(_ match: TrackMapStationMatch) {
		station = match
		query = ""
		searching = false
		if let rect = index.focusRect(stations: match.stations, padding: 450) { controller.focus(rect) }
	}

	private func stationCard(_ match: TrackMapStationMatch) -> some View {
		let boardID = catalogStation(match)?.id
		return HStack(spacing: 8) {
			VStack(alignment: .leading, spacing: 1) {
				Text(match.name).font(.subheadline.weight(.semibold)).lineLimit(2)
				if let subtitle = subtitle(match) { Text(subtitle).font(.caption).foregroundStyle(app.theme.ink.opacity(0.7)) }
			}
			.accessibilityElement(children: .combine)
			Spacer(minLength: 4)
			Button {
				guard let boardID else { return }
				// Like a transfer, the board opens over the map; Back returns here.
				app.selectStation(boardID, switchTab: false)
				path.append(TrackMapDestination.stationBoard)
			} label: { Label("Board", systemImage: "list.bullet.rectangle").frame(minHeight: 44) }
				.foregroundStyle(app.theme.accent)
				.disabled(boardID == nil)
				.accessibilityLabel("Open \(match.name) board")
				.accessibilityIdentifier("track-map-station-board")
			Button { station = nil } label: { Image(systemName: "xmark").frame(minWidth: 44, minHeight: 44) }
				.foregroundStyle(app.theme.ink.opacity(0.7))
				.accessibilityLabel("Close station")
		}
		.padding(.leading, 14)
		.foregroundStyle(app.theme.ink)
		.background(app.theme.background.opacity(0.94), in: RoundedRectangle(cornerRadius: 14))
		.overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(app.theme.ink.opacity(0.15)) }
	}

	// MARK: Route filters

	private var routes: [String] {
		let shown = session.snapshot.map(TrackMapRoutes.routes) ?? []
		return TrackMapRoutes.order.filter { shown.contains($0) || session.selectedRoutes.contains($0) }
	}

	@ViewBuilder private var routeFilters: some View {
		if !routes.isEmpty {
			ScrollView(.horizontal, showsIndicators: false) {
				HStack(spacing: 4) {
					Button("All") { session.selectedRoutes = [] }
						.chip(selected: session.selectedRoutes.isEmpty)
						.background(app.theme.background.opacity(0.9), in: Capsule())
						.accessibilityAddTraits(session.selectedRoutes.isEmpty ? .isSelected : [])
						.accessibilityIdentifier("track-map-route-all")
					ForEach(routes, id: \.self) { route in
						let selected = session.selectedRoutes.contains(route)
						Button {
							if selected { session.selectedRoutes.remove(route) } else { session.selectedRoutes.insert(route) }
						} label: { RouteBullet(route: route, small: true) }
							.chip(selected: selected)
							.background(app.theme.background.opacity(0.9), in: Capsule())
							.accessibilityAddTraits(selected ? .isSelected : [])
							.accessibilityIdentifier("track-map-route-\(route)")
					}
				}
			}
			.scrollClipDisabled()
		}
	}

	// MARK: Status

	private var banner: String? {
		switch session.status {
		case .idle: return app.connected ? nil : "Offline. Train positions need a connection."
		case .loading: return "Loading train positions…"
		case .ready: return nil
		case .offline: return session.snapshot == nil ? "Offline. Train positions need a connection." : "Offline. Trains are held at their last estimated positions."
		case .failed(let message): return message
		case .rejected(let error): return error.localizedDescription
		}
	}

	private func statusBanner(_ text: String) -> some View {
		HStack(alignment: .firstTextBaseline, spacing: 6) {
			Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
			Text(text).frame(maxWidth: .infinity, alignment: .leading)
		}
		.font(.footnote)
		.padding(10)
		.foregroundStyle(app.theme.ink)
		.background(app.theme.background.opacity(0.94), in: RoundedRectangle(cornerRadius: 12))
		.accessibilityElement(children: .combine)
		.accessibilityIdentifier("track-map-status")
	}

	private var bottomBar: some View {
		HStack(alignment: .bottom, spacing: 8) {
			// The artwork's credit stays on screen whenever the map is shown.
			Text(index.attribution.components(separatedBy: ". ").first ?? index.attribution)
				.font(.caption2)
				.lineLimit(2)
				.padding(.horizontal, 8).padding(.vertical, 4)
				.foregroundStyle(app.theme.ink)
				.background(app.theme.background.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
				.frame(maxWidth: .infinity, alignment: .leading)
				.accessibilityIdentifier("track-map-attribution")
			mapButton("Visible trains", systemImage: "list.bullet", identifier: "track-map-trains") {
				trainsInView = controller.visibleRect
				showTrains = true
			}
			mapButton("Fit map", systemImage: "arrow.up.left.and.arrow.down.right", identifier: "track-map-fit") {
				controller.fit()
			}
		}
	}

	private func mapButton(_ title: String, systemImage: String, identifier: String, action: @escaping () -> Void) -> some View {
		Button(action: action) {
			Image(systemName: systemImage).font(.body.weight(.semibold)).frame(width: 44, height: 44)
		}
		.foregroundStyle(app.theme.accent)
		.background(app.theme.background.opacity(0.94), in: Circle())
		.overlay { Circle().strokeBorder(app.theme.ink.opacity(0.15)) }
		.accessibilityLabel(title)
		.accessibilityIdentifier(identifier)
	}

	// MARK: Selection

	private func select(_ keys: [String]) {
		guard let snapshot = session.snapshot else { return }
		let conditions = session.conditions(now: store.now(), reduceMotion: reduceMotion)
		let states = keys.compactMap { key in snapshot.trains.first { $0.key == key }.map { TrackMapPresenter.state(for: $0, in: snapshot, conditions: conditions) } }
		if states.count == 1 { path.append(TrackMapDestination.train(states[0].id)) }
		else if states.count > 1 { overlap = states; showOverlap = true }
	}

	private func openPendingTrain() {
		guard let key = pendingTrain else { return }
		pendingTrain = nil
		path.append(TrackMapDestination.train(key))
	}
}
