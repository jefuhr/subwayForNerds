import SwiftUI
import TransitCore

/// The map's menu: line filters, estimated slow zones, then every train the map knows about
/// as an accessible list: those in view first, then the rest of the map, then trains that
/// cannot be placed and why.
struct TrackMapTrainsList: View {
	let session: TrackMapSession
	/// The part of the map that was on screen when the list opened.
	let visibleRect: TrackMapRect?
	let select: (String) -> Void
	@Environment(AppModel.self) private var app
	@Environment(TrackMapStore.self) private var store
	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@Environment(\.dismiss) private var dismiss

	/// Lines with a train or slow zone on the map, plus any selected line that has since dropped off.
	private var routes: [String] {
		// app.now ticks once a second, so lines appear and expire while the menu is open.
		_ = app.now
		let shown = session.snapshot.map { TrackMapRoutes.routes(in: $0, now: store.now()) } ?? []
		return TrackMapRoutes.order.filter { shown.contains($0) || session.selectedRoutes.contains($0) }
	}

	private var states: [TrackMapTrainState] {
		guard let snapshot = session.snapshot else { return [] }
		// app.now ticks once a second, so stale labels and expiry stay current while the list is open.
		_ = app.now
		return TrackMapPresenter.states(snapshot, conditions: session.conditions(now: store.now(), reduceMotion: reduceMotion), routes: session.selectedRoutes)
	}

	var body: some View {
		let all = states
		let plotted = all.filter(\.isPlotted)
		let inView = plotted.filter { state in visibleRect.map { rect in state.point.map(rect.contains) ?? false } ?? true }
		let elsewhere = plotted.filter { state in !inView.contains { $0.id == state.id } }
		let unplaced = all.filter { !$0.isPlotted }
		NavigationStack {
			List {
				if !routes.isEmpty { Section { routeFilters } }
				Section { slowZoneRow }
				if all.isEmpty {
					Text(session.snapshot == nil ? "Train positions have not loaded yet." : "No trains match these lines right now.")
						.foregroundStyle(.secondary)
				}
				section(visibleRect == nil ? "On the map" : "In view", inView)
				if visibleRect != nil { section("Elsewhere on the map", elsewhere) }
				section("Not on the map", unplaced)
				Section {
					legend("circle.fill", "Solid outline: position reported by the train")
					legend("circle.dashed", "Dashed outline: estimated from the feed")
					legend("circle.circle", "Halo: near a stop, exact track position unknown")
					legend("circle.lefthalf.filled", "Faded: stale, not moving")
				} header: { ListHeader("Marker key") } footer: {
					Text("\(session.index.attribution)\n\(session.index.topology.sourceURL)")
						.accessibilityIdentifier("track-map-credit")
				}
			}
			.themedList()
			.navigationTitle("Map")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.actionStyle() } }
		}
		.presentationDetents([.medium, .large])
	}

	/// The same selection the map draws, edited live.
	private var routeFilters: some View {
		ScrollView(.horizontal, showsIndicators: false) {
			HStack(spacing: 4) {
				Button("All") { session.selectedRoutes = [] }
					.buttonStyle(.plain).chip(selected: session.selectedRoutes.isEmpty)
					.accessibilityAddTraits(session.selectedRoutes.isEmpty ? .isSelected : [])
					.accessibilityIdentifier("track-map-route-all")
				ForEach(routes, id: \.self) { route in
					let selected = session.selectedRoutes.contains(route)
					Button {
						if selected { session.selectedRoutes.remove(route) } else { session.selectedRoutes.insert(route) }
					} label: { RouteBullet(route: route, small: true) }
						.buttonStyle(.plain).chip(selected: selected)
						.accessibilityAddTraits(selected ? .isSelected : [])
						.accessibilityIdentifier("track-map-route-\(route)")
				}
			}
		}
		.listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 8))
	}

	/// Opens the slow-zone details inside this menu.
	private var slowZoneRow: some View {
		// app.now ticks once a second, so an estimate expires on screen.
		_ = app.now
		let state = TrackMapSlowZonePresenter.state(session.snapshot, now: store.now(), routes: session.selectedRoutes, frozenAt: session.frozenAt)
		let label: String = switch state.status {
		case .active: "Estimated slow zones · \(state.zones.count)\(state.cached ? " · Cached" : "")"
		case .expired: "Slow-zone estimates expired"
		case .unavailable: "Slow-zone estimates unavailable"
		}
		return NavigationLink {
			TrackMapSlowZonesView(session: session, now: { [store] in store.now() })
		} label: {
			HStack(spacing: 6) {
				Image(systemName: "line.diagonal").font(.body.weight(.heavy)).foregroundStyle(Color(red: 0.85, green: 0.45, blue: 0.03)).accessibilityHidden(true)
				Text(label).font(.subheadline.weight(.semibold))
				Spacer(minLength: 4)
				Text("Transit Lab").font(.caption).foregroundStyle(.secondary)
			}
			.frame(minHeight: 44)
		}
		.accessibilityElement(children: .ignore)
		.accessibilityLabel("\(label). Amber lines show estimated slow zones. Source: Transit Lab. Show zone details")
		.accessibilityAddTraits(.isButton)
		.accessibilityIdentifier("track-map-slow-zones")
	}

	@ViewBuilder private func section(_ title: String, _ rows: [TrackMapTrainState]) -> some View {
		if !rows.isEmpty {
			Section {
				ForEach(rows) { state in row(state) }
			} header: { ListHeader("\(title) · \(rows.count)") }
		}
	}

	private func row(_ state: TrackMapTrainState) -> some View {
		Button { select(state.id) } label: {
			HStack(alignment: .top, spacing: 8) {
				RouteBullet(route: state.train.route, small: true)
				VStack(alignment: .leading, spacing: 1) {
					Text(state.train.destination).font(.subheadline.weight(.semibold))
					Text(state.trackCertainty.label).font(.caption)
					Text(state.isPlotted ? state.positionCertainty.label : state.unplottedReason ?? "Not on the map")
						.font(.caption).foregroundStyle(.secondary)
					if state.isPlotted && state.freshness != .live {
						Text("Stale · not moving").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
					}
				}
				Spacer(minLength: 0)
				Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).accessibilityHidden(true)
			}
			.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.accessibilityElement(children: .ignore)
		.accessibilityLabel(state.isPlotted ? state.accessibilityLabel : "\(state.accessibilityLabel). \(state.unplottedReason ?? "No reliable position")")
		.accessibilityHint("Opens train details")
		.accessibilityAddTraits(.isButton)
		.accessibilityIdentifier("track-map-train-\(state.id)")
	}

	private func legend(_ systemImage: String, _ text: String) -> some View {
		Label(text, systemImage: systemImage).font(.footnote)
	}
}
