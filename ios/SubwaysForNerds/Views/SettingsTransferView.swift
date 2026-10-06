import SwiftUI
import UniformTypeIdentifiers
import TransitCore

extension UTType {
	static let nerdsSettings = UTType(exportedAs: "nyc.juliet.subwaysfornerds.settings", conformingTo: .json)
}
struct NerdsFileDocument: FileDocument {
	static var readableContentTypes: [UTType] { [.nerdsSettings] }
	var data: Data
	init(data: Data) { self.data = data }
	init(configuration: ReadConfiguration) throws {
		guard let data = configuration.file.regularFileContents else { throw SettingsError.invalid }; self.data = data
	}
	func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
struct SettingsTransferSection: View {
	@Environment(AppModel.self) private var app
	@State private var importing = false
	@State private var exporting = false
	@State private var document = NerdsFileDocument(data: Data())
	@State private var error: String?
	var body: some View {
		Section {
			Button("Export settings") {
				do { document = NerdsFileDocument(data: try NerdsSettingsFile(settings: app.portableSettings, lastStation: app.stationID).data()); error = nil; exporting = true }
				catch { self.error = error.localizedDescription }
			}.accessibilityIdentifier("exportSettings")
			Button("Import settings") { importing = true }.accessibilityIdentifier("importSettings")
			if let message = error ?? app.settingsError { Text(message).foregroundStyle(.red).font(.footnote).accessibilityIdentifier("settingsError") }
		} header: { ListHeader("Move your settings") } footer: {
			Text("Move favorites, themes, station filters, and widget preferences between devices with a .nerds file. No account is needed.")
		}
		.fileImporter(isPresented: $importing, allowedContentTypes: [.nerdsSettings]) { result in
			switch result { case .success(let url): app.previewSettingsFile(url); case .failure(let failure): error = failure.localizedDescription }
		}
		.fileExporter(isPresented: $exporting, document: document, contentType: .nerdsSettings, defaultFilename: "subway-settings-" + Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))) { result in
			if case .failure(let failure) = result { error = failure.localizedDescription }
		}
	}
}
@MainActor func settingsLabel(_ path: String, app: AppModel) -> String {
	let labels = ["favorites": "Favorites", "theme": "Theme", "stations": "Stations", "widgets": "Widgets", "display": "Display", "lockScreen": "Lock Screen", "directionOrder": "Direction order", "showService": "Service icons", "fields": "Shown information", "compact": "Compact rows", "trainsPerDirection": "Trains per direction", "timeStyle": "Arrival display", "matchAppFilters": "Match app filters", "direction": "Direction", "routes": "Lines", "view": "Board grouping"]
	return path.split(separator: "/").map { part in
		let key = part.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
		return app.stations.first(where: { $0.id == key })?.name ?? labels[key] ?? key.capitalized
	}.joined(separator: " · ")
}
func settingsValue(_ value: JSONValue?) -> String {
	guard let value else { return "Not set" }
	switch value {
	case .bool(let on): return on ? "On" : "Off"
	case .string(let text): return AppTheme.all.first(where: { $0.id == text })?.name ?? WidgetField(rawValue: text)?.title ?? text
	case .number(let number): return number.formatted()
	case .array(let array): return array.isEmpty ? "None" : array.map { settingsValue($0) }.joined(separator: ", ")
	case .object(let object): return object.keys.sorted().map { $0.capitalized + ": " + settingsValue(object[$0]) }.joined(separator: " · ")
	case .null: return "Not set"
	}
}
struct SettingsChangesView: View {
	@Environment(AppModel.self) private var app
	let from: PortableSettings
	let to: PortableSettings
	var body: some View {
		ForEach((try? SettingsMerge.changes(from: from, to: to)) ?? []) { change in
			VStack(alignment: .leading, spacing: 4) {
				Text(settingsLabel(change.path, app: app)).font(.subheadline.weight(.semibold))
				Text("Current: " + settingsValue(change.local)).font(.caption).foregroundStyle(.secondary)
				Text("New: " + settingsValue(change.remote)).font(.caption)
			}
		}
	}
}
struct SettingsImportPreview: View {
	@Environment(AppModel.self) private var app
	@Environment(AccountModel.self) private var account
	@Environment(\.dismiss) private var dismiss
	let file: NerdsSettingsFile
	@State private var error: String?
	var body: some View {
		NavigationStack {
			List {
				Section {
					Text("\(file.settings.favorites.count) favorites")
					Text("Last station: " + (app.stations.first(where: { $0.id == file.lastStation })?.name ?? file.lastStation))
					Text(account.account == nil ? "This replaces settings on this device." : "This replaces settings on this device and will sync to your account.")
				}
				Section("Changes") { SettingsChangesView(from: app.portableSettings, to: file.settings) }
				Section {
					Button("Replace settings", role: .destructive) {
						do { try app.importSettings(file); dismiss() } catch { self.error = error.localizedDescription }
					}.accessibilityIdentifier("confirmSettingsImport")
					if let error { Text(error).foregroundStyle(.red) }
				}
			}.themedList().navigationTitle("Import settings").navigationBarTitleDisplayMode(.inline)
			.toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { app.pendingSettingsImport = nil; dismiss() } } }
		}
	}
}
