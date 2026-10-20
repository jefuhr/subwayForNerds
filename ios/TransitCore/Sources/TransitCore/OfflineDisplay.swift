import Foundation

/// Presentation rules for cached data. A cached countdown is the original source
/// prediction counted down by the device clock: it is an estimate, never an
/// observation, so callers must always show `estimateLabel` beside it.
public enum OfflineDisplay {
	public static let estimatedNextStopLabel = "Estimated next stop"
	public static let partialTripLabel = "Partial trip · onward stops from the station board"

	/// True only for a known, non-future source timestamp no older than the estimate limit.
	public static func isEstimateUsable(timestamp: TimeInterval?, now: TimeInterval, preferences: OfflinePreferences) -> Bool {
		guard let timestamp, timestamp > 0, timestamp <= now else { return false }
		return now - timestamp <= preferences.estimateLimit
	}

	/// Live (uncached) data uses `Display.countdown` unchanged. Cached data counts down
	/// in minutes while usable, then shows the last clock time; a passed time says so
	/// instead of implying the train is still coming.
	public static func countdown(time: TimeInterval?, timestamp: TimeInterval?, now: TimeInterval, cached: Bool, preferences: OfflinePreferences, timeFormat: TimeFormat = .twelveHour, staleAfter: TimeInterval? = nil) -> Countdown {
		guard let time else { return Countdown(value: "—", unit: "no estimate") }
		guard cached else { return Display.countdown(time, timestamp: timestamp ?? 0, now: now, cached: false, timeFormat: timeFormat, staleAfter: staleAfter) }
		let seconds = time - now
		if seconds < 0 { return Countdown(value: Display.clockTime(time, format: timeFormat), unit: "estimate passed") }
		guard isEstimateUsable(timestamp: timestamp, now: now, preferences: preferences) else { return Countdown(value: Display.clockTime(time, format: timeFormat), unit: "last estimate") }
		return Countdown(value: seconds < 60 ? "<1" : String(Int(floor(seconds / 60))), unit: "min")
	}

	/// Explicitly canceled or skipped service never receives an estimate.
	public static func countdown(departure: Departure, now: TimeInterval, cached: Bool, preferences: OfflinePreferences, timeFormat: TimeFormat = .twelveHour) -> Countdown {
		if let unit = withdrawn(departure.relationship) { return Countdown(value: "—", unit: unit) }
		return countdown(time: departure.time, timestamp: departure.timestamp, now: now, cached: cached, preferences: preferences, timeFormat: timeFormat, staleAfter: Display.predictionStaleAfter(departure.staleAfter, feed: departure.feed))
	}

	public static func countdown(stop: StopPrediction, sourceTimestamp: TimeInterval?, now: TimeInterval, cached: Bool, preferences: OfflinePreferences, timeFormat: TimeFormat = .twelveHour, staleAfter: TimeInterval? = nil) -> Countdown {
		if let unit = withdrawn(stop.relationship) { return Countdown(value: "—", unit: unit) }
		return countdown(time: stop.arrival ?? stop.departure, timestamp: sourceTimestamp, now: now, cached: cached, preferences: preferences, timeFormat: timeFormat, staleAfter: staleAfter)
	}

	/// The provenance line that must accompany every cached time.
	public static func estimateLabel(timestamp: TimeInterval?, now: TimeInterval, preferences: OfflinePreferences) -> String {
		guard let timestamp, timestamp > 0 else { return "Offline · source time unknown · no estimate" }
		guard timestamp <= now else { return "Offline · source time is ahead of this device · no estimate" }
		let age = "source " + Display.ageLabel(timestamp, now: now)
		return isEstimateUsable(timestamp: timestamp, now: now, preferences: preferences) ? "Offline estimate · \(age)" : "Last known times · \(age)"
	}

	/// Index of the next saved stop whose predicted time is still ahead. This is an
	/// estimate from the snapshot, never the train's observed position.
	public static func estimatedNextStopIndex(_ stops: [StopPrediction], now: TimeInterval) -> Int? {
		stops.firstIndex { stop in
			guard withdrawn(stop.relationship) == nil, let time = stop.arrival ?? stop.departure else { return false }
			return time >= now
		}
	}

	/// Cached car assignments are history, never the current consist.
	public static func currentConsist(_ consist: Consist?, now: TimeInterval, cached: Bool) -> Bool {
		!cached && Display.currentConsist(consist, now: now)
	}

	public static func completenessLabel(_ trip: CachedTrip) -> String? { trip.isComplete ? nil : partialTripLabel }

	private static func withdrawn(_ relationship: String?) -> String? {
		switch relationship ?? "" {
		case "CANCELED", "DELETED": "canceled"
		case "SKIPPED": "skipped"
		case "NO_DATA": "no estimate"
		default: nil
		}
	}
}
