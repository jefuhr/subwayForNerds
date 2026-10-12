import XCTest

/// Offline saving and rides, against the fixture server. Outages keep the same
/// endpoint (SFN_TEST_OFFLINE or the Development toggle), so this endpoint's
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
		XCTAssertTrue(app.descendants(matching: .any)["offlineReadiness"].firstMatch.waitForExistence(timeout: 20))
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
		XCTAssertTrue(app.buttons["savedTrips"].exists, "The board offers saved trains directly")
		app.terminate()

		// Relaunch with no connection on the same endpoint.
		app = launch(reset: false, outage: true)
		XCTAssertTrue(app.descendants(matching: .any)["activeRideBanner"].firstMatch.waitForExistence(timeout: 10), "The ride survives relaunch")
		XCTAssertTrue(app.descendants(matching: .any)["boardOfflineEstimate"].firstMatch.waitForExistence(timeout: 10), "The saved board is labeled as offline estimates")
		XCTAssertTrue(app.descendants(matching: .any)["boardError"].firstMatch.label.contains("No connection"))
		screenshot("offline-board-outage", app: app)
		app.buttons["openRide"].tap()
		XCTAssertTrue(app.descendants(matching: .any)["offlineEstimateLabel"].firstMatch.waitForExistence(timeout: 10), "Ride details show offline provenance")
		XCTAssertTrue(app.buttons["endRide"].exists && app.buttons["removeSavedTrip"].exists)
		screenshot("offline-ride-details", app: app)
		backToBoard(app)

		// Reconnect: the same endpoint refreshes immediately and drops offline labels.
		app.tab("Settings").tap()
		let outage = app.switches["simulateOutage"]
		scrollTo(outage, in: app)
		outage.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
		XCTAssertEqual(outage.value as? String, "0")
		app.tab("Board").tap()
		// SwiftUI propagates a Label's identifier to its symbol as well as its text.
		// Match the actual status text instead of reading the first matching symbol.
		let live = app.staticTexts.matching(NSPredicate(format: "label == 'Live feed' OR label == 'Partial live data'")).firstMatch
		XCTAssertTrue(live.waitForExistence(timeout: 20), "Reconnecting refreshes the board. \(app.debugDescription)")
		XCTAssertFalse(app.descendants(matching: .any)["boardOfflineEstimate"].firstMatch.exists)
		screenshot("offline-reconnected", app: app)

		// Storage controls confirm before removing anything.
		app.tab("Settings").tap()
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
