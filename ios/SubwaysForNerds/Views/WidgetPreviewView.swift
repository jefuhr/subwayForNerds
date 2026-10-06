#if DEBUG
import SwiftUI
import WidgetKit
import TransitCore

/// Uses the extension's actual view for repeatable layout QA, including families
/// that cannot all be placed on one simulator's Home and Lock Screens.
struct WidgetPreviewView: View {
	@Environment(AppModel.self) private var app
	@State private var family: WidgetFamily = .systemSmall
	@State private var scenario = "Live"
	@State private var tinted = false
	@State private var largeText = false
	private let families: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge, .accessoryInline, .accessoryCircular, .accessoryRectangular]
	private func name(_ family: WidgetFamily) -> String {
		switch family { case .systemSmall: "Small"; case .systemMedium: "Medium"; case .systemLarge: "Large"; case .systemExtraLarge: "Extra large"; case .accessoryInline: "Inline"; case .accessoryCircular: "Circular"; default: "Rectangular" }
	}
	/// Home Screen sizes are the iPhone 17's; accessory sizes are the larger iPhones'.
	private var size: CGSize {
		switch family {
		case .systemSmall: CGSize(width: 164, height: 164)
		case .systemMedium: CGSize(width: 350, height: 164)
		case .systemLarge: CGSize(width: 350, height: 365)
		case .systemExtraLarge: CGSize(width: 720, height: 365)
		case .accessoryInline: CGSize(width: 270, height: 24)
		case .accessoryCircular: CGSize(width: 76, height: 76)
		default: CGSize(width: 172, height: 76)
		}
	}
	private var accessory: Bool { [.accessoryInline, .accessoryCircular, .accessoryRectangular].contains(family) }
	/// Home Screen sizes use WidgetKit's default content margins. Circular widgets
	/// inset themselves to their circle; rectangular previews keep a conservative inset.
	private var inset: Double {
		switch family { case .accessoryInline, .accessoryCircular: 0; case .accessoryRectangular: 12; default: 16 }
	}
	private var shape: AnyShape { family == .accessoryCircular ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: accessory ? 20 : 24, style: .continuous)) }
	private var entry: SubwayWidgetEntry {
		var value = SubwayWidgetEntry.example()
		value.themeID = app.themeID
		value.display = app.widgetPreferences.display
		value.lockScreen = app.widgetPreferences.lockScreen
		if scenario == "Saved", var board = value.board { value.cached = true; board.departures = board.departures.map { var row = $0; row.timestamp -= 600; return row }; value.board = board }
		if scenario == "No favorites" { value.station = nil; value.board = nil; value.message = "Add a favorite in the app." }
		if scenario == "No matches" { value.preference.routes = ["A"] }
		if scenario == "Track groups" { value.preference.view = .track }
		if scenario == "Long name" { value.station?.name = "Times Sq–42 St / Port Authority Bus Terminal" }
		if scenario == "Location unavailable" { value.locationNotice = "Location unavailable · saved favorite" }
		if scenario == "Regional" {
			value.station?.name = "Journal Square"; value.station?.routes = ["PATH-JSQ-33"]
			if var board = value.board { board.departures = board.departures.map { var row = $0; row.route = "PATH-JSQ-33"; row.direction = row.direction == "NORTH" ? "TO_NY" : "TO_NJ"; return row }; value.board = board }
		}
		return value
	}
	var body: some View {
		ScrollView {
			VStack(spacing: 18) {
				Picker("Size", selection: $family) { ForEach(families, id: \.self) { Text(name($0)).tag($0) } }
					.accessibilityIdentifier("widgetPreviewFamily")
				Picker("Scenario", selection: $scenario) { ForEach(["Live", "Saved", "No favorites", "No matches", "Long name", "Regional", "Location unavailable", "Track groups"], id: \.self) { Text($0).tag($0) } }
					.accessibilityIdentifier("widgetPreviewScenario")
				Toggle("Tinted", isOn: $tinted).accessibilityIdentifier("widgetPreviewTinted")
				Toggle("Large text", isOn: $largeText).accessibilityIdentifier("widgetPreviewLargeText")
				ScrollView(.horizontal) {
					SubwayWidgetView(entry: entry, previewFamily: family, previewRenderingMode: tinted ? .accented : .fullColor)
						.dynamicTypeSize(largeText ? .accessibility3 : .large)
						.padding(inset)
						.frame(width: size.width, height: size.height)
						.background {
							// The preview cannot draw WidgetKit's container background, tinted glass, or a wallpaper.
							if accessory || tinted { Color(hex: tinted && !accessory ? 0x2C2C2E : 0x111610) }
							else { SubwayWidgetBackground(theme: app.theme) }
						}
						.clipShape(shape)
						.accessibilityElement(children: .contain).accessibilityIdentifier("widgetPreviewCanvas")
						// Lock Screen and tinted content is white on a dark stand-in, whatever the app theme.
						.environment(\.colorScheme, .dark)
				}
				Text("Widget view preview · \(name(family)) · \(scenario)").font(.caption).accessibilityIdentifier("widgetPreviewDescription")
			}.padding()
		}.navigationTitle("Widget previews").navigationBarTitleDisplayMode(.inline)
	}
}
#endif
