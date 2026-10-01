import CoreLocation
import SwiftUI
import TransitCore

struct StationPickerView: View {
	@Environment(AppModel.self) private var app
	@Environment(\.dismiss) private var dismiss
	@State private var query = ""

	private func distance(_ station: Station) -> Double? {
		guard let location = app.nearbyLocation else { return nil }
		return station.parts.map { location.distance(from: CLLocation(latitude: $0.lat, longitude: $0.lon)) }.min()
			?? location.distance(from: CLLocation(latitude: station.lat, longitude: station.lon))
	}
	private var matches: [Station] {
		return app.stations.filter { Display.stationMatches($0, query: query) }.sorted {
			if app.nearbyLocation != nil { return (distance($0) ?? .infinity) < (distance($1) ?? .infinity) }
			let a = app.favorites.contains($0.id), b = app.favorites.contains($1.id)
			return a == b ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : a
		}
	}

	var body: some View {
		List {
			Section {
				HStack {
					Button { Task { await app.locateNearby() } } label: {
						HStack(spacing: 6) {
							Image(systemName: "location")
							Text(app.locating ? "Finding your location…" : "Stations near me")
						}
					}
					.disabled(app.locating).accessibilityIdentifier("nearbyStations")
					Spacer()
					if app.nearbyLocation != nil { Button("Clear nearby sort") { app.nearbyLocation = nil } }
				}
				.buttonStyle(.borderless).actionStyle().font(.subheadline).frame(minHeight: 44)
				.listRowInsets(.vertical, 0)
				if let error = app.locationError { Notice(text: error) }
				if let error = app.catalogError { Notice(text: error) }
			}
			if query.isEmpty && app.nearbyLocation == nil {
				Section {
					ForEach(["602", "617", "611", "607"].compactMap { id in app.stations.first { $0.id == id } }) { station in
						Button(station.name) { choose(station) }
							.font(.subheadline)
							.listRowInsets(.vertical, 8)
					}
				} header: { ListHeader("Quick switch") }
			}
			Section {
				ForEach(matches) { station in
					HStack(spacing: 4) {
						Button { choose(station) } label: {
							VStack(alignment: .leading, spacing: 3) {
								HStack(alignment: .firstTextBaseline, spacing: 8) {
									Text(station.name).font(.subheadline.weight(.semibold)).multilineTextAlignment(.leading)
									Spacer(minLength: 4)
									Text((station.municipality.map { "\($0), " } ?? "") + boroughName(station.borough) + (distance(station).map { " · \($0 < 1000 ? "\(Int($0.rounded())) m" : String(format: "%.1f km", $0 / 1000))" } ?? ""))
										.font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
								}
								RouteStrip(routes: station.routes)
							}
							.frame(maxWidth: .infinity, alignment: .leading)
							.contentShape(Rectangle())
						}.buttonStyle(.plain).accessibilityIdentifier("station_\(station.id)")
						Button { app.toggleFavorite(station.id) } label: {
							Image(systemName: app.favorites.contains(station.id) ? "star.fill" : "star").frame(minWidth: 44, minHeight: 44)
						}.buttonStyle(.borderless).accessibilityLabel("\(app.favorites.contains(station.id) ? "Remove favorite" : "Favorite") \(station.name)")
					}
					.listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 6))
				}
				if matches.isEmpty { ContentUnavailableView.search(text: query) }
			} header: { ListHeader(app.nearbyLocation != nil ? "Closest station first" : "\(matches.count) station \(matches.count == 1 ? "complex" : "complexes") · favorites first") }
		}
		.themedList().navigationTitle("Find a station").navigationBarTitleDisplayMode(.inline)
		.searchable(text: $query, prompt: "Station, line, or borough")
		.autocorrectionDisabled().textInputAutocapitalization(.never)
		.toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
		.refreshable { await app.refreshCatalog() }
	}
	private func choose(_ station: Station) { app.selectStation(station.id); dismiss() }
}
