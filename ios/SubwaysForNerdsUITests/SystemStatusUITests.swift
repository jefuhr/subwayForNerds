import XCTest

@MainActor final class SystemStatusUITests: XCTestCase {
	func testSettingsOpensSystemStatusWithEveryDiagnosticSection() {
		continueAfterFailure = false
		let app = XCUIApplication()
		app.launchEnvironment["SFN_RESET_STATE"] = "1"
		app.launchEnvironment["SFN_DISABLE_LOCATION"] = "1"
		app.launchEnvironment["SFN_API_BASE_URL"] = ProcessInfo.processInfo.environment["SFN_WIDGET_QA_API"] ?? "http://127.0.0.1:8092/subwaysForNerds/api/v1/"
		app.launch()
		let settings = app.tabBars.buttons["Settings"].exists ? app.tabBars.buttons["Settings"] : app.buttons["Settings"].firstMatch
		XCTAssertTrue(settings.waitForExistence(timeout: 10))
		settings.tap()

		let entry = app.buttons["systemStatusSettings"]
		reveal(entry, in: app)
		XCTAssertTrue(entry.isHittable)
		entry.tap()

		XCTAssertTrue(app.navigationBars["System status"].waitForExistence(timeout: 5))
		XCTAssertTrue(app.descendants(matching: .any)["systemStatusTotalStorage"].waitForExistence(timeout: 15))
		// Rows leave the accessibility tree once scrolled away, so each is checked as it appears.
		let expected = [
			"systemStatusAppBundleStorage": "App bundle", "systemStatusSettingsStorage": "Settings", "systemStatusCacheStorage": "Cache",
			// A fresh install has no fleet pack.
			"systemStatusFleetStorage": "Not downloaded", "systemStatusDeviceFreeStorage": "Available on device",
			"systemStatusNetworkStrength": "Signal & link quality", "systemStatusRamUsed": "App RAM used",
			"systemStatusThermalState": "Thermal state", "systemStatusLowPowerMode": "Low Power Mode"
		]
		for identifier in ["systemStatusAppBundleStorage", "systemStatusSettingsStorage", "systemStatusCacheStorage", "systemStatusFleetStorage", "systemStatusDeviceFreeStorage", "systemStatusNetworkStrength", "systemStatusRamUsed", "systemStatusThermalState", "systemStatusLowPowerMode"] {
			let element = app.descendants(matching: .any)[identifier]
			reveal(element, in: app)
			XCTAssertTrue(element.exists, "\(identifier) is missing")
			XCTAssertTrue(element.label.contains(expected[identifier]!), "\(identifier) reads \(element.label)")
		}
		let refresh = app.buttons["refreshSystemStatus"]
		reveal(refresh, in: app)
		refresh.tap()
		XCTAssertTrue(app.descendants(matching: .any)["systemStatusLowPowerMode"].waitForExistence(timeout: 5))

		let screenshot = XCTAttachment(screenshot: app.screenshot())
		screenshot.name = "System status"
		screenshot.lifetime = .keepAlways
		add(screenshot)
	}

	func testSettingsAndSystemStatusDropExplanatoryText() {
		continueAfterFailure = false
		let app = XCUIApplication()
		app.launchEnvironment["SFN_RESET_STATE"] = "1"
		app.launchEnvironment["SFN_DISABLE_LOCATION"] = "1"
		app.launchEnvironment["SFN_API_BASE_URL"] = ProcessInfo.processInfo.environment["SFN_WIDGET_QA_API"] ?? "http://127.0.0.1:8092/subwaysForNerds/api/v1/"
		app.launch()
		let settings = app.tabBars.buttons["Settings"].exists ? app.tabBars.buttons["Settings"] : app.buttons["Settings"].firstMatch
		XCTAssertTrue(settings.waitForExistence(timeout: 10))
		settings.tap()
		XCTAssertTrue(app.buttons["combinedStationsSettings"].waitForExistence(timeout: 10))
		// Footers, the tagline and the About caption explained how things work; the data rows stay.
		assertNoTextWhileScrolling(in: app, prefixes: [
			"Know the system", "When off, connections at a station", "Applies to the app and widgets", "Widgets use your station selection",
			"Boards you view, nearby boards", "App storage breakdown, network link quality", "Times are predictions, not promises", "Your current station stays separate",
			"Move combined stations, hidden lines"
		])
		let entry = app.buttons["systemStatusSettings"]
		reveal(entry, in: app)
		entry.tap()
		XCTAssertTrue(app.navigationBars["System status"].waitForExistence(timeout: 5))
		XCTAssertTrue(app.descendants(matching: .any)["systemStatusTotalStorage"].waitForExistence(timeout: 15))
		assertNoTextWhileScrolling(in: app, prefixes: ["Installed app, widgets, and frameworks", "Settings, preferences, and widget choices", "App RAM is the footprint"])
		let cache = app.descendants(matching: .any)["systemStatusCacheStorage"]
		reveal(cache, in: app)
		XCTAssertTrue(cache.exists, "Storage sizes stay")
	}

	/// Rows leave the accessibility tree once scrolled away, so each page is checked as it appears.
	private func assertNoTextWhileScrolling(in app: XCUIApplication, prefixes: [String]) {
		let explanatory = NSCompoundPredicate(orPredicateWithSubpredicates: prefixes.map { NSPredicate(format: "label BEGINSWITH %@", $0) })
		for _ in 0..<16 {
			let match = app.staticTexts.matching(explanatory).firstMatch
			XCTAssertFalse(match.exists, "Explanatory text was removed, but this is back: \(match.exists ? match.label : "")")
			app.swipeUp()
		}
		for _ in 0..<16 { app.swipeDown() }
	}

	private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
		for _ in 0..<20 {
			if element.exists && element.isHittable { return }
			app.swipeUp()
		}
	}
}
