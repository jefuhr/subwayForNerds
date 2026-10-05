import SwiftUI

struct ThemedList: ViewModifier {
	@Environment(AppModel.self) private var app
	func body(content: Content) -> some View {
		// Explicit, so split-view sidebars keep the same cards as full-width lists.
		content.listStyle(.insetGrouped)
			.scrollContentBackground(.hidden)
			.listSectionSpacing(.compact)
			.contentMargins(.top, 4, for: .scrollContent)
			.environment(\.defaultMinListRowHeight, 30)
			.background(app.theme.background)
			.foregroundStyle(app.theme.ink)
	}
}

/// Themed lists set the ink as the foreground style, which also recolors buttons and links.
/// Actions use the accent explicitly: selectable lists tint with the deeper selection color.
struct ActionStyle: ViewModifier {
	@Environment(AppModel.self) private var app
	func body(content: Content) -> some View { content.foregroundStyle(app.theme.accent) }
}

/// Chips draw a 30-point capsule inside a 44-point hit area so rows of them stay compact.
struct Chip: ViewModifier {
	@Environment(AppModel.self) private var app
	var selected: Bool
	func body(content: Content) -> some View {
		content.font(.caption.weight(.semibold)).lineLimit(1)
			.padding(.horizontal, 8)
			.frame(minWidth: 44, minHeight: 30)
			.foregroundStyle(selected ? app.theme.accent : app.theme.ink)
			.background(selected ? app.theme.accent.opacity(0.18) : .clear, in: Capsule())
			.overlay { Capsule().strokeBorder(selected ? app.theme.accent : app.theme.ink.opacity(0.2)) }
			.frame(minHeight: 44)
			.contentShape(Rectangle())
	}
}

extension View {
	func themedList() -> some View { modifier(ThemedList()) }
	func chip(selected: Bool = false) -> some View { modifier(Chip(selected: selected)) }
	func actionStyle() -> some View { modifier(ActionStyle()) }
}
