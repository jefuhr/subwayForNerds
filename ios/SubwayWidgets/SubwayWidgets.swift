import SwiftUI
import WidgetKit
import TransitCore

@main
struct SubwayWidgets: Widget {
	var body: some WidgetConfiguration {
		StaticConfiguration(kind: WidgetSharedStore.kind, provider: SubwayTimelineProvider()) { entry in
			SubwayWidgetView(entry: entry)
		}
		.configurationDisplayName("Closest favorite trains")
		.description("Both directions at your closest favorite station. Set line filters in the app’s Settings → Widgets.")
		.supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge, .accessoryInline, .accessoryCircular, .accessoryRectangular])
	}
}
