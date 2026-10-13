import XCTest

/// Loads through the fixture server's throttled port (`FIXTURE_SLOW_PORT`), where every
/// response body takes about three seconds, so each bar can be read mid-download.
@MainActor final class LoadingBarUITests: XCTestCase {
	func testBoardAndTrainDetailsShowByteProgressWhileDownloading() {
		let app = launch()
		let board = app.descendants(matching: .any)["boardLoading"].firstMatch
		XCTAssertTrue(board.waitForExistence(timeout: 20))
		XCTAssertEqual(board.label, "Loading departures")
		// The station's name joins the text once the catalog has loaded; a fresh install may not have it yet.
		waitForValue(of: board, matching: #"^\d{1,3} percent\. Receiving departures( for .+)? · .+ of .+$"#)
		screenshot("Board loading bar mid-download", app: app)
		XCTAssertTrue(board.waitForNonExistence(timeout: 30))
		let departure = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'departure_'")).firstMatch
		scrollTo(departure, in: app)
		departure.tap()
		let trip = app.descendants(matching: .any)["tripLoading"].firstMatch
		XCTAssertTrue(trip.waitForExistence(timeout: 10))
		XCTAssertEqual(trip.label, "Loading train details")
		waitForValue(of: trip, matching: #"^\d{1,3} percent\. Receiving train details · .+ of .+$"#)
		screenshot("Train details loading bar mid-download", app: app)
		XCTAssertTrue(trip.waitForNonExistence(timeout: 30))
		XCTAssertTrue(app.descendants(matching: .any)["trainDetails"].firstMatch.exists)
	}

	func testFleetPackShowsServerBuildStepsThenDownloadStages() {
		let app = launch()
		XCTAssertTrue(app.descendants(matching: .any)["boardLoading"].firstMatch.waitForNonExistence(timeout: 30))
		tab("Settings", in: app).tap()
		// Thirty days of history is a scope no other test prepares, so the server builds it fresh.
		let scope = app.buttons["fleetPackScope"]
		scrollTo(scope, in: app)
		scope.tap()
		let history = app.segmentedControls["fleetPackHistory"].buttons["30 days"]
		XCTAssertTrue(history.waitForExistence(timeout: 10))
		history.tap()
		app.navigationBars.buttons.element(boundBy: 0).tap()
		let prepare = app.buttons["checkFleetDownload"]
		scrollTo(prepare, in: app)
		prepare.tap()
		let preparing = app.descendants(matching: .any)["preparingFleetPack"].firstMatch
		XCTAssertTrue(preparing.waitForExistence(timeout: 10))
		XCTAssertEqual(preparing.label, "Preparing fleet pack")
		// Server build progress weighs stages by estimate, so it reads as approximate.
		waitForValue(of: preparing, matching: #"^about \d{1,3} percent\. Step \d of \d · .+$"#)
		screenshot("Fleet pack build progress", app: app)
		let download = app.buttons["downloadFleet"]
		XCTAssertTrue(download.waitForExistence(timeout: 60))
		scrollTo(download, in: app)
		download.tap()
		let downloading = app.descendants(matching: .any)["fleetDownloadProgress"].firstMatch
		XCTAssertTrue(downloading.waitForExistence(timeout: 10))
		XCTAssertEqual(downloading.label, "Downloading fleet pack")
		waitForValue(of: downloading, matching: #"^about \d{1,3} percent\. Step 1 of 5 · Downloading the fleet pack · .+ of .+$"#)
		screenshot("Fleet pack download progress", app: app)
		XCTAssertTrue(app.buttons["openSavedFleet"].waitForExistence(timeout: 60))
	}

	private func launch() -> XCUIApplication {
		continueAfterFailure = false
		let app = XCUIApplication()
		app.launchEnvironment["SFN_API_BASE_URL"] = ProcessInfo.processInfo.environment["SFN_SLOW_QA_API"] ?? "http://127.0.0.1:8093/subwaysForNerds/api/v1/"
		app.launchEnvironment["SFN_RESET_STATE"] = "1"
		app.launchEnvironment["SFN_DISABLE_LOCATION"] = "1"
		app.launchEnvironment["SFN_TEST_NOW"] = String(ISO8601DateFormatter().date(from: "2026-09-06T00:59:40Z")!.timeIntervalSince1970)
		app.launch()
		return app
	}

	/// The bar's accessibility value is "<percent> percent. <detail>"; polls until it reads as expected.
	private func waitForValue(of element: XCUIElement, matching pattern: String, timeout: TimeInterval = 20) {
		let deadline = Date().addingTimeInterval(timeout)
		var last = ""
		while Date() < deadline {
			if element.exists {
				last = element.value as? String ?? ""
				if last.range(of: pattern, options: .regularExpression) != nil { return }
			}
			usleep(100_000)
		}
		XCTFail("Value never matched \(pattern). Last value: \(last)")
	}

	private func tab(_ name: String, in app: XCUIApplication) -> XCUIElement {
		app.tabBars.buttons[name].exists ? app.tabBars.buttons[name] : app.buttons[name].firstMatch
	}

	private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
		for _ in 0..<12 {
			if element.exists && element.isHittable { return }
			app.swipeUp()
		}
		XCTAssertTrue(element.waitForExistence(timeout: 10))
	}

	private func screenshot(_ name: String, app: XCUIApplication) {
		let attachment = XCTAttachment(screenshot: app.screenshot())
		attachment.name = name
		attachment.lifetime = .keepAlways
		add(attachment)
	}
}
