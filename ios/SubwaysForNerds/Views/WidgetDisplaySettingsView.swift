import SwiftUI
import TransitCore

struct WidgetDisplaySettingsView: View {
	@Environment(AppModel.self) private var app
	var lockScreen = false
	private var options: WidgetDisplayOptions { lockScreen ? app.widgetPreferences.lockScreen.display : app.widgetPreferences.display }
	private var prefix: String { lockScreen ? "widgetLock" : "widget" }
	private func save(_ value: WidgetDisplayOptions) {
		if lockScreen {
			var settings = app.widgetPreferences.lockScreen; settings.display = value; app.setWidgetLockScreen(settings)
		} else { app.setWidgetDisplay(value) }
	}
	private func binding<T>(_ key: WritableKeyPath<WidgetDisplayOptions, T>) -> Binding<T> {
		Binding(get: { options[keyPath: key] }, set: { value in
			var updated = options; updated[keyPath: key] = value; save(updated)
		})
	}
	var body: some View {
		List {
			Section {
				Picker("Refresh interval", selection: binding(\.refreshInterval)) {
					ForEach(WidgetRefreshInterval.allCases) { Text($0.title).tag($0) }
				}.accessibilityIdentifier("\(prefix)RefreshInterval")
			} header: { ListHeader("Refresh") } footer: {
				Text("Requests new train data for \(lockScreen ? "Lock Screen" : "Home Screen") widgets. iOS controls the timing and may refresh less often. Countdown timers update between data refreshes.")
			}
			Section {
				Toggle("Compact rows", isOn: binding(\.compact)).accessibilityIdentifier("\(prefix)Compact")
				Picker("Trains per direction", selection: binding(\.trainsPerDirection)) {
					Text(lockScreen ? "Fit as many as possible" : "Fit automatically").tag(0)
					ForEach(1...(lockScreen ? 6 : 8), id: \.self) { Text("\($0)").tag($0) }
				}.accessibilityIdentifier("\(prefix)TrainCount")
				if lockScreen {
					Picker("Direction order", selection: Binding(get: { app.widgetPreferences.lockScreen.directionOrder }, set: { value in
						var settings = app.widgetPreferences.lockScreen; settings.directionOrder = value; app.setWidgetLockScreen(settings)
					})) {
						ForEach(LockScreenDirectionOrder.allCases) { Text($0.title).tag($0) }
					}.accessibilityIdentifier("widgetLockDirectionOrder")
				}
				Picker("Arrival display", selection: binding(\.timeStyle)) {
					ForEach(WidgetTimeStyle.allCases) { Text($0.title).tag($0) }
				}.accessibilityIdentifier("\(prefix)TimeStyle")
			} header: { ListHeader("Layout") } footer: {
				Text(lockScreen ? "Each direction gets its own column. Fit as many as possible fills the available space with up to six trains per direction. Compact rows and fewer details leave room for more trains. Counts adapt to widget and text size. PATH uses New Jersey left and New York right by default." : "Directions use arrows. Train counts adapt to the widget size and text size. Lock Screen display is configured separately.")
			}
			Section {
				if lockScreen {
					Toggle("Show service icons", isOn: Binding(get: { app.widgetPreferences.lockScreen.showService }, set: { value in
						var settings = app.widgetPreferences.lockScreen; settings.showService = value; app.setWidgetLockScreen(settings)
					})).accessibilityIdentifier("widgetLockShowService")
				}
				ForEach(lockScreen ? LockScreenWidgetOptions.fields : WidgetField.allCases) { field in
					Toggle(lockScreen && field == .service ? "Service details (local / express)" : field.title, isOn: Binding(get: { options.fields.contains(field) }, set: { enabled in
						var updated = options
						if enabled { updated.fields.insert(field) } else { updated.fields.remove(field) }
						save(updated)
					})).accessibilityIdentifier("\(prefix)Field_\(field.rawValue)")
				}
			} header: { ListHeader("Show information") } footer: {
				Text(lockScreen ? "These settings apply only to Lock Screen widgets. Rectangular widgets can show a station heading; circular widgets show selected train details. Inline widgets show routes and arrivals, in the selected direction order. Inline and circular countdowns use rounded minutes. Car details appear only when reported and still current. Saved predictions always remain marked as last estimates." : "These settings apply only to Home Screen widgets, in either filter mode. Car details appear only when reported and still current. Small widgets shorten details to fit. Saved predictions always remain marked as last estimates.")
			}
			Section {
				Button("Reset widget display") {
					if lockScreen { app.setWidgetLockScreen(LockScreenWidgetOptions()) } else { app.setWidgetDisplay(WidgetDisplayOptions()) }
				}.accessibilityIdentifier("\(prefix)DisplayReset")
			}
		}.themedList().navigationTitle(lockScreen ? "Lock Screen display" : "Home Screen display").navigationBarTitleDisplayMode(.inline)
	}
}
