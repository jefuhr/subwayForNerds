import XCTest

@MainActor final class FleetPackUITests: XCTestCase {
	func testDefaultScopeAndExactMultiSelection() {
		let app = launch()
		tab("Settings", in: app).tap()
		reveal(app.buttons["fleetPackScope"], in: app)
		app.buttons["fleetPackScope"].tap()
		XCTAssertTrue(app.buttons["fleetPackEverything"].waitForExistence(timeout: 5))
		XCTAssertTrue(app.segmentedControls["fleetPackHistory"].buttons["7 days"].isSelected)
		XCTAssertTrue(app.buttons["fleetPackAllEquipment"].isSelected)
		let first = app.buttons["fleetPackEquipment_R211A"]
		reveal(first, in: app)
		XCTAssertTrue(first.waitForExistence(timeout: 10))
		first.tap()
		XCTAssertTrue(first.isSelected)
		let second = app.buttons["fleetPackEquipment_R46"]
		reveal(second, in: app)
		XCTAssertTrue(second.exists)
		second.tap()
		XCTAssertTrue(second.isSelected)
		let unknown = app.buttons["fleetPackYard_unknown"]
		reveal(unknown, in: app)
		unknown.tap()
		XCTAssertTrue(unknown.isSelected)
		app.swipeDown(); app.swipeDown(); app.swipeDown()
		app.segmentedControls["fleetPackHistory"].buttons["30 days"].tap()
		app.buttons["fleetPackEverything"].tap()
		XCTAssertTrue(app.segmentedControls["fleetPackHistory"].buttons["30 days"].isSelected)
		XCTAssertTrue(app.buttons["fleetPackAllEquipment"].isSelected)
		let artifact = XCTAttachment(screenshot: app.screenshot())
		artifact.name = "Fleet pack scope defaults and Everything"
		artifact.lifetime = .keepAlways
		add(artifact)
	}

	func testPrepareShowsSizesBeforeSavingAndSavedScopeSurvivesOfflineRelaunch() {
		let app = launch()
		tab("Settings", in: app).tap()
		let prepare = app.buttons["checkFleetDownload"]
		reveal(prepare, in: app)
		XCTAssertTrue(prepare.exists)
		XCTAssertFalse(app.buttons["downloadFleet"].exists)
		prepare.tap()
		let download = app.buttons["downloadFleet"]
		XCTAssertTrue(download.waitForExistence(timeout: 30))
		let archiveSize = app.descendants(matching: .any)["fleetPackArchiveSize"].firstMatch
		reveal(archiveSize, in: app)
		XCTAssertTrue(archiveSize.exists)
		XCTAssertTrue(app.descendants(matching: .any)["fleetPackSavedEstimate"].firstMatch.exists)
		let prepared = XCTAttachment(screenshot: app.screenshot())
		prepared.name = "Prepared archive and saved-size estimate"
		prepared.lifetime = .keepAlways
		add(prepared)
		reveal(download, in: app)
		download.tap()
		let open = app.buttons["openSavedFleet"]
		XCTAssertTrue(open.waitForExistence(timeout: 30))
		app.terminate()
		app.launchEnvironment.removeValue(forKey: "SFN_RESET_STATE")
		app.launchEnvironment["SFN_TEST_OFFLINE"] = "1"
		app.launch()
		tab("Settings", in: app).tap()
		reveal(app.staticTexts["savedFleetScope"], in: app)
		XCTAssertTrue(app.staticTexts["savedFleetScope"].label.contains("7 days"))
		reveal(open, in: app)
		open.tap()
		XCTAssertTrue(app.descendants(matching: .any)["fleetBrowser"].firstMatch.waitForExistence(timeout: 10))
		XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Saved scope:")).firstMatch.exists)
		let saved = XCTAttachment(screenshot: app.screenshot())
		saved.name = "Offline relaunch with saved fleet scope"
		saved.lifetime = .keepAlways
		add(saved)
	}

	private func launch() -> XCUIApplication {
		continueAfterFailure = false
		let app = XCUIApplication()
		app.launchEnvironment["SFN_RESET_STATE"] = "1"
		app.launchEnvironment["SFN_DISABLE_LOCATION"] = "1"
		app.launchEnvironment["SFN_API_BASE_URL"] = ProcessInfo.processInfo.environment["SFN_WIDGET_QA_API"] ?? "http://127.0.0.1:8092/subwaysForNerds/api/v1/"
		app.launch()
		XCTAssertTrue(tab("Settings", in: app).waitForExistence(timeout: 10))
		return app
	}
	private func tab(_ name: String, in app: XCUIApplication) -> XCUIElement {
		app.tabBars.buttons[name].exists ? app.tabBars.buttons[name] : app.buttons[name].firstMatch
	}
	private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
		for _ in 0..<20 {
			if element.exists && element.isHittable { return }
			app.swipeUp()
		}
	}
}
