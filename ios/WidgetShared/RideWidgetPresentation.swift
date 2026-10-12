import SwiftUI
import TransitCore
import WidgetKit

/// A saved ride has its own presentation so a predicted next stop cannot be
/// confused with the widget's usual nearby-station selection.
struct SubwayRideWidgetView: View {
	let entry: SubwayWidgetEntry
	let family: WidgetFamily
	private var ride: WidgetRideSnapshot? { entry.ride }
	private var now: TimeInterval { entry.date.timeIntervalSince1970 }
	private var train: Train? { ride?.trip.train }
	private var next: StopPrediction? { ride?.nextStop(now: now) }
	private var historical: Bool { entry.cached || (ride?.trip.sourceTimestamp ?? 0) > now || Display.freshness(ride?.trip.sourceTimestamp, now: now) != .live }
	private var isLarge: Bool { family == .systemLarge || family == .systemExtraLarge }
	private var canceled: Bool { ["CANCELED", "DELETED"].contains(train?.relationship ?? "") }
	private var emptyMessage: String {
		if canceled { return "Train canceled in last report" }
		if train?.assigned == false { return "No train assigned in last report. Reconnect for an update." }
		return "No future saved estimates. Reconnect for an update."
	}
	private var age: String { Display.ageLabel(ride?.trip.sourceTimestamp, now: now) }
	private var provenance: String {
		historical ? OfflineDisplay.estimateLabel(timestamp: ride?.trip.sourceTimestamp, now: now, preferences: entry.offline) : "Updated \(age)"
	}
	private func estimate(_ stop: StopPrediction) -> Countdown {
		let value = OfflineDisplay.countdown(stop: stop, sourceTimestamp: ride?.trip.sourceTimestamp, now: now,
			cached: historical, preferences: entry.offline, timeFormat: entry.units.time)
		return widgetIntervalCountdown(value, time: stop.arrival ?? stop.departure, now: now, displayUntil: entry.displayUntil?.timeIntervalSince1970)
	}
	private var compactEstimate: String {
		guard let next else { return "—" }
		let value = estimate(next)
		return value.value + (value.unit == "min" ? "m" : "")
	}

	var body: some View {
		Group {
			switch family {
			case .accessoryInline:
				Text("\(train.map { Display.routeLabel($0.route) } ?? "Ride") → \(next?.name ?? "Reconnect") · \(compactEstimate)\(historical ? " · offline \(age)" : "")")
					.font(.caption2).lineLimit(1).minimumScaleFactor(0.7)
			case .accessoryCircular:
				VStack(spacing: 1) {
					Text(train.map { Display.routeLabel($0.route) } ?? "Ride").font(.system(size: 9, weight: .bold))
					Text(compactEstimate).font(.system(size: 17, weight: .semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.65)
					Text(next?.name ?? "Reconnect").font(.system(size: 7)).lineLimit(1).minimumScaleFactor(0.65)
					Text(historical ? "Offline · \(age)" : age).font(.system(size: 7)).lineLimit(1).minimumScaleFactor(0.65)
				}.frame(maxWidth: .infinity, maxHeight: .infinity).padding(11)
			case .accessoryRectangular:
				VStack(alignment: .leading, spacing: 2) {
					Text("\(train.map { Display.routeLabel($0.route) } ?? "Ride") → \(next?.name ?? "Reconnect")").font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.75)
					Text(compactEstimate).font(.title3.weight(.semibold).monospacedDigit()).lineLimit(1)
					Text(provenance).font(.system(size: 9)).lineLimit(1).minimumScaleFactor(0.65)
				}
			default:
				home
			}
		}
		.accessibilityElement(children: .combine)
		.accessibilityLabel("Your ride, \(train.map { Display.routeLabel($0.route) } ?? "train") to \(train?.destination ?? "destination unavailable"). \(next.map { "Estimated next stop \($0.name), \(compactEstimate)." } ?? emptyMessage) \(provenance)")
		.accessibilityIdentifier("widgetActiveRide")
	}

	private var home: some View {
		VStack(alignment: .leading, spacing: 5) {
			HStack(spacing: 6) {
				if let train { RouteBullet(route: train.route, diameter: 20).widgetAccentable() }
				Text("Your ride").font(.caption.weight(.semibold))
				Spacer(minLength: 0)
				if !historical { Image(systemName: "antenna.radiowaves.left.and.right").font(.caption2) }
			}
			if let next {
				Text("Estimated next stop").font(.caption2).opacity(0.7)
				Text(next.name).font(.headline).lineLimit(family == .systemSmall ? 1 : 2).minimumScaleFactor(0.75)
				time(next, prominent: true)
				if isLarge, let trip = ride?.trip {
					Divider().padding(.vertical, 4)
					let stops = trip.stops.filter { $0.id != next.id && $0.relationship != "SKIPPED" && ($0.arrival ?? $0.departure ?? -.infinity) > (next.arrival ?? next.departure ?? now) }
					ForEach(Array(stops.prefix(5).enumerated()), id: \.offset) { _, stop in
						HStack(alignment: .firstTextBaseline) {
							Text(stop.name).font(.caption).lineLimit(1)
							Spacer(minLength: 4)
							time(stop, prominent: false)
						}.padding(.vertical, 2)
					}
				}
			} else { Text(emptyMessage).font(.caption).fixedSize(horizontal: false, vertical: true) }
			Spacer(minLength: 0)
			if ride?.trip.isComplete == false { Text("Partial saved trip").font(.system(size: 10)).opacity(0.7) }
			Text(provenance).font(.system(size: family == .systemSmall ? 9 : 10)).opacity(0.75).lineLimit(2).minimumScaleFactor(0.85)
		}
	}

	private func time(_ stop: StopPrediction, prominent: Bool) -> some View {
		let value = estimate(stop)
		return HStack(alignment: .firstTextBaseline, spacing: 3) {
			Text(value.value).font(prominent ? .title2.weight(.semibold).monospacedDigit() : .caption.monospacedDigit())
			if value.unit == "min" { Text("min").font(.caption2) }
		}.lineLimit(1).minimumScaleFactor(0.75)
	}
}
