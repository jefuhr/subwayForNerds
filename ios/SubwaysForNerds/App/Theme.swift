import SwiftUI

struct AppTheme: Identifiable {
	let id: String
	let name: String
	let note: String
	let accent: Color
	let background: Color
	let ink: Color
	let dark: Bool
	/// Selected rows use white text, so dark themes' light accents are deepened for contrast.
	var selection: Color { dark ? accent.mix(with: .black, by: 0.55) : accent }

	static let all: [AppTheme] = [
		.init(id: "subway", name: "Subway console", note: "Your next move, in focus", accent: Color(hex: 0xC7F36B), background: Color(hex: 0x111610), ink: Color(hex: 0xF6F9F1), dark: true),
		.init(id: "nyc-ferry", name: "NYC Ferry", note: "A little familiar blue", accent: Color(hex: 0x0075B8), background: Color(hex: 0xF2FAFF), ink: Color(hex: 0x12334B), dark: false),
		.init(id: "night", name: "Night", note: "For the late train home", accent: Color(hex: 0x7FD4FF), background: Color(hex: 0x0D1728), ink: Color(hex: 0xEAF6FF), dark: true),
		.init(id: "hello-kitty", name: "Hello Kitty", note: "Pink with a purpose", accent: Color(hex: 0xB62461), background: Color(hex: 0xFFF1F6), ink: Color(hex: 0x48233A), dark: false),
		.init(id: "cinnamoroll", name: "Cinnamoroll", note: "Sky blue and quiet", accent: Color(hex: 0x257AA9), background: Color(hex: 0xEEF9FF), ink: Color(hex: 0x28465A), dark: false),
		.init(id: "pompompurin", name: "Pompompurin", note: "Butter yellow, brown beret", accent: Color(hex: 0x8D5E14), background: Color(hex: 0xFFF7CF), ink: Color(hex: 0x543814), dark: false),
		.init(id: "kuromi", name: "Kuromi", note: "A little dark and twisty", accent: Color(hex: 0xCB9DE8), background: Color(hex: 0x21152C), ink: Color(hex: 0xFAEFFF), dark: true),
		.init(id: "windows-xp", name: "Windows XP", note: "Next stop: 2001", accent: Color(hex: 0x245CB5), background: Color(hex: 0xECE9D8), ink: Color(hex: 0x182B4A), dark: false),
		.init(id: "hacker", name: "Hacker", note: "Mind the terminal gap", accent: Color(hex: 0x00FF41), background: Color(hex: 0x050C07), ink: Color(hex: 0xBAFFCB), dark: true),
		.init(id: "burger-king", name: "Burger King", note: "Have it your way", accent: Color(hex: 0xD62300), background: Color(hex: 0xF5EBDC), ink: Color(hex: 0x502314), dark: false)
	]
}

extension Color {
	init(hex: UInt32) { self.init(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255) }
}

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
