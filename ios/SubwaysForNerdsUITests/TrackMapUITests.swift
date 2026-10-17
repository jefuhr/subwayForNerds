import XCTest
import UIKit

/// Recorded HTTP acceptance only. Run with scripts/test-track-map-ios.sh and an explicit
/// coordinator-leased simulator. Screenshots preserve rendering evidence for visual review;
/// they do not establish rail alignment, complete network coverage or physical-device acceptance.
@MainActor
final class TrackMapUITests: XCTestCase, @unchecked Sendable {
	private let tripKey = "gtfs-l|20260905|122300_L..N|"
	private var app: XCUIApplication?
	private var fixtureBase: URL!
	private let pollWindow: TimeInterval = 18

	override func setUpWithError() throws {
		// XCTest's synchronous lifecycle callbacks are nonisolated in Swift.
		// Assert the UI runner's main executor before accessing this test's state.
		try MainActor.assumeIsolated {
			continueAfterFailure = false
			let endpoint = ProcessInfo.processInfo.environment["SFN_WIDGET_QA_API"] ?? ""
			let url = try XCTUnwrap(URL(string: endpoint), "Supply SFN_WIDGET_QA_API from the isolated map runner")
			XCTAssertTrue(["localhost", "127.0.0.1"].contains(url.host ?? ""), "Recorded local HTTP is required; production is never a fallback")
			let port = try XCTUnwrap(url.port, "Supply an explicit coordinator-leased fixture port")
			XCTAssertTrue((1024...65535).contains(port), "Use an unprivileged coordinator-leased fixture port")
			fixtureBase = url
			XCUIDevice.shared.orientation = .portrait
		}
	}

	override func tearDownWithError() throws {
		try MainActor.assumeIsolated {
			if let app {
				capture("final-\(name)", app)
				app.terminate()
			}
			if fixtureBase != nil { _ = try control(unavailable: false) }
			XCUIDevice.shared.orientation = .portrait
		}
	}

	func testSearchGesturesFitAndViewportSurviveNavigationAndRotation() throws {
		_ = try control(unavailable: false, reset: true)
		let app = launch()
		openMap(app)
		element("track-map-fit", app).tap()
		let initial = try viewport(app)
		search("Union Sq", app)
		let result = element("track-map-search-result-0", app)
		XCTAssertTrue(result.waitForExistence(timeout: 10))
		XCTAssertTrue(result.label.contains("Union Sq"), result.label)
		result.tap()
		waitForKeyboardDismissal(app)
		waitForUnionSquare(app)
		let focused = try viewport(app)
		XCTAssertNotEqual(initial, focused, "Station search must move the map")
		// Bounds center of the three independently reviewed Union Square platform
		// groups in this fixed PDF, rather than merely any change from the fit view.
		XCTAssertEqual(focused.x, 1568, accuracy: 25, "Search must center Union Square")
		XCTAssertEqual(focused.y, 6136, accuracy: 25, "Search must center Union Square")
		let canvas = element("track-map-canvas", app)
		capture("station-focused-before-pinch", app)
		// XCTest starts its virtual fingers only a few points apart. A broad pinch
		// crosses UIKit's recognition threshold while remaining inside the canvas.
		canvas.pinch(withScale: 4, velocity: 1)
		let zoomChanged = NSPredicate { _, _ in
			guard let value = canvas.value as? String,
				let zoom = value.components(separatedBy: CharacterSet(charactersIn: "0123456789.-").inverted).compactMap(Double.init).last else { return false }
			return zoom > focused.zoom
		}
		XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: zoomChanged, object: nil)], timeout: 10), .completed)
		let zoomed = try viewport(app)
		XCTAssertGreaterThan(zoomed.zoom, focused.zoom)
		capture("after-pinch", app)
		canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1,
			thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.6)))
		let panned = try viewport(app)
		XCTAssertNotEqual(panned, zoomed, "Dragging must pan the artwork")
		capture("search-zoom-pan", app)

		tab("Board", app).tap()
		tab("Map", app).tap()
		assertViewport(panned, try viewport(app), "tab return")
		try rotate(to: .landscapeLeft, app)
		assertViewport(panned, try viewport(app), "landscape")
		capture("landscape-viewport", app)
		try rotate(to: .portrait, app)
		assertViewport(panned, try viewport(app), "portrait")

		element("track-map-station-board", app).tap()
		XCTAssertTrue(element("stationBoardScreen", app).waitForExistence(timeout: 15))
		app.navigationBars.buttons.element(boundBy: 0).tap()
		assertViewport(panned, try viewport(app), "station board return")
		assertSearchClearOfTabs(app)
		element("track-map-fit", app).tap()
		let fitted = try viewport(app)
		XCTAssertLessThan(fitted.zoom, panned.zoom)
		XCTAssertEqual(fitted.x, 3672, accuracy: 4)
		XCTAssertEqual(fitted.y, 5770, accuracy: 4)
		capture("fit-full-original-pdf", app)
	}

	func testEstimatedSlowZoneHighlightsLegendAndAccessibleDetails() throws {
		let snapshot = try recordedSnapshot()
		let payload = try XCTUnwrap(snapshot["slowZones"] as? [String: Any], "The integrated fixture must supply slow-zone estimates")
		let zones = try XCTUnwrap(payload["zones"] as? [[String: Any]])
		let mapped = try XCTUnwrap(zones.first { zone in
			!(zone["paths"] as? [[Any]] ?? []).isEmpty && (zone["routes"] as? [String] ?? []).contains("L")
		}, "Keep a reviewed L-line fixture segment for map acceptance")
		let id = try XCTUnwrap(mapped["id"] as? String)
		let segment = try XCTUnwrap(mapped["segment"] as? String)
		let app = launch()
		openMap(app)
		search("Union Sq", app)
		element("track-map-search-result-0", app).tap()
		waitForKeyboardDismissal(app)
		waitForUnionSquare(app)
		let before = try viewport(app)
		let legend = element("track-map-slow-zones", app)
		XCTAssertTrue(legend.waitForExistence(timeout: 15))
		XCTAssertTrue(legend.label.contains("Estimated slow zones"), legend.label)
		XCTAssertTrue(legend.label.contains("Transit Lab"), legend.label)
		capture("slow-zones-amber-under-trains", app)
		selectL(app)
		element("track-map-slow-zones", app).tap()
		let row = element("track-map-slow-zone-\(id)", app)
		if !row.waitForExistence(timeout: 5) { app.swipeUp() }
		XCTAssertTrue(row.waitForExistence(timeout: 5))
		XCTAssertTrue(row.label.contains(segment), row.label)
		XCTAssertTrue(row.label.contains("Estimated"), row.label)
		XCTAssertTrue(row.label.contains("Typically +"), row.label)
		XCTAssertTrue(row.label.contains("Source: Transit Lab"), row.label)
		capture("slow-zones-accessible-segment-delay-kind-source", app)
		element("track-map-slow-zones-done", app).tap()
		assertViewport(before, try viewport(app), "slow-zone details return")
	}

	func testRecordedTrainRouteFilterCertaintyAndDetailReturn() throws {
		let snapshot = try recordedSnapshot()
		let trains = try XCTUnwrap(snapshot["trains"] as? [[String: Any]])
		XCTAssertTrue(trains.contains { $0["key"] as? String == tripKey }, "The recorded L train must remain in the fixture")
		let app = launch()
		openMap(app)
		search("Union Sq", app)
		element("track-map-search-result-0", app).tap()
		waitForKeyboardDismissal(app)
		waitForUnionSquare(app)
		let before = try viewport(app)
		selectL(app)
		// Check overlay placement against recorded top-left PDF points. Exact rail coverage
		// in the source topology and visual artwork review remain separate acceptance gates.
		let train = try XCTUnwrap(trains.first { $0["key"] as? String == tripKey })
		let point = try XCTUnwrap(train["point"] as? [String: Any])
		let marker = element("track-map-marker-\(tripKey)", app)
		XCTAssertTrue(marker.waitForExistence(timeout: 15))
		let canvasFrame = element("track-map-canvas", app).frame
		let x = try XCTUnwrap(point["x"] as? Double)
		let y = try XCTUnwrap(point["y"] as? Double)
		let markerFrame = marker.frame
		XCTAssertEqual(Double(markerFrame.midX), Double(canvasFrame.midX) + (x - before.x) * before.zoom, accuracy: 4, "Marker x must align with the PDF viewport")
		XCTAssertEqual(Double(markerFrame.midY), Double(canvasFrame.midY) + (y - before.y) * before.zoom, accuracy: 4, "Marker y must use the PDF's top-left coordinate contract")
		element("track-map-trains", app).tap()
		let row = element("track-map-train-\(tripKey)", app)
		reveal(row, app)
		XCTAssertTrue(row.label.contains("L"), row.label)
		XCTAssertTrue(row.label.localizedCaseInsensitiveContains("track"), "Track certainty must be spoken: \(row.label)")
		XCTAssertTrue(row.label.localizedCaseInsensitiveContains("position") || row.label.localizedCaseInsensitiveContains("estimated") || row.label.localizedCaseInsensitiveContains("reported"), row.label)
		let visibleRows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "track-map-train-")).allElementsBoundByIndex
		let routeByKey = Dictionary(uniqueKeysWithValues: trains.compactMap { train -> (String, String)? in
			guard let key = train["key"] as? String, let route = train["route"] as? String else { return nil }
			return (key, route)
		})
		for visible in visibleRows {
			XCTAssertEqual(routeByKey[String(visible.identifier.dropFirst("track-map-train-".count))], "L", "Route filter leaked a different line")
		}
		capture("filtered-accessible-trains", app)
		row.tap()
		XCTAssertTrue(element("trainDetails", app).waitForExistence(timeout: 15))
		capture("recorded-train-details", app)
		app.navigationBars.buttons.element(boundBy: 0).tap()
		assertViewport(before, try viewport(app), "train detail return")
		assertSearchClearOfTabs(app)
	}

	func testUnplacedRecordedTrainsRemainIndividuallyAccessible() throws {
		let snapshot = try recordedSnapshot()
		let trains = try XCTUnwrap(snapshot["trains"] as? [[String: Any]])
		let unplaced = try XCTUnwrap(trains.first { $0["placement"] as? String == "unplaced" && $0["route"] as? String == "L" }, "The recorded acceptance feed must include an unplaced L train")
		let key = try XCTUnwrap(unplaced["key"] as? String)
		let reason = try XCTUnwrap(unplaced["reason"] as? String, "The fixture must explain why the train is unplaced")
		let app = launch()
		openMap(app)
		selectL(app)
		element("track-map-trains", app).tap()
		let row = element("track-map-train-\(key)", app)
		reveal(row, app)
		XCTAssertFalse(row.label.isEmpty)
		XCTAssertTrue(row.label.localizedCaseInsensitiveContains("not on"), row.label)
		XCTAssertTrue(row.label.contains(reason), "Unplaced train needs its recorded spoken reason: \(row.label)")
		capture("unplaced-train-reason", app)
	}

	func testReportedTrackDoesNotImplyCertainPosition() throws {
		let snapshot = try recordedSnapshot()
		let trains = try XCTUnwrap(snapshot["trains"] as? [[String: Any]])
		let uncertain = try XCTUnwrap(trains.first { $0["route"] as? String == "L" && $0["placement"] as? String == "near-stop" && $0["trackBasis"] as? String == "reported" })
		let key = try XCTUnwrap(uncertain["key"] as? String)
		let app = launch()
		openMap(app)
		selectL(app)
		element("track-map-trains", app).tap()
		let row = element("track-map-train-\(key)", app)
		reveal(row, app)
		XCTAssertTrue(row.label.contains("reported"), row.label)
		XCTAssertTrue(row.label.contains("Near stop, exact position unknown"), row.label)
		capture("reported-track-uncertain-position", app)
	}

	func testSameNamedStationsRemainDistinctSearchChoices() {
		let app = launch()
		openMap(app)
		search("23 St", app)
		XCTAssertTrue(element("track-map-search-result-1", app).waitForExistence(timeout: 10))
		let choices = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "track-map-search-result-")).allElementsBoundByIndex
		XCTAssertGreaterThanOrEqual(choices.count, 2)
		XCTAssertEqual(Set(choices.map(\.label)).count, choices.count, "Same-name stations need distinct route/borough descriptions")
		capture("same-name-station-choices", app)
	}

	func testPollingStopsHiddenAndBackgroundAndRecoversAfterHTTPFailure() throws {
		_ = try control(unavailable: false, reset: true)
		let app = launch()
		openMap(app)
		try waitForRequests(after: 0)
		let before = try viewport(app)
		tab("Settings", app).tap()
		try pause(2)
		let hidden = try requestCount()
		try pause(pollWindow)
		let afterHidden = try requestCount()
		XCTAssertEqual(afterHidden, hidden, "Map snapshot polling continued in another tab")
		tab("Map", app).tap()
		try waitForRequests(after: hidden)
		assertViewport(before, try viewport(app), "poll response")
		XCUIDevice.shared.press(.home)
		try pause(2)
		let background = try requestCount()
		try pause(pollWindow)
		let afterBackground = try requestCount()
		XCTAssertEqual(afterBackground, background, "Map snapshot polling continued in the background")
		app.activate()
		try waitForRequests(after: background)
		_ = try control(unavailable: true)
		let failedAfter = try requestCount()
		try waitForRequests(after: failedAfter)
		let status = element("track-map-status", app)
		XCTAssertTrue(status.waitForExistence(timeout: 10), "HTTP failure must show a status")
		XCTAssertFalse(status.label.isEmpty)
		XCTAssertTrue(element("track-map-canvas", app).exists, "The installed PDF must survive loss of train HTTP")
		assertViewport(before, try viewport(app), "HTTP failure")
		capture("http-failure-base-map-retained", app)
		let markerQuery = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "track-map-marker-"))
		let allStale = NSPredicate { _, _ in
			markerQuery.count > 0 && markerQuery.matching(NSPredicate(format: "NOT (label CONTAINS %@)", "Stale")).count == 0
		}
		XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: allStale, object: nil)], timeout: 10), .completed,
			"Held markers must announce stale after the failure is presented")
		// Read a bounded sample by stable identity. Re-querying every virtual marker
		// by index can span multiple accessibility refreshes on a loaded simulator.
		let heldKeys = Array(markerQuery.allElementsBoundByIndex.prefix(3)).map(\.identifier)
		XCTAssertFalse(heldKeys.isEmpty, "Recorded live markers are needed to verify freeze")
		let failedMarkers = markerFrames(heldKeys, app)
		try pause(3)
		XCTAssertEqual(markerFrames(heldKeys, app), failedMarkers, "Held train positions must stop moving immediately after failure")
		_ = try control(unavailable: false)
		let recovery = try requestCount()
		try waitForRequests(after: recovery)
		try pause(2)
		XCTAssertFalse(status.exists, "Successful refresh must clear the error banner")
		capture("http-recovered", app)
	}

	func testOverlappingRecordedMarkersOfferTrainChooser() throws {
		_ = try control(unavailable: false, reset: true)
		let app = launch()
		openMap(app)
		try waitForRequests(after: 0)
		element("track-map-fit", app).tap()
		try pause(2)
		// These are virtual accessibility elements over PDFView. XCTest may fail
		// while resolving their activation points even though coordinate taps work.
		// Keep the tap inside the canvas and away from its overlaid controls.
		let interior = element("track-map-canvas", app).frame.insetBy(dx: 24, dy: 120)
		var shown: [CGPoint] = []
		var hit: CGPoint?
		for marker in markers(app) {
			let frame = marker.frame
			let point = CGPoint(x: frame.midX, y: frame.midY)
			guard !frame.isEmpty, point.x.isFinite, point.y.isFinite, interior.contains(point) else { continue }
			if let nearby = shown.first(where: { hypot(point.x - $0.x, point.y - $0.y) < 16 }) {
				hit = CGPoint(x: (point.x + nearby.x) / 2, y: (point.y + nearby.y) / 2)
				break
			}
			shown.append(point)
		}
		let point = try XCTUnwrap(hit, "Frozen feed needs two overlapping plotted markers for chooser acceptance")
		app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y)).tap()
		XCTAssertTrue(app.staticTexts["Choose a train"].waitForExistence(timeout: 10))
		XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", " to ")).count >= 2)
		capture("overlap-train-chooser", app)
	}

	func testDarkControlsAndAccessibilityTextKeepMapActionsReachable() {
		if ProcessInfo.processInfo.environment["SFN_MAP_EXPECT_REDUCED_MOTION"] == "1" {
			XCTAssertTrue(UIAccessibility.isReduceMotionEnabled, "The leased simulator must actually expose reduced motion")
		}
		let app = launch(largeText: true)
		tab("Settings", app).tap()
		let theme = element("theme_hacker", app)
		reveal(theme, app)
		theme.tap()
		XCTAssertTrue(theme.isSelected)
		openMap(app)
		for id in ["track-map-search", "track-map-fit", "track-map-trains"] {
			XCTAssertTrue(element(id, app).isHittable, "Large text obscures \(id)")
		}
		XCTAssertTrue(element("track-map-attribution", app).exists)
		element("track-map-fit", app).tap()
		capture("dark-controls-large-text-original-artwork", app)
	}

	func testInstalledBaseMapSearchAndFitWorkWhenLaunchedOffline() throws {
		let app = launch(offline: true)
		openMap(app)
		XCTAssertTrue(element("track-map-status", app).waitForExistence(timeout: 10))
		XCTAssertTrue(element("track-map-status", app).label.contains("Offline"))
		element("track-map-fit", app).tap()
		let fitted = try viewport(app)
		search("Union Sq", app)
		XCTAssertTrue(element("track-map-search-result-0", app).waitForExistence(timeout: 10))
		element("track-map-search-result-0", app).tap()
		XCTAssertNotEqual(fitted, try viewport(app), "Offline search uses the installed topology")
		XCTAssertTrue(element("track-map-attribution", app).exists)
		capture("offline-installed-pdf-and-local-search", app)
	}

	private func launch(largeText: Bool = false, offline: Bool = false) -> XCUIApplication {
		let app = XCUIApplication()
		app.launchEnvironment = ["SFN_API_BASE_URL": fixtureBase.absoluteString, "SFN_TEST_NOW": "1788656380",
			"SFN_RESET_STATE": "1", "SFN_DISABLE_LOCATION": "1", "SFN_SIMULATE_OUTAGE": offline ? "1" : "0"]
		if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
		self.app = app
		app.launch()
		XCTAssertTrue(tab("Map", app).waitForExistence(timeout: 25))
		return app
	}

	private func openMap(_ app: XCUIApplication) {
		tab("Map", app).tap()
		XCTAssertTrue(element("track-map-canvas", app).waitForExistence(timeout: 30), app.debugDescription)
		XCTAssertTrue(element("track-map-search", app).exists)
		XCTAssertTrue(element("track-map-fit", app).exists)
		XCTAssertTrue(element("track-map-attribution", app).label.contains("vanshnookenraggen"), "The source credit must remain visible")
	}

	private func search(_ query: String, _ app: XCUIApplication) {
		let search = element("track-map-search", app)
		search.tap()
		search.typeText(query)
	}
	private func waitForKeyboardDismissal(_ app: XCUIApplication) {
		let closed = NSPredicate { _, _ in !app.keyboards.firstMatch.exists }
		XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: closed, object: nil)], timeout: 10), .completed)
	}
	private func rotate(to orientation: UIDeviceOrientation, _ app: XCUIApplication) throws {
		XCUIDevice.shared.orientation = orientation
		let landscape = orientation.isLandscape
		let laidOut = NSPredicate { _, _ in
			let window = app.windows.firstMatch.frame
			let canvas = self.element("track-map-canvas", app).frame
			return window.width > 0 && canvas.width > 0
				&& (window.width > window.height) == landscape
				&& (canvas.width > canvas.height) == landscape
		}
		XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: laidOut, object: nil)], timeout: 30), .completed,
			"Rotation must finish laying out the actual window and PDF canvas")
		try pause(0.5)
	}
	private func waitForUnionSquare(_ app: XCUIApplication) {
		let canvas = element("track-map-canvas", app)
		let focused = NSPredicate { _, _ in
			guard let value = canvas.value as? String else { return false }
			let numbers = value.components(separatedBy: CharacterSet(charactersIn: "0123456789.-").inverted).compactMap(Double.init)
			return numbers.count == 3 && abs(numbers[0] - 1568) < 4 && abs(numbers[1] - 6136) < 4
		}
		XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: focused, object: nil)], timeout: 10), .completed,
			"Search must finish centering Union Square before recording its viewport")
	}
	private func selectL(_ app: XCUIApplication) {
		let route = element("track-map-route-L", app)
		XCTAssertTrue(route.waitForExistence(timeout: 20))
		for _ in 0..<8 where !route.isHittable { app.scrollViews.containing(.button, identifier: "track-map-route-all").firstMatch.swipeLeft() }
		XCTAssertTrue(route.isHittable)
		if !route.isSelected { route.tap() }
		XCTAssertTrue(route.isSelected)
	}

	private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
	private func tab(_ label: String, _ app: XCUIApplication) -> XCUIElement { app.tabBars.buttons[label].exists ? app.tabBars.buttons[label] : app.buttons[label].firstMatch }

	private func reveal(_ row: XCUIElement, _ app: XCUIApplication) {
		for down in [false, true] {
			for _ in 0..<40 {
				if row.exists && row.isHittable { return }
				if down { app.swipeDown() } else { app.swipeUp() }
			}
		}
		XCTAssertTrue(row.exists && row.isHittable, "Missing acceptance row: \(row)")
	}

	private struct Viewport: Equatable { let x: Double; let y: Double; let zoom: Double }
	private func viewport(_ app: XCUIApplication) throws -> Viewport {
		let canvas = element("track-map-canvas", app)
		XCTAssertTrue(canvas.waitForExistence(timeout: 15))
		let ready = NSPredicate { _, _ in (canvas.value as? String)?.contains("zoom") == true }
		XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 10), .completed)
		let value = try XCTUnwrap(canvas.value as? String)
		let numbers = value.components(separatedBy: CharacterSet(charactersIn: "0123456789.-").inverted).compactMap(Double.init)
		XCTAssertEqual(numbers.count, 3, "Expected center and scale: \(value)")
		guard numbers.count == 3 else { throw NSError(domain: "TrackMapViewport", code: 1) }
		return Viewport(x: numbers[0], y: numbers[1], zoom: numbers[2])
	}

	private func assertViewport(_ expected: Viewport, _ actual: Viewport, _ step: String) {
		XCTAssertEqual(actual.x, expected.x, accuracy: 4, step)
		XCTAssertEqual(actual.y, expected.y, accuracy: 4, step)
		XCTAssertEqual(actual.zoom, expected.zoom, accuracy: 0.005, step)
	}

	private func assertSearchClearOfTabs(_ app: XCUIApplication) {
		let tabs = app.tabBars.firstMatch
		guard tabs.exists, tabs.frame.midY < app.frame.midY else { return }
		XCTAssertGreaterThanOrEqual(element("track-map-search", app).frame.minY, tabs.frame.maxY - 1,
			"The iPad tab bar must not cover station search after returning to the map")
	}

	private func markerFrames(_ keys: [String], _ app: XCUIApplication) -> [String: CGRect] {
		Dictionary(uniqueKeysWithValues: keys.map { ($0, element($0, app).frame) })
	}
	private func markers(_ app: XCUIApplication) -> [XCUIElement] { app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "track-map-marker-")).allElementsBoundByIndex }

	private func capture(_ name: String, _ app: XCUIApplication) {
		// A full-screen capture preserves landscape orientation; app-only cropping
		// can retain the previous portrait bounds during an interface rotation.
		let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
		shot.name = name; shot.lifetime = .keepAlways; add(shot)
	}

	private func json(_ path: String, body: [String: Bool]? = nil) throws -> [String: Any] {
		let url = try XCTUnwrap(URL(string: path, relativeTo: fixtureBase))
		var request = URLRequest(url: url)
		request.cachePolicy = .reloadIgnoringLocalCacheData
		request.timeoutInterval = 10
		if let body {
			request.httpMethod = "PUT"
			request.setValue("application/json", forHTTPHeaderField: "Content-Type")
			request.httpBody = try JSONSerialization.data(withJSONObject: body)
		}
		// XCTest pumps its run loop while HTTP completes. Suspending a MainActor
		// test here can deadlock XCTest's fail-fast asynchronous teardown on iOS 27.
		let result = TrackMapHTTPResult()
		let completed = expectation(description: "Fixture HTTP \(path)")
		let task = URLSession.shared.dataTask(with: request) { data, response, error in
			if let error { result.store(.failure(error)) }
			else if let data, let response { result.store(.success((data, response))) }
			else { result.store(.failure(URLError(.badServerResponse))) }
			completed.fulfill()
		}
		task.resume()
		defer { task.cancel() }
		XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 15), .completed)
		let (data, response) = try XCTUnwrap(result.read()).get()
		XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "Fixture request \(path)")
		return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
	}

	@discardableResult private func control(unavailable: Bool, reset: Bool = false) throws -> [String: Any] {
		try json("/__test/track-map", body: ["unavailable": unavailable, "resetRequests": reset])
	}
	private func requestCount() throws -> Int {
		let state = try json("/__test/track-map")
		return try XCTUnwrap(state["requests"] as? Int)
	}
	private func recordedSnapshot() throws -> [String: Any] {
		_ = try control(unavailable: false)
		let snapshot = try json("track-map/nyc-2.6.8-v1/snapshot")
		let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
		attachment.name = "recorded-track-map-snapshot"; attachment.lifetime = .keepAlways; add(attachment)
		return snapshot
	}
	private func pause(_ seconds: TimeInterval) throws {
		let elapsed = expectation(description: "Observe lifecycle for \(seconds) seconds")
		DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { elapsed.fulfill() }
		XCTAssertEqual(XCTWaiter.wait(for: [elapsed], timeout: seconds + 10), .completed)
	}
	private func waitForRequests(after previous: Int) throws {
		let deadline = Date().addingTimeInterval(35)
		while try requestCount() <= previous {
			guard Date() < deadline else { XCTFail("No map HTTP request after \(previous)"); return }
			try pause(0.25)
		}
	}
}

private final class TrackMapHTTPResult: @unchecked Sendable {
	private let lock = NSLock()
	private var value: Result<(Data, URLResponse), Error>?
	func store(_ value: Result<(Data, URLResponse), Error>) { lock.withLock { self.value = value } }
	func read() -> Result<(Data, URLResponse), Error>? { lock.withLock { value } }
}
