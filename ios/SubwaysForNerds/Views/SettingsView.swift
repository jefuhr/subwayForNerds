import SwiftUI
import TransitCore

struct SettingsView: View {
	@Environment(AppModel.self) private var app
	@Environment(\.horizontalSizeClass) private var sizeClass
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
				LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: sizeClass == .regular ? 5 : 2), spacing: 8) {
					ForEach(AppTheme.all) { theme in themeTile(theme) }
				}
				.listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
			} header: { ListHeader("Theme") }
			Section {
				NavigationLink("Display and information") { WidgetDisplaySettingsView() }.accessibilityIdentifier("widgetDisplaySettings")
				Toggle("Match app filters", isOn: Binding(get: { app.widgetPreferences.matchAppFilters }, set: { app.setWidgetMatchApp($0) }))
					.accessibilityIdentifier("widgetMatchAppFilters")
				if !app.widgetPreferences.matchAppFilters {
					ForEach(app.favoriteStations) { station in
						NavigationLink(station.name) { WidgetFiltersView(station: station) }
							.accessibilityIdentifier("widgetFilters_\(station.id)")
					}
				}
				if app.favorites.isEmpty { Text("Favorite a station on the Board to set up your widgets.").font(.footnote).foregroundStyle(.secondary) }
				if app.widgetStore == nil { Notice(text: "Widget sharing is unavailable. Build both targets with the same App Group enabled.") }
			} header: { ListHeader("Widgets") } footer: {
				Text("All widget sizes show both directions at your closest favorite. Match app filters uses that station’s lines and grouping. Turn it off to keep separate filters per station. iOS schedules updates; use the widget’s refresh button for a new report.")
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
				VStack(alignment: .leading, spacing: 0) {
					Text(theme.name).font(.footnote.weight(.semibold))
					Text(theme.note).font(.caption2).foregroundStyle(.secondary)
				}
				.lineLimit(2).multilineTextAlignment(.leading)
				Spacer(minLength: 0)
			}
			.padding(8)
			.frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
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
					LabeledContent("Saved", value: easternDate(saved.generatedAt)).font(.subheadline)
					LabeledContent("Saved size", value: ByteCountFormatter.string(fromByteCount: saved.byteLength, countStyle: .file)).font(.subheadline)
					Text("\(saved.counts.cars.formatted()) cars · \(saved.counts.events.formatted()) movement events").font(.caption)
					Text("History: \(easternDate(saved.historyStart)) – \(easternDate(saved.historyEnd))").font(.caption).foregroundStyle(.secondary)
				}
			} else { Text("Save the full roster, source records, last reports, and all retained movement history to this device.").font(.footnote) }
			if let available = app.availableManifest {
				VStack(alignment: .leading, spacing: 2) {
					LabeledContent("Download size", value: ByteCountFormatter.string(fromByteCount: available.downloadByteLength, countStyle: .file)).font(.subheadline)
					LabeledContent("Size after saving", value: ByteCountFormatter.string(fromByteCount: available.byteLength, countStyle: .file)).font(.subheadline)
					Text("Published \(easternDate(available.generatedAt))\(available.compression == "gzip" ? ". Allow free space for both sizes while the compressed download is prepared." : "")")
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
