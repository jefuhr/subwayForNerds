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
			} header: { ListHeader("Refresh") }
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
			} header: { ListHeader("Layout") }
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
			} header: { ListHeader("Show information") }
			Section {
				Button("Reset widget display") {
					if lockScreen { app.setWidgetLockScreen(LockScreenWidgetOptions()) } else { app.setWidgetDisplay(WidgetDisplayOptions()) }
				}.accessibilityIdentifier("\(prefix)DisplayReset")
			}
		}.themedList().navigationTitle(lockScreen ? "Lock Screen display" : "Home Screen display").navigationBarTitleDisplayMode(.inline)
	}
}
