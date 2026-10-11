import SwiftUI
import TransitCore

struct SettingsView: View {
	@Environment(AppModel.self) private var app
	@Environment(\.horizontalSizeClass) private var sizeClass
	@Environment(\.dynamicTypeSize) private var dynamicType
	@State private var endpoint = ""
	@State private var endpointError: String?
	@State private var confirmDelete = false
	var body: some View {
		List {
			Section {
				HStack(spacing: 12) {
					Image("Kitty").resizable().scaledToFit().frame(width: 44, height: 44).accessibilityHidden(true)
					VStack(alignment: .leading, spacing: 1) {
						Text("subways for nerds.").font(.headline)
						Text("Know the system. Make your next move.").font(.caption).foregroundStyle(.secondary)
					}
				}
				.listRowInsets(.vertical, 8)
			}
			Section {
				// Five columns fit all ten themes in two rows on wider screens.
				LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: dynamicType.isAccessibilitySize ? 1 : sizeClass == .regular ? 5 : 2), spacing: 6) {
					ForEach(AppTheme.all) { theme in themeTile(theme) }
				}
				.listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
			} header: { ListHeader("Theme") }
			Section {
				NavigationLink { StationSelectionSettingsView() } label: { LabeledContent("Station selection", value: app.stationSelection.mode.title) }
					.accessibilityIdentifier("stationSelectionSettings")
				NavigationLink("Favorite trains") { FavoriteTrainsSettingsView() }.accessibilityIdentifier("favoriteTrainsSettings")
			} header: { ListHeader("Board") }
			Section {
				Picker("Distance units", selection: Binding(get: { app.units.distance }, set: { app.setDistanceUnit($0) })) {
					ForEach(DistanceUnit.allCases) { unit in Text(unit.title).tag(unit) }
				}.accessibilityIdentifier("distanceUnits")
				Picker("Time format", selection: Binding(get: { app.units.time }, set: { app.setTimeFormat($0) })) {
					ForEach(TimeFormat.allCases) { format in Text(format.title).tag(format) }
				}.accessibilityIdentifier("timeFormat")
			} header: { ListHeader("Units") } footer: { Text("Applies throughout the app and Home and Lock Screen widgets. Times use New York time. Automatic shows nearby distances in meters or kilometers and favorite radii in feet and miles.") }
			.tint(app.theme.selection)
			.id(app.themeID)

			Section {
				NavigationLink { StationSelectionSettingsView(widget: true) } label: {
					LabeledContent("Widget station", value: app.widgetPreferences.stationSelection.followApp ? "Same as app" : app.widgetPreferences.stationSelection.selection.mode.title)
				}.accessibilityIdentifier("widgetStationSelectionSettings")
				NavigationLink("Home Screen display") { WidgetDisplaySettingsView() }.accessibilityIdentifier("widgetDisplaySettings")
				NavigationLink("Lock Screen display") { WidgetDisplaySettingsView(lockScreen: true) }.accessibilityIdentifier("widgetLockScreenSettings")
				Toggle("Match app filters", isOn: Binding(get: { app.widgetPreferences.matchAppFilters }, set: { app.setWidgetMatchApp($0) }))
					.accessibilityIdentifier("widgetMatchAppFilters")
				if !app.widgetPreferences.matchAppFilters {
					ForEach(app.favoriteStations) { station in
						NavigationLink(station.name) { WidgetFiltersView(station: station) }
							.accessibilityIdentifier("widgetFilters_\(station.id)")
					}
				}
				if app.favorites.isEmpty && (app.widgetPreferences.stationSelection.followApp ? app.stationSelection : app.widgetPreferences.stationSelection.selection).mode == .favorite { Text("Add a favorite station or choose Closest station above.").font(.footnote).foregroundStyle(.secondary) }
				if app.widgetStore == nil { Notice(text: "Widget sharing is unavailable. Build both targets with the same App Group enabled.") }
			} header: { ListHeader("Widgets") } footer: {
				Text("Home and Lock Screen widgets use your station selection and show both directions. Match app filters uses that station’s lines and grouping. iOS schedules updates; use the widget’s refresh button for a new report.")
			}
			SettingsTransferSection()
			AccountSettingsSection()
			offlineSection
			#if DEBUG
			Section { NavigationLink("Widget previews") { WidgetPreviewView() }.accessibilityIdentifier("widgetPreviews") }
			Section {
				TextField("API URL", text: $endpoint).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
					.font(.subheadline).accessibilityIdentifier("apiEndpoint")
				HStack {
					Button("Save API address") {
						do { try app.setEndpoint(endpoint); endpoint = app.endpoint; endpointError = nil }
						catch { endpointError = error.localizedDescription }
					}
					Spacer()
					Button("Use production server") {
						endpoint = TransitAPI.productionBaseURL.absoluteString
						do { try app.setEndpoint(endpoint); endpointError = nil } catch { endpointError = error.localizedDescription }
					}
				}
				.buttonStyle(.borderless).actionStyle().font(.subheadline)
				if let error = endpointError { Notice(text: error) }
			} header: { ListHeader("Development server") } footer: { Text("Use a reachable API base address ending in /api/v1/. Your favorites, filters, and theme are saved on this device.") }
			#endif
			Section {
				Group {
					Link("Web app", destination: URL(string: "https://juliet.nyc/subwaysForNerds/")!)
					Link("Taking the ferry?", destination: URL(string: "https://juliet.nyc/ferryTimesMobile/")!)
					Link("Usage statistics", destination: URL(string: "https://juliet.nyc/subwaysForNerds/stats")!)
					Link("A juliet.nyc project", destination: URL(string: "https://juliet.nyc")!)
				}
				.font(.subheadline).actionStyle()
				Text("Times are predictions, not promises. Location finds nearby and favorite stations in the app and, when allowed, widgets. Location and station search text stay on this device.").font(.caption).foregroundStyle(.secondary)
			} header: { ListHeader("About") }
		}.themedList().navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
			.task { endpoint = app.endpoint; await app.checkDownload() }
	}

	private func themeTile(_ theme: AppTheme) -> some View {
		let selected = theme.id == app.themeID
		return Button { app.setTheme(theme.id) } label: {
			HStack(spacing: 8) {
				Circle().fill(theme.background)
					.overlay { Circle().fill(theme.accent).padding(5) }
					.overlay { Circle().strokeBorder(app.theme.ink.opacity(0.25)) }
					.frame(width: 24, height: 24)
				Text(theme.name).font(.footnote.weight(.semibold)).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
				Spacer(minLength: 0)
			}
			.padding(8)
			.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
			.background(selected ? app.theme.accent.opacity(0.16) : app.theme.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
			.overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? app.theme.accent : .clear, lineWidth: 1.5) }
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.accessibilityIdentifier("theme_\(theme.id)")
		.accessibilityAddTraits(selected ? .isSelected : [])
	}

	private var offlineSection: some View {
		Section {
			if let saved = app.offlineManifest {
				VStack(alignment: .leading, spacing: 2) {
					LabeledContent("Saved", value: easternDate(saved.generatedAt, timeFormat: app.units.time)).font(.subheadline)
					LabeledContent("Saved size", value: ByteCountFormatter.string(fromByteCount: saved.byteLength, countStyle: .file)).font(.subheadline)
					Text("\(saved.counts.cars.formatted()) cars · \(saved.counts.events.formatted()) movement events").font(.caption)
					Text("History: \(easternDate(saved.historyStart, timeFormat: app.units.time)) – \(easternDate(saved.historyEnd, timeFormat: app.units.time))").font(.caption).foregroundStyle(.secondary)
				}
			} else { Text("Save the full roster, source records, last reports, and all retained movement history to this device.").font(.footnote) }
			if let available = app.availableManifest {
				VStack(alignment: .leading, spacing: 2) {
					LabeledContent("Download size", value: ByteCountFormatter.string(fromByteCount: available.downloadByteLength, countStyle: .file)).font(.subheadline)
					LabeledContent("Size after saving", value: ByteCountFormatter.string(fromByteCount: available.byteLength, countStyle: .file)).font(.subheadline)
					Text("Published \(easternDate(available.generatedAt, timeFormat: app.units.time))\(available.compression == "gzip" ? ". Allow free space for both sizes while the compressed download is prepared." : "")")
						.font(.caption).foregroundStyle(.secondary)
				}
				if app.isDownloading {
					VStack(alignment: .leading, spacing: 4) {
						ProgressView(value: app.downloadProgress ?? 0).accessibilityLabel("Fleet download progress")
						Text((app.downloadProgress ?? 0) >= 0.99 ? "Checking and saving fleet…" : "\(Int((app.downloadProgress ?? 0) * 100))% complete").font(.caption.monospacedDigit())
					}
					Button("Cancel download", role: .cancel) { app.cancelDownload() }.actionStyle().accessibilityIdentifier("cancelFleetDownload")
				}
			}
			if !app.isDownloading {
				HStack {
					if app.availableManifest != nil {
						Button(app.offlineManifest == nil ? "Download fleet" : "Update fleet download") { app.startDownload() }
							.disabled(app.offlineStore == nil).accessibilityIdentifier("downloadFleet")
						Spacer()
					}
					Button("Check for update") { Task { await app.checkDownload() } }.accessibilityIdentifier("checkFleetDownload")
				}
				.buttonStyle(.borderless).actionStyle().font(.subheadline).frame(minHeight: 44)
			}
			if app.offlineManifest != nil {
				HStack {
					Button("Browse saved fleet") { app.useSavedFleet = true; app.selectedTab = 1 }
						.actionStyle().accessibilityIdentifier("openSavedFleet")
					Spacer()
					if !app.isDownloading {
						Button("Delete download", role: .destructive) { confirmDelete = true }
							.foregroundStyle(.red).accessibilityIdentifier("deleteFleetDownload")
							// Attached to the button so iPad's popover points at it.
							.confirmationDialog("Delete the saved fleet?", isPresented: $confirmDelete, titleVisibility: .visible) {
								Button("Delete download", role: .destructive) { Task { await app.deleteDownload() } }
								Button("Cancel", role: .cancel) {}
							} message: { Text("You can download a new copy whenever you are connected.") }
					}
				}
				.buttonStyle(.borderless).font(.subheadline).frame(minHeight: 44)
			}
			if app.offlineStore == nil { Notice(text: "Download storage is unavailable. Try reopening the app.") }
			if let error = app.downloadError { Notice(text: error) }
		} header: { ListHeader("Offline fleet") } footer: { Text("Downloads happen only when you choose Download or Update. Keep the app open while downloading and saving. Saved reports are historical and retain their original history window until replaced or deleted. Failed downloads preserve your previous copy.") }
	}
}

struct StationSelectionSettingsView: View {
	@Environment(AppModel.self) private var app
	@FocusState private var editingRadius: Bool
	var widget = false
	private var selection: Binding<StationSelection> {
		Binding(get: { widget ? app.widgetPreferences.stationSelection.selection : app.stationSelection }, set: { value in
			if widget { var preferences = app.widgetPreferences.stationSelection; preferences.selection = value; app.setWidgetStationSelection(preferences) }
			else { app.setStationSelection(value) }
		})
	}
	var body: some View {
		List {
			if widget {
				Section {
					Toggle("Follow app station selection", isOn: Binding(get: { app.widgetPreferences.stationSelection.followApp }, set: { value in
						var preferences = app.widgetPreferences.stationSelection; preferences.followApp = value; app.setWidgetStationSelection(preferences)
					})).accessibilityIdentifier("widgetFollowAppStation")
					if app.widgetPreferences.stationSelection.followApp {
						LabeledContent("App setting", value: app.stationSelection.mode.title)
						if app.stationSelection.mode == .nearbyFavorite { LabeledContent("Radius", value: app.units.distance.radiusLabel(feet: app.stationSelection.radiusFeet)) }
					}
				} footer: { Text("Applies to Home and Lock Screen widgets. Your separate widget choice is kept when following the app.") }
			}
			if !widget || !app.widgetPreferences.stationSelection.followApp {
				StationSelectionControls(selection: selection, unit: app.units.distance, identifier: widget ? "widget" : "app", editingRadius: $editingRadius)
			}
		}.themedList().navigationTitle(widget ? "Widget station" : "Station selection").navigationBarTitleDisplayMode(.inline)
		.toolbar { ToolbarItemGroup(placement: .keyboard) {
			Spacer()
			Button("Done") { editingRadius = false }.accessibilityIdentifier((widget ? "widget" : "app") + "RadiusDone")
		} }
	}
}

private struct StationSelectionControls: View {
	@Binding var selection: StationSelection
	let unit: DistanceUnit
	let identifier: String
	@State private var radiusText = ""
	@State private var draftRadius = 5280.0
	var editingRadius: FocusState<Bool>.Binding
	private var validRadius: Int? { unit.radiusFeet(from: radiusText) }
	private func commitRadius() {
		if let radius = validRadius, radius != selection.radiusFeet { selection.radiusFeet = radius }
		radiusText = unit.radiusInput(feet: selection.radiusFeet)
		draftRadius = Double(selection.radiusFeet)
	}
	var body: some View {
		Section {
			Picker("Open automatically", selection: $selection.mode) {
				ForEach(StationSelection.Mode.allCases) { mode in Text(mode.title).tag(mode) }
			}.accessibilityIdentifier(identifier + "StationMode")
		} footer: { Text(identifier == "widget" ? "Uses your latest available location when Home and Lock Screen widgets refresh." : "Uses your location when the board opens. Choosing a station yourself always takes priority.") }
		if selection.mode == .nearbyFavorite {
			Section {
				HStack {
					Text("Radius (\(unit.radiusUnit.rawValue))")
					TextField(unit.radiusUnit.title, text: $radiusText).keyboardType(.decimalPad).multilineTextAlignment(.trailing).focused(editingRadius)
						.accessibilityLabel("Radius in \(unit.spokenName)").accessibilityIdentifier(identifier + "RadiusFeet")
						.onSubmit { commitRadius() }
				}
				Slider(value: Binding(get: { draftRadius }, set: { draftRadius = $0; radiusText = unit.radiusInput(feet: Int($0)) }), in: 1...26400, step: 1, onEditingChanged: { editing in if !editing { commitRadius() } })
					.accessibilityLabel("Favorite radius").accessibilityValue("\(unit.radiusInput(feet: Int(draftRadius))) \(unit.spokenName)").accessibilityIdentifier(identifier + "RadiusSlider")
					.accessibilityAdjustableAction { direction in
						let delta = direction == .increment ? 264 : direction == .decrement ? -264 : 0
						radiusText = unit.radiusInput(feet: min(26400, max(1, Int(draftRadius) + delta))); commitRadius()
					}
				Text(unit.radiusLabel(feet: Int(draftRadius))).font(.footnote).foregroundStyle(.secondary)
				if validRadius == nil { Text(unit.radiusRangeDescription).font(.footnote).foregroundStyle(.red) }
			} header: { ListHeader("Favorite radius") } footer: { Text("Choose the closest favorite only when it is inside this radius. At or beyond the radius, show the closest station. Distance is measured in a straight line, not walking distance.") }
			.onAppear { radiusText = unit.radiusInput(feet: selection.radiusFeet); draftRadius = Double(selection.radiusFeet) }
			.onChange(of: radiusText) { _, _ in if let radius = validRadius { draftRadius = Double(radius) } }
			.onChange(of: selection.radiusFeet) { _, value in radiusText = unit.radiusInput(feet: value); draftRadius = Double(value) }
			.onChange(of: unit) { _, _ in radiusText = unit.radiusInput(feet: selection.radiusFeet); draftRadius = Double(selection.radiusFeet) }
			.onChange(of: editingRadius.wrappedValue) { _, focused in if !focused { commitRadius() } }
			.onDisappear { commitRadius() }
		}
	}
}

struct FavoriteTrainsSettingsView: View {
	@Environment(AppModel.self) private var app
	@State private var removedCar: String?
	@State private var removedConsist: [String]?
	var body: some View {
		List {
			if removedCar != nil || removedConsist != nil {
				Section {
					HStack {
						Text("Favorite removed")
						Spacer()
						Button("Undo") {
							if let id = removedCar, !app.trainFavorites.cars.contains(id) { app.toggleFavoriteCar(id) }
							if let ids = removedConsist, !app.trainFavorites.containsConsist(ids) { app.toggleFavoriteConsist(ids) }
							if app.settingsError == nil { removedCar = nil; removedConsist = nil }
						}.accessibilityLabel("Undo removal").accessibilityIdentifier("undoTrainRemoval").frame(minHeight: 44)
					}
				}
			}
			Section {
				Picker("Match saved consists", selection: Binding(get: { app.trainFavorites.match }, set: { app.setTrainMatch($0) })) {
					ForEach(TrainFavorites.Match.allCases) { match in Text(match.title).tag(match) }
				}.accessibilityIdentifier("favoriteTrainMatch")
			} footer: { Text("Exact consist requires every saved car, in any order. Any member car highlights a train with at least one car from a saved consist. Individually saved cars always match. Changing this keeps all your favorites.") }
			Section {
				ForEach(app.trainFavorites.cars, id: \.self) { id in
					HStack {
						NavigationLink(TrainFavorites.label(id)) { FleetDetailView(id: id, kind: "cars") }
						Button { app.toggleFavoriteCar(id); if app.settingsError == nil { removedCar = id; removedConsist = nil } } label: { Image(systemName: "star.fill").frame(minWidth: 44, minHeight: 44) }
							.buttonStyle(.borderless).foregroundStyle(app.theme.accent).accessibilityLabel("Remove favorite car \(TrainFavorites.label(id))").accessibilityIdentifier("removeFavoriteCar_\(id)")
					}
				}
				if app.trainFavorites.cars.isEmpty { Text("Star a car in train or fleet details.").foregroundStyle(.secondary) }
			} header: { ListHeader("Cars") }
			Section {
				ForEach(app.trainFavorites.consists, id: \.self) { ids in
					HStack {
						VStack(alignment: .leading) {
							Text("\(ids.count) cars").font(.subheadline.weight(.semibold))
							Text(ids.map(TrainFavorites.label).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
						}
						Spacer(minLength: 4)
						Button { app.toggleFavoriteConsist(ids); if app.settingsError == nil { removedConsist = ids; removedCar = nil } } label: { Image(systemName: "star.fill").frame(minWidth: 44, minHeight: 44) }
							.buttonStyle(.borderless).foregroundStyle(app.theme.accent).accessibilityLabel("Remove favorite consist, \(ids.count) cars").accessibilityIdentifier("removeFavoriteConsist")
					}
				}
				if app.trainFavorites.consists.isEmpty { Text("Star a whole consist in train or fleet details.").foregroundStyle(.secondary) }
			} header: { ListHeader("Consists") }
		}.themedList().navigationTitle("Favorite trains").navigationBarTitleDisplayMode(.inline)
	}
}

struct FavoriteCarButton: View {
	@Environment(AppModel.self) private var app
	let id: String
	var body: some View {
		let saved = app.trainFavorites.cars.contains(id)
		Button { app.toggleFavoriteCar(id) } label: { Image(systemName: saved ? "star.fill" : "star").frame(minWidth: 44, minHeight: 44) }
			.buttonStyle(.borderless).foregroundStyle(app.theme.accent)
			.accessibilityLabel("Favorite car \(TrainFavorites.label(id))")
			.accessibilityIdentifier("favoriteCar_\(id)").accessibilityAddTraits(saved ? .isSelected : [])
	}
}

struct FavoriteConsistButton: View {
	@Environment(AppModel.self) private var app
	let ids: [String]
	var compact = false
	var body: some View {
		let saved = app.trainFavorites.containsConsist(ids)
		Button { app.toggleFavoriteConsist(ids) } label: {
			HStack {
				Image(systemName: saved ? "star.fill" : "star")
				if !compact { Text("Favorite consist"); Spacer(minLength: 0) }
			}.frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
		}.buttonStyle(.borderless).foregroundStyle(app.theme.accent)
			.accessibilityLabel("Favorite consist, \(ids.count) cars")
			.accessibilityIdentifier("favoriteConsist").accessibilityAddTraits(saved ? .isSelected : [])
	}
}
