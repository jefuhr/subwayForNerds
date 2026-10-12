import XCTest

@MainActor
final class OfflineWidgetUITests: XCTestCase {
	/// Uses the extension's real SwiftUI views. Attachments preserve layout evidence;
	/// WidgetKit scheduling on a physical device remains a separate acceptance check.
	func testSavedRideWidgetFamiliesAndExpiry() throws {
		continueAfterFailure = false
		let app = XCUIApplication()
		app.launchEnvironment = ["SFN_RESET_STATE": "1", "SFN_DISABLE_LOCATION": "1",
			"SFN_API_BASE_URL": "http://127.0.0.1:8092/subwaysForNerds/api/v1/"]
		app.launch()
		let settings = app.tabBars.buttons["Settings"].exists ? app.tabBars.buttons["Settings"] : app.buttons["Settings"].firstMatch
		XCTAssertTrue(settings.waitForExistence(timeout: 20))
		settings.tap()
		let previews = app.buttons["widgetPreviews"]
		for _ in 0..<14 where !previews.isHittable { app.swipeUp() }
		XCTAssertTrue(previews.isHittable)
		previews.tap()
		for family in ["Small", "Medium", "Large", "Extra large", "Inline", "Circular", "Rectangular"] {
			app.buttons["widgetPreviewFamily"].tap(); app.buttons[family].tap()
			app.buttons["widgetPreviewScenario"].tap(); app.buttons["Saved ride"].tap()
			XCTAssertTrue(app.descendants(matching: .any)["widgetActiveRide"].firstMatch.waitForExistence(timeout: 5))
			capture("saved-ride-\(family)", app: app)
		}
		app.buttons["widgetPreviewFamily"].tap(); app.buttons["Small"].tap()
		for scenario in ["Expired ride", "Partial ride", "Finished estimates"] {
			app.buttons["widgetPreviewScenario"].tap(); app.buttons[scenario].tap()
			let ride = app.descendants(matching: .any)["widgetActiveRide"].firstMatch
			XCTAssertTrue(ride.waitForExistence(timeout: 5))
			if scenario == "Expired ride" { XCTAssertTrue(ride.label.contains("Last known times")) }
			if scenario == "Finished estimates" { XCTAssertTrue(ride.label.contains("No future saved estimates")) }
			capture(scenario, app: app)
		}
	}

	private func capture(_ name: String, app: XCUIApplication) {
		let canvas = app.otherElements["widgetPreviewCanvas"]
		XCTAssertTrue(canvas.waitForExistence(timeout: 5))
		let attachment = XCTAttachment(screenshot: canvas.screenshot())
		attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
	}
}
