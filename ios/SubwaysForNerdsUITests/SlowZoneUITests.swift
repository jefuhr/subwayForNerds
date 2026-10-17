import XCTest

/// Estimated slow zones against the fixture server, whose synthetic Transit Lab rows put the
/// recorded downtown 4 train inside 28 St → 23 St-Baruch College with a major slowdown ahead.
@MainActor
final class SlowZoneUITests: XCTestCase {
	private let departureID = "departure_gtfs|20260905|123100_4..S06X064||635S|1"
	private let boardTag = "In an estimated slow zone: 28 St → 23 St-Baruch College, typically 42s slower"

	func testBoardTagDetailSegmentsAndOfflineWording() {
		var app = launch(reset: true)
		let departure = app.buttons[departureID]
		scrollTo(departure, in: app)
		XCTAssertTrue(departure.label.contains(boardTag), departure.label)
		XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label CONTAINS 'In an estimated'")).count, 1, "Only the train inside a zone is tagged")
		screenshot("slow-zone-board-tag", app: app)

		departure.tap()
		XCTAssertTrue(app.descendants(matching: .any)["trainDetails"].firstMatch.waitForExistence(timeout: 10))
		let summary = app.descendants(matching: .any)["slowZoneSummary"].firstMatch
		XCTAssertTrue(summary.waitForExistence(timeout: 10))
		XCTAssertEqual(summary.label, "2 estimated slow zones ahead · about +2m 56s typical")
		let current = app.descendants(matching: .any)["slowZone_633S_634S"].firstMatch
		scrollTo(current, in: app)
		XCTAssertEqual(current.label, "Estimated slow zone · now. 28 St → 23 St-Baruch College · +42s on a 1m 32s run · since Aug 10")
		// The current zone ends at the first remaining stop, so it leads the list.
		let firstStop = app.buttons.matching(NSPredicate(format: "label CONTAINS '23 St-Baruch College'")).firstMatch
		XCTAssertTrue(firstStop.exists)
		XCTAssertLessThanOrEqual(current.frame.maxY, firstStop.frame.minY + 1)
		screenshot("slow-zone-detail-current", app: app)

		let disruption = app.descendants(matching: .any)["slowZone_419S_420S"].firstMatch
		scrollTo(disruption, in: app)
		XCTAssertEqual(disruption.label, "Estimated major slowdown. Wall St → Bowling Green · +2m 14s on a 1m 28s run · since Aug 31")
		let wallStreet = app.buttons["Connections at Wall St"], bowlingGreen = app.buttons["Connections at Bowling Green"]
		XCTAssertTrue(wallStreet.exists && bowlingGreen.exists)
		XCTAssertLessThanOrEqual(wallStreet.frame.maxY, disruption.frame.minY + 1, "The segment row follows its first stop")
		XCTAssertLessThanOrEqual(disruption.frame.maxY, bowlingGreen.frame.minY + 1, "The segment row sits immediately before the stop where it ends")
		XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Wall St → Bowling Green'")).count, 0, "Segment rows are not tappable")
		screenshot("slow-zone-detail-disruption", app: app)
		let attribution = app.staticTexts["slowZoneAttribution"]
		scrollTo(attribution, in: app)
		XCTAssertTrue(attribution.label.hasPrefix("Slow zones are estimated from weekday daytime run times by Transit Lab (transitlab.nyc, CC BY 4.0)"))
		screenshot("slow-zone-detail-attribution", app: app)

		let save = app.buttons["saveTripOffline"]
		scrollTo(save, in: app, towardTop: true)
		save.tap()
		XCTAssertTrue(app.buttons["removeSavedTrip"].waitForExistence(timeout: 10))

		// A light theme keeps the tag and the rows legible.
		tab("Settings", in: app).tap()
		let light = app.buttons["theme_nyc-ferry"]
		scrollTo(light, in: app)
		light.tap()
		XCTAssertTrue(light.isSelected)
		tab("Board", in: app).tap()
		scrollTo(current, in: app, towardTop: true)
		screenshot("slow-zone-detail-light-theme", app: app)
		if !app.buttons["findStation"].firstMatch.isHittable { app.navigationBars.buttons.element(boundBy: 0).tap() }
		scrollTo(departure, in: app)
		XCTAssertTrue(departure.label.contains(boardTag), departure.label)
		screenshot("slow-zone-board-tag-light-theme", app: app)
		app.terminate()

		// Offline, the saved board hides the tag and the saved trip never says "now".
		app = launch(reset: false, outage: true)
		XCTAssertTrue(app.descendants(matching: .any)["boardOfflineEstimate"].firstMatch.waitForExistence(timeout: 10))
		let saved = app.buttons[departureID]
		scrollTo(saved, in: app)
		XCTAssertFalse(saved.label.contains("In an estimated"), saved.label)
		screenshot("slow-zone-board-offline", app: app)
		saved.tap()
		XCTAssertTrue(app.descendants(matching: .any)["offlineEstimateLabel"].firstMatch.waitForExistence(timeout: 10))
		let offlineZone = app.descendants(matching: .any)["slowZone_633S_634S"].firstMatch
		scrollTo(offlineZone, in: app)
		XCTAssertEqual(offlineZone.label, "Estimated slow zone. 28 St → 23 St-Baruch College · +42s on a 1m 32s run · since Aug 10")
		screenshot("slow-zone-detail-offline", app: app)
	}

	private func launch(reset: Bool, outage: Bool = false) -> XCUIApplication {
		continueAfterFailure = false
		let app = XCUIApplication()
		app.launchEnvironment["SFN_API_BASE_URL"] = ProcessInfo.processInfo.environment["SFN_WIDGET_QA_API"] ?? "http://127.0.0.1:8092/subwaysForNerds/api/v1/"
		app.launchEnvironment["SFN_RESET_STATE"] = reset ? "1" : "0"
		app.launchEnvironment["SFN_TEST_OFFLINE"] = outage ? "1" : "0"
		app.launchEnvironment["SFN_DISABLE_LOCATION"] = "1"
		app.launchEnvironment["SFN_TEST_NOW"] = String(ISO8601DateFormatter().date(from: "2026-09-06T00:59:40Z")!.timeIntervalSince1970)
		app.launch()
		XCTAssertTrue(app.buttons["selectedStation"].waitForExistence(timeout: 20))
		return app
	}

	/// iPhone shows a tab bar; iPad shows the same tabs at the top of the window.
	private func tab(_ name: String, in app: XCUIApplication) -> XCUIElement {
		app.tabBars.buttons[name].exists ? app.tabBars.buttons[name] : app.buttons[name].firstMatch
	}

	private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, towardTop: Bool = false) {
		for _ in 0..<15 {
			if element.exists && element.isHittable { return }
			if towardTop { app.swipeDown() } else { app.swipeUp() }
		}
		XCTAssertTrue(element.waitForExistence(timeout: 10))
		XCTAssertTrue(element.isHittable)
	}

	private func screenshot(_ name: String, app: XCUIApplication) {
		let attachment = XCTAttachment(screenshot: app.screenshot())
		attachment.name = name
		attachment.lifetime = .keepAlways
		add(attachment)
	}
}
