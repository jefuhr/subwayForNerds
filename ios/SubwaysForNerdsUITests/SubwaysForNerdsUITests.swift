import XCTest

@MainActor
final class SubwaysForNerdsUITests: XCTestCase {
	private func launch(reset: Bool = true, offline: Bool = false) -> XCUIApplication {
		continueAfterFailure = false
		let app = XCUIApplication()
		app.launchEnvironment["SFN_API_BASE_URL"] = offline
			? "http://127.0.0.1:1/subwaysForNerds/api/v1/"
			: "http://127.0.0.1:8092/subwaysForNerds/api/v1/"
		app.launchEnvironment["SFN_RESET_STATE"] = reset ? "1" : "0"
		app.launchEnvironment["SFN_DISABLE_LOCATION"] = "1"
		app.launchEnvironment["SFN_TEST_NOW"] = String(ISO8601DateFormatter().date(from: "2026-09-06T00:59:40Z")!.timeIntervalSince1970)
		app.launch()
		XCTAssertTrue(app.buttons["selectedStation"].waitForExistence(timeout: 20))
		return app
	}

	func testStationSearchFavoritesAndThemesPersist() {
		var app = launch()
		app.buttons["toggleFavorite"].tap()
		XCTAssertEqual(app.buttons["toggleFavorite"].label, "Remove favorite station")
		app.buttons["findStation"].tap()
		let search = app.searchFields.firstMatch
		XCTAssertTrue(search.waitForExistence(timeout: 5))
		search.tap(); search.typeText("Times Sq")
		let station = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'station_' AND label CONTAINS[c] 'Times'")).firstMatch
		XCTAssertTrue(station.waitForExistence(timeout: 5))
		station.tap()
		XCTAssertTrue(app.buttons["selectedStation"].label.contains("Times"))
		app.tab("Settings").tap()
		scrollTo(app.buttons["theme_hacker"], in: app)
		app.buttons["theme_hacker"].tap()
		XCTAssertTrue(app.buttons["theme_hacker"].isSelected, "Tapping anywhere on a theme tile selects it")
		screenshot("native-theme", app: app)
		app.terminate()
		app = launch(reset: false)
		XCTAssertTrue(app.buttons["selectedStation"].label.contains("Times"))
		app.buttons["findStation"].tap()
		let favorite = app.buttons["station_602"]
		XCTAssertTrue(favorite.waitForExistence(timeout: 5))
		screenshot("native-station-search", app: app)
	}

	func testBoardViewsStayVisibleAndPersistPerStation() {
		var app = launch()
		let departure = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'departure_'")).firstMatch
		XCTAssertTrue(departure.waitForExistence(timeout: 20))
		XCTAssertLessThan(departure.frame.minY, app.frame.height * 0.6, "Station controls should leave room for departure times without scrolling")
		XCTAssertTrue(app.buttons["boardView_track"].isHittable)
		XCTAssertTrue(app.buttons["boardView_track"].isSelected)
		screenshot("compact-board-track", app: app)

		for id in ["direction", "family", "corridor", "track", "service"] {
			let option = app.buttons["boardView_\(id)"]
			XCTAssertTrue(option.waitForExistence(timeout: 5))
			option.tap()
			let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: option)
			XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
			XCTAssertTrue(departure.waitForExistence(timeout: 5))
			screenshot("compact-board-\(id)", app: app)
		}
		app.terminate()
		app = launch(reset: false)
		XCTAssertTrue(app.buttons["boardView_service"].waitForExistence(timeout: 5))
		XCTAssertTrue(app.buttons["boardView_service"].isSelected)
		app.buttons["findStation"].tap()
		let search = app.searchFields.firstMatch
		XCTAssertTrue(search.waitForExistence(timeout: 5))
		search.tap(); search.typeText("Times Sq")
		let station = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'station_' AND label CONTAINS[c] 'Times'")).firstMatch
		XCTAssertTrue(station.waitForExistence(timeout: 5))
		station.tap()
		XCTAssertTrue(app.buttons["boardView_track"].waitForExistence(timeout: 5))
		XCTAssertTrue(app.buttons["boardView_track"].isSelected, "A different station retains its own board view")
	}

	func testTrainDetailsFleetAndPermissionFallback() {
		let app = launch()
		let departure = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'departure_'")).firstMatch
		scrollTo(departure, in: app)
		departure.tap()
		XCTAssertTrue(app.descendants(matching: .any)["trainDetails"].firstMatch.waitForExistence(timeout: 10))
		screenshot("native-train-details", app: app)
		app.tab("Fleet").tap()
		let car = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'fleet_'")).firstMatch
		scrollTo(car, in: app)
		car.tap()
		XCTAssertTrue(app.descendants(matching: .any)["fleetDetails"].firstMatch.waitForExistence(timeout: 10))
		screenshot("native-fleet-details", app: app)
		app.tab("Board").tap()
		// iPad keeps the board beside train details; iPhone pushes details over it.
		if !app.buttons["findStation"].isHittable { app.navigationBars.buttons.firstMatch.tap() }
		app.buttons["findStation"].tap()
		app.buttons["nearbyStations"].tap()
		XCTAssertTrue(app.searchFields.firstMatch.exists, "Search remains available when location is disabled")
	}

	func testDownloadedFleetSurvivesOfflineRelaunch() {
		var app = launch()
		app.tab("Settings").tap()
		scrollTo(app.buttons["downloadFleet"], in: app)
		XCTAssertTrue(app.buttons["downloadFleet"].waitForExistence(timeout: 20))
		app.buttons["downloadFleet"].tap()
		let saved = app.buttons["openSavedFleet"]
		XCTAssertTrue(saved.waitForExistence(timeout: 60))
		screenshot("native-download-complete", app: app)
		app.terminate()
		app = launch(reset: false, offline: true)
		app.tab("Settings").tap()
		scrollTo(app.buttons["openSavedFleet"], in: app)
		app.buttons["openSavedFleet"].tap()
		let car = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'fleet_'")).firstMatch
		scrollTo(car, in: app)
		car.tap()
		XCTAssertTrue(app.descendants(matching: .any)["fleetDetails"].firstMatch.waitForExistence(timeout: 10))
		XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'currently reporting'")).firstMatch.exists)
		screenshot("native-offline-fleet", app: app)
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

private extension XCUIApplication {
	/// iPhone shows a tab bar; iPad shows the same tabs at the top of the window.
	func tab(_ name: String) -> XCUIElement {
		tabBars.buttons[name].exists ? tabBars.buttons[name] : buttons[name].firstMatch
	}
}
