import SwiftUI
import TransitCore
import WidgetKit

struct SubwayWidgetView: View {
	@Environment(\.widgetFamily) private var environmentFamily
	@Environment(\.widgetRenderingMode) private var environmentRenderingMode
	@Environment(\.dynamicTypeSize) private var typeSize
	let entry: SubwayWidgetEntry
	var previewFamily: WidgetFamily?
	var previewRenderingMode: WidgetRenderingMode?
	private var family: WidgetFamily { previewFamily ?? environmentFamily }
	private var renderingMode: WidgetRenderingMode { previewRenderingMode ?? environmentRenderingMode }
	private var theme: AppTheme { AppTheme.all.first { $0.id == entry.themeID } ?? AppTheme.all[0] }
	private var accessory: Bool { [.accessoryInline, .accessoryCircular, .accessoryRectangular].contains(family) }
	private var ink: Color { accessory || renderingMode != .fullColor ? .primary : theme.ink }
	private var accent: Color { accessory || renderingMode != .fullColor ? .primary : theme.accent }
	private var directions: [String] { entry.station?.routes.contains(where: { $0.hasPrefix("PATH-") }) == true ? ["TO_NY", "TO_NJ"] : ["NORTH", "SOUTH"] }
	private var options: WidgetDisplayOptions { entry.display }
	private func shows(_ field: WidgetField) -> Bool { options.fields.contains(field) }
	private var count: Int {
		if accessory { return 2 }
		if typeSize.isAccessibilitySize { return 1 }
		let capacity: Int
		switch family { case .systemSmall: capacity = options.compact ? 2 : 1; case .systemMedium: capacity = options.compact ? 3 : 2; case .systemLarge: capacity = options.compact ? 6 : 4; case .systemExtraLarge: capacity = options.compact ? 8 : 6; default: capacity = 1 }
		return options.trainsPerDirection == 0 ? capacity : min(capacity, max(1, options.trainsPerDirection))
	}
	private var groups: [DepartureGroup] {
		guard let board = entry.board else { return [] }
		return widgetDepartures(board, preference: entry.preference, limit: count, now: entry.date.timeIntervalSince1970, cached: entry.cached)
	}
	private var sourceTime: TimeInterval? { entry.board?.departures.map(\.timestamp).min() }
	private var estimated: Bool { entry.cached || Display.freshness(sourceTime, now: entry.date.timeIntervalSince1970) != .live }

	var body: some View {
		Group {
			if accessory { accessoryContent }
			else { homeContent }
		}
		.foregroundStyle(ink)
		.containerBackground(for: .widget) { theme.background }
		.widgetURL(entry.url)
	}

	private var homeContent: some View {
		VStack(alignment: .leading, spacing: options.compact ? 3 : 8) {
			HStack(alignment: .top, spacing: 4) {
				if shows(.stationName) || entry.station == nil { Text(entry.station?.name ?? "Your next train").font(.system(size: options.compact ? 13 : 17, weight: .semibold)).lineLimit(2).minimumScaleFactor(0.8).fixedSize(horizontal: false, vertical: true).layoutPriority(1).widgetAccentable().accessibilityIdentifier("widgetStationName") }
				Spacer(minLength: 0)
				if shows(.refreshButton) { Button(intent: RefreshSubwayWidget()) { Image(systemName: "arrow.clockwise").font(.caption).padding(5) }
					.buttonStyle(.plain).foregroundStyle(accent).accessibilityLabel("Refresh departures").accessibilityIdentifier("widgetRefresh") }
			}
			if let message = entry.message, entry.board == nil { Text(message).font(.caption).fixedSize(horizontal: false, vertical: true) }
			else {
				HStack(alignment: .top, spacing: family == .systemSmall ? 6 : 10) { ForEach(directions, id: \.self) { direction in directionColumn(direction) } }
			}
			Spacer(minLength: 0)
			VStack(alignment: .leading, spacing: 2) {
				if let time = sourceTime, shows(.updatedAt) || estimated { Text("\(estimated ? "Last estimate" : "As of") \(Display.clockTime(time))").font(.system(size: family == .systemSmall ? 9 : 10)) }
				if let notice = entry.locationNotice { Text(notice).font(.system(size: 9)).lineLimit(1).minimumScaleFactor(0.8) }
			}.foregroundStyle(ink.opacity(0.7))
		}
	}

	private func directionColumn(_ direction: String) -> some View {
		VStack(alignment: .leading, spacing: options.compact ? 3 : 6) {
			Text(arrow(direction)).font(.caption.weight(.semibold)).foregroundStyle(accent).lineLimit(1).minimumScaleFactor(0.7)
			let selected = groups.filter { $0.direction == direction }
			if selected.isEmpty { Text("No matching trains").font(.caption2).foregroundStyle(.secondary) }
			ForEach(selected) { group in
				if shows(.groupHeaders), entry.preference.view != .direction, family != .systemSmall { Text(groupLabel(group)).font(.system(size: 9)).lineLimit(1).foregroundStyle(ink.opacity(0.7)) }
				ForEach(group.departures) { departure in trainRow(departure, detailed: true) }
			}
		}.frame(maxWidth: .infinity, alignment: .leading)
	}

	private func trainRow(_ departure: Departure, detailed: Bool) -> some View {
		VStack(alignment: .leading, spacing: 1) {
			HStack(spacing: 3) {
				if options.compact {
					RouteBullet(route: departure.route, small: true).scaleEffect(0.72).frame(width: Display.regionalRoute(departure.route) == nil ? 18 : 36, height: 18).widgetAccentable()
				} else { RouteBullet(route: departure.route, small: true).widgetAccentable() }
				if shows(.destination), family != .systemSmall { Text(departure.destination).font(.system(size: options.compact ? 10 : 11)).lineLimit(1) }
				Spacer(minLength: 0)
				time(departure).font(.system(size: options.compact ? 13 : 16, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
			}
			if shows(.destination), family == .systemSmall { Text(departure.destination).font(.system(size: 8)).lineLimit(1) }
			let details = widgetTrainDetails(departure, options: options, now: entry.date.timeIntervalSince1970, cached: entry.cached)
			if !details.isEmpty { Text(details).font(.system(size: options.compact ? 8 : 9)).foregroundStyle(ink.opacity(0.75)).lineLimit(1).minimumScaleFactor(0.75) }
		}
		.accessibilityElement(children: .ignore)
		.accessibilityLabel("\(Display.displayRoute(departure.route)) to \(departure.destination), \(Display.countdown(departure.time, timestamp: departure.timestamp, now: entry.date.timeIntervalSince1970, cached: entry.cached).value), \(estimated ? "last estimate" : "estimated arrival"), \(widgetTrainDetails(departure, options: options, now: entry.date.timeIntervalSince1970, cached: entry.cached))")
	}

	@ViewBuilder private var accessoryContent: some View {
		if entry.station == nil || entry.board == nil {
			Label(entry.message ?? "Open Subway Nerds", systemImage: "tram.fill").font(.caption).lineLimit(2)
		} else if family == .accessoryInline {
			Text("\(inline(directions[0]))  \(inline(directions[1]))\(estimated ? " · est." : "")")
				.font(.caption).lineLimit(1).minimumScaleFactor(0.7).accessibilityIdentifier("widgetInlineDepartures")
		} else {
			VStack(alignment: .leading, spacing: 1) {
				if family == .accessoryRectangular, shows(.stationName) { Text(entry.station?.name ?? "").font(.system(size: 10, weight: .semibold)).lineLimit(1) }
				ForEach(directions, id: \.self) { direction in accessoryDirection(direction) }
				if estimated { Text("last est.").font(.system(size: 7)) }
			}
		}
	}
	private func accessoryDirection(_ direction: String) -> some View {
		let rows = nextTwo(direction)
		return HStack(alignment: .top, spacing: family == .accessoryCircular ? 2 : 4) {
			Text(arrow(direction)).font(.system(size: 10, weight: .bold))
			ForEach(0..<2, id: \.self) { index in
				VStack(alignment: .leading, spacing: 0) {
					if index < rows.count {
						let row = rows[index]
						if family == .accessoryCircular {
							Text(compactArrival(row)).font(.system(size: estimated ? 7 : 9, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
						} else {
							HStack(spacing: 2) {
								Text(routeName(row.route)).font(.system(size: 10, weight: .heavy))
								time(row).font(.system(size: 11, weight: .semibold)).monospacedDigit()
							}.lineLimit(1).minimumScaleFactor(0.65)
						}
						let details = accessoryDetails(row)
						if !details.isEmpty { Text(details).font(.system(size: family == .accessoryCircular ? 6 : 7)).lineLimit(1).minimumScaleFactor(0.7) }
					} else { Text("—").font(.system(size: 10)) }
				}
				.frame(maxWidth: .infinity, alignment: .leading)
				.accessibilityElement(children: .combine)
				.accessibilityIdentifier("widgetDeparture_\(direction)_\(index)")
			}
		}
	}
	private func nextTwo(_ direction: String) -> [Departure] {
		Array(groups.filter { $0.direction == direction }.flatMap(\.departures).sorted {
			let a = $0.time ?? .infinity, b = $1.time ?? .infinity
			return a == b ? $0.key < $1.key : a < b
		}.prefix(2))
	}
	private func compactArrival(_ row: Departure) -> String {
		let countdown = Display.countdown(row.time, timestamp: row.timestamp, now: entry.date.timeIntervalSince1970, cached: entry.cached)
		let clock = options.timeStyle == .clock || countdown.unit != "min"
		let value = clock ? Display.clockTime(row.time).replacingOccurrences(of: " AM", with: "").replacingOccurrences(of: " PM", with: "") : countdown.value + "m"
		return routeName(row.route) + value
	}
	private func accessoryDetails(_ row: Departure) -> String {
		var selected = options
		selected.fields = options.fields.intersection([.carType, .carCount])
		return widgetTrainDetails(row, options: selected, now: entry.date.timeIntervalSince1970, cached: entry.cached)
	}
	@ViewBuilder private func time(_ departure: Departure) -> some View {
		let countdown = Display.countdown(departure.time, timestamp: departure.timestamp, now: entry.date.timeIntervalSince1970, cached: entry.cached)
		if options.timeStyle == .clock, let arrival = departure.time { Text(Display.clockTime(arrival)) }
		else if options.timeStyle == .minutes { Text(countdown.value + (countdown.unit == "min" ? "m" : "")) }
		else if countdown.unit == "min", let arrival = departure.time, arrival > entry.date.timeIntervalSince1970 {
			Text(timerInterval: entry.date...Date(timeIntervalSince1970: arrival), countsDown: true, showsHours: false)
		} else { Text(countdown.value) }
	}
	private func inline(_ direction: String) -> String {
		let rows = nextTwo(direction)
		return arrow(direction) + (rows.isEmpty ? "— —" : rows.map(compactArrival).joined(separator: " "))
	}
	private func routeName(_ route: String) -> String { Display.regionalRoute(route)?.label ?? Display.displayRoute(route) }
	private func arrow(_ direction: String) -> String { direction == "NORTH" ? "↑" : direction == "SOUTH" ? "↓" : direction == "TO_NY" ? "→" : "←" }
	private func groupLabel(_ group: DepartureGroup) -> String {
		switch entry.preference.view { case .track: return "Track \(group.track ?? "?") · \(group.partId)"; default: return group.label }
	}
}
