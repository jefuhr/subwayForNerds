import SwiftUI
import TransitCore

struct RouteBullet: View {
	let route: String
	var small = false
	private var color: Color {
		switch route {
		case "1", "2", "3": Color(hex: 0xEE352E)
		case "4", "5", "6", "6X": Color(hex: 0x00933C)
		case "7", "7X": Color(hex: 0xB933AD)
		case "A", "C", "E": Color(hex: 0x0039A6)
		case "B", "D", "F", "FX", "M": Color(hex: 0xFF6319)
		case "N", "Q", "R", "W": Color(hex: 0xFCCC0A)
		case "G": Color(hex: 0x6CBE45)
		case "J", "Z": Color(hex: 0x996633)
		default: Color(hex: 0x62666B)
		}
	}
	var body: some View {
		if let regional = Display.regionalRoute(route) {
			Text(regional.label)
				.font(.system(small ? .caption2 : .caption, weight: .heavy))
				.foregroundStyle(route.hasPrefix("PATH-") && route != "PATH-NWK-WTC" ? Color.black : Color.white)
				.multilineTextAlignment(.center)
				.padding(.horizontal, 8).padding(.vertical, small ? 5 : 8)
				.background {
					if regional.colors.count == 2 {
						LinearGradient(stops: [.init(color: Color(hex: regional.colors[0]), location: 0), .init(color: Color(hex: regional.colors[0]), location: 0.5), .init(color: Color(hex: regional.colors[1]), location: 0.5), .init(color: Color(hex: regional.colors[1]), location: 1)], startPoint: .topLeading, endPoint: .bottomTrailing)
					} else { Color(hex: regional.colors[0]) }
				}
				.clipShape(RoundedRectangle(cornerRadius: 7))
				.accessibilityLabel(regional.name)
		} else {
			Text(Display.displayRoute(route))
			.font(.system(small ? .caption : .body, design: .default, weight: .black))
			.foregroundStyle(["N", "Q", "R", "W", "G", "B", "D", "F", "FX", "M"].contains(route) ? Color.black : Color.white)
			.frame(minWidth: small ? 25 : 34, minHeight: small ? 25 : 34)
			.background(color, in: Circle())
			.accessibilityLabel("Line \(Display.displayRoute(route))")
		}
	}
}
