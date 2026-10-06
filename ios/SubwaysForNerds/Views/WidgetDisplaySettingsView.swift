import SwiftUI
import TransitCore

struct WidgetDisplaySettingsView: View {
	@Environment(AppModel.self) private var app
	private func binding<T>(_ key: WritableKeyPath<WidgetDisplayOptions, T>) -> Binding<T> {
		Binding(get: { app.widgetPreferences.display[keyPath: key] }, set: { value in
			var options = app.widgetPreferences.display; options[keyPath: key] = value; app.setWidgetDisplay(options)
		})
	}
	var body: some View {
		List {
			Section {
				Toggle("Compact rows", isOn: binding(\.compact)).accessibilityIdentifier("widgetCompact")
				Picker("Trains per direction", selection: binding(\.trainsPerDirection)) {
					Text("Fit automatically").tag(0)
					ForEach(1...8, id: \.self) { Text("\($0)").tag($0) }
				}.accessibilityIdentifier("widgetTrainCount")
				Picker("Arrival display", selection: binding(\.timeStyle)) {
					ForEach(WidgetTimeStyle.allCases) { Text($0.title).tag($0) }
				}.accessibilityIdentifier("widgetTimeStyle")
			} header: { ListHeader("Layout") } footer: { Text("Directions use arrows. Train counts adapt to the widget size and text size. Lock Screen widgets show the next two trains in each direction.") }
			Section {
				ForEach(WidgetField.allCases) { field in
					Toggle(field.title, isOn: Binding(get: { app.widgetPreferences.display.fields.contains(field) }, set: { enabled in
						var options = app.widgetPreferences.display
						if enabled { options.fields.insert(field) } else { options.fields.remove(field) }
						app.setWidgetDisplay(options)
					})).accessibilityIdentifier("widgetField_\(field.rawValue)")
				}
			} header: { ListHeader("Show information") } footer: { Text("These display settings apply to every widget, in either filter mode. Car details appear only when reported and still current. Small widgets shorten details to fit. Saved predictions always remain marked as last estimates.") }
			Section { Button("Reset widget display") { app.setWidgetDisplay(WidgetDisplayOptions()) }.accessibilityIdentifier("widgetDisplayReset") }
		}.themedList().navigationTitle("Widget display").navigationBarTitleDisplayMode(.inline)
	}
}
