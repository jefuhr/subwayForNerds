import SwiftUI
import TransitCore
import WidgetKit

struct SubwayWidgetView: View {
	@Environment(\.widgetFamily) private var environmentFamily
	@Environment(\.widgetRenderingMode) private var environmentRenderingMode
	@ScaledMetric(relativeTo: .caption2) private var accessoryTextScale = 1.0
	@ScaledMetric(relativeTo: .footnote) private var homeTextScale = 1.0
	let entry: SubwayWidgetEntry
	var previewFamily: WidgetFamily?
	var previewRenderingMode: WidgetRenderingMode?
	private var family: WidgetFamily { previewFamily ?? environmentFamily }
	private var renderingMode: WidgetRenderingMode { previewRenderingMode ?? environmentRenderingMode }
	private var theme: AppTheme { AppTheme.all.first { $0.id == entry.themeID } ?? AppTheme.all[0] }
	private var accessory: Bool { [.accessoryInline, .accessoryCircular, .accessoryRectangular].contains(family) }
	private var fullColor: Bool { !accessory && renderingMode == .fullColor }
	private var ink: Color { fullColor ? theme.ink : .primary }
	private var accent: Color { fullColor ? theme.accent : .primary }
	/// Secondary text keeps the theme's ink hue rather than a system gray.
	private var muted: Color { ink.opacity(0.62) }
	private var directions: [String] {
		let regional = entry.station?.routes.contains(where: { $0.hasPrefix("PATH-") }) == true
		return accessory ? entry.lockScreen.orderedDirections(regional: regional) : (regional ? ["TO_NY", "TO_NJ"] : ["NORTH", "SOUTH"])
	}
	private var options: WidgetDisplayOptions { accessory ? entry.lockScreen.display : entry.display }
	private func shows(_ field: WidgetField) -> Bool { options.fields.contains(field) }
	private func groups(limit: Int) -> [DepartureGroup] {
		guard let board = entry.board else { return [] }
		return widgetDepartures(board, preference: entry.preference, limit: limit, now: entry.date.timeIntervalSince1970, cached: entry.cached)
	}
	private var groups: [DepartureGroup] { groups(limit: entry.lockScreen.candidateCounts[0]) }
	private var sourceTime: TimeInterval? { entry.board?.departures.map(\.timestamp).min() }
	private var estimated: Bool { entry.cached || Display.freshness(sourceTime, now: entry.date.timeIntervalSince1970) != .live }

	var body: some View {
		Group {
			if accessory { accessoryContent }
			else { homeContent }
		}
		.foregroundStyle(ink)
		.containerBackground(for: .widget) { background }
		.widgetURL(entry.url)
	}

	@ViewBuilder private var background: some View {
		if accessory { theme.background } else { SubwayWidgetBackground(theme: theme) }
	}

	// MARK: Home Screen

	private var metrics: HomeMetrics { HomeMetrics(small: family == .systemSmall, compact: options.compact, scale: family == .systemSmall ? 1 : min(homeTextScale, 1.35)) }
	/// Each size starts one train above what it usually holds; the layout keeps the most
	/// that fit, so larger text shows fewer trains. Every candidate tried costs a layout
	/// pass for each timeline entry, so the lists stay short.
	private var homeCandidateCounts: [Int] {
		switch family {
		case .systemSmall: return options.candidateCounts(maximum: 3)
		case .systemMedium: return options.candidateCounts(maximum: 4)
		case .systemLarge: return options.candidateCounts(maximum: 9)
		default: return options.candidateCounts(maximum: 14)
		}
	}

	private var homeContent: some View {
		VStack(alignment: .leading, spacing: metrics.headerSpacing) {
			homeHeader
			if let message = entry.message, entry.board == nil {
				messageView(message).frame(maxHeight: .infinity, alignment: .top)
			} else {
				ViewThatFits(in: .vertical) {
					ForEach(homeCandidateCounts, id: \.self) { limit in homeColumns(limit: limit).fixedSize(horizontal: false, vertical: true) }
				}
				.frame(maxHeight: .infinity, alignment: .top)
			}
			if family == .systemSmall ? showsReportTime : footerNotice { homeFooter }
		}
	}
	private var showsReportTime: Bool { sourceTime != nil && (shows(.updatedAt) || estimated) }
	/// Only the tallest sizes spell out why a saved favorite is shown; shorter ones mark the name with an icon.
	private var footerNotice: Bool { entry.locationNotice != nil && [.systemLarge, .systemExtraLarge].contains(family) }

	private var homeHeader: some View {
		HStack(alignment: .center, spacing: 6) {
			if shows(.stationName) || entry.station == nil {
				// Short widgets keep the name to one line, so a long name never costs a row of trains.
				Text(entry.station?.name ?? "Your next train")
					.font(.system(size: metrics.title, weight: .semibold))
					.lineLimit([.systemSmall, .systemMedium].contains(family) ? 1 : 2).minimumScaleFactor(0.7).fixedSize(horizontal: false, vertical: true)
					.layoutPriority(1).widgetAccentable().accessibilityIdentifier("widgetStationName")
			}
			if let notice = entry.locationNotice, !footerNotice {
				Image(systemName: "location.slash.fill").font(.system(size: metrics.footer, weight: .semibold)).foregroundStyle(muted).accessibilityLabel(notice)
			}
			Spacer(minLength: 0)
			if family != .systemSmall { reportTime }
			if shows(.refreshButton) {
				Button(intent: RefreshSubwayWidget()) {
					Image(systemName: "arrow.clockwise").font(.system(size: metrics.refresh * 0.45, weight: .bold))
						.frame(width: metrics.refresh, height: metrics.refresh)
						.background(accent.opacity(0.16), in: Circle())
				}
				.buttonStyle(.plain).foregroundStyle(accent)
				.accessibilityLabel("Refresh departures").accessibilityIdentifier("widgetRefresh")
			}
		}
	}

	/// Small widgets put the report time under the trains; larger ones keep it beside the refresh button.
	@ViewBuilder private var reportTime: some View {
		if let time = sourceTime, showsReportTime {
			HStack(spacing: 4) {
				Circle().fill(estimated ? Color.orange : accent).frame(width: 5, height: 5)
				Text("\(estimated ? "Last estimate" : "As of") \(Display.clockTime(time, format: entry.units.time))").lineLimit(1)
			}
			.font(.system(size: metrics.footer, weight: .medium)).foregroundStyle(muted).fixedSize()
			.accessibilityElement(children: .combine).accessibilityIdentifier("widgetUpdatedAt")
		}
	}

	private var homeFooter: some View {
		VStack(alignment: .leading, spacing: 2) {
			if family == .systemSmall { reportTime }
			if footerNotice, let notice = entry.locationNotice {
				Label(notice, systemImage: "location.slash.fill").labelStyle(CompactLabel(spacing: 4))
					.font(.system(size: metrics.footer, weight: .medium)).foregroundStyle(muted).lineLimit(1)
			}
		}
	}

	private func messageView(_ message: String) -> some View {
		Label { Text(message).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "tram.fill").foregroundStyle(accent) }
			.labelStyle(CompactLabel(spacing: 6))
			.font(.system(size: metrics.small ? 12 : 13, weight: .medium)).foregroundStyle(ink.opacity(0.85))
	}

	private func homeColumns(limit: Int) -> some View {
		let selected = groups(limit: limit)
		return HStack(alignment: .top, spacing: metrics.columnSpacing) {
			ForEach(directions, id: \.self) { direction in directionColumn(direction, groups: selected.filter { $0.direction == direction }) }
		}
	}

	/// The direction arrow sits in a gutter beside its trains, so it costs no row of its own.
	private func directionColumn(_ direction: String, groups: [DepartureGroup]) -> some View {
		let headers = shows(.groupHeaders) && entry.preference.view != .direction && family != .systemSmall
		var items: [ColumnItem] = []
		for group in groups {
			if headers { items.append(ColumnItem(id: "header-" + group.id, header: groupLabel(group))) }
			for departure in group.departures { items.append(ColumnItem(id: departure.id, departure: departure, index: items.filter { $0.departure != nil }.count)) }
		}
		return HStack(alignment: .top, spacing: metrics.small ? 3 : 5) {
			Image(systemName: arrowSymbol(direction)).font(.system(size: metrics.arrow, weight: .heavy)).foregroundStyle(accent)
				.frame(height: headers && !groups.isEmpty ? metrics.groupHeader * 1.25 : metrics.bullet)
				.accessibilityLabel(Display.directionLabel(direction))
			VStack(alignment: .leading, spacing: metrics.rowSpacing) {
				if groups.isEmpty { Text(metrics.small ? "No matches" : "No matching trains").font(.system(size: metrics.detail + 1, weight: .medium)).foregroundStyle(muted).lineLimit(1).minimumScaleFactor(0.8).frame(minHeight: metrics.bullet) }
				ForEach(items) { item in
					if let header = item.header {
						Text(header).font(.system(size: metrics.groupHeader, weight: .semibold)).textCase(.uppercase).tracking(0.3).foregroundStyle(muted).lineLimit(1)
							.padding(.bottom, -metrics.rowSpacing / 2)
					} else if let departure = item.departure { homeRow(departure, direction: direction, index: item.index) }
				}
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	private func homeRow(_ departure: Departure, direction: String, index: Int) -> some View {
		let details = widgetTrainDetails(departure, options: options, now: entry.date.timeIntervalSince1970, cached: entry.cached)
		let countdown = Display.countdown(departure.time, timestamp: departure.timestamp, now: entry.date.timeIntervalSince1970, cached: entry.cached, timeFormat: entry.units.time)
		return Group {
			if family == .systemSmall {
				VStack(alignment: .leading, spacing: 1) {
					HStack(spacing: 3) { bullet(departure.route); Spacer(minLength: 0); homeTime(departure, countdown: countdown) }
					if shows(.destination) { Text(departure.destination).font(.system(size: metrics.destination, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8) }
					if !details.isEmpty { Text(details).font(.system(size: metrics.detail)).foregroundStyle(muted).lineLimit(1).minimumScaleFactor(0.85) }
				}
			} else {
				HStack(alignment: .top, spacing: 5) {
					bullet(departure.route)
					VStack(alignment: .leading, spacing: 1) {
						HStack(alignment: .firstTextBaseline, spacing: 4) {
							if shows(.destination) { Text(departure.destination).font(.system(size: metrics.destination, weight: .medium)).lineLimit(1).minimumScaleFactor(0.9) }
							// Extra large columns are wide enough to keep details on the arrival line.
							if family == .systemExtraLarge, !details.isEmpty { Text(details).font(.system(size: metrics.detail + 1)).foregroundStyle(muted).lineLimit(1).padding(.leading, 4) }
							Spacer(minLength: 0)
							homeTime(departure, countdown: countdown)
						}
						.frame(minHeight: metrics.bullet)
						if family != .systemExtraLarge, !details.isEmpty { Text(details).font(.system(size: metrics.detail)).foregroundStyle(muted).lineLimit(1) }
					}
				}
			}
		}
		.accessibilityElement(children: .ignore)
		.accessibilityLabel("\(Display.displayRoute(departure.route)) to \(departure.destination), \(countdown.value), \(estimated ? "last estimate" : "estimated arrival"), \(details)")
		.accessibilityIdentifier("widgetDeparture_\(direction)_\(index)")
	}

	private func bullet(_ route: String) -> some View {
		RouteBullet(route: route, diameter: metrics.bullet, knockout: !fullColor).widgetAccentable()
	}

	/// Arrival values are the strongest text in a row and minutes stay small beside them.
	/// Clock times omit AM/PM, leaving room for destinations; the report time carries it.
	@ViewBuilder private func homeTime(_ departure: Departure, countdown: Countdown) -> some View {
		let now = entry.date.timeIntervalSince1970
		let value = Font.system(size: metrics.time, weight: .semibold).monospacedDigit()
		let unit = Font.system(size: metrics.time * 0.62, weight: .semibold)
		if options.timeStyle == .countdown, countdown.unit == "min", let arrival = departure.time, arrival > now {
			// WidgetKit lays timers out at an unpredictable width, so a hidden sample
			// of the widest value sizes the box and the digits keep to its trailing edge.
			Text(arrival - now >= 600 ? "00:00" : "0:00").font(value).lineLimit(1).fixedSize().hidden()
				.overlay(alignment: .trailing) {
					Text(timerInterval: entry.date...Date(timeIntervalSince1970: arrival), countsDown: true, showsHours: false)
						.font(value).multilineTextAlignment(.trailing).lineLimit(1)
				}
		} else if options.timeStyle == .minutes, countdown.unit == "min" {
			Text("\(Text(countdown.value).font(value))\(Text(" min").font(unit))").lineLimit(1).fixedSize()
		} else if departure.time != nil, options.timeStyle == .clock || countdown.unit == "last estimate" {
			Text(shortClockTime(departure.time)).font(value).lineLimit(1).fixedSize()
		} else { Text(countdown.value).font(value).lineLimit(1).fixedSize() }
	}

	// MARK: Lock Screen

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
		} else if family == .accessoryCircular {
			ZStack {
				AccessoryWidgetBackground()
				// Keep rows inside the circle's inscribed square.
				accessoryFit.padding(10)
			}
		} else { accessoryFit }
	}
	/// Circular widgets also check width, so large text drops details rather than truncating arrivals.
	private var accessoryFit: some View {
		ViewThatFits(in: family == .accessoryCircular ? [.horizontal, .vertical] : .vertical) {
			ForEach(entry.lockScreen.candidateCounts, id: \.self) { limit in
				accessoryColumns(limit: limit).fixedSize(horizontal: false, vertical: true)
			}
			// At very large text sizes, retain both arrivals and the mandatory
			// freshness label before spending space on optional information.
			accessoryColumns(limit: 1, simplified: true).fixedSize(horizontal: false, vertical: true)
		}
	}
	private func accessoryColumns(limit: Int, simplified: Bool = false) -> some View {
		let circular = family == .accessoryCircular
		return VStack(alignment: circular ? .center : .leading, spacing: options.compact ? 1 : 3) {
			if !simplified, family == .accessoryRectangular, shows(.stationName) {
				Text(entry.station?.name ?? "").font(.system(size: 11 * accessoryTextScale, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7).accessibilityIdentifier("widgetStationName")
			}
			HStack(alignment: .top, spacing: circular ? 3 : 10) {
				ForEach(directions, id: \.self) { direction in accessoryDirection(direction, limit: limit, simplified: simplified) }
			}
			if estimated { Text("last est.").font(.system(size: simplified ? 7 : 7 * accessoryTextScale, weight: .medium)) }
			else if !simplified, shows(.updatedAt), let time = sourceTime { Text("As of \(Display.clockTime(time, format: entry.units.time))").font(.system(size: 7 * accessoryTextScale, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7) }
		}
	}
	private var accessoryArrivalSize: Double { (family == .accessoryCircular ? (options.compact ? 8 : 10) : (options.compact ? 10 : 12)) * accessoryTextScale }
	private var accessoryDetailSize: Double { (options.compact ? 6 : 8) * accessoryTextScale }
	private func accessoryDirection(_ direction: String, limit: Int, simplified: Bool) -> some View {
		let rows = nextDepartures(direction, limit: limit)
		let circular = family == .accessoryCircular
		let arrivalSize = simplified ? min(accessoryArrivalSize, circular ? 10 : 14) : accessoryArrivalSize
		let inlineDetails = family == .accessoryRectangular && options.compact && options.fields.isDisjoint(with: [.service, .carNumbers, .location])
		return VStack(alignment: circular ? .center : .leading, spacing: options.compact ? 1 : 3) {
			if circular { Image(systemName: arrowSymbol(direction)).font(.system(size: arrivalSize * 0.85, weight: .heavy)).accessibilityHidden(true) }
			HStack(alignment: .top, spacing: 2) {
				if !circular { Image(systemName: arrowSymbol(direction)).font(.system(size: arrivalSize * 0.8, weight: .heavy)).frame(height: arrivalSize * 1.2).accessibilityHidden(true) }
				VStack(alignment: circular ? .center : .leading, spacing: options.compact ? 1 : 3) {
					if rows.isEmpty { Text("—").font(.system(size: arrivalSize)).accessibilityLabel("No matching trains") }
					ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
						let details = accessoryDetails(row)
						// Regional names fill the arrival line, so their details take the next line.
						let inlineDetails = inlineDetails && Display.regionalRoute(row.route) == nil
						VStack(alignment: circular ? .center : .leading, spacing: 0) {
							if circular {
								if entry.lockScreen.showService, Display.regionalRoute(row.route) != nil {
									serviceBadge(row.route, size: simplified ? 6 : accessoryDetailSize * 1.25).accessibilityIdentifier("widgetServiceIcon_\(direction)_\(index)")
								}
								HStack(spacing: 0.5) {
									if entry.lockScreen.showService, Display.regionalRoute(row.route) == nil {
										serviceBadge(row.route, size: min(12, arrivalSize)).accessibilityIdentifier("widgetServiceIcon_\(direction)_\(index)")
									}
									Text(compactArrival(row, includeRoute: false)).font(.system(size: arrivalSize, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.35).layoutPriority(1)
								}
							} else {
								HStack(spacing: 2) {
									if entry.lockScreen.showService { serviceBadge(row.route, size: min(14, arrivalSize)).layoutPriority(1).accessibilityIdentifier("widgetServiceIcon_\(direction)_\(index)") }
									time(row).fontWeight(.semibold).monospacedDigit().lineLimit(1).minimumScaleFactor(0.65).layoutPriority(1)
									if inlineDetails, !simplified, !details.isEmpty { Text(details).font(.system(size: accessoryDetailSize)).opacity(0.8).lineLimit(1).minimumScaleFactor(0.7) }
								}.font(.system(size: arrivalSize))
							}
							// Secondary lines shorten to fit, so circular layouts measure only the arrivals.
							if !simplified, shows(.destination) { Text(row.destination).font(.system(size: accessoryDetailSize)).lineLimit(1).minimumScaleFactor(0.7).frame(idealWidth: circular ? 0 : nil) }
							if !simplified, !inlineDetails, !details.isEmpty { Text(details).font(.system(size: accessoryDetailSize)).opacity(0.8).lineLimit(1).minimumScaleFactor(0.7).frame(idealWidth: circular ? 0 : nil) }
						}
						.accessibilityElement(children: previewFamily == nil ? .ignore : .contain)
						.accessibilityLabel("\(direction), \(routeName(row.route)) to \(row.destination), \(compactArrival(row)), \(estimated ? "last estimate" : "estimated arrival"), \(accessoryDetails(row))")
						.accessibilityIdentifier("widgetDeparture_\(direction)_\(index)")
					}
				}.frame(maxWidth: circular ? nil : .infinity, alignment: .leading)
			}
		}.frame(maxWidth: circular ? nil : .infinity, alignment: .leading)
	}
	private func nextDepartures(_ direction: String, limit: Int) -> [Departure] {
		Array(groups.filter { $0.direction == direction }.flatMap(\.departures).sorted {
			let a = $0.time ?? .infinity, b = $1.time ?? .infinity
			return a == b ? $0.key < $1.key : a < b
		}.prefix(limit))
	}
	private func compactArrival(_ row: Departure, includeRoute: Bool = true) -> String {
		let countdown = Display.countdown(row.time, timestamp: row.timestamp, now: entry.date.timeIntervalSince1970, cached: entry.cached, timeFormat: entry.units.time)
		let clock = options.timeStyle == .clock || countdown.unit != "min"
		let value = clock ? shortClockTime(row.time) : countdown.value + "m"
		return (includeRoute && entry.lockScreen.showService ? routePrefix(row.route) : "") + value
	}
	/// Longer route names need a space before the arrival; single letters read fine joined ("Q3m").
	private func routePrefix(_ route: String) -> String { routeName(route) + (routeName(route).count > 1 ? " " : "") }
	/// Subway lines use the filled letter symbols; regional names are cut out of a solid badge to stay legible in one color.
	@ViewBuilder private func serviceBadge(_ route: String, size: Double) -> some View {
		let label = routeName(route)
		Group {
			if Display.regionalRoute(route) == nil, label.count == 1 {
				Image(systemName: "\(label.lowercased()).circle.fill").resizable().scaledToFit().frame(width: size, height: size)
			} else {
				RouteBullet(route: route, diameter: size * 1.3, knockout: true)
			}
		}.widgetAccentable().accessibilityLabel("Service \(label)")
	}
	private func shortClockTime(_ time: TimeInterval?) -> String { String(Display.clockTime(time, format: entry.units.time).split(whereSeparator: \.isWhitespace).first ?? "—") }
	private func accessoryDetails(_ row: Departure) -> String {
		var selected = options
		selected.fields = options.fields.intersection(Set(LockScreenWidgetOptions.fields))
		return widgetTrainDetails(row, options: selected, now: entry.date.timeIntervalSince1970, cached: entry.cached)
	}
	@ViewBuilder private func time(_ departure: Departure) -> some View {
		let countdown = Display.countdown(departure.time, timestamp: departure.timestamp, now: entry.date.timeIntervalSince1970, cached: entry.cached, timeFormat: entry.units.time)
		if accessory, options.compact, departure.time != nil, options.timeStyle == .clock || countdown.unit != "min" { Text(shortClockTime(departure.time)) }
		else if options.timeStyle == .clock, let arrival = departure.time { Text(Display.clockTime(arrival, format: entry.units.time)) }
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
					let badge = Display.regionalRoute(row.route) == nil && route.count == 1 ? Text(Image(systemName: "\(route.lowercased()).circle.fill")) : Text(routePrefix(row.route))
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
	private func arrowSymbol(_ direction: String) -> String { direction == "NORTH" ? "arrow.up" : direction == "SOUTH" ? "arrow.down" : direction == "TO_NY" ? "arrow.right" : "arrow.left" }
	private func groupLabel(_ group: DepartureGroup) -> String {
		switch entry.preference.view { case .track: return "Track \(group.track ?? "?") · \(group.partId)"; default: return group.label }
	}
}

/// A faint wash from the top gives the flat theme color some depth. The in-app
/// preview draws it too, because WidgetKit's container background only renders in widgets.
struct SubwayWidgetBackground: View {
	let theme: AppTheme
	var body: some View {
		LinearGradient(colors: [theme.background.mix(with: theme.dark ? theme.ink : .white, by: theme.dark ? 0.07 : 0.45), theme.background], startPoint: .top, endPoint: .bottom)
	}
}

/// One type scale and spacing rhythm for every Home Screen size. Small widgets
/// keep their size in either density and text size; their narrow columns have no room to grow.
private struct HomeMetrics {
	let small: Bool
	let compact: Bool
	var scale = 1.0
	var title: Double { (small ? 14 : compact ? 15 : 16) * scale }
	var bullet: Double { (small ? 14 : compact ? 18 : 20) * scale }
	var time: Double { (small ? 12 : compact ? 14 : 16) * scale }
	var destination: Double { (small ? 9.5 : compact ? 11.5 : 12.5) * scale }
	var detail: Double { (small ? 8 : compact ? 8.5 : 9.5) * scale }
	var groupHeader: Double { 8.5 * scale }
	var arrow: Double { (small ? 8 : compact ? 9 : 10) * scale }
	var footer: Double { (small ? 9 : 10) * scale }
	var refresh: Double { small ? 20 : 22 }
	var rowSpacing: Double { small ? 7 : compact ? 5 : 8 }
	var headerSpacing: Double { small ? 6 : 8 }
	var columnSpacing: Double { small ? 9 : 14 }
}

private struct ColumnItem: Identifiable {
	let id: String
	var header: String?
	var departure: Departure?
	var index = 0
}

private struct CompactLabel: LabelStyle {
	var spacing: Double
	func makeBody(configuration: Configuration) -> some View {
		HStack(alignment: .firstTextBaseline, spacing: spacing) { configuration.icon; configuration.title }
	}
}
