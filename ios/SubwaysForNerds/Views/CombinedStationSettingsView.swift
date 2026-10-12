import SwiftUI
import TransitCore

struct CombinedStationsView: View {
	@Environment(AppModel.self) private var app
	@State private var adding = false
	var body: some View {
		List {
			Section {
				Button { adding = true } label: { Label("Create combined station", systemImage: "plus") }
					.accessibilityIdentifier("addCombinedStation")
			} footer: { Text("Bring departures from multiple stations into one board. Original stations stay available.") }
			Section {
				ForEach(app.combinedStations.keys.sorted(), id: \.self) { id in
					if let definition = app.combinedStations[id] {
						NavigationLink { CombinedStationEditor(id: id) } label: {
							VStack(alignment: .leading, spacing: 4) {
								Text(definition.name).font(.headline)
								Text("\(definition.stationIDs.count) stations").font(.caption).foregroundStyle(.secondary)
							}
						}.accessibilityIdentifier("editCombinedStation_\(id)")
					}
				}
			} header: { ListHeader("Your combined stations") }
		}
		.themedList().navigationTitle("Combined stations").navigationBarTitleDisplayMode(.inline)
		.sheet(isPresented: $adding) { NavigationStack { CombinedStationEditor() } }
	}
}

struct CombinedStationEditor: View {
	var id: String?
	var onSaved: () -> Void = {}
	@Environment(AppModel.self) private var app
	@Environment(\.dismiss) private var dismiss
	@State private var name = ""
	@FocusState private var nameFocused: Bool
	@FocusState private var searchFocused: Bool
	@State private var selected = Set<String>()
	@State private var query = ""
	@State private var loaded = false
	@State private var error: String?
	@State private var confirmingDelete = false
	private var matches: [Station] {
		app.stations.filter { Display.stationMatches($0, query: query) }.sorted {
			if selected.contains($0.id) != selected.contains($1.id) { return selected.contains($0.id) }
			return $0.name.localizedStandardCompare($1.name) == .orderedAscending
		}
	}
	var body: some View {
		List {
			Section {
				TextField("Combined station name", text: $name).accessibilityIdentifier("combinedStationName")
					.focused($nameFocused).submitLabel(.done).onSubmit { nameFocused = false }
			} footer: { Text("Choose at least two stations. Each departure will show where to board.") }
			Section {
				HStack {
					Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
					TextField("Find stations to combine", text: $query)
						.accessibilityIdentifier("combinedStationSearch")
						.textInputAutocapitalization(.never).focused($searchFocused)
						.submitLabel(.done).onSubmit { searchFocused = false }
					if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).accessibilityLabel("Clear station search") }
				}
			}
			if let id {
				Section {
					Button("Delete combined station", role: .destructive) { confirmingDelete = true }.accessibilityIdentifier("deleteCombinedStation")
						.alert("Delete combined station?", isPresented: $confirmingDelete) {
							Button("Delete combined station", role: .destructive) {
								do { try app.deleteCombinedStation(id); dismiss() } catch { self.error = error.localizedDescription }
							}
							Button("Cancel", role: .cancel) {}
						} message: { Text("Its favorite and board filters will be removed. Original stations and saved trips stay available.") }
				}
			}
			if let error { Section { Notice(text: error) } }
			Section {
				ForEach(selected.filter { id in !app.stations.contains { $0.id == id } }.sorted(), id: \.self) { id in
					Button { selected.remove(id) } label: { Label("Unavailable station \(id) · remove", systemImage: "exclamationmark.triangle") }
				}
				ForEach(matches) { station in
					Button {
						if selected.contains(station.id) { selected.remove(station.id) } else { selected.insert(station.id) }
					} label: {
						HStack {
							VStack(alignment: .leading, spacing: 4) {
								Text(station.name).font(.subheadline.weight(.semibold))
								Text((station.municipality.map { "\($0) · " } ?? "") + boroughName(station.borough)).font(.caption).foregroundStyle(.secondary)
								RouteStrip(routes: station.routes)
								if LineVisibility.station(station, hiddenRoutes: app.hiddenRoutes) == nil { Text("Lines hidden in settings").font(.caption).foregroundStyle(.secondary) }
							}
							Spacer()
							Image(systemName: selected.contains(station.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(app.theme.accent)
						}
						.contentShape(Rectangle())
					}.buttonStyle(.plain).accessibilityIdentifier("combinedStationMember_\(station.id)")
						.accessibilityAddTraits(selected.contains(station.id) ? .isSelected : [])
				}
			} header: { ListHeader("\(selected.count) selected") }
		}
		.themedList().navigationTitle(id == nil ? "New combined station" : "Edit combined station").navigationBarTitleDisplayMode(.inline)
		.autocorrectionDisabled()
		.toolbar {
			ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
			ToolbarItem(placement: .confirmationAction) {
				Button("Save") {
					do { try app.saveCombinedStation(id: id, name: name, stationIDs: Array(selected)); dismiss(); onSaved() }
					catch { self.error = error.localizedDescription }
				}.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selected.count < 2).accessibilityIdentifier("saveCombinedStation")
			}
		}
		.onAppear {
			guard !loaded else { return }; loaded = true
			if let id, let definition = app.combinedStations[id] { name = definition.name; selected = Set(definition.stationIDs) }
		}
	}
}

struct LineVisibilityView: View {
	@Environment(AppModel.self) private var app
	private let systems = ["Subway & SIR", "PATH", "NJ Transit"]
	private func system(_ route: String) -> String { route.hasPrefix("PATH") ? "PATH" : route.hasPrefix("NJT-") ? "NJ Transit" : "Subway & SIR" }
	var body: some View {
		List {
			Section {
				Button("Enable all lines") { app.setHiddenLines([]) }.accessibilityIdentifier("enableAllLines")
				Button("Hide all lines") { app.setHiddenLines(app.allLineKeys) }.accessibilityIdentifier("hideAllLines")
			} footer: { Text("Applies to stations, departures, connections, alerts, and station widgets. Station filters still apply. Saved trips, your active ride, and fleet history stay accessible.") }
			if let error = app.settingsError { Section { Notice(text: error) } }
			ForEach(systems, id: \.self) { group in
				let routes = app.allLineKeys.filter { system($0) == group }
				if !routes.isEmpty {
					Section {
						ForEach(routes, id: \.self) { route in
							Toggle(isOn: Binding(get: { LineVisibility.isEnabled(route, hiddenRoutes: app.hiddenRoutes) }, set: { app.setLine(route, enabled: $0) })) {
								HStack { RouteBullet(route: route, small: true); Text(Display.regionalRoute(route)?.name ?? "Line \(route)") }
							}.accessibilityIdentifier("globalLine_\(route)")
						}
						HStack {
							Button("Enable \(group)") { app.setHiddenLines(app.hiddenRoutes.filter { !routes.contains(LineVisibility.key($0)) }) }
							Spacer()
							Button("Hide \(group)") { app.setHiddenLines(Array(Set(app.hiddenRoutes + routes))) }
						}.buttonStyle(.borderless).font(.caption)
					} header: { ListHeader(group) }
				}
			}
			if app.allLineKeys.isEmpty { Text("Connect to load the station catalog and line controls.").foregroundStyle(.secondary) }
		}
		.themedList().navigationTitle("Lines").navigationBarTitleDisplayMode(.inline)
	}
}
