import SwiftUI

@main @MainActor
struct SubwaysForNerdsApp: App {
	@State private var app = AppModel()
	var body: some Scene {
		WindowGroup { AppRootView().environment(app).tint(app.theme.accent).preferredColorScheme(app.theme.dark ? .dark : .light) }
	}
}

struct AppRootView: View {
	@Environment(AppModel.self) private var app
	@Environment(\.scenePhase) private var phase

	var body: some View {
		@Bindable var app = app
		TabView(selection: $app.selectedTab) {
			Tab("Board", systemImage: "tram.fill", value: 0) { BoardSplitView().id(app.stationID) }
			Tab("Fleet", systemImage: "train.side.front.car", value: 1) { FleetSplitView() }
			Tab("Settings", systemImage: "gearshape", value: 2) { NavigationStack { SettingsView() } }
		}
		.task(id: phase) {
			guard !Task.isCancelled else { return }
			if phase == .active { await app.runWhileActive() } else { app.suspend() }
		}
	}
}
