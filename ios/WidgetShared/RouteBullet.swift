import SwiftUI
import TransitCore

struct RouteBullet: View {
	let route: String
	var small = false
	/// Widgets use exact sizes so rows can be measured; the app keeps text styles for Dynamic Type.
	var diameter: Double?
	/// Tinted widgets draw every view in one color, so the label is cut out of its badge instead.
	var knockout = false
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
		if let diameter { sized(diameter) }
		else if let regional = Display.regionalRoute(route) {
			Text(regional.label)
				.font(.system(small ? .caption2 : .caption, weight: .heavy))
				.foregroundStyle(regionalInk)
				.multilineTextAlignment(.center)
				.padding(.horizontal, 8).padding(.vertical, small ? 5 : 8)
				.background { regionalFill(regional) }
				.clipShape(RoundedRectangle(cornerRadius: 7))
				.accessibilityLabel(regional.name)
		} else {
			Text(Display.displayRoute(route))
			.font(.system(small ? .caption : .body, design: .default, weight: .black))
			.foregroundStyle(lineInk)
			.frame(minWidth: small ? 25 : 34, minHeight: small ? 25 : 34)
			.background(color, in: Circle())
			.accessibilityLabel("Line \(Display.displayRoute(route))")
		}
	}
	private var regionalInk: Color { route.hasPrefix("PATH-") && route != "PATH-NWK-WTC" ? .black : .white }
	private var lineInk: Color { ["N", "Q", "R", "W", "G", "B", "D", "F", "FX", "M"].contains(route) ? .black : .white }
	@ViewBuilder private func regionalFill(_ regional: RegionalRoute) -> some View {
		if regional.colors.count == 2 {
			LinearGradient(stops: [.init(color: Color(hex: regional.colors[0]), location: 0), .init(color: Color(hex: regional.colors[0]), location: 0.5), .init(color: Color(hex: regional.colors[1]), location: 0.5), .init(color: Color(hex: regional.colors[1]), location: 1)], startPoint: .topLeading, endPoint: .bottomTrailing)
		} else { Color(hex: regional.colors[0]) }
	}
	/// Fixed-size badge for widgets. Regional names keep the row height and grow
	/// sideways; where the name does not fit, the line's color alone remains.
	@ViewBuilder private func sized(_ diameter: Double) -> some View {
		if let regional = Display.regionalRoute(route) {
			ViewThatFits(in: .horizontal) {
				cutout(Text(regional.label).font(.system(size: diameter * 0.52, weight: .heavy)).foregroundStyle(regionalInk).lineLimit(1))
					.padding(.horizontal, diameter * 0.28).frame(height: diameter).fixedSize()
					.background { if knockout { Color.white } else { regionalFill(regional) } }
				Color.clear.frame(width: diameter * 1.5, height: diameter)
					.background { if knockout { Color.white } else { regionalFill(regional) } }
			}
			.clipShape(RoundedRectangle(cornerRadius: diameter * 0.3, style: .continuous))
			.compositingGroup()
			.accessibilityElement(children: .ignore)
			.accessibilityLabel(regional.name)
		} else {
			cutout(Text(Display.displayRoute(route)).font(.system(size: diameter * (Display.displayRoute(route).count > 1 ? 0.44 : 0.6), weight: .heavy)).foregroundStyle(lineInk).lineLimit(1).minimumScaleFactor(0.6))
				.frame(width: diameter, height: diameter)
				.background(knockout ? Color.white : color, in: Circle())
				.compositingGroup()
				.accessibilityLabel("Line \(Display.displayRoute(route))")
		}
	}
	@ViewBuilder private func cutout(_ label: some View) -> some View {
		if knockout { label.blendMode(.destinationOut) } else { label }
	}
}
