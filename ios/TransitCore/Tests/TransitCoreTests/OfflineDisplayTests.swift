import Foundation
import Testing
@testable import TransitCore

struct OfflineDisplayTests {
	let prefs = OfflinePreferences()
	let source = OfflineFixtures.start

	@Test func estimatesAreUsableOnlyForKnownPastSourcesWithinTheLimit() {
		#expect(!OfflineDisplay.isEstimateUsable(timestamp: nil, now: source, preferences: prefs))
		#expect(!OfflineDisplay.isEstimateUsable(timestamp: 0, now: source, preferences: prefs))
		#expect(!OfflineDisplay.isEstimateUsable(timestamp: source + 1, now: source, preferences: prefs))
		#expect(OfflineDisplay.isEstimateUsable(timestamp: source, now: source, preferences: prefs))
		#expect(OfflineDisplay.isEstimateUsable(timestamp: source, now: source + 1800, preferences: prefs))
		#expect(!OfflineDisplay.isEstimateUsable(timestamp: source, now: source + 1801, preferences: prefs))
		let short = OfflinePreferences(estimateLimitMinutes: 5)
		#expect(OfflineDisplay.isEstimateUsable(timestamp: source, now: source + 300, preferences: short))
		#expect(!OfflineDisplay.isEstimateUsable(timestamp: source, now: source + 301, preferences: short))
	}

	@Test func cachedCountdownCountsDownTheOriginalPredictionThenFallsBackToClockTimes() {
		let time = source + 1200
		func countdown(_ now: TimeInterval, timestamp: TimeInterval? = OfflineFixtures.start, preferences: OfflinePreferences = OfflinePreferences()) -> Countdown {
			OfflineDisplay.countdown(time: time, timestamp: timestamp, now: now, cached: true, preferences: preferences, timeFormat: .twentyFourHour)
		}
		let clock = Display.clockTime(time, format: .twentyFourHour)
		#expect(countdown(source + 60) == Countdown(value: "19", unit: "min"))
		#expect(countdown(source + 1140) == Countdown(value: "1", unit: "min"))
		#expect(countdown(source + 1141) == Countdown(value: "<1", unit: "min"))
		#expect(countdown(time) == Countdown(value: "<1", unit: "min"))
		#expect(countdown(time + 1) == Countdown(value: clock, unit: "estimate passed"))
		// Past the estimate limit (30 min default) only the last clock time remains.
		let late = OfflinePreferences(estimateLimitMinutes: 5)
		#expect(countdown(source + 300, preferences: late) == Countdown(value: "15", unit: "min"))
		#expect(countdown(source + 301, preferences: late) == Countdown(value: clock, unit: "last estimate"))
		// Missing or future source times never count down.
		#expect(countdown(source + 60, timestamp: nil) == Countdown(value: clock, unit: "last estimate"))
		#expect(countdown(source + 60, timestamp: source + 61) == Countdown(value: clock, unit: "last estimate"))
		#expect(OfflineDisplay.countdown(time: nil, timestamp: source, now: source, cached: true, preferences: prefs) == Countdown(value: "—", unit: "no estimate"))
	}

	@Test func liveCountdownIsUnchanged() {
		for now in [source + 10, source + 200, source + 700] {
			#expect(OfflineDisplay.countdown(time: source + 600, timestamp: source, now: now, cached: false, preferences: prefs) == Display.countdown(source + 600, timestamp: source, now: now))
		}
	}

	@Test func canceledAndSkippedServiceNeverGetsAnEstimate() {
		for (relationship, unit) in [("CANCELED", "canceled"), ("DELETED", "canceled"), ("SKIPPED", "skipped")] {
			let departure = OfflineFixtures.departure("t", time: source + 600, timestamp: source, relationship: relationship)
			#expect(OfflineDisplay.countdown(departure: departure, now: source + 60, cached: true, preferences: prefs) == Countdown(value: "—", unit: unit))
			#expect(OfflineDisplay.countdown(departure: departure, now: source + 60, cached: false, preferences: prefs) == Countdown(value: "—", unit: unit))
			let stop = StopPrediction(id: "1", name: "One", arrival: source + 600, relationship: relationship)
			#expect(OfflineDisplay.countdown(stop: stop, sourceTimestamp: source, now: source + 60, cached: true, preferences: prefs) == Countdown(value: "—", unit: unit))
		}
		let scheduled = OfflineFixtures.departure("t", time: source + 600, timestamp: source, relationship: "SCHEDULED")
		#expect(OfflineDisplay.countdown(departure: scheduled, now: source + 60, cached: true, preferences: prefs) == Countdown(value: "9", unit: "min"))
	}

	@Test func estimateLabelsAlwaysStateSourceAge() {
		#expect(OfflineDisplay.estimateLabel(timestamp: source, now: source + 240, preferences: prefs) == "Offline estimate · source 4m ago")
		#expect(OfflineDisplay.estimateLabel(timestamp: source, now: source + 7200, preferences: prefs) == "Last known times · source 2h ago")
		#expect(OfflineDisplay.estimateLabel(timestamp: nil, now: source, preferences: prefs).contains("no estimate"))
		#expect(OfflineDisplay.estimateLabel(timestamp: source + 5, now: source, preferences: prefs).contains("no estimate"))
	}

	@Test func boardProvenanceSaysWhenTheBoardWasSaved() {
		#expect(OfflineDisplay.boardProvenance(savedAt: source, now: source + 240) == "Board saved 4m ago · countdowns use this device's clock; trains that left say estimate passed")
		#expect(OfflineDisplay.boardProvenance(savedAt: nil, now: source) == "Last board from this visit · not saved offline")
	}

	@Test func nextSavedStopIsAnEstimateThatSkipsWithdrawnAndPassedStops() {
		let stops = [
			StopPrediction(id: "a", name: "A", arrival: source + 60),
			StopPrediction(id: "b", name: "B", arrival: source + 120, relationship: "SKIPPED"),
			StopPrediction(id: "c", name: "C", departure: source + 180),
			StopPrediction(id: "d", name: "D"),
		]
		#expect(OfflineDisplay.estimatedNextStopIndex(stops, now: source) == 0)
		#expect(OfflineDisplay.estimatedNextStopIndex(stops, now: source + 61) == 2)
		#expect(OfflineDisplay.estimatedNextStopIndex(stops, now: source + 180) == 2)
		#expect(OfflineDisplay.estimatedNextStopIndex(stops, now: source + 181) == nil)
		#expect(OfflineDisplay.estimatedNextStopLabel.contains("not observed"))
	}

	@Test func cachedCarAssignmentsAreNeverCurrent() {
		let consist = Consist(cars: [ConsistCar(number: "1")], updatedAt: source, fetchedAt: source)
		#expect(OfflineDisplay.currentConsist(consist, now: source + 10, cached: false))
		#expect(!OfflineDisplay.currentConsist(consist, now: source + 10, cached: true))
	}

	@Test func partialTripsComeFromBoardOnwardStopsAndAreLabeled() {
		let onward = [OnwardStop(stationId: "102", stopId: "102N", name: "Station 102", time: source + 900)]
		let trip = CachedTrip(tripKey: "t", endpoint: OfflineFixtures.endpoint, departure: OfflineFixtures.departure("t", timestamp: source, onward: onward), savedAt: source, accessedAt: source)
		#expect(!trip.isComplete)
		#expect(OfflineDisplay.completenessLabel(trip) == OfflineDisplay.partialTripLabel)
		#expect(trip.stops.map(\.id) == ["101N", "102N"])
		// The departure's location is position text ("Station 101" here), never a stop name.
		#expect(trip.stops[0].name == CachedTrip.boardingStopFallbackName && trip.stops[0].stationId == nil)
		#expect(trip.train?.position == nil)
		#expect(trip.sourceTimestamp == source)
		let complete = CachedTrip(tripKey: "t", endpoint: OfflineFixtures.endpoint, detail: OfflineFixtures.detail("t"), savedAt: source, accessedAt: source)
		#expect(complete.isComplete && OfflineDisplay.completenessLabel(complete) == nil)
		#expect(CachedTrip(tripKey: "t", endpoint: "x", savedAt: 0, accessedAt: 0).sourceTimestamp == nil)
	}
}
