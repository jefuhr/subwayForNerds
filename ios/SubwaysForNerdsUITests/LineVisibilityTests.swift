import XCTest

@MainActor
final class LineVisibilityTests: XCTestCase {
	func testHiddenOnlyStationDisappearsAndLineVisibilitySurvivesRelaunch() {
		var app = launch()
		selectStation("328", query: "Cortlandt", name: "WTC Cortlandt", in: app)
		openLineVisibility(in: app)
		app.buttons["enableAllLines"].tap()
		setSwitch(app.switches["globalLine_1"], enabled: false, in: app)
		screenshot("global-lines-one-hidden", app: app)
		returnToBoard(in: app)
		assertCortlandtSearch(in: app, includesSingleLineStation: false)
		app.terminate()

		app = launch(reset: false)
		openLineVisibility(in: app)
		assertSwitch(app.switches["globalLine_1"], enabled: false)
		returnToBoard(in: app)
		assertCortlandtSearch(in: app, includesSingleLineStation: false)
		openLineVisibility(in: app)
		setSwitch(app.switches["globalLine_1"], enabled: true, in: app)
		returnToBoard(in: app)
		assertCortlandtSearch(in: app, includesSingleLineStation: true)
		screenshot("global-lines-station-restored", app: app)
		app.terminate()

		app = launch(reset: false)
		openLineVisibility(in: app)
		assertSwitch(app.switches["globalLine_1"], enabled: true)
		returnToBoard(in: app)
		selectStation("328", query: "Cortlandt", name: "WTC Cortlandt", in: app)
	}

	func testAllHiddenAllowsFullCatalogGroupEditingAndPersistentManageLinesRecovery() {
		var app = launch()
		selectStation("628", query: "Fulton", name: "Fulton St", in: app)
		openLineVisibility(in: app)
		app.buttons["enableAllLines"].tap()
		app.buttons["hideAllLines"].tap()
		assertSwitch(app.switches["globalLine_1"], enabled: false)
		assertSwitch(app.switches["globalLine_4"], enabled: false)
		screenshot("global-lines-bulk-hidden", app: app)
		returnToBoard(in: app)
		assertEmptyBoardWithManageLines(in: app)
		screenshot("global-lines-all-hidden-empty-board", app: app)

		// Hidden-only stations stay available to the editor's full catalog.
		tab("Settings", in: app).tap()
		scrollTo(app.buttons["combinedStationsSettings"], in: app)
		app.buttons["combinedStationsSettings"].tap()
		XCTAssertTrue(app.buttons["addCombinedStation"].waitForExistence(timeout: 5))
		app.buttons["addCombinedStation"].tap()
		let field = app.textFields["combinedStationName"]
		XCTAssertTrue(field.waitForExistence(timeout: 5))
		replaceText(in: field, with: "Hidden catalog connection")
		for (id, query) in [("628", "Fulton"), ("624", "World Trade Center"), ("328", "WTC Cortlandt")] {
			search(query, in: app)
			let member = app.buttons["combinedStationMember_" + id]
			scrollTo(member, in: app)
			XCTAssertFalse(member.isSelected)
			member.tap()
			XCTAssertTrue(member.isSelected)
		}
		finishSearch(forToolbar: "saveCombinedStation", in: app)
		let save = app.buttons["saveCombinedStation"]
		XCTAssertTrue(save.isEnabled, "All hidden is a valid global state and must not block saving a group")
		save.tap()
		assertSelectedStation("Hidden catalog connection", in: app)
		assertEmptyBoardWithManageLines(in: app)
		app.buttons["manageLines"].tap()
		XCTAssertTrue(app.buttons["enableAllLines"].waitForExistence(timeout: 5), "The empty board links directly to global line management")
		assertSwitch(app.switches["globalLine_1"], enabled: false)
		app.terminate()

		app = launch(reset: false)
		assertSelectedStation("Hidden catalog connection", in: app)
		assertEmptyBoardWithManageLines(in: app)
		screenshot("global-lines-all-hidden-relaunch", app: app)
		app.buttons["manageLines"].tap()
		XCTAssertTrue(app.buttons["enableAllLines"].waitForExistence(timeout: 5))
		app.buttons["enableAllLines"].tap()
		assertSwitch(app.switches["globalLine_1"], enabled: true)
		assertSwitch(app.switches["globalLine_4"], enabled: true)
		screenshot("global-lines-bulk-recovery", app: app)
		app.terminate()

		app = launch(reset: false)
		assertSelectedStation("Hidden catalog connection", in: app)
		assertCortlandtSearch(in: app, includesSingleLineStation: true)
		selectStation("628", query: "Fulton", name: "Fulton St", in: app)
		openLineVisibility(in: app)
		assertSwitch(app.switches["globalLine_1"], enabled: true)
		assertSwitch(app.switches["globalLine_4"], enabled: true)
	}

	func testGlobalVisibilityOverridesAppFilterAndRetainsIndependentWidgetPreferences() {
		var app = launch()
		assertSelectedStation("Union", in: app)
		XCTAssertTrue(app.buttons["direction_ALL"].waitForExistence(timeout: 20))
		app.buttons["toggleFavorite"].tap()
		app.buttons["Filter line 4"].tap()
		app.buttons["boardView_family"].tap()
		XCTAssertTrue(app.buttons["Filter line 4"].isSelected)
		// Only this recorded fixture board needs a positive departure assertion.
		XCTAssertTrue(departures(in: app).firstMatch.waitForExistence(timeout: 20))

		openWidgetFilters(in: app)
		setSwitch(app.switches["widgetRoute_6"], enabled: true, in: app)
		assertSwitch(app.switches["widgetRoute_4"], enabled: false)
		app.buttons["widgetGrouping"].tap()
		app.buttons["Service"].tap()
		XCTAssertTrue(app.buttons["widgetGrouping"].label.contains("Service"))
		screenshot("global-lines-independent-widget-preferences", app: app)
		returnToBoard(in: app)
		XCTAssertTrue(app.buttons["Filter line 4"].isSelected)
		XCTAssertTrue(app.buttons["boardView_family"].isSelected)

		openLineVisibility(in: app)
		setSwitch(app.switches["globalLine_4"], enabled: false, in: app)
		returnToBoard(in: app)
		assertNoDepartures(in: app)
		screenshot("global-lines-override-selected-app-line", app: app)
		openWidgetFilters(in: app)
		assertSwitch(app.switches["widgetRoute_6"], enabled: true)
		XCTAssertTrue(app.buttons["widgetGrouping"].label.contains("Service"))
		returnToBoard(in: app)
		app.terminate()

		app = launch(reset: false)
		assertSelectedStation("Union", in: app)
		assertNoDepartures(in: app)
		openLineVisibility(in: app)
		assertSwitch(app.switches["globalLine_4"], enabled: false)
		returnToBoard(in: app)
		openWidgetFilters(in: app)
		assertSwitch(app.switches["widgetRoute_6"], enabled: true)
		XCTAssertTrue(app.buttons["widgetGrouping"].label.contains("Service"))
		returnToBoard(in: app)
		openLineVisibility(in: app)
		setSwitch(app.switches["globalLine_4"], enabled: true, in: app)
		returnToBoard(in: app)
		XCTAssertTrue(app.buttons["Filter line 4"].isSelected, "Global visibility must not erase the station's own filter")
		XCTAssertTrue(app.buttons["boardView_family"].isSelected)
		XCTAssertTrue(departures(in: app).firstMatch.waitForExistence(timeout: 20))
		openWidgetFilters(in: app)
		assertSwitch(app.switches["widgetRoute_6"], enabled: true)
		assertSwitch(app.switches["widgetRoute_4"], enabled: false)
		XCTAssertTrue(app.buttons["widgetGrouping"].label.contains("Service"))
		screenshot("global-lines-restored-independent-preferences", app: app)
	}

	func testGlobalControlsExposeCanonicalLineKeys() {
		let app = launch()
		openLineVisibility(in: app)
		app.buttons["enableAllLines"].tap()
		for route in ["4", "5", "6", "7", "F", "S", "SIR"] {
			let control = app.switches["globalLine_" + route]
			scrollTo(control, in: app)
			assertSwitch(control, enabled: true)
			XCTAssertEqual(app.switches.matching(identifier: "globalLine_" + route).count, 1)
		}
		screenshot("global-lines-canonical-shuttle-and-SIR", app: app)
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

	private func openLineVisibility(in app: XCUIApplication) {
		tab("Settings", in: app).tap()
		let lines = app.buttons["lineVisibilitySettings"]
		scrollTo(lines, in: app)
		lines.tap()
		XCTAssertTrue(app.buttons["hideAllLines"].waitForExistence(timeout: 5))
		XCTAssertTrue(app.buttons["enableAllLines"].exists)
	}

	private func openWidgetFilters(in app: XCUIApplication) {
		tab("Settings", in: app).tap()
		let match = app.switches["widgetMatchAppFilters"]
		scrollTo(match, in: app)
		assertSwitch(match, enabled: false)
		let filters = app.buttons["widgetFilters_602"]
		scrollTo(filters, in: app)
		filters.tap()
		XCTAssertTrue(app.buttons["widgetGrouping"].waitForExistence(timeout: 5))
	}

	private func returnToBoard(in app: XCUIApplication) {
		app.navigationBars.buttons.firstMatch.tap()
		tab("Board", in: app).tap()
		XCTAssertTrue(app.buttons["selectedStation"].waitForExistence(timeout: 10))
	}

	private func assertCortlandtSearch(in app: XCUIApplication, includesSingleLineStation: Bool) {
		app.buttons["findStation"].tap()
		search("Cortlandt", in: app)
		// This positive control proves the catalog/search results have loaded.
		XCTAssertTrue(app.buttons["station_624"].waitForExistence(timeout: 5))
		if includesSingleLineStation {
			XCTAssertTrue(app.buttons["station_328"].waitForExistence(timeout: 5))
		} else {
			XCTAssertFalse(app.buttons["station_328"].waitForExistence(timeout: 2), "A station with only globally hidden line 1 must leave the picker")
		}
		finishSearch(forToolbar: "Done", in: app)
		app.buttons["Done"].tap()
	}

	private func selectStation(_ id: String, query: String, name: String, in app: XCUIApplication) {
		app.buttons["findStation"].tap()
		search(query, in: app)
		let station = app.buttons["station_" + id]
		scrollTo(station, in: app)
		station.tap()
		assertSelectedStation(name, in: app)
		XCTAssertTrue(app.buttons["direction_ALL"].waitForExistence(timeout: 20))
	}

	private func search(_ query: String, in app: XCUIApplication) {
		let field = app.textFields["combinedStationSearch"].exists ? app.textFields["combinedStationSearch"] : app.searchFields.firstMatch
		XCTAssertTrue(field.waitForExistence(timeout: 5))
		replaceText(in: field, with: query == "Fulton" ? "Fulton J Z" : query)
	}

	private func replaceText(in field: XCUIElement, with text: String) {
		field.tap()
		let value = field.value as? String ?? ""
		if field.buttons["Clear text"].exists {
			field.buttons["Clear text"].tap()
		} else if !value.isEmpty && value != field.placeholderValue {
			field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
			field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
		}
		field.typeText(text)
		XCTAssertEqual(field.value as? String, text)
		if field.elementType == .textField { field.typeText("\n") }
	}

	private func finishSearch(forToolbar identifier: String, in app: XCUIApplication) {
		if !app.buttons[identifier].isHittable {
			let close = app.buttons["close"].exists ? app.buttons["close"] : app.buttons["Cancel"]
			if close.exists { close.tap() }
		}
		XCTAssertTrue(app.buttons[identifier].waitForExistence(timeout: 5))
	}

	private func setSwitch(_ control: XCUIElement, enabled: Bool, in app: XCUIApplication) {
		scrollTo(control, in: app)
		if control.value as? String != (enabled ? "1" : "0") {
			control.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
		}
		assertSwitch(control, enabled: enabled)
	}

	private func assertSwitch(_ control: XCUIElement, enabled: Bool) {
		XCTAssertTrue(control.waitForExistence(timeout: 5))
		let state = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", enabled ? "1" : "0"), object: control)
		XCTAssertEqual(XCTWaiter.wait(for: [state], timeout: 5), .completed)
	}

	private func assertSelectedStation(_ name: String, in app: XCUIApplication) {
		let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS[c] %@", name), object: app.buttons["selectedStation"])
		XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 10), .completed)
	}

	private func assertEmptyBoardWithManageLines(in app: XCUIApplication) {
		XCTAssertTrue(app.buttons["manageLines"].waitForExistence(timeout: 20))
		assertNoDepartures(in: app)
		XCTAssertFalse(app.descendants(matching: .any)["boardSettingsError"].exists)
	}

	private func departures(in app: XCUIApplication) -> XCUIElementQuery {
		app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'departure_'"))
	}

	private func assertNoDepartures(in app: XCUIApplication) {
		let empty = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.departures(in: app).count == 0 }, object: app)
		XCTAssertEqual(XCTWaiter.wait(for: [empty], timeout: 10), .completed)
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
