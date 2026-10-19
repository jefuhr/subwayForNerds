import Foundation
import Testing
@testable import TransitCore

struct DepartureRowDisplayTests {
	private func departure(track: String? = "A4", reported: Bool = true) -> Departure {
		var row = Departure(key: "k", tripKey: "t", route: "B", destination: "Brighton Beach", direction: "NORTH", stopId: "D43N", partId: "D43", area: "Broadway - Brighton · Manhattan", pattern: "Local", patternSource: "feed", location: "", feed: "gtfs", timestamp: 1000)
		if reported { row.actualTrack = track } else { row.scheduledTrack = track }
		return row
	}

	@Test func boardingLabelOmitsProvenanceOnRequest() {
		var row = departure()
		#expect(Display.boardingLabel(row, showProvenance: false) == "Broadway - Brighton · Manhattan · Track A4")
		#expect(Display.boardingLabel(row, showProvenance: true) == "Broadway - Brighton · Manhattan · Track A4 · reported")
		#expect(Display.boardingLabel(row) == "Broadway - Brighton · Manhattan · Track A4 · reported")
		row = departure(reported: false)
		#expect(Display.boardingLabel(row, showProvenance: false) == "Broadway - Brighton · Manhattan · Track A4")
		#expect(Display.boardingLabel(row, showProvenance: true) == "Broadway - Brighton · Manhattan · Track A4 · scheduled")
		// An area that already ends in the track is not repeated, with or without provenance.
		row.area = "Broadway - Brighton · Manhattan · Track A4"
		#expect(Display.boardingLabel(row, showProvenance: false) == "Broadway - Brighton · Manhattan · Track A4")
		#expect(Display.boardingLabel(row, showProvenance: true) == "Broadway - Brighton · Manhattan · Track A4 · scheduled")
		row.area = "Track A4"
		#expect(Display.boardingLabel(row, showProvenance: false) == "Track A4")
	}

	@Test func unknownTrackStaysWithoutProvenance() {
		var row = departure(track: nil)
		row.scheduledTrack = nil; row.actualTrack = nil
		#expect(Display.boardingLabel(row, showProvenance: false) == "Broadway - Brighton · Manhattan · Track unknown")
		#expect(Display.boardingLabel(row, showProvenance: true) == "Broadway - Brighton · Manhattan · Track unknown")
	}

	@Test func trackGroupHeaderFollowsProvenance() {
		#expect(Display.trackGroupLabel(track: "A4", reported: true, showProvenance: false) == "Track A4")
		#expect(Display.trackGroupLabel(track: "A4", reported: true, showProvenance: true) == "Track A4 · reported")
		#expect(Display.trackGroupLabel(track: "A4", reported: false, showProvenance: true) == "Track A4 · scheduled")
		#expect(Display.trackGroupLabel(track: "A4", reported: false, showProvenance: false) == "Track A4")
		#expect(Display.trackGroupLabel(track: nil, reported: false, showProvenance: false) == "Track unknown")
		#expect(Display.trackGroupLabel(track: nil, reported: false, showProvenance: true) == "Track unknown")
	}

	@Test func combinedPositionJoinsLocationStopsAndAge() {
		let line = Display.positionLine(location: "At Newkirk Plaza", historical: false, stopsAway: 1, reportedAt: 975, now: 1000)
		#expect(line.text == "At Newkirk Plaza · 1 stop away · 25s ago")
		#expect(line.location == "At Newkirk Plaza")
		#expect(line.detail == "1 stop away · 25s ago")
		#expect(Display.positionLine(location: "Between A and B", historical: false, stopsAway: 3, reportedAt: 880, now: 1000).text == "Between A and B · 3 stops away · 2m ago")
		#expect(Display.positionLine(location: "At Terminal", historical: false, stopsAway: 0, reportedAt: 1000, now: 1000).text == "At Terminal · 0 stops away · 0s ago")
	}

	@Test func combinedPositionKeepsLastReportPrefix() {
		let line = Display.positionLine(location: "At Newkirk Plaza", historical: true, stopsAway: 1, reportedAt: 700, now: 1000)
		#expect(line.text == "Last report: At Newkirk Plaza · 1 stop away · 5m ago")
		#expect(line.location == "Last report: At Newkirk Plaza")
		// With no location there is nothing to be the last report of.
		#expect(Display.positionLine(location: "", historical: true, stopsAway: 1, reportedAt: 700, now: 1000).text == "1 stop away · 5m ago")
	}

	@Test func combinedPositionOmitsMissingPartsWithoutDanglingSeparators() {
		#expect(Display.positionLine(location: "At Newkirk Plaza", historical: false, stopsAway: nil, reportedAt: nil, now: 1000).text == "At Newkirk Plaza")
		#expect(Display.positionLine(location: "At Newkirk Plaza", historical: false, stopsAway: 2, reportedAt: nil, now: 1000).text == "At Newkirk Plaza · 2 stops away")
		#expect(Display.positionLine(location: "At Newkirk Plaza", historical: false, stopsAway: nil, reportedAt: 975, now: 1000).text == "At Newkirk Plaza · 25s ago")
		#expect(Display.positionLine(location: "At Newkirk Plaza", historical: false, stopsAway: -1, reportedAt: nil, now: 1000).text == "At Newkirk Plaza")
		#expect(Display.positionLine(location: "", historical: false, stopsAway: 1, reportedAt: 975, now: 1000).text == "1 stop away · 25s ago")
		#expect(Display.positionLine(location: "", historical: false, stopsAway: 4, reportedAt: nil, now: 1000).text == "4 stops away")
	}

	@Test func combinedPositionFallsBackToTodaysTextWhenNothingIsKnown() {
		let line = Display.positionLine(location: "", historical: false, stopsAway: nil, reportedAt: nil, now: 1000)
		#expect(line.text == "Stop-relative position")
		#expect(line.location.isEmpty)
		#expect(Display.positionLine(location: "", historical: false, stopsAway: nil, reportedAt: 975, now: 1000).text == "Stop-relative position · 25s ago")
	}

	@Test func stopDetailMatchesTheSplitLayout() {
		#expect(Display.stopDetail(stopsAway: 1, reportedAt: 975, now: 1000) == "1 stop away · 25s ago")
		#expect(Display.stopDetail(stopsAway: nil, reportedAt: nil, now: 1000) == "Stop-relative position")
		#expect(Display.stopDetail(stopsAway: -1, reportedAt: 975, now: 1000) == "Stop-relative position · 25s ago")
		#expect(Display.stopDetail(stopsAway: 3, reportedAt: nil, now: 1000) == "3 stops away")
	}

	@Test func headwayLabels() {
		#expect(Display.headwayLabel(5) == "+5m gap")
		#expect(Display.headwayAccessibilityLabel(5) == "5 minutes after previous train")
		#expect(Display.headwayAccessibilityLabel(1) == "1 minute after previous train")
		#expect(Display.splitHeadwayLabel(5) == "+5m after previous")
	}
}
