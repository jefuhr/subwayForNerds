import SwiftUI
import TransitCore
import WidgetKit

struct SubwayWidgetView: View {
	@Environment(\.widgetFamily) private var environmentFamily
	@Environment(\.widgetRenderingMode) private var environmentRenderingMode
	@Environment(\.dynamicTypeSize) private var typeSize
	@ScaledMetric(relativeTo: .caption2) private var accessoryTextScale = 1.0
	let entry: SubwayWidgetEntry
	var previewFamily: WidgetFamily?
	var previewRenderingMode: WidgetRenderingMode?
	private var family: WidgetFamily { previewFamily ?? environmentFamily }
	private var renderingMode: WidgetRenderingMode { previewRenderingMode ?? environmentRenderingMode }
	private var theme: AppTheme { AppTheme.all.first { $0.id == entry.themeID } ?? AppTheme.all[0] }
	private var accessory: Bool { [.accessoryInline, .accessoryCircular, .accessoryRectangular].contains(family) }
	private var ink: Color { accessory || renderingMode != .fullColor ? .primary : theme.ink }
	private var accent: Color { accessory || renderingMode != .fullColor ? .primary : theme.accent }
	private var directions: [String] {
		let regional = entry.station?.routes.contains(where: { $0.hasPrefix("PATH-") }) == true
		return accessory ? entry.lockScreen.orderedDirections(regional: regional) : (regional ? ["TO_NY", "TO_NJ"] : ["NORTH", "SOUTH"])
	}
	private var options: WidgetDisplayOptions { accessory ? entry.lockScreen.display : entry.display }
	private func shows(_ field: WidgetField) -> Bool { options.fields.contains(field) }
	private var count: Int {
		if accessory { return entry.lockScreen.candidateCounts[0] }
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
			ViewThatFits(in: .horizontal) {
				ForEach(entry.lockScreen.candidateCounts, id: \.self) { limit in
					inlineText(limit: limit).font(options.compact ? .caption2 : .caption).lineLimit(1).fixedSize(horizontal: true, vertical: false)
						.accessibilityLabel(inlineSummary(limit: limit))
						.accessibilityIdentifier("widgetInlineDepartures")
				}
				inlineText(limit: 1).font(.caption2).lineLimit(1).minimumScaleFactor(0.6).accessibilityLabel(inlineSummary(limit: 1)).accessibilityIdentifier("widgetInlineDepartures")
			}
		} else {
			ViewThatFits(in: .vertical) {
				ForEach(entry.lockScreen.candidateCounts, id: \.self) { limit in
					accessoryColumns(limit: limit).fixedSize(horizontal: false, vertical: true)
				}
				// At very large text sizes, retain both arrivals and the mandatory
				// freshness label before spending space on optional information.
				accessoryColumns(limit: 1, simplified: true).fixedSize(horizontal: false, vertical: true)
			}
		}
	}
	private func accessoryColumns(limit: Int, simplified: Bool = false) -> some View {
		VStack(alignment: .leading, spacing: options.compact ? 1 : 3) {
			if !simplified, family == .accessoryRectangular, shows(.stationName) {
				Text(entry.station?.name ?? "").font(.system(size: 10 * accessoryTextScale, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7).accessibilityIdentifier("widgetStationName")
			}
			HStack(alignment: .top, spacing: family == .accessoryCircular ? 3 : 8) {
				ForEach(directions, id: \.self) { direction in accessoryDirection(direction, limit: limit, simplified: simplified) }
			}
			if estimated { Text("last est.").font(.system(size: simplified ? 7 : 7 * accessoryTextScale)) }
			else if !simplified, shows(.updatedAt), let time = sourceTime { Text("As of \(Display.clockTime(time))").font(.system(size: 7 * accessoryTextScale)).lineLimit(1).minimumScaleFactor(0.7) }
		}
	}
	private var accessoryArrivalSize: Double { (family == .accessoryCircular ? (options.compact ? 8 : 10) : (options.compact ? 10 : 12)) * accessoryTextScale }
	private var accessoryDetailSize: Double { (options.compact ? 6 : 8) * accessoryTextScale }
	private func accessoryDirection(_ direction: String, limit: Int, simplified: Bool) -> some View {
		let rows = nextDepartures(direction, limit: limit)
		let arrivalSize = simplified ? min(accessoryArrivalSize, family == .accessoryCircular ? 10 : 14) : accessoryArrivalSize
		let inlineDetails = family == .accessoryRectangular && options.compact && options.fields.isDisjoint(with: [.service, .carNumbers, .location])
		return VStack(alignment: .leading, spacing: options.compact ? 1 : 3) {
			if family == .accessoryCircular { Text(arrow(direction)).font(.system(size: arrivalSize, weight: .bold)).accessibilityHidden(true) }
			HStack(alignment: .top, spacing: 2) {
				if family != .accessoryCircular { Text(arrow(direction)).font(.system(size: arrivalSize, weight: .bold)).accessibilityHidden(true) }
				VStack(alignment: .leading, spacing: options.compact ? 1 : 3) {
					if rows.isEmpty { Text("—").font(.system(size: arrivalSize)).accessibilityLabel("No matching trains") }
					ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
						let details = accessoryDetails(row)
						VStack(alignment: .leading, spacing: 0) {
							if family == .accessoryCircular {
								if entry.lockScreen.showService, Display.regionalRoute(row.route) != nil {
									serviceBadge(row.route, size: simplified ? 6 : accessoryDetailSize).accessibilityIdentifier("widgetServiceIcon_\(direction)_\(index)")
								}
								HStack(spacing: 1) {
									if entry.lockScreen.showService, Display.regionalRoute(row.route) == nil {
										serviceBadge(row.route, size: min(12, arrivalSize)).accessibilityIdentifier("widgetServiceIcon_\(direction)_\(index)")
									}
									Text(compactArrival(row, includeRoute: false)).font(.system(size: arrivalSize, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.35).layoutPriority(1)
								}
							} else {
								HStack(spacing: 2) {
									if entry.lockScreen.showService { serviceBadge(row.route, size: min(14, arrivalSize)).accessibilityIdentifier("widgetServiceIcon_\(direction)_\(index)") }
									time(row).fontWeight(.semibold).monospacedDigit().lineLimit(1).minimumScaleFactor(0.65).layoutPriority(1)
									if inlineDetails, !simplified, !details.isEmpty { Text(details).font(.system(size: accessoryDetailSize)).lineLimit(1).minimumScaleFactor(0.7) }
								}.font(.system(size: arrivalSize))
							}
							if !simplified, shows(.destination) { Text(row.destination).font(.system(size: accessoryDetailSize)).lineLimit(1).minimumScaleFactor(0.7) }
							if !simplified, !inlineDetails, !details.isEmpty { Text(details).font(.system(size: accessoryDetailSize)).lineLimit(1).minimumScaleFactor(0.7) }
						}
						.accessibilityElement(children: previewFamily == nil ? .ignore : .contain)
						.accessibilityLabel("\(direction), \(routeName(row.route)) to \(row.destination), \(compactArrival(row)), \(estimated ? "last estimate" : "estimated arrival"), \(accessoryDetails(row))")
						.accessibilityIdentifier("widgetDeparture_\(direction)_\(index)")
					}
				}.frame(maxWidth: .infinity, alignment: .leading)
			}
		}.frame(maxWidth: .infinity, alignment: .leading)
	}
	private func nextDepartures(_ direction: String, limit: Int) -> [Departure] {
		Array(groups.filter { $0.direction == direction }.flatMap(\.departures).sorted {
			let a = $0.time ?? .infinity, b = $1.time ?? .infinity
			return a == b ? $0.key < $1.key : a < b
		}.prefix(limit))
	}
	private func compactArrival(_ row: Departure, includeRoute: Bool = true) -> String {
		let countdown = Display.countdown(row.time, timestamp: row.timestamp, now: entry.date.timeIntervalSince1970, cached: entry.cached)
		let clock = options.timeStyle == .clock || countdown.unit != "min"
		let value = clock ? shortClockTime(row.time) : countdown.value + "m"
		return (includeRoute && entry.lockScreen.showService ? routeName(row.route) : "") + value
	}
	@ViewBuilder private func serviceBadge(_ route: String, size: Double) -> some View {
		let label = routeName(route)
		Group {
			if Display.regionalRoute(route) == nil, label.count == 1 {
				Image(systemName: "\(label.lowercased()).circle.fill").resizable().scaledToFit().frame(width: size, height: size)
			} else {
				Text(label).font(.system(size: size * 0.8, weight: .heavy)).lineLimit(1).minimumScaleFactor(0.35).padding(.horizontal, 1)
					.overlay(RoundedRectangle(cornerRadius: 2).stroke(lineWidth: 0.5))
			}
		}.widgetAccentable().accessibilityLabel("Service \(label)")
	}
	private func shortClockTime(_ time: TimeInterval?) -> String { String(Display.clockTime(time).split(whereSeparator: \.isWhitespace).first ?? "—") }
	private func accessoryDetails(_ row: Departure) -> String {
		var selected = options
		selected.fields = options.fields.intersection(Set(LockScreenWidgetOptions.fields))
		return widgetTrainDetails(row, options: selected, now: entry.date.timeIntervalSince1970, cached: entry.cached)
	}
	@ViewBuilder private func time(_ departure: Departure) -> some View {
		let countdown = Display.countdown(departure.time, timestamp: departure.timestamp, now: entry.date.timeIntervalSince1970, cached: entry.cached)
		if accessory, options.compact, departure.time != nil, options.timeStyle == .clock || countdown.unit != "min" { Text(shortClockTime(departure.time)) }
		else if options.timeStyle == .clock, let arrival = departure.time { Text(Display.clockTime(arrival)) }
		else if options.timeStyle == .minutes { Text(countdown.value + (countdown.unit == "min" ? "m" : "")) }
		else if countdown.unit == "min", let arrival = departure.time, arrival > entry.date.timeIntervalSince1970 {
			Text(timerInterval: entry.date...Date(timeIntervalSince1970: arrival), countsDown: true, showsHours: false)
		} else { Text(countdown.value) }
	}
	private func inline(_ direction: String, limit: Int) -> String {
		let rows = nextDepartures(direction, limit: limit)
		return arrow(direction) + (rows.isEmpty ? "—" : rows.map { compactArrival($0) }.joined(separator: " "))
	}
	private func inlineSummary(limit: Int) -> String {
		directions.map { inline($0, limit: limit) }.joined(separator: "  ") + (estimated ? " · est." : "")
	}
	private func inlineText(limit: Int) -> Text {
		var text = Text("")
		for (column, direction) in directions.enumerated() {
			if column > 0 { text = Text("\(text)  ") }
			text = Text("\(text)\(arrow(direction))")
			let rows = nextDepartures(direction, limit: limit)
			if rows.isEmpty { text = Text("\(text)—") }
			for (index, row) in rows.enumerated() {
				if index > 0 { text = Text("\(text) ") }
				if entry.lockScreen.showService {
					let route = routeName(row.route)
					let badge = Display.regionalRoute(row.route) == nil && route.count == 1 ? Text(Image(systemName: "\(route.lowercased()).circle.fill")) : Text(route)
					text = Text("\(text)\(badge)")
				}
				text = Text("\(text)\(compactArrival(row, includeRoute: false))")
			}
		}
		if estimated { text = Text("\(text) · est.") }
		return text
	}
	private func routeName(_ route: String) -> String { Display.regionalRoute(route)?.label ?? Display.displayRoute(route) }
	private func arrow(_ direction: String) -> String { direction == "NORTH" ? "↑" : direction == "SOUTH" ? "↓" : direction == "TO_NY" ? "→" : "←" }
	private func groupLabel(_ group: DepartureGroup) -> String {
		switch entry.preference.view { case .track: return "Track \(group.track ?? "?") · \(group.partId)"; default: return group.label }
	}
}
