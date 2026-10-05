import XCTest

@MainActor
final class WidgetHomeScreenTests: XCTestCase {
	func testWidgetGallerySharedFavoriteAndNavigation() throws {
		try XCTSkipUnless(ProcessInfo.processInfo.environment["SFN_WIDGET_HOME_QA"] == "1", "Opt-in test changes the simulator Home Screen")
		continueAfterFailure = false
		let app = XCUIApplication()
		app.launchEnvironment = ["SFN_RESET_STATE": "1", "SFN_DISABLE_LOCATION": "1", "SFN_API_BASE_URL": ProcessInfo.processInfo.environment["SFN_WIDGET_QA_API"] ?? "http://127.0.0.1:8092/subwaysForNerds/api/v1/"]
		app.launch()
		XCTAssertTrue(app.buttons["toggleFavorite"].waitForExistence(timeout: 20))
		app.buttons["toggleFavorite"].tap()
		XCUIDevice.shared.press(.home)
		let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
		let icon = springboard.icons["Subway Nerds"]
		XCTAssertTrue(icon.waitForExistence(timeout: 10))
		icon.press(forDuration: 1.5)
		XCTAssertTrue(springboard.buttons["Edit Home Screen"].waitForExistence(timeout: 5))
		springboard.buttons["Edit Home Screen"].tap()
		print("WIDGET_HOME_EDIT_TREE\n" + springboard.debugDescription)
		if springboard.buttons["Edit"].exists { springboard.buttons["Edit"].tap() }
		if springboard.buttons["Add Widget"].exists { springboard.buttons["Add Widget"].tap() }
		else if springboard.buttons["Add Widgets"].exists { springboard.buttons["Add Widgets"].tap() }
		else { XCTFail("Widget gallery action unavailable: \(springboard.debugDescription)"); return }
		let search = springboard.searchFields.firstMatch
		XCTAssertTrue(search.waitForExistence(timeout: 10))
		search.tap(); search.typeText("Subway Nerds")
		print("WIDGET_HOME_GALLERY_TREE\n" + springboard.debugDescription)
		let result = springboard.staticTexts["Subway Nerds"].firstMatch
		XCTAssertTrue(result.waitForExistence(timeout: 10))
		result.tap()
		print("WIDGET_HOME_PREVIEW_TREE\n" + springboard.debugDescription)
		let attachment = XCTAttachment(screenshot: springboard.screenshot()); attachment.name = "widget-system-gallery"; attachment.lifetime = .keepAlways; add(attachment)
		// iOS 27's remote widget gallery draws its controls but does not expose
		// them in SpringBoard's accessibility hierarchy on the simulator.
		if springboard.buttons["Add Widget"].waitForExistence(timeout: 3) {
			springboard.buttons["Add Widget"].tap()
		} else {
			springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.905)).tap()
		}
		if springboard.alerts.buttons["Allow"].waitForExistence(timeout: 5) { springboard.alerts.buttons["Allow"].tap() }
		if springboard.buttons["Done"].exists { springboard.buttons["Done"].tap() }
		let initial = XCTAttachment(screenshot: springboard.screenshot()); initial.name = "widget-system-added"; initial.lifetime = .keepAlways; add(initial)
		print("WIDGET_HOME_INSTALLED_TREE\n" + springboard.debugDescription)
		let station = springboard.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Union'")).firstMatch
		XCTAssertTrue(station.waitForExistence(timeout: 20), "The installed widget must receive the app’s favorite through the App Group")
		let installed = XCTAttachment(screenshot: springboard.screenshot()); installed.name = "widget-system-home"; installed.lifetime = .keepAlways; add(installed)
		station.tap()
		XCTAssertTrue(app.buttons["selectedStation"].waitForExistence(timeout: 10))
		XCTAssertTrue(app.buttons["selectedStation"].label.contains("Union"))
		XCUIDevice.shared.press(.home)
		station.press(forDuration: 1.5)
		if springboard.buttons["Remove Widget"].waitForExistence(timeout: 5) {
			springboard.buttons["Remove Widget"].tap()
			if springboard.alerts.buttons["Remove"].exists { springboard.alerts.buttons["Remove"].tap() }
		}
	}
}
