import Foundation

/// Wording for Transit Lab's estimated slow zones, matching the web board.
public enum SlowZoneDisplay {
	public static let attribution = "Slow zones are estimated from weekday daytime run times by Transit Lab (transitlab.nyc, CC BY 4.0), built from MTA data. Not an official MTA speed restriction list; the slow section can be anywhere between the two stops."

	public static func isDisruption(_ zone: SlowZone) -> Bool { zone.kind == "disruption" }

	/// Unknown future kinds read as ordinary slow zones.
	public static func label(_ zone: SlowZone) -> String { isDisruption(zone) ? "major slowdown" : "slow zone" }

	/// Rounded to whole seconds: "42s", "1m 32s", or "2m" with no leftover seconds.
	public static func seconds(_ value: Double) -> String {
		let total = value.isFinite ? Int(min(max(0, value), 1_000_000).rounded()) : 0
		guard total >= 60 else { return "\(total)s" }
		return total % 60 == 0 ? "\(total / 60)m" : "\(total / 60)m \(total % 60)s"
	}

	private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

	/// A YYYY-MM-DD calendar date as "Aug 10". It is never converted through an instant,
	/// so the day cannot shift with the device's time zone; other text is kept as received.
	public static func date(_ text: String) -> String {
		let parts = text.split(separator: "-", omittingEmptySubsequences: false)
		guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
			parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
			let month = Int(parts[1]), let day = Int(parts[2]), (1...12).contains(month), (1...31).contains(day) else { return text }
		return "\(months[month - 1]) \(day)"
	}

	/// The board row's compact tag, such as "+42s".
	public static func boardTag(_ zone: SlowZone) -> String { "+" + seconds(zone.extraSeconds) }

	public static func accessibilityLabel(_ zone: SlowZone) -> String {
		"In an estimated \(label(zone)): \(zone.segment), typically \(seconds(zone.extraSeconds)) slower"
	}

	/// One line for train details, or nil when no zones lie ahead.
	public static func summary(_ zones: [TrainSlowZone]) -> String? {
		guard !zones.isEmpty else { return nil }
		let extra = zones.reduce(0) { $0 + $1.extraSeconds }
		return "\(zones.count) estimated slow zone\(zones.count == 1 ? "" : "s") ahead · about +\(seconds(extra)) typical"
	}

	/// A cached trip is a past snapshot, so it never says the train is in the zone now.
	public static func title(_ zone: TrainSlowZone, cached: Bool) -> String {
		label(zone.zone) + (zone.current == true && !cached ? " · now" : "")
	}

	public static func detail(_ zone: TrainSlowZone) -> String {
		"\(zone.segment) · +\(seconds(zone.extraSeconds)) on a \(seconds(zone.baselineSeconds)) run · since \(date(zone.since))"
	}

	/// Zones whose segment ends at the stop at `index`, shown immediately before that stop.
	public static func zones(_ zones: [TrainSlowZone]?, before index: Int) -> [TrainSlowZone] {
		(zones ?? []).filter { $0.toIndex == index }
	}
}
