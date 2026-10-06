import XCTest

/// Opt-in screenshot passes for reviewing widget spacing. The preview gallery covers
/// every family and state; the other passes place real widgets in SpringBoard and the
/// Lock Screen editor, where WidgetKit's own margins, timers, fonts, and tinting apply.
@MainActor
final class WidgetUXPassTests: XCTestCase {
	private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
	private let environment = ProcessInfo.processInfo.environment
	private func list(_ key: String, _ fallback: String) -> [String] { (environment[key] ?? fallback).split(separator: ",").map(String.init) }

	/// Adds each Home Screen size in turn, captures it with live departures, then removes it.
	func testRealHomeScreenWidgets() throws {
		try XCTSkipUnless(environment["SFN_WIDGET_UX_PASS"] == "1", "Opt-in test changes the simulator Home Screen")
		continueAfterFailure = true
		let app = XCUIApplication()
		app.launchEnvironment = ["SFN_RESET_STATE": "1", "SFN_DISABLE_LOCATION": "1", "SFN_API_BASE_URL": environment["SFN_WIDGET_UX_API"] ?? "https://juliet.nyc/subwaysForNerds/api/v1/"]
		app.launch()
		XCTAssertTrue(app.buttons["toggleFavorite"].waitForExistence(timeout: 30))
		app.buttons["toggleFavorite"].tap()
		if let theme = environment["SFN_WIDGET_UX_THEME"] {
			app.tabBars.buttons["Settings"].tap()
			scrollTo(app.buttons["theme_\(theme)"], in: app)
			app.buttons["theme_\(theme)"].tap()
		}
		XCUIDevice.shared.press(.home)
		removeWidgets()
		let sizes = list("SFN_WIDGET_UX_SIZES", "Small,Medium,Large")
		for (page, size) in ["Small", "Medium", "Large"].enumerated() where sizes.contains(size) {
			guard addWidget(page: page, name: size) else { continue }
			sleep(10)
			capture("home-\(size)")
			if environment["SFN_WIDGET_UX_KEEP"] != "1" { removeWidgets() }
		}
	}

	/// Resets the app to live production departures with its default station saved as the only favorite.
	func testPrepareLiveFavorite() throws {
		try XCTSkipUnless(environment["SFN_WIDGET_UX_PASS"] == "1", "Opt-in setup for real widget passes")
		let app = XCUIApplication()
		app.launchEnvironment = ["SFN_RESET_STATE": "1", "SFN_DISABLE_LOCATION": "1", "SFN_API_BASE_URL": environment["SFN_WIDGET_UX_API"] ?? "https://juliet.nyc/subwaysForNerds/api/v1/"]
		app.launch()
		XCTAssertTrue(app.buttons["toggleFavorite"].waitForExistence(timeout: 30))
		app.buttons["toggleFavorite"].tap()
		XCUIDevice.shared.press(.home)
	}

	/// Switches the app theme without resetting state, so widgets already on the Home Screen redraw in it.
	func testApplyThemeToPlacedWidgets() throws {
		try XCTSkipUnless(environment["SFN_WIDGET_UX_PASS"] == "1" && environment["SFN_WIDGET_UX_THEME"] != nil, "Opt-in theme switch")
		let theme = environment["SFN_WIDGET_UX_THEME"] ?? "subway"
		let app = XCUIApplication()
		app.launchEnvironment = ["SFN_DISABLE_LOCATION": "1"]
		app.launch()
		XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 20))
		app.tabBars.buttons["Settings"].tap()
		scrollTo(app.buttons["theme_\(theme)"], in: app)
		app.buttons["theme_\(theme)"].tap()
		XCUIDevice.shared.press(.home)
	}

	/// Shows the Home Screen page that holds placed widgets (the second by default) and captures it.
	func testShowPlacedWidgets() throws {
		try XCTSkipUnless(environment["SFN_WIDGET_UX_PASS"] == "1", "Opt-in screenshot pass")
		XCUIDevice.shared.press(.home)
		sleep(1)
		XCUIDevice.shared.press(.home)
		for _ in 1..<(Int(environment["SFN_WIDGET_UX_PAGE"] ?? "2") ?? 2) { springboard.swipeLeft(); sleep(1) }
		sleep(UInt32(environment["SFN_WIDGET_UX_WAIT"] ?? "15") ?? 15)
		capture("placed-widgets")
	}

	/// Captures placed widgets under each Home Screen appearance, ending with the
	/// last one listed (Default unless overridden) so the simulator is restored.
	func testPlacedWidgetsInEachAppearance() throws {
		try XCTSkipUnless(environment["SFN_WIDGET_UX_PASS"] == "1", "Opt-in test changes the simulator Home Screen")
		continueAfterFailure = true
		for mode in list("SFN_WIDGET_UX_APPEARANCES", "Tinted,Clear,Default") {
			XCUIDevice.shared.press(.home)
			sleep(1)
			XCUIDevice.shared.press(.home)
			springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72)).press(forDuration: 2)
			if springboard.buttons["Edit"].waitForExistence(timeout: 3) { springboard.buttons["Edit"].tap() }
			guard springboard.buttons["Customize"].waitForExistence(timeout: 3) else { XCTFail("Customize missing"); return }
			springboard.buttons["Customize"].tap()
			// "Dark" also names the light/dark control below the appearance choices.
			let choice = springboard.buttons.matching(identifier: mode).firstMatch
			guard choice.waitForExistence(timeout: 3) else { XCTFail("\(mode) missing"); return }
			choice.tap()
			sleep(2)
			if springboard.buttons["dismiss popup"].exists { springboard.buttons["dismiss popup"].tap() }
			else { springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap() }
			if springboard.buttons["Done"].waitForExistence(timeout: 3) { springboard.buttons["Done"].tap() }
			for page in 1...2 {
				springboard.swipeLeft()
				// Widgets redraw after an appearance change; wait past the placeholder.
				sleep(12)
				capture("appearance-\(mode)-page\(page + 1)")
			}
		}
	}

	/// Adds the Lock Screen widgets in PosterBoard's editor and captures them there with live
	/// departures. It always leaves with Cancel, so the simulator's Lock Screen is unchanged.
	/// The editor can show a render from an earlier build of the extension, so compare
	/// layout details with the preview gallery.
	func testRealLockScreenWidgets() throws {
		try XCTSkipUnless(environment["SFN_WIDGET_UX_PASS"] == "1", "Opt-in test opens the simulator Lock Screen editor")
		continueAfterFailure = true
		let posterBoard = XCUIApplication(bundleIdentifier: "com.apple.PosterBoard")
		defer {
			if posterBoard.buttons["editing-cancel"].exists { posterBoard.buttons["editing-cancel"].tap() }
			XCUIDevice.shared.press(.home)
		}
		if posterBoard.buttons["editing-cancel"].exists { posterBoard.buttons["editing-cancel"].tap(); sleep(2) }
		XCUIDevice.shared.press(.home)
		XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
		sleep(2)
		XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
		sleep(2)
		springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).press(forDuration: 2)
		guard springboard.buttons["Customize"].waitForExistence(timeout: 5) else { XCTFail("Customize missing"); return }
		springboard.buttons["Customize"].tap()
		guard posterBoard.buttons["Add Widget"].waitForExistence(timeout: 8) else { XCTFail("Add Widget missing"); return }
		posterBoard.buttons["Add Widget"].tap()
		sleep(2)
		capture("lock-gallery")
		let ours = posterBoard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'Subway Nerds'")).firstMatch
		for _ in 0..<8 where !(ours.exists && ours.isHittable) { posterBoard.swipeUp(); sleep(1) }
		guard ours.exists else { XCTFail("Subway Nerds missing from the Lock Screen gallery"); return }
		ours.tap()
		sleep(2)
		capture("lock-gallery-app")
		// The circular and rectangular previews have no accessibility elements of their own.
		for x in [0.28, 0.61] {
			posterBoard.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.75)).tap()
			sleep(2)
		}
		capture("lock-gallery-added")
		if posterBoard.buttons["close"].exists { posterBoard.buttons["close"].tap() }
		sleep(1)
		// Drag the app list down by its grabber to uncover the widgets.
		posterBoard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).press(forDuration: 0.05, thenDragTo: posterBoard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
		sleep(Int(environment["SFN_WIDGET_UX_WAIT"] ?? "30").map(UInt32.init) ?? 30)
		capture("lock-editor-widgets")
	}

	/// Element screenshots of the preview canvas for each family, state, and theme.
	func testCapturePreviewGallery() throws {
		try XCTSkipUnless(environment["SFN_WIDGET_UX_PASS"] == "1", "Opt-in screenshot pass")
		continueAfterFailure = true
		let families = list("SFN_WIDGET_UX_FAMILIES", "Small,Medium,Large,Extra large,Inline,Circular,Rectangular")
		let scenarios = list("SFN_WIDGET_UX_SCENARIOS", "Live,Saved,No favorites,No matches,Long name,Regional,Location unavailable,Track groups")
		let app = XCUIApplication()
		app.launchEnvironment = ["SFN_RESET_STATE": "1", "SFN_DISABLE_LOCATION": "1", "SFN_API_BASE_URL": environment["SFN_WIDGET_QA_API"] ?? "http://127.0.0.1:8092/subwaysForNerds/api/v1/",
			"SFN_TEST_NOW": String(ISO8601DateFormatter().date(from: "2026-09-06T00:59:40Z")!.timeIntervalSince1970)]
		app.launch()
		XCTAssertTrue(app.buttons["selectedStation"].waitForExistence(timeout: 20))
		for theme in list("SFN_WIDGET_UX_THEMES", "subway") {
			app.tabBars.buttons["Settings"].tap()
			scrollTo(app.buttons["theme_\(theme)"], in: app)
			app.buttons["theme_\(theme)"].tap()
			scrollTo(app.buttons["widgetPreviews"], in: app)
			app.buttons["widgetPreviews"].tap()
			for family in families {
				app.buttons["widgetPreviewFamily"].tap(); app.buttons[family].tap()
				for scenario in scenarios {
					app.buttons["widgetPreviewScenario"].tap(); app.buttons[scenario].tap()
					captureCanvas("\(theme)-\(family)-\(scenario)", app: app)
				}
				app.buttons["widgetPreviewScenario"].tap(); app.buttons["Live"].tap()
				for toggle in ["widgetPreviewTinted", "widgetPreviewLargeText"] where environment["SFN_WIDGET_UX_MODES"] != "0" {
					app.switches[toggle].coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
					captureCanvas("\(theme)-\(family)-\(toggle == "widgetPreviewTinted" ? "Tinted" : "Large text")", app: app)
					app.switches[toggle].coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
				}
			}
			app.navigationBars.buttons.firstMatch.tap()
			for _ in 0..<4 { app.swipeDown() }
		}
	}

	/// The iOS 27 widget gallery draws its size pages and Add button without
	/// accessibility elements on the simulator, so those steps use coordinates.
	private func addWidget(page: Int, name: String) -> Bool {
		let icon = springboard.icons.matching(NSPredicate(format: "identifier == 'Subway Nerds' AND NOT (value CONTAINS 'Widget')")).firstMatch
		guard icon.waitForExistence(timeout: 10) else { XCTFail("App icon missing"); return false }
		icon.press(forDuration: 1.5)
		guard springboard.buttons["Edit Home Screen"].waitForExistence(timeout: 5) else { XCTFail("Edit Home Screen missing"); return false }
		springboard.buttons["Edit Home Screen"].tap()
		if springboard.buttons["Edit"].waitForExistence(timeout: 3) { springboard.buttons["Edit"].tap() }
		if springboard.buttons["Add Widget"].waitForExistence(timeout: 3) { springboard.buttons["Add Widget"].tap() }
		else if springboard.buttons["Add Widgets"].exists { springboard.buttons["Add Widgets"].tap() }
		let search = springboard.searchFields.firstMatch
		guard search.waitForExistence(timeout: 10) else { XCTFail("Widget gallery search missing"); return false }
		search.tap(); search.typeText("Subway Nerds")
		let result = springboard.staticTexts["Subway Nerds"].firstMatch
		guard result.waitForExistence(timeout: 10) else { XCTFail("Gallery result missing"); return false }
		result.tap()
		sleep(2)
		for _ in 0..<page {
			springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.55)).press(forDuration: 0.05, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.55)))
			sleep(1)
		}
		sleep(1)
		capture("gallery-\(name)")
		springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.905)).tap()
		if springboard.alerts.buttons["Allow"].waitForExistence(timeout: 4) { springboard.alerts.buttons["Allow"].tap() }
		if springboard.buttons["Done"].waitForExistence(timeout: 3) { springboard.buttons["Done"].tap() }
		return true
	}

	/// Removes this app's widgets from the first few Home Screen pages, then returns to the app icon's page.
	private func removeWidgets() {
		XCUIDevice.shared.press(.home)
		sleep(1)
		XCUIDevice.shared.press(.home)
		for _ in 0..<4 {
			for _ in 0..<4 {
				let widget = springboard.icons.matching(NSPredicate(format: "identifier == 'Subway Nerds' AND value CONTAINS 'Widget'")).allElementsBoundByIndex.first { $0.isHittable }
				guard let widget else { break }
				widget.press(forDuration: 1.5)
				guard springboard.buttons["Remove Widget"].waitForExistence(timeout: 5) else { break }
				springboard.buttons["Remove Widget"].tap()
				if springboard.alerts.buttons["Remove"].waitForExistence(timeout: 3) { springboard.alerts.buttons["Remove"].tap() }
				sleep(1)
			}
			if springboard.icons.matching(NSPredicate(format: "identifier == 'Subway Nerds' AND NOT (value CONTAINS 'Widget')")).firstMatch.isHittable { return }
			springboard.swipeLeft()
			sleep(1)
		}
	}

	private func captureCanvas(_ name: String, app: XCUIApplication) {
		let canvas = app.otherElements["widgetPreviewCanvas"]
		guard canvas.waitForExistence(timeout: 5) else { return }
		let attachment = XCTAttachment(screenshot: canvas.screenshot())
		attachment.name = name
		attachment.lifetime = .keepAlways
		add(attachment)
		// Extra large previews are wider than a phone; capture the trailing half too.
		if name.contains("Extra large") {
			canvas.swipeLeft()
			let trailing = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
			trailing.name = name + " trailing"
			trailing.lifetime = .keepAlways
			add(trailing)
			canvas.swipeRight()
		}
	}

	private func capture(_ name: String) {
		let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
		attachment.name = name
		attachment.lifetime = .keepAlways
		add(attachment)
	}

	private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
		for _ in 0..<12 {
			if element.exists && element.isHittable { return }
			app.swipeUp()
		}
	}
}
