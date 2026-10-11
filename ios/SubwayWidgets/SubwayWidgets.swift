import SwiftUI
import WidgetKit
import TransitCore

@main
struct SubwayWidgets: Widget {
	var body: some WidgetConfiguration {
		StaticConfiguration(kind: WidgetSharedStore.kind, provider: SubwayTimelineProvider()) { entry in
			SubwayWidgetView(entry: entry)
		}
		.configurationDisplayName("Nearby trains")
		.description("Both directions at your chosen nearby station. Set station selection and line filters in the app’s Settings → Widgets.")
		.supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge, .accessoryInline, .accessoryCircular, .accessoryRectangular])
	}
}
