import SwiftUI
import TransitCore

/// Every train the map knows about as an accessible list: those in view first, then
/// the rest of the map, then trains that cannot be placed and why.
struct TrackMapTrainsList: View {
	let session: TrackMapSession
	/// The part of the map that was on screen when the list opened.
	let visibleRect: TrackMapRect?
	let select: (String) -> Void
	@Environment(AppModel.self) private var app
	@Environment(TrackMapStore.self) private var store
	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@Environment(\.dismiss) private var dismiss

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
			.navigationTitle("Visible trains")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.actionStyle() } }
		}
		.presentationDetents([.medium, .large])
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
