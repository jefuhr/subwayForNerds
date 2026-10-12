import XCTest

@MainActor
final class CombinedWidgetTests: XCTestCase {
	func testMixedSystemWidgetsKeepBoardingOriginsInsideEveryFamily() {
		continueAfterFailure = false
		let app = XCUIApplication()
		app.launchEnvironment = ["SFN_RESET_STATE": "1", "SFN_DISABLE_LOCATION": "1", "SFN_API_BASE_URL": "http://127.0.0.1:8092/subwaysForNerds/api/v1/"]
		app.launch()
		XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 20))
		app.tabBars.buttons["Settings"].tap()
		let preview = app.buttons["widgetPreviews"]
		for _ in 0..<16 where !preview.isHittable { app.swipeUp() }
		preview.tap()
		app.buttons["widgetPreviewScenario"].tap()
		app.buttons["Mixed combined"].tap()
		for family in ["Small", "Medium", "Large", "Inline", "Circular", "Rectangular"] {
			app.buttons["widgetPreviewFamily"].tap()
			app.buttons[family].tap()
			let canvas = app.otherElements["widgetPreviewCanvas"]
			XCTAssertTrue(canvas.waitForExistence(timeout: 5))
			let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'widgetCombinedDeparture_'"))
			XCTAssertGreaterThan(rows.count, 0)
			for row in rows.allElementsBoundByIndex {
				XCTAssertTrue(row.label.contains("board at Fulton St") || row.label.contains("board at World Trade Center"))
				XCTAssertTrue(canvas.frame.insetBy(dx: -1, dy: -1).contains(row.frame), "\(family): \(row.frame) outside \(canvas.frame)")
			}
			let image = XCTAttachment(screenshot: app.screenshot())
			image.name = "combined-widget-\(family)"; image.lifetime = .keepAlways; add(image)
		}
	}
}
