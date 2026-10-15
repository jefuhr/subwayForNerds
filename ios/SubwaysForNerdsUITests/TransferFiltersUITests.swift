import XCTest

@MainActor
final class TransferFiltersUITests: XCTestCase {
	/// The recorded L train boards at 14 St-Union Sq and connects at 6 Av (station 601).
	private let departureID = "departure_gtfs-l|20260905|122300_L..N||L03N|0"

	func testSharedAndSeparateTransferFiltersAndStationBoardReturn() {
		var app = launch()
		// A favorite chip brings the board back to the train's station later.
		app.buttons["toggleFavorite"].tap()
		openConnections(in: app)
		screenshot("transfer-filters-shared", app: app)

		// Shared mode edits station 601's board filters, never the selected 602 board.
		select(app.buttons["transferDirection_SOUTH"])
		select(app.buttons["transferRouteFilter_F"])
		XCTAssertTrue(app.buttons["transferAllLines"].exists)

		// Opening the board selects 601 and shows the same shared filters.
		openStationBoard(in: app)
		XCTAssertTrue(app.buttons["direction_SOUTH"].waitForExistence(timeout: 10))
		XCTAssertTrue(app.buttons["direction_SOUTH"].isSelected, "Shared mode writes the transfer station's board filters")
		screenshot("transfer-station-board", app: app)

		// The back button returns to the same transfer with its filters.
		app.navigationBars.buttons.element(boundBy: 0).tap()
		assertTransfer(in: app)
		XCTAssertTrue(app.buttons["transferDirection_SOUTH"].isSelected)

		// The interactive edge swipe returns as well.
		openStationBoard(in: app)
		edgeSwipeBack(in: app)
		assertTransfer(in: app)
		screenshot("transfer-after-edge-swipe", app: app)

		// Back again reaches the original train, with its boarding station captured before the station change.
		app.navigationBars.buttons.element(boundBy: 0).tap()
		XCTAssertTrue(app.descendants(matching: .any)["trainDetails"].firstMatch.waitForExistence(timeout: 10))
		XCTAssertTrue(app.staticTexts["Boarding at 14 St-Union Sq"].waitForExistence(timeout: 5))
		returnToBoardList(in: app)
		XCTAssertTrue(app.buttons["selectedStation"].label.contains("6 Av"), "The board stays on the opened station: \(app.buttons["selectedStation"].label)")

		// Separate mode copies 601's board filters on first use, then edits independently.
		setSeparateFilters(true, in: app)
		tab("Board", in: app).tap()
		let favorite = app.buttons["favoriteStation_602"]
		XCTAssertTrue(favorite.waitForExistence(timeout: 10))
		favorite.tap()
		openConnections(in: app)
		XCTAssertTrue(app.buttons["transferDirection_SOUTH"].isSelected, "Separate mode starts from the board filters")
		select(app.buttons["transferDirection_NORTH"])
		// A line with no connections in this direction distinguishes "no matches" and offers a reset.
		app.buttons["transferRouteFilter_F"].tap()
		select(app.buttons["transferRouteFilter_M"])
		if !app.staticTexts["transferNoMatches"].exists { scrollTo(app.staticTexts["transferNoMatches"], in: app) }
		XCTAssertTrue(app.staticTexts["transferNoMatches"].waitForExistence(timeout: 5))
		screenshot("transfer-no-matches", app: app)
		scrollTo(app.buttons["transferResetFilters"], in: app)
		app.buttons["transferResetFilters"].tap()
		XCTAssertFalse(app.staticTexts["transferNoMatches"].waitForExistence(timeout: 2))
		scrollTo(app.buttons["transferDirection_ALL"], in: app)
		XCTAssertTrue(app.buttons["transferDirection_ALL"].isSelected)
		select(app.buttons["transferDirection_NORTH"])

		openStationBoard(in: app)
		XCTAssertTrue(app.buttons["direction_SOUTH"].waitForExistence(timeout: 10))
		XCTAssertTrue(app.buttons["direction_SOUTH"].isSelected, "Separate edits leave the board filters alone")
		app.navigationBars.buttons.element(boundBy: 0).tap()
		assertTransfer(in: app)
		XCTAssertTrue(app.buttons["transferDirection_NORTH"].isSelected)
		app.terminate()

		// Both the mode and the separate entry survive relaunch; turning the mode off keeps the entry.
		app = launch(reset: false)
		setSeparateFilters(false, in: app)
		setSeparateFilters(true, in: app)
		tab("Board", in: app).tap()
		let restored = app.buttons["favoriteStation_602"]
		if restored.waitForExistence(timeout: 5) { restored.tap() }
		openConnections(in: app)
		XCTAssertTrue(app.buttons["transferDirection_NORTH"].isSelected, "Re-enabling reuses the saved transfer entry")
		screenshot("transfer-filters-separate-relaunch", app: app)
	}

	private func launch(reset: Bool = true) -> XCUIApplication {
		continueAfterFailure = false
		let app = XCUIApplication()
		app.launchEnvironment["SFN_API_BASE_URL"] = ProcessInfo.processInfo.environment["SFN_WIDGET_QA_API"] ?? "http://127.0.0.1:8092/subwaysForNerds/api/v1/"
		app.launchEnvironment["SFN_SIMULATE_OUTAGE"] = "0"
		app.launchEnvironment["SFN_RESET_STATE"] = reset ? "1" : "0"
		app.launchEnvironment["SFN_DISABLE_LOCATION"] = "1"
		app.launchEnvironment["SFN_TEST_NOW"] = String(ISO8601DateFormatter().date(from: "2026-09-06T00:59:40Z")!.timeIntervalSince1970)
		app.launch()
		XCTAssertTrue(app.buttons["selectedStation"].waitForExistence(timeout: 20))
		return app
	}

	private func openConnections(in app: XCUIApplication) {
		let departure = app.buttons[departureID]
		scrollTo(departure, in: app)
		departure.tap()
		XCTAssertTrue(app.descendants(matching: .any)["trainDetails"].firstMatch.waitForExistence(timeout: 10))
		let connections = app.buttons["Connections at 6 Av"]
		scrollTo(connections, in: app)
		connections.tap()
		assertTransfer(in: app)
		XCTAssertTrue(app.buttons["transferDirection_ALL"].waitForExistence(timeout: 20))
	}

	private func assertTransfer(in app: XCUIApplication) {
		XCTAssertTrue(app.buttons["openStationBoard"].waitForExistence(timeout: 10))
	}

	private func openStationBoard(in app: XCUIApplication) {
		scrollTo(app.buttons["openStationBoard"], in: app)
		XCTAssertTrue(app.buttons["openStationBoard"].isEnabled)
		app.buttons["openStationBoard"].tap()
		XCTAssertTrue(app.descendants(matching: .any)["stationBoardScreen"].firstMatch.waitForExistence(timeout: 10))
		XCTAssertFalse(app.buttons["openStationBoard"].isHittable)
	}

	/// Drags from the leading edge of the pushed board's column, like the system back gesture.
	private func edgeSwipeBack(in app: XCUIApplication) {
		let board = app.descendants(matching: .any)["stationBoardScreen"].firstMatch
		let frame = board.frame
		let origin = app.coordinate(withNormalizedOffset: .zero)
		let start = origin.withOffset(CGVector(dx: frame.minX + 2, dy: frame.midY))
		let end = origin.withOffset(CGVector(dx: frame.minX + frame.width * 0.8, dy: frame.midY))
		start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
	}

	/// iPhone pops details off the board; iPad keeps the board beside them.
	private func returnToBoardList(in app: XCUIApplication) {
		if !app.buttons["findStation"].firstMatch.isHittable { app.navigationBars.buttons.element(boundBy: 0).tap() }
		XCTAssertTrue(app.buttons["selectedStation"].waitForExistence(timeout: 10))
	}

	private func setSeparateFilters(_ enabled: Bool, in app: XCUIApplication) {
		tab("Settings", in: app).tap()
		let toggle = app.switches["separateTransferFilters"]
		scrollTo(toggle, in: app)
		if (toggle.value as? String == "1") != enabled { toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap() }
		XCTAssertEqual(toggle.value as? String, enabled ? "1" : "0")
	}

	private func select(_ element: XCUIElement) {
		XCTAssertTrue(element.waitForExistence(timeout: 10))
		element.tap()
		XCTAssertTrue(element.isSelected)
	}

	private func tab(_ name: String, in app: XCUIApplication) -> XCUIElement {
		app.tabBars.buttons[name].exists ? app.tabBars.buttons[name] : app.buttons[name].firstMatch
	}

	private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
		for towardTop in [false, true] {
			for _ in 0..<12 {
				if element.exists && element.isHittable { return }
				if towardTop { app.swipeDown() } else { app.swipeUp() }
			}
		}
		XCTAssertTrue(element.waitForExistence(timeout: 10))
		XCTAssertTrue(element.isHittable)
	}

	private func screenshot(_ name: String, app: XCUIApplication) {
		let attachment = XCTAttachment(screenshot: app.screenshot())
		attachment.name = name
		attachment.lifetime = .keepAlways
		add(attachment)
	}
}
