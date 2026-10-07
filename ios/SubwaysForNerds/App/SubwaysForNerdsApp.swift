import SwiftUI

@main @MainActor
struct SubwaysForNerdsApp: App {
	@State private var app = AppModel()
	@State private var account = AccountModel()
	var body: some Scene {
		WindowGroup { AppRootView().environment(app).environment(account).tint(app.theme.accent).preferredColorScheme(app.theme.dark ? .dark : .light) }
	}
}

struct AppRootView: View {
	@Environment(AppModel.self) private var app
	@Environment(\.scenePhase) private var phase
	@Environment(AccountModel.self) private var account

	var body: some View {
		@Bindable var app = app
		TabView(selection: $app.selectedTab) {
			Tab("Board", systemImage: "tram.fill", value: 0) { BoardSplitView().id(app.stationID) }
			Tab("Fleet", systemImage: "train.side.front.car", value: 1) { FleetSplitView() }
			Tab("Settings", systemImage: "gearshape", value: 2) { NavigationStack { SettingsView() } }
		}
		.onOpenURL { url in
			if url.isFileURL { app.previewSettingsFile(url) }
			else if !account.handle(url) { app.openWidgetURL(url) }
		}
		.sheet(item: $app.pendingSettingsImport) { file in SettingsImportPreview(file: file) }
		.onChange(of: app.connected) { _, connected in
			if connected { Task { await account.reconnect() } }
		}
		.onChange(of: phase) { _, phase in
			if phase != .active { app.suspend(background: phase == .background) }
		}
		.task(id: phase) {
			guard phase == .active, !Task.isCancelled else { return }
			await account.run(app: app)
		}
		.task(id: phase) {
			guard phase == .active, !Task.isCancelled else { return }
			await app.runWhileActive()
		}
	}
}
