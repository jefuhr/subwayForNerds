import XCTest

/// Offline saving and rides, against the fixture server. Outages keep the same
/// endpoint (SFN_TEST_OFFLINE or the System status toggle), so this endpoint's
/// cache is what the app shows; switching to an unreachable endpoint would hide it.
@MainActor
final class OfflineRideTests: XCTestCase {
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

	func testSavedTripAndRideSurviveSameEndpointOutageRelaunchAndReconnect() {
		var app = launch(reset: true)
		let departure = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'departure_'")).firstMatch
		XCTAssertTrue(departure.waitForExistence(timeout: 20))
		scrollTo(departure, in: app)
		departure.tap()
		XCTAssertTrue(app.descendants(matching: .any)["trainDetails"].firstMatch.waitForExistence(timeout: 10))
		let save = app.buttons["saveTripOffline"]
		XCTAssertTrue(save.waitForExistence(timeout: 10))
		save.tap()
		XCTAssertTrue(app.buttons["removeSavedTrip"].waitForExistence(timeout: 10), "Saving shows the saved state")
		app.buttons["startRide"].tap()
		XCTAssertTrue(app.buttons["endRide"].waitForExistence(timeout: 10), "I'm on this train starts a ride")
		screenshot("offline-saved-and-riding", app: app)
		backToBoard(app)
		XCTAssertTrue(app.descendants(matching: .any)["activeRideBanner"].firstMatch.waitForExistence(timeout: 10))
		XCTAssertFalse(app.buttons["savedTrips"].exists, "Saved trains live in Settings > Offline, not on the board")
		app.terminate()

		// Relaunch with no connection on the same endpoint.
		app = launch(reset: false, outage: true)
		XCTAssertTrue(app.descendants(matching: .any)["activeRideBanner"].firstMatch.waitForExistence(timeout: 10), "The ride survives relaunch")
		XCTAssertTrue(app.descendants(matching: .any)["boardOfflineEstimate"].firstMatch.waitForExistence(timeout: 10), "The saved board is labeled as offline estimates")
		assertSavedBoardShowsNoNotice(app)
		screenshot("offline-board-outage", app: app)
		app.buttons["openRide"].tap()
		XCTAssertTrue(app.descendants(matching: .any)["trainDetails"].firstMatch.waitForExistence(timeout: 10), "Tapping the banner opens ride details")
		XCTAssertTrue(app.descendants(matching: .any)["offlineEstimateLabel"].firstMatch.waitForExistence(timeout: 10), "Ride details show offline provenance")
		XCTAssertTrue(app.buttons["endRide"].exists && app.buttons["removeSavedTrip"].exists)
		screenshot("offline-ride-details", app: app)
		backToBoard(app)

		// Reconnect: the same endpoint refreshes immediately and drops offline labels.
		app.tab("Settings").tap()
		reveal(app.buttons["systemStatusSettings"], in: app)
		app.buttons["systemStatusSettings"].tap()
		XCTAssertTrue(app.navigationBars["System status"].waitForExistence(timeout: 5))
		let outage = app.switches["simulateOutage"]
		scrollTo(outage, in: app)
		outage.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
		XCTAssertEqual(outage.value as? String, "0")
		app.tab("Board").tap()
		// The header no longer says "Live feed"; a live board is the one without the offline estimate card.
		let estimate = app.descendants(matching: .any)["boardOfflineEstimate"].firstMatch
		XCTAssertTrue(waitForAbsence(of: estimate, timeout: 20), "Reconnecting refreshes the board. \(app.debugDescription)")
		XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'departure_'")).firstMatch.waitForExistence(timeout: 10))
		screenshot("offline-reconnected", app: app)

		// Storage controls confirm before removing anything.
		app.tab("Settings").tap()
		// Settings keeps System status pushed from the reconnect step.
		let systemStatusBar = app.navigationBars["System status"]
		if systemStatusBar.exists { systemStatusBar.buttons.firstMatch.tap() }
		XCTAssertTrue(app.buttons["systemStatusSettings"].waitForExistence(timeout: 5))
		reveal(app.buttons["offlineSettings"], in: app)
		app.buttons["offlineSettings"].tap()
		XCTAssertTrue(app.descendants(matching: .any)["offlineUsage"].firstMatch.waitForExistence(timeout: 10))
		XCTAssertTrue(app.buttons["offlineSavedTrains"].label.contains("1"))
		XCTAssertFalse(app.buttons["removeAllOffline"].exists, "There is no remove-everything control")
		app.buttons["clearAutomaticOffline"].tap()
		let confirm = app.buttons.matching(NSPredicate(format: "label == 'Clear automatic downloads' AND identifier != 'clearAutomaticOffline'")).firstMatch
		XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Clearing automatic downloads asks first")
		screenshot("offline-clear-confirmation", app: app)
		confirm.tap()
		XCTAssertTrue(app.buttons["offlineSavedTrains"].label.contains("1"), "Clearing automatic downloads keeps saved trains")
		app.tab("Board").tap()
		XCTAssertTrue(app.descendants(matching: .any)["activeRideBanner"].firstMatch.waitForExistence(timeout: 5), "Clearing automatic downloads keeps the active ride")
		app.tab("Settings").tap()
		let departureCount = app.steppers["offlineDepartures"]
		XCTAssertTrue(departureCount.waitForExistence(timeout: 10))
		// SwiftUI exposes this adjustable control as a leaf without Increment
		// children; tap its visible plus control using the element's own frame.
		departureCount.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
		XCTAssertEqual(departureCount.value as? String, "6")
		scrollTo(app.buttons["offlineRadius_5280"], in: app)
		app.buttons["offlineRadius_5280"].tap()
		scrollTo(app.buttons["offlineEstimateLimit_60"], in: app)
		app.buttons["offlineEstimateLimit_60"].tap()
		XCTAssertTrue(app.buttons["offlineEstimateLimit_60"].isSelected)
		app.terminate()
		app = launch(reset: false)
		app.tab("Settings").tap()
		reveal(app.buttons["offlineSettings"], in: app)
		app.buttons["offlineSettings"].tap()
		XCTAssertTrue(app.steppers["offlineDepartures"].waitForExistence(timeout: 10))
		XCTAssertEqual(app.steppers["offlineDepartures"].value as? String, "6", "Departure cache count persists")
		scrollTo(app.buttons["offlineRadius_5280"], in: app)
		XCTAssertTrue(app.buttons["offlineRadius_5280"].isSelected, "Nearby cache distance persists")
		scrollTo(app.buttons["offlineEstimateLimit_60"], in: app)
		XCTAssertTrue(app.buttons["offlineEstimateLimit_60"].waitForExistence(timeout: 10))
		XCTAssertTrue(app.buttons["offlineEstimateLimit_60"].isSelected, "Offline preferences persist")
		screenshot("offline-settings", app: app)
	}

	func testRideBannerOpensDetailsAndXEndsRideAfterConfirmation() {
		let app = launch(reset: true)
		let departure = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'departure_'")).firstMatch
		XCTAssertTrue(departure.waitForExistence(timeout: 20))
		scrollTo(departure, in: app)
		departure.tap()
		XCTAssertTrue(app.buttons["startRide"].waitForExistence(timeout: 10))
		app.buttons["startRide"].tap()
		XCTAssertTrue(app.buttons["endRide"].waitForExistence(timeout: 10))
		backToBoard(app)

		let banner = app.descendants(matching: .any)["activeRideBanner"].firstMatch
		XCTAssertTrue(banner.waitForExistence(timeout: 10))
		let open = app.buttons["openRide"], end = app.buttons["endRideFromBanner"]
		XCTAssertTrue(open.exists && end.exists)
		XCTAssertFalse(app.buttons["Ride details"].exists, "The Ride details chip is gone")
		XCTAssertEqual(end.label, "End ride")
		XCTAssertGreaterThanOrEqual(end.frame.width, 44)
		XCTAssertGreaterThanOrEqual(end.frame.height, 44)
		XCTAssertGreaterThan(end.frame.midX, open.frame.midX, "The X sits at the trailing edge")
		XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'next stop not observed'")).count, 0)
		screenshot("ride-banner", app: app)

		// Anywhere else on the banner opens the ride.
		open.tap()
		XCTAssertTrue(app.descendants(matching: .any)["trainDetails"].firstMatch.waitForExistence(timeout: 10), "Tapping the banner opens ride details")
		backToBoard(app)

		// The X asks first, and cancelling keeps the ride without opening it.
		end.tap()
		XCTAssertTrue(app.staticTexts["End this ride?"].waitForExistence(timeout: 5))
		XCTAssertFalse(app.descendants(matching: .any)["trainDetails"].firstMatch.exists, "The X must not trigger the banner tap")
		screenshot("ride-banner-end-confirmation", app: app)
		dismissConfirmation(app)
		XCTAssertTrue(banner.waitForExistence(timeout: 5), "Cancel keeps the ride")

		end.tap()
		let confirm = app.buttons.matching(NSPredicate(format: "label == 'End ride' AND identifier != 'endRideFromBanner'")).firstMatch
		XCTAssertTrue(confirm.waitForExistence(timeout: 5))
		confirm.tap()
		XCTAssertTrue(waitForAbsence(of: banner, timeout: 10), "Confirming ends the ride and removes the banner")
	}

	func testOfflineCardOpensSystemStatusInSettingsAndBackReturnsThere() {
		var app = launch(reset: true)
		XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'departure_'")).firstMatch.waitForExistence(timeout: 20))
		// Give the board a moment to reach the offline cache before relaunching without a connection.
		_ = XCTWaiter.wait(for: [XCTestExpectation(description: "board saved")], timeout: 3)
		app.terminate()

		app = launch(reset: false, outage: true)
		let estimate = app.descendants(matching: .any)["boardOfflineEstimate"].firstMatch
		XCTAssertTrue(estimate.waitForExistence(timeout: 10))
		assertSavedBoardShowsNoNotice(app)
		screenshot("offline-card", app: app)
		estimate.tap()
		XCTAssertTrue(app.navigationBars["System status"].waitForExistence(timeout: 5), "The card opens System status")
		XCTAssertTrue(app.tab("Settings").isSelected, "System status opens in the Settings tab")
		app.navigationBars["System status"].buttons.firstMatch.tap()
		XCTAssertTrue(app.buttons["systemStatusSettings"].waitForExistence(timeout: 5) || app.navigationBars["Settings"].exists, "Back returns to Settings")
		XCTAssertFalse(app.navigationBars["System status"].exists)

		// It also works while Settings already has another screen pushed.
		reveal(app.buttons["offlineSettings"], in: app)
		app.buttons["offlineSettings"].tap()
		XCTAssertTrue(app.navigationBars["Offline"].waitForExistence(timeout: 5))
		app.tab("Board").tap()
		XCTAssertTrue(estimate.waitForExistence(timeout: 10))
		estimate.tap()
		XCTAssertTrue(app.navigationBars["System status"].waitForExistence(timeout: 5), "System status opens over a pushed Settings screen")
		XCTAssertTrue(app.tab("Settings").isSelected)
		app.navigationBars["System status"].buttons.firstMatch.tap()
		XCTAssertFalse(app.navigationBars["System status"].exists)
		XCTAssertTrue(app.tab("Settings").isSelected, "Back stays in Settings")
		screenshot("offline-card-system-status-back", app: app)
	}

	/// iPhone shows the dialog as a popover without a Cancel button; tapping outside it cancels.
	private func dismissConfirmation(_ app: XCUIApplication) {
		let cancel = app.buttons["Cancel"]
		if cancel.waitForExistence(timeout: 2) { cancel.tap() }
		else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.55)).tap() }
		XCTAssertTrue(waitForAbsence(of: app.staticTexts["End this ride?"], timeout: 5), "The confirmation closed")
	}

	/// A saved board says it is an offline estimate; it shows no error or degraded-feed notice.
	private func assertSavedBoardShowsNoNotice(_ app: XCUIApplication) {
		XCTAssertTrue(app.descendants(matching: .any)["boardOfflineEstimate"].firstMatch.waitForExistence(timeout: 10), "The saved board is labeled as offline estimates")
		XCTAssertFalse(app.descendants(matching: .any)["boardError"].firstMatch.exists, "A saved board shows no board error")
		for text in ["Showing a saved board", "No connection ·", "Some feeds are stale or unavailable"] {
			XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).count, 0, "\(text) must not appear on a saved board")
		}
	}

	private func waitForAbsence(of element: XCUIElement, timeout: TimeInterval) -> Bool {
		XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)], timeout: timeout) == .completed
	}

	private func backToBoard(_ app: XCUIApplication) {
		app.tab("Board").tap()
		// iPhone pushes details over the board; iPad keeps both.
		if !app.buttons["findStation"].isHittable { app.navigationBars.buttons.firstMatch.tap() }
		XCTAssertTrue(app.buttons["findStation"].waitForExistence(timeout: 5))
	}

	private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, towardTop: Bool = false) {
		for _ in 0..<12 {
			if element.exists && element.isHittable { return }
			if towardTop { app.swipeDown() } else { app.swipeUp() }
		}
		XCTAssertTrue(element.waitForExistence(timeout: 10))
	}

	/// Settings may open scrolled anywhere; look below first, then above.
	/// Hittable alone is not enough: a row under the translucent navigation bar or the
	/// floating tab bar passes that check, but a tap there lands on the bar instead.
	private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
		let visible = {
			guard element.exists && element.isHittable else { return false }
			let navigationBar = app.navigationBars.firstMatch, tabBar = app.tabBars.firstMatch
			let top = navigationBar.exists ? navigationBar.frame.maxY : 0
			let bottom = tabBar.exists ? tabBar.frame.minY : app.frame.maxY
			return element.frame.minY >= top && element.frame.maxY <= bottom
		}
		for _ in 0..<8 where !visible() { app.swipeUp() }
		for _ in 0..<16 where !visible() { app.swipeDown() }
		XCTAssertTrue(visible())
	}

	private func screenshot(_ name: String, app: XCUIApplication) {
		let attachment = XCTAttachment(screenshot: app.screenshot())
		attachment.name = name
		attachment.lifetime = .keepAlways
		add(attachment)
	}
}

private extension XCUIApplication {
	func tab(_ name: String) -> XCUIElement {
		tabBars.buttons[name].exists ? tabBars.buttons[name] : buttons[name].firstMatch
	}
}
