import XCTest

/// Board departure rows against the recorded fixture server: the default rows are short, and each
/// Departure rows setting changes what the row says.
@MainActor
final class DepartureRowSettingsUITests: XCTestCase {
	/// The L train at 14 St-Union Sq: "At 14 St-Union Sq", 0 stops away, and a car assignment.
	private let firstL = "departure_gtfs-l|20260905|122300_L..N||L03N|0"
	/// The next northbound L, which has a gap after the one above.
	private let secondL = "departure_gtfs-l|20260905|122800_L..N||L03N|3"

	func testDefaultRowsAreShortAndEachSettingChangesTheRow() {
		var app = launch(reset: true)
		let consistText = "R211A · 4149–4145"
		let first = row(firstL, in: app)
		let second = row(secondL, in: app)

		// Defaults: one position line, car numbers and the gap shown, and no "reported" qualifier
		// in the Track view group header (the board opens in Track view) or on platform lines.
		XCTAssertTrue(first.label.contains("At 14 St-Union Sq · 0 stops away · "), first.label)
		XCTAssertTrue(first.label.contains(consistText), first.label)
		XCTAssertFalse(first.label.contains("after previous"), first.label)
		XCTAssertTrue(second.label.contains("minutes after previous train"), second.label)
		XCTAssertFalse(second.label.contains("m after previous"), second.label)
		let header = groupHeader(containing: "Track 2", in: app)
		XCTAssertFalse(header.label.contains("reported") || header.label.contains("scheduled"), header.label)
		screenshot("departure-rows-default", app: app)
		chooseView("boardView_direction", in: app)
		XCTAssertTrue(row(firstL, in: app).label.contains("Canarsie · West Side · Track 2"), row(firstL, in: app).label)
		XCTAssertFalse(row(firstL, in: app).label.contains("reported"), row(firstL, in: app).label)
		screenshot("departure-rows-default-direction-view", app: app)

		// Track source on restores the qualifier on platform lines and Track view group headers.
		setToggle("departureRowsTrackProvenance", on: true, in: app)
		tab("Board", in: app).tap()
		XCTAssertTrue(row(firstL, in: app).label.contains("Track 2 · reported"), row(firstL, in: app).label)
		chooseView("boardView_track", in: app)
		XCTAssertTrue(groupHeader(containing: "Track 2", in: app).label.contains("Track 2 · reported"), groupHeader(containing: "Track 2", in: app).label)
		screenshot("departure-rows-track-provenance", app: app)
		setToggle("departureRowsTrackProvenance", on: false, in: app)
		tab("Board", in: app).tap()
		XCTAssertFalse(groupHeader(containing: "Track 2", in: app).label.contains("reported"), groupHeader(containing: "Track 2", in: app).label)

		// Splitting the position restores today's two lines, with the gap beside the stops line.
		setToggle("departureRowsCombinePosition", on: false, in: app)
		tab("Board", in: app).tap()
		XCTAssertFalse(row(firstL, in: app).label.contains("At 14 St-Union Sq · 0 stops away"), row(firstL, in: app).label)
		XCTAssertTrue(row(firstL, in: app).label.contains("At 14 St-Union Sq"), row(firstL, in: app).label)
		XCTAssertTrue(row(firstL, in: app).label.contains("0 stops away"), row(firstL, in: app).label)
		XCTAssertTrue(row(secondL, in: app).label.contains("m after previous"), row(secondL, in: app).label)
		XCTAssertFalse(row(secondL, in: app).label.contains("minutes after previous train"), row(secondL, in: app).label)
		screenshot("departure-rows-split-position", app: app)

		// The gap and the car numbers each hide on their own, in both layouts.
		setToggle("departureRowsHeadway", on: false, in: app)
		setToggle("departureRowsConsist", on: false, in: app)
		tab("Board", in: app).tap()
		XCTAssertFalse(row(secondL, in: app).label.contains("after previous"), row(secondL, in: app).label)
		XCTAssertFalse(row(firstL, in: app).label.contains("R211A"), row(firstL, in: app).label)
		setToggle("departureRowsCombinePosition", on: true, in: app)
		tab("Board", in: app).tap()
		XCTAssertTrue(row(firstL, in: app).label.contains("At 14 St-Union Sq · 0 stops away · "), row(firstL, in: app).label)
		XCTAssertFalse(row(secondL, in: app).label.contains("after previous"), row(secondL, in: app).label)
		screenshot("departure-rows-toggled", app: app)
		app.terminate()

		// Choices survive a relaunch.
		app = launch(reset: false)
		tab("Settings", in: app).tap()
		waitForValue("0", of: toggle("departureRowsTrackProvenance", in: app), id: "departureRowsTrackProvenance")
		waitForValue("1", of: toggle("departureRowsCombinePosition", in: app), id: "departureRowsCombinePosition")
		waitForValue("0", of: toggle("departureRowsConsist", in: app), id: "departureRowsConsist")
		waitForValue("0", of: toggle("departureRowsHeadway", in: app), id: "departureRowsHeadway")
		screenshot("departure-rows-settings", app: app)
	}

	private func launch(reset: Bool) -> XCUIApplication {
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

	private func row(_ id: String, in app: XCUIApplication) -> XCUIElement {
		let element = app.buttons[id]
		scrollTo(element, in: app)
		return element
	}

	private func groupHeader(containing text: String, in app: XCUIApplication) -> XCUIElement {
		let header = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'departureGroup_' AND label CONTAINS %@", text)).firstMatch
		scrollTo(header, in: app, towardTop: true)
		return header
	}

	private func chooseView(_ id: String, in app: XCUIApplication) {
		let chip = app.buttons[id]
		scrollTo(chip, in: app, towardTop: true)
		chip.tap()
		XCTAssertTrue(chip.isSelected)
	}

	private func toggle(_ id: String, in app: XCUIApplication) -> XCUIElement {
		let element = app.switches[id]
		scrollTo(element, in: app)
		return element
	}

	private func setToggle(_ id: String, on enabled: Bool, in app: XCUIApplication) {
		tab("Settings", in: app).tap()
		let element = toggle(id, in: app)
		keepClearOfTabBar(element, in: app)
		// Retry only while the switch visibly has not changed, so a slow update is never toggled twice.
		for attempt in 0..<3 where (element.value as? String == "1") != enabled {
			// The switch sits at the row's trailing edge; the first try taps there, later ones tap the row.
			element.coordinate(withNormalizedOffset: CGVector(dx: attempt == 0 ? 0.92 : 0.5, dy: 0.5)).tap()
			_ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", enabled ? "1" : "0"), object: element)], timeout: 3)
		}
		waitForValue(enabled ? "1" : "0", of: element, id: id)
	}

	/// A row that is technically hittable can still sit under the floating tab bar, so nudge it up first.
	private func keepClearOfTabBar(_ element: XCUIElement, in app: XCUIApplication) {
		for _ in 0..<4 where element.frame.midY > app.frame.height * 0.7 {
			let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
			from.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)))
		}
	}

	/// The switch value updates after the tap's animation, so wait a bounded time instead of reading it at once.
	private func waitForValue(_ value: String, of element: XCUIElement, id: String) {
		let matches = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
		XCTAssertEqual(XCTWaiter().wait(for: [matches], timeout: 5), .completed, "\(id) should become \(value), is \(String(describing: element.value))")
	}

	/// iPhone shows a tab bar; iPad shows the same tabs at the top of the window.
	private func tab(_ name: String, in app: XCUIApplication) -> XCUIElement {
		app.tabBars.buttons[name].exists ? app.tabBars.buttons[name] : app.buttons[name].firstMatch
	}

	private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, towardTop: Bool = false) {
		for toward in [towardTop, !towardTop] {
			for _ in 0..<12 {
				if element.exists && element.isHittable { return }
				if toward { app.swipeDown() } else { app.swipeUp() }
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
