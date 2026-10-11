import Foundation

public enum DistanceUnit: String, Codable, Sendable, CaseIterable, Identifiable {
	case auto, mi, ft, m, km
	public var id: String { rawValue }
	public var title: String {
		switch self { case .auto: "Automatic"; case .mi: "Miles (mi)"; case .ft: "Feet (ft)"; case .m: "Meters (m)"; case .km: "Kilometers (km)" }
	}
	public var radiusUnit: DistanceUnit { self == .auto ? .ft : self }
	public var spokenName: String {
		switch radiusUnit { case .mi: "miles"; case .m: "meters"; case .km: "kilometers"; default: "feet" }
	}
	private var metersPerUnit: Double {
		switch self { case .mi: 1609.344; case .ft: 0.3048; case .km: 1000; default: 1 }
	}
	private func decimal(_ value: Double, digits: Int) -> String {
		value.formatted(.number.locale(Locale(identifier: "en_US_POSIX")).grouping(.never).precision(.fractionLength(0...digits)))
	}
	public func distanceLabel(meters: Double) -> String {
		guard meters.isFinite, meters >= 0 else { return "—" }
		if self == .auto { return meters < 1000 ? "\(Int(meters.rounded())) m" : String(format: "%.1f km", locale: Locale(identifier: "en_US_POSIX"), meters / 1000) }
		let value = meters / metersPerUnit
		if self == .mi || self == .km {
			return value > 0 && value < 0.01 ? "<0.01 \(rawValue)" : "\(decimal(value, digits: 2)) \(rawValue)"
		}
		return "\(Int(value.rounded())) \(rawValue)"
	}
	/// Editing uses more precision than a nearby-distance label, so changing units
	/// does not round a one-foot preference away or move the strict radius boundary.
	public func radiusInput(feet: Int) -> String { decimal(Double(feet) * 0.3048 / radiusUnit.metersPerUnit, digits: 8) }
	public func radiusFeet(from text: String) -> Int? {
		let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard input.range(of: #"^(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)$"#, options: .regularExpression) != nil,
			let value = Double(input), value.isFinite else { return nil }
		let feet = value * radiusUnit.metersPerUnit / 0.3048
		// Eight-decimal unit strings may land a few thousandths of a foot either
		// side of an endpoint. Accept that representation error, never another foot.
		let tolerance = radiusUnit.metersPerUnit / 0.3048 * 0.000000005 + 0.000000001
		guard feet >= 1 - tolerance, feet <= 26400 + tolerance else { return nil }
		return Int(feet.rounded())
	}
	public func radiusLabel(feet: Int) -> String {
		if self == .auto { return "\(feet.formatted()) ft · \(decimal(Double(feet) / 5280, digits: 4)) mi" }
		return "\(radiusInput(feet: feet)) \(rawValue)"
	}
	public var radiusRangeDescription: String { "Enter a distance from \(radiusInput(feet: 1)) to \(radiusInput(feet: 26400)) \(spokenName)." }
}

public enum TimeFormat: String, Codable, Sendable, CaseIterable, Identifiable {
	case twelveHour = "12h", twentyFourHour = "24h"
	public var id: String { rawValue }
	public var title: String { self == .twelveHour ? "12-hour" : "24-hour" }
}

public struct UnitPreferences: Codable, Sendable, Equatable {
	public var distance: DistanceUnit = .auto
	public var time: TimeFormat = .twelveHour
	public init(distance: DistanceUnit = .auto, time: TimeFormat = .twelveHour) { self.distance = distance; self.time = time }
	private enum CodingKeys: String, CodingKey { case distance, time }
	private struct AnyKey: CodingKey {
		let stringValue: String
		var intValue: Int? { nil }
		init?(stringValue: String) { self.stringValue = stringValue }
		init?(intValue: Int) { return nil }
	}
	public init(from decoder: Decoder) throws {
		let keys = try decoder.container(keyedBy: AnyKey.self)
		guard Set(keys.allKeys.map(\.stringValue)) == ["distance", "time"] else { throw SettingsError.invalid }
		let values = try decoder.container(keyedBy: CodingKeys.self)
		distance = try values.decode(DistanceUnit.self, forKey: .distance)
		time = try values.decode(TimeFormat.self, forKey: .time)
	}
}
