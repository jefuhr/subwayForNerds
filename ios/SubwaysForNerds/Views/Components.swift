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

struct RouteStrip: View {
	let routes: [String]
	var body: some View {
		FlowLayout(spacing: 4) { ForEach(Array(routes.enumerated()), id: \.offset) { _, route in RouteBullet(route: route, small: true) } }
	}
}

/// Wraps children onto further lines instead of truncating them.
struct FlowLayout: Layout {
	var spacing: CGFloat = 4
	func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
		let frames = arrange(subviews, width: proposal.width ?? .infinity)
		return CGSize(width: frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
	}
	func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
		for (subview, frame) in zip(subviews, arrange(subviews, width: bounds.width)) {
			subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
		}
	}
	private func arrange(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
		var frames: [CGRect] = []
		var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
		for subview in subviews {
			let size = subview.sizeThatFits(.unspecified)
			if x > 0 && x + size.width > width { x = 0; y += lineHeight + spacing; lineHeight = 0 }
			frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
			x += size.width + spacing
			lineHeight = max(lineHeight, size.height)
		}
		return frames
	}
}

/// Section titles sized for dense lists; the system header style is as large as row content.
struct ListHeader: View {
	let title: String
	init(_ title: String) { self.title = title }
	var body: some View { Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).textCase(nil) }
}

struct Notice: View {
	let text: String
	var body: some View {
		HStack(alignment: .firstTextBaseline, spacing: 6) {
			Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
			Text(text).foregroundStyle(.secondary)
		}
		.font(.footnote).accessibilityElement(children: .combine)
	}
}

/// One aligned table row for all feeds instead of a two-line row per feed.
struct SourcesView: View {
	@Environment(AppModel.self) private var app
	let sources: [SourceState]
	let now: TimeInterval
	var body: some View {
		Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
			ForEach(sources) { source in
				GridRow {
					Circle()
						.fill(source.error == nil && Display.freshness(source.timestamp, now: now) == .live ? app.theme.accent : Color.orange)
						.frame(width: 6, height: 6)
					Text(source.id).fontWeight(.semibold)
					Text(Display.ageLabel(source.timestamp, now: now)).gridColumnAlignment(.trailing)
					Text("fetched \(Display.ageLabel(source.fetchedAt, now: now))").foregroundStyle(.secondary)
				}
				.accessibilityElement(children: .combine)
				if let error = source.error {
					GridRow {
						Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
						Text(error).foregroundStyle(.secondary).gridCellColumns(3)
					}
				}
			}
		}
		.font(.caption2.monospacedDigit())
	}
}

private func changeText(_ change: TripChange, stale: Bool) -> String {
	"\(stale ? "Last known · " : "")\(change.label)\(change.advisory == true ? " · advisory" : "")"
}

/// Colors follow the web board: amber for planned or scheduled, red for unplanned.
private struct ChangeGlyph: View {
	let change: TripChange
	let stale: Bool
	var body: some View {
		Image(systemName: stale || change.classification == "scheduled" ? "clock.fill" : "exclamationmark.triangle.fill")
			.foregroundStyle(change.classification == "unplanned" ? Color(hex: 0xE53935) : ["planned", "scheduled"].contains(change.classification) ? Color(hex: 0xD5A000) : .orange)
	}
}

/// Rows show icons only; train details list the full text.
struct ChangeIcons: View {
	let changes: [TripChange]
	var alerts: [String] = []
	let now: TimeInterval
	var cached = false
	var body: some View {
		if !changes.isEmpty || !alerts.isEmpty {
			HStack(spacing: 3) {
				ForEach(changes.prefix(4)) { change in
					let stale = Display.changeStale(change, now: now, cached: cached)
					ChangeGlyph(change: change, stale: stale)
						.accessibilityLabel("\(change.classification) · \(changeText(change, stale: stale))")
				}
				if changes.count > 4 { Text("+\(changes.count - 4)").foregroundStyle(.secondary) }
				if !alerts.isEmpty {
					Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(.orange)
						.accessibilityLabel("Alert · " + alerts.joined(separator: " · "))
				}
			}
			.font(.caption2)
		}
	}
}

struct ChangesSection: View {
	let changes: [TripChange]
	let now: TimeInterval
	var cached = false
	var body: some View {
		if !changes.isEmpty {
			Section {
				ForEach(changes) { change in
					let stale = Display.changeStale(change, now: now, cached: cached)
					DisclosureGroup {
						VStack(alignment: .leading, spacing: 3) {
							if let description = change.description { Text(description).font(.footnote) }
							Text(change.classification.capitalized + " · " + change.kind)
							if let before = change.before, let after = change.after { Text("\(before) → \(after)") }
							if !change.affectedStops.isEmpty { Text("Affected stops: " + change.affectedStops.joined(separator: ", ")) }
							ForEach(Array(change.evidence.enumerated()), id: \.offset) { _, evidence in
								Text("\(evidence.source) · \(Display.ageLabel(evidence.timestamp, now: now))\(evidence.unavailable == true ? " · unavailable" : "")").foregroundStyle(.secondary)
							}
							if !change.alertIds.isEmpty { Text("Alert IDs: " + change.alertIds.joined(separator: ", ")).textSelection(.enabled) }
						}
						.font(.caption)
					} label: {
						HStack(alignment: .firstTextBaseline, spacing: 6) {
							ChangeGlyph(change: change, stale: stale)
							Text(changeText(change, stale: stale))
						}
						.font(.footnote)
						.accessibilityElement(children: .combine)
						.accessibilityLabel("\(change.classification) · \(changeText(change, stale: stale))")
					}
				}
			} header: { ListHeader("Different from normal") } footer: {
				Text("Compared with weekday daytime service. Scheduled variations differ from disruptions; advisory notices may not affect every train.")
			}
		}
	}
}

/// Small labeled values in as many columns as fit (two on a phone), for identifiers that do not need a row each.
struct FactGrid: View {
	let facts: [(label: String, value: String)]
	var body: some View {
		LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12, alignment: .topLeading)], alignment: .leading, spacing: 8) {
			ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
				VStack(alignment: .leading, spacing: 1) {
					Text(fact.label).font(.caption2).foregroundStyle(.secondary)
					Text(fact.value).font(.subheadline)
				}
				.accessibilityElement(children: .combine)
			}
		}
	}
}

struct RawJSONView<Value: Encodable>: View {
	let value: Value
	var title = "Decoded feed & identifiers"
	private var json: String {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
		return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "Unavailable"
	}
	var body: some View {
		DisclosureGroup(title) {
			ScrollView(.horizontal) { Text(json).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
		}
	}
}

func boroughName(_ borough: String) -> String {
	["NJ": "New Jersey", "M": "Manhattan", "B": "Brooklyn", "Bk": "Brooklyn", "Bx": "Bronx", "Q": "Queens", "SI": "Staten Island"][borough] ?? borough
}

func easternDate(_ timestamp: TimeInterval) -> String {
	let formatter = DateFormatter()
	formatter.locale = Locale(identifier: "en_US")
	formatter.timeZone = TimeZone(identifier: "America/New_York")
	formatter.dateStyle = .medium
	formatter.timeStyle = .short
	return formatter.string(from: Date(timeIntervalSince1970: timestamp)) + " ET"
}

func poll(every seconds: Double, action: @escaping @MainActor () async -> Void) async {
	while !Task.isCancelled {
		await action()
		do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
	}
}
