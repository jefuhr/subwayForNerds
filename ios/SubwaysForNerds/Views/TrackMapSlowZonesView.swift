import SwiftUI
import TransitCore

/// Text remains available for reviewed estimates whose rail geometry is unmapped.
struct TrackMapSlowZonesView: View {
	let session: TrackMapSession
	let now: @MainActor () -> TimeInterval
	@Environment(AppModel.self) private var app
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		NavigationStack {
			TimelineView(.periodic(from: .now, by: 1)) { _ in
				let state = TrackMapSlowZonePresenter.state(session.snapshot, now: now(), routes: session.selectedRoutes, frozenAt: session.frozenAt)
				List {
					Section {
						Label("Amber lines · Estimated slow zones", systemImage: "line.diagonal")
							.font(.subheadline.weight(.semibold))
							.foregroundStyle(Color.orange)
						Text(SlowZoneDisplay.attribution).font(.caption)
							.accessibilityIdentifier("track-map-slow-zone-source")
						if let through = state.dataThrough {
							Text("Data through \(SlowZoneDisplay.date(through))\(state.cached ? " · Cached" : "")").font(.caption)
						}
					}
					.listRowBackground(app.theme.background)
					if state.status == .active {
						Section("\(state.zones.count) \(state.zones.count == 1 ? "estimate" : "estimates")\(session.selectedRoutes.isEmpty ? "" : " on selected lines")") {
							if state.zones.isEmpty { Text("No estimated slow zones on the selected lines.") }
							ForEach(state.zones) { zone in
								VStack(alignment: .leading, spacing: 5) {
									Text(zone.zone.segment).font(.subheadline.weight(.semibold))
									Text(zone.kindLabel).font(.caption.weight(.semibold)).foregroundStyle(Color.orange)
									Text(zone.typicalDelay).font(.caption)
									if !zone.zone.routes.isEmpty {
										Text("Lines \(zone.zone.routes.map(Display.displayRoute).joined(separator: ", "))").font(.caption)
									}
									Text("Since \(SlowZoneDisplay.date(zone.zone.since)) · Source: Transit Lab").font(.caption)
									if let reason = zone.unplottedReason { Text(reason).font(.caption) }
								}
								.accessibilityElement(children: .combine)
								.accessibilityLabel(zone.accessibilityLabel)
								.accessibilityIdentifier("track-map-slow-zone-\(zone.id)")
							}
						}
						.listRowBackground(app.theme.background)
						if state.unmappedCount > 0 {
							Text("\(state.unmappedCount) estimates across all lines have no reviewed map path. Their locations are not drawn.")
								.font(.caption)
								.listRowBackground(app.theme.background)
								.accessibilityIdentifier("track-map-slow-zone-unmapped")
						}
					} else {
						Text(state.status == .expired ? "Slow-zone estimates expired. Highlights return when fresh data is available." : "Slow-zone estimates are unavailable. Check again after the next map update.")
							.listRowBackground(app.theme.background)
							.accessibilityIdentifier("track-map-slow-zone-status")
					}
				}
				.foregroundStyle(app.theme.ink)
				.scrollContentBackground(.hidden)
				.background(app.theme.background)
			}
			.navigationTitle("Estimated slow zones")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("track-map-slow-zones-done") }
			}
		}
	}
}
