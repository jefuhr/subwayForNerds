import XCTest

@MainActor
final class WidgetRefreshTests: XCTestCase {
	func testRefreshIntervalsStayIndependentAfterRelaunchAndReset() {
		continueAfterFailure = false
		var app = launch(reset: true)
		openDisplay("widgetDisplaySettings", in: app)
		chooseRefresh("10 minutes", id: "widgetRefreshInterval", in: app)
		capture("home-refresh-10-minutes", app: app)
		app.navigationBars.buttons.firstMatch.tap()
		openDisplay("widgetLockScreenSettings", in: app)
		chooseRefresh("1 minute", id: "widgetLockRefreshInterval", in: app)
		capture("lock-refresh-1-minute", app: app)
		app.terminate()

		app = launch(reset: false)
		openDisplay("widgetDisplaySettings", in: app)
		XCTAssertTrue(app.buttons["widgetRefreshInterval"].label.contains("10 minutes"))
		resetDisplay(in: app)
		XCTAssertTrue(app.buttons["widgetRefreshInterval"].label.contains("5 minutes"))
		chooseRefresh("15 minutes", id: "widgetRefreshInterval", in: app)
		app.navigationBars.buttons.firstMatch.tap()
		openDisplay("widgetLockScreenSettings", in: app)
		XCTAssertTrue(app.buttons["widgetLockRefreshInterval"].label.contains("1 minute"), "Resetting Home Screen display must preserve Lock Screen refresh")
		chooseRefresh("30 minutes", id: "widgetLockRefreshInterval", in: app)
		resetDisplay(in: app)
		XCTAssertTrue(app.buttons["widgetLockRefreshInterval"].label.contains("5 minutes"))
		app.navigationBars.buttons.firstMatch.tap()
		openDisplay("widgetDisplaySettings", in: app)
		XCTAssertTrue(app.buttons["widgetRefreshInterval"].label.contains("15 minutes"), "Resetting Lock Screen display must preserve Home Screen refresh")
		capture("widget-refresh-default-restored", app: app)
	}

	private func launch(reset: Bool) -> XCUIApplication {
		let app = XCUIApplication()
		app.launchEnvironment = ["SFN_RESET_STATE": reset ? "1" : "0", "SFN_DISABLE_LOCATION": "1",
			"SFN_API_BASE_URL": ProcessInfo.processInfo.environment["SFN_WIDGET_QA_API"] ?? "http://127.0.0.1:8092/subwaysForNerds/api/v1/"]
		app.launch()
		XCTAssertTrue(app.buttons["selectedStation"].waitForExistence(timeout: 20))
		let settings = app.tabBars.buttons["Settings"].exists ? app.tabBars.buttons["Settings"] : app.buttons["Settings"].firstMatch
		settings.tap()
		return app
	}
	private func openDisplay(_ id: String, in app: XCUIApplication) {
		// Both display links are together, near the bottom of the Settings list.
		for _ in 0..<4 { app.swipeDown() }
		scrollTo(app.buttons[id], in: app)
		app.buttons[id].tap()
		let intervalID = id == "widgetDisplaySettings" ? "widgetRefreshInterval" : "widgetLockRefreshInterval"
		XCTAssertTrue(app.buttons[intervalID].waitForExistence(timeout: 5))
	}
	private func chooseRefresh(_ title: String, id: String, in app: XCUIApplication) {
		app.buttons[id].tap()
		XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 5))
		app.buttons[title].tap()
		XCTAssertTrue(app.buttons[id].label.contains(title))
	}
	private func resetDisplay(in app: XCUIApplication) {
		scrollTo(app.buttons["Reset widget display"], in: app)
		app.buttons["Reset widget display"].tap()
		for _ in 0..<4 { app.swipeDown() }
	}
	private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
		for _ in 0..<12 {
			if element.exists && element.isHittable { return }
			app.swipeUp()
		}
		XCTAssertTrue(element.exists && element.isHittable)
	}
	private func capture(_ name: String, app: XCUIApplication) {
		let attachment = XCTAttachment(screenshot: app.screenshot())
		attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
	}
}
