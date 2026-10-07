import XCTest

@MainActor
final class SubwaysForNerdsUITests: XCTestCase {
	private func launch(reset: Bool = true, offline: Bool = false, location: String? = nil, systemLocation: Bool = false, settingsFile: String? = nil) -> XCUIApplication {
		continueAfterFailure = false
		let app = XCUIApplication()
		app.launchEnvironment["SFN_API_BASE_URL"] = offline
			? "http://127.0.0.1:1/subwaysForNerds/api/v1/"
			: (ProcessInfo.processInfo.environment["SFN_WIDGET_QA_API"] ?? "http://127.0.0.1:8092/subwaysForNerds/api/v1/")
		app.launchEnvironment["SFN_TEST_SETTINGS_FILE"] = settingsFile
		app.launchEnvironment["SFN_RESET_STATE"] = reset ? "1" : "0"
		app.launchEnvironment["SFN_DISABLE_LOCATION"] = location == nil && !systemLocation ? "1" : "0"
		app.launchEnvironment["SFN_TEST_LOCATION"] = location
		app.launchEnvironment["SFN_TEST_NOW"] = String(ISO8601DateFormatter().date(from: "2026-09-06T00:59:40Z")!.timeIntervalSince1970)
		app.launch()
		if settingsFile == nil { XCTAssertTrue(app.buttons["selectedStation"].waitForExistence(timeout: 20)) }
		else { XCTAssertTrue(app.navigationBars["Import settings"].waitForExistence(timeout: 20)) }
		return app
	}

	func testClosestFavoriteOnOfflineLaunchAndForegroundReturn() {
		var app = launch()
		XCTAssertTrue(app.buttons["direction_ALL"].waitForExistence(timeout: 20))
		app.buttons["toggleFavorite"].tap()
		app.buttons["findStation"].tap()
		let search = app.searchFields.firstMatch
		XCTAssertTrue(search.waitForExistence(timeout: 5))
		search.tap(); search.typeText("Times Sq")
		let timesSquare = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'station_' AND label CONTAINS[c] 'Times'")).firstMatch
		XCTAssertTrue(timesSquare.waitForExistence(timeout: 5))
		timesSquare.tap()
		app.buttons["toggleFavorite"].tap()
		app.buttons["favoriteStation_602"].tap()
		app.terminate()

		// Use the saved catalog immediately, even while a network request fails.
		app = launch(reset: false, offline: true, location: "40.755290,-73.987495")
		let nearest = NSPredicate(format: "label CONTAINS[c] 'Times'")
		XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: nearest, object: app.buttons["selectedStation"])], timeout: 5), .completed)
		app.buttons["favoriteStation_602"].tap()
		let manualStation = app.buttons["selectedStation"].label
		XCTAssertFalse(manualStation.contains("Times"), "A manual station choice wins for this visit")
		app.activate()
		XCTAssertEqual(app.buttons["selectedStation"].label, manualStation)
		XCUIDevice.shared.press(.home)
		XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
		app.activate()
		XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: nearest, object: app.buttons["selectedStation"])], timeout: 5), .completed)
		screenshot("closest-favorite-foreground", app: app)
	}

	func testWidgetSettingsPreserveIndependentFiltersAcrossToggleAndRelaunch() {
		var app = launch()
		app.buttons["toggleFavorite"].tap()
		app.tab("Settings").tap()
		let match = app.switches["widgetMatchAppFilters"]
		scrollTo(match, in: app)
		XCTAssertEqual(match.value as? String, "0")
		app.buttons["widgetFilters_602"].tap()
		let route = app.switches.matching(NSPredicate(format: "identifier BEGINSWITH 'widgetRoute_'" )).firstMatch
		XCTAssertTrue(route.waitForExistence(timeout: 5))
		let routeID = route.identifier
		route.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
		let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: route)
		XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
		screenshot("widget-independent-filters", app: app)
		app.navigationBars.buttons.firstMatch.tap()
		match.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
		XCTAssertFalse(app.buttons["widgetFilters_602"].exists)
		match.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
		app.buttons["widgetFilters_602"].tap()
		XCTAssertEqual(app.switches[routeID].value as? String, "1")
		app.terminate()
		app = launch(reset: false)
		app.tab("Settings").tap()
		scrollTo(app.switches["widgetMatchAppFilters"], in: app)
		app.buttons["widgetFilters_602"].tap()
		XCTAssertEqual(app.switches[routeID].value as? String, "1")
		screenshot("widget-filters-after-relaunch", app: app)
	}

	func testWidgetDisplaySettingsHideInformationAndSurviveRelaunch() {
		var app = launch()
		app.tab("Settings").tap()
		scrollTo(app.buttons["widgetDisplaySettings"], in: app)
		app.buttons["widgetDisplaySettings"].tap()
		let station = app.switches["widgetField_stationName"]
		scrollTo(station, in: app)
		XCTAssertTrue(app.navigationBars["Home Screen display"].waitForExistence(timeout: 15))
		station.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5)).tap()
		XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "0"), object: station)], timeout: 10), .completed)
		let cars = app.switches["widgetField_carCount"]
		scrollTo(cars, in: app)
		cars.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5)).tap()
		XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: cars)], timeout: 10), .completed)
		screenshot("widget-display-settings", app: app)
		app.navigationBars.buttons.firstMatch.tap()
		scrollTo(app.buttons["widgetPreviews"], in: app)
		app.buttons["widgetPreviews"].tap()
		XCTAssertFalse(app.staticTexts["widgetStationName"].exists)
		XCTAssertFalse(app.staticTexts["↑ Uptown / North"].exists)
		screenshot("widget-hidden-heading-and-car-counts", app: app)
		app.terminate()
		app = launch(reset: false)
		app.tab("Settings").tap()
		scrollTo(app.buttons["widgetDisplaySettings"], in: app)
		app.buttons["widgetDisplaySettings"].tap()
		scrollTo(app.switches["widgetField_stationName"], in: app)
		XCTAssertEqual(app.switches["widgetField_stationName"].value as? String, "0")
		scrollTo(app.switches["widgetField_carCount"], in: app)
		XCTAssertEqual(app.switches["widgetField_carCount"].value as? String, "1")
	}

	func testLockScreenWidgetsShowTwoDeparturesInEachDirection() {
		let app = launch()
		app.tab("Settings").tap()
		scrollTo(app.buttons["widgetPreviews"], in: app)
		app.buttons["widgetPreviews"].tap()
		for family in ["Inline", "Circular", "Rectangular"] {
			app.buttons["widgetPreviewFamily"].tap()
			app.buttons[family].tap()
			if family == "Inline" {
				XCTAssertEqual(app.staticTexts["widgetInlineDepartures"].label, "↓Q3m B5m  ↑B2m Q4m")
			} else {
				for direction in ["NORTH", "SOUTH"] {
					for index in 0..<2 {
						let slot = app.descendants(matching: .any)["widgetDeparture_\(direction)_\(index)"]
						XCTAssertTrue(slot.isHittable, "Both departures must fit in each direction")
					}
				}
				let downtown = app.descendants(matching: .any)["widgetDeparture_SOUTH_0"]
				let uptown = app.descendants(matching: .any)["widgetDeparture_NORTH_0"]
				XCTAssertLessThan(downtown.frame.midX, uptown.frame.midX)
				assertLockScreenDeparturesFit(in: app, minimumPerDirection: 2)
			}
			screenshot("widget-two-departures-\(family)", app: app)
		}
		app.buttons["widgetPreviewScenario"].tap(); app.buttons["Saved"].tap()
		XCTAssertTrue(app.staticTexts["last est."].exists)
		assertLockScreenDeparturesFit(in: app, minimumPerDirection: 2)
		screenshot("widget-two-departures-saved", app: app)
		app.navigationBars.buttons.firstMatch.tap()
		for style in ["Minutes and seconds", "Arrival clock time"] {
			for _ in 0..<3 { app.swipeDown() }
			scrollTo(app.buttons["widgetLockScreenSettings"], in: app)
			app.buttons["widgetLockScreenSettings"].tap()
			app.buttons["widgetLockTimeStyle"].tap(); app.buttons[style].tap()
			app.navigationBars.buttons.firstMatch.tap()
			scrollTo(app.buttons["widgetPreviews"], in: app)
			app.buttons["widgetPreviews"].tap()
			app.buttons["widgetPreviewFamily"].tap(); app.buttons["Rectangular"].tap()
			assertLockScreenDeparturesFit(in: app, minimumPerDirection: 2)
			screenshot("lock-arrival-format-\(style)", app: app)
			app.navigationBars.buttons.firstMatch.tap()
		}
	}

	func testLockScreenCustomizationFitsMoreTrainsAndStaysIndependent() {
		var app = launch()
		app.tab("Settings").tap()
		scrollTo(app.buttons["widgetLockScreenSettings"], in: app)
		app.buttons["widgetLockScreenSettings"].tap()
		app.buttons["widgetLockTrainCount"].tap(); app.buttons["Fit as many as possible"].tap()
		app.buttons["widgetLockDirectionOrder"].tap(); app.buttons["Uptown left, downtown right"].tap()
		for field in ["stationName", "carType"] {
			let toggle = app.switches["widgetLockField_\(field)"]
			scrollTo(toggle, in: app)
			toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
			XCTAssertEqual(toggle.value as? String, "0")
		}
		screenshot("lock-customization-settings", app: app)
		app.navigationBars.buttons.firstMatch.tap()
		scrollTo(app.buttons["widgetDisplaySettings"], in: app)
		app.buttons["widgetDisplaySettings"].tap()
		scrollTo(app.switches["widgetField_stationName"], in: app)
		XCTAssertEqual(app.switches["widgetField_stationName"].value as? String, "1", "Lock Screen display must not change Home Screen settings")
		scrollTo(app.switches["widgetField_carType"], in: app)
		XCTAssertEqual(app.switches["widgetField_carType"].value as? String, "1")
		app.terminate()
		app = launch(reset: false)
		app.tab("Settings").tap()
		scrollTo(app.buttons["widgetLockScreenSettings"], in: app)
		app.buttons["widgetLockScreenSettings"].tap()
		XCTAssertTrue(app.buttons["widgetLockTrainCount"].label.contains("Fit as many as possible"))
		XCTAssertTrue(app.buttons["widgetLockDirectionOrder"].label.contains("Uptown left"))
		scrollTo(app.switches["widgetLockField_carType"], in: app)
		XCTAssertEqual(app.switches["widgetLockField_carType"].value as? String, "0")
		app.navigationBars.buttons.firstMatch.tap()
		scrollTo(app.buttons["widgetPreviews"], in: app)
		app.buttons["widgetPreviews"].tap()
		for family in ["Circular", "Rectangular"] {
			app.buttons["widgetPreviewFamily"].tap(); app.buttons[family].tap()
			for direction in ["NORTH", "SOUTH"] {
				let third = app.descendants(matching: .any)["widgetDeparture_\(direction)_2"]
				XCTAssertTrue(third.isHittable, "Maximum density must fit more than two trains in each direction")
			}
			XCTAssertLessThan(app.descendants(matching: .any)["widgetDeparture_NORTH_0"].frame.midX, app.descendants(matching: .any)["widgetDeparture_SOUTH_0"].frame.midX)
			XCTAssertFalse(app.staticTexts["widgetStationName"].exists)
			assertLockScreenDeparturesFit(in: app, minimumPerDirection: 3)
			screenshot("lock-maximum-density-\(family)", app: app)
		}
		app.buttons["widgetPreviewFamily"].tap(); app.buttons["Inline"].tap()
		let inline = app.staticTexts["widgetInlineDepartures"].label
		XCTAssertTrue(inline.hasPrefix("↑"))
		XCTAssertTrue(inline.contains("Q6m") && inline.contains("Q7m"), "Inline maximum density should include a third train in both directions when space allows")
		screenshot("lock-maximum-density-Inline", app: app)
		app.buttons["widgetPreviewFamily"].tap(); app.buttons["Rectangular"].tap()
		app.buttons["widgetPreviewScenario"].tap(); app.buttons["Saved"].tap()
		XCTAssertTrue(app.staticTexts["last est."].isHittable, "Saved predictions must retain their freshness label at maximum density")
		assertLockScreenDeparturesFit(in: app, minimumPerDirection: 1)
		screenshot("lock-maximum-density-saved", app: app)
		app.switches["widgetPreviewLargeText"].tap()
		for family in ["Rectangular", "Circular"] {
			app.buttons["widgetPreviewFamily"].tap(); app.buttons[family].tap()
			assertLockScreenDeparturesFit(in: app, minimumPerDirection: 1)
			XCTAssertTrue(app.staticTexts["last est."].isHittable)
			screenshot("lock-large-text-\(family)", app: app)
		}
	}

	func testHomeScreenWidgetsKeepMarginsSeparateColumnsAndFillTheirHeight() {
		let app = launch()
		app.tab("Settings").tap()
		scrollTo(app.buttons["widgetPreviews"], in: app)
		app.buttons["widgetPreviews"].tap()
		for (family, minimum) in [("Small", 2), ("Medium", 3), ("Large", 7), ("Extra large", 7)] {
			app.buttons["widgetPreviewFamily"].tap(); app.buttons[family].tap()
			let canvas = app.otherElements["widgetPreviewCanvas"]
			XCTAssertTrue(canvas.waitForExistence(timeout: 5))
			// WidgetKit insets Home Screen content by 16 points on every side.
			let content = canvas.frame.insetBy(dx: 15.5, dy: 15.5)
			let heading = app.staticTexts["widgetStationName"].frame
			let reportTime = app.descendants(matching: .any)["widgetUpdatedAt"].frame
			XCTAssertTrue(content.contains(heading), "\(family) heading must stay inside the content margins")
			XCTAssertTrue(content.contains(reportTime), "\(family) report time must stay inside the content margins")
			var columns: [CGRect] = []
			for direction in ["NORTH", "SOUTH"] {
				let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "widgetDeparture_\(direction)_")).allElementsBoundByIndex.map(\.frame)
				XCTAssertGreaterThanOrEqual(rows.count, minimum, "\(family) should fit at least \(minimum) trains per direction")
				guard let first = rows.first else { continue }
				for row in rows {
					XCTAssertTrue(content.contains(row), "\(family) rows must stay inside the content margins")
					XCTAssertGreaterThan(row.minY, heading.maxY)
					XCTAssertFalse(row.intersects(reportTime), "\(family) rows must not run into the report time")
				}
				columns.append(rows.reduce(first) { $0.union($1) })
				if ["Large", "Extra large"].contains(family), let lowest = rows.map(\.maxY).max() {
					XCTAssertLessThan(content.maxY - lowest, first.height + 8, "\(family) should use its height for more trains instead of leaving a gap")
				}
			}
			if columns.count == 2 { XCTAssertFalse(columns[0].intersects(columns[1]), "\(family) direction columns must not overlap") }
			screenshot("home-layout-\(family)", app: app)
		}
	}

	private func assertLockScreenDeparturesFit(in app: XCUIApplication, minimumPerDirection: Int) {
		let canvas = app.otherElements["widgetPreviewCanvas"]
		XCTAssertTrue(canvas.exists)
		XCTAssertEqual(canvas.frame.height, 76, accuracy: 1, "The accessibility container must match the fixed widget size")
		let bounds = canvas.frame.insetBy(dx: 11, dy: 11)
		// Circular widgets are circles, so their rows are checked against the circle itself.
		let circular = abs(canvas.frame.width - canvas.frame.height) < 1
		let center = CGPoint(x: canvas.frame.midX, y: canvas.frame.midY)
		for direction in ["NORTH", "SOUTH"] {
			let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "widgetDeparture_\(direction)_")).allElementsBoundByIndex
			XCTAssertGreaterThanOrEqual(rows.count, minimumPerDirection)
			for row in rows {
				XCTAssertTrue(row.isHittable)
				if circular {
					for corner in [CGPoint(x: row.frame.minX, y: row.frame.minY), CGPoint(x: row.frame.maxX, y: row.frame.minY), CGPoint(x: row.frame.minX, y: row.frame.maxY), CGPoint(x: row.frame.maxX, y: row.frame.maxY)] {
						XCTAssertLessThanOrEqual(hypot(corner.x - center.x, corner.y - center.y), canvas.frame.width / 2 + 0.5, "Departure rows must stay inside the circle")
					}
					continue
				}
				XCTAssertGreaterThanOrEqual(row.frame.minY, bounds.minY)
				XCTAssertLessThanOrEqual(row.frame.maxY, bounds.maxY, "Departure rows must stay inside the widget")
				XCTAssertGreaterThanOrEqual(row.frame.minX, bounds.minX)
				XCTAssertLessThanOrEqual(row.frame.maxX, bounds.maxX)
			}
		}
	}

	func testLockScreenServiceIconsFitCompactWidgetsAndCanBeHidden() {
		var app = launch()
		app.tab("Settings").tap()
		scrollTo(app.buttons["widgetPreviews"], in: app)
		app.buttons["widgetPreviews"].tap()
		for family in ["Circular", "Rectangular"] {
			app.buttons["widgetPreviewFamily"].tap(); app.buttons[family].tap()
			assertLockScreenDeparturesFit(in: app, minimumPerDirection: 2)
			for direction in ["NORTH", "SOUTH"] {
				for index in 0..<2 { XCTAssertTrue(app.images["widgetServiceIcon_\(direction)_\(index)"].isHittable, "Compact mode must retain a service icon for every departure") }
			}
			screenshot("lock-compact-service-icons-\(family)", app: app)
		}
		app.navigationBars.buttons.firstMatch.tap()
		for _ in 0..<3 { app.swipeDown() }
		scrollTo(app.buttons["widgetLockScreenSettings"], in: app)
		app.buttons["widgetLockScreenSettings"].tap()
		let service = app.switches["widgetLockShowService"]
		scrollTo(service, in: app)
		XCTAssertEqual(service.value as? String, "1")
		service.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
		let details = app.switches["widgetLockField_service"]
		scrollTo(details, in: app)
		details.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
		app.navigationBars.buttons.firstMatch.tap()
		scrollTo(app.buttons["widgetPreviews"], in: app)
		app.buttons["widgetPreviews"].tap()
		app.buttons["widgetPreviewFamily"].tap(); app.buttons["Rectangular"].tap()
		XCTAssertFalse(app.images.matching(NSPredicate(format: "identifier BEGINSWITH 'widgetServiceIcon_'" )).firstMatch.exists)
		XCTAssertTrue(app.descendants(matching: .any)["widgetDeparture_NORTH_0"].label.contains("Local"))
		screenshot("lock-service-details-without-icons", app: app)
		app.buttons["widgetPreviewFamily"].tap(); app.buttons["Inline"].tap()
		XCTAssertEqual(app.staticTexts["widgetInlineDepartures"].label, "↓3m 5m  ↑2m 4m")
		app.terminate()
		app = launch(reset: false)
		app.tab("Settings").tap()
		scrollTo(app.buttons["widgetLockScreenSettings"], in: app)
		app.buttons["widgetLockScreenSettings"].tap()
		XCTAssertEqual(app.switches["widgetLockShowService"].value as? String, "0")
		scrollTo(app.switches["widgetLockField_service"], in: app)
		XCTAssertEqual(app.switches["widgetLockField_service"].value as? String, "1")
		screenshot("lock-service-settings-after-relaunch", app: app)
	}

	func testEveryWidgetFamilyAndFailureStateRenders() {
		let app = launch()
		app.tab("Settings").tap()
		scrollTo(app.buttons["widgetPreviews"], in: app)
		app.buttons["widgetPreviews"].tap()
		XCTAssertTrue(app.buttons["widgetPreviewFamily"].waitForExistence(timeout: 5))
		for family in ["Small", "Medium", "Large", "Extra large", "Inline", "Circular", "Rectangular"] {
			app.buttons["widgetPreviewFamily"].tap()
			app.buttons[family].tap()
			XCTAssertTrue(app.staticTexts["widgetPreviewDescription"].label.contains(family))
			if ["Small", "Medium", "Large", "Extra large"].contains(family) {
				XCTAssertTrue(app.staticTexts["widgetStationName"].isHittable, "Every Home Screen size must retain its station heading")
			}
			screenshot("widget-family-\(family)", app: app)
		}
		for scenario in ["Saved", "No favorites", "No matches", "Long name", "Regional", "Location unavailable"] {
			app.buttons["widgetPreviewScenario"].tap()
			app.buttons[scenario].tap()
			XCTAssertTrue(app.staticTexts["widgetPreviewDescription"].label.contains(scenario))
			screenshot("widget-state-\(scenario)", app: app)
		}
		app.switches["widgetPreviewTinted"].tap()
		screenshot("widget-tinted", app: app)
	}

	func testWidgetDeepLinkWinsOverClosestFavoriteStartup() {
		let app = launch(location: "40.755290,-73.987495")
		app.buttons["toggleFavorite"].tap()
		app.buttons["findStation"].tap()
		let search = app.searchFields.firstMatch
		search.tap(); search.typeText("Times Sq")
		XCTAssertTrue(app.buttons["station_611"].waitForExistence(timeout: 10))
		app.buttons["station_611"].tap()
		app.buttons["toggleFavorite"].tap()
		XCUIDevice.shared.press(.home)
		app.open(URL(string: "subwaynerds://board?station=602")!)
		XCTAssertTrue(app.buttons["selectedStation"].waitForExistence(timeout: 10))
		let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS[c] 'Union'"), object: app.buttons["selectedStation"])
		XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
		screenshot("widget-deep-link-displayed-station", app: app)
	}

	func testBoardLocationButtonListsAllStationsByDistance() {
		let app = launch(location: "40.730953,-73.981628")
		XCTAssertTrue(app.buttons["direction_ALL"].waitForExistence(timeout: 20))
		app.buttons["toggleFavorite"].tap()
		app.buttons["nearbyFromBoard"].tap()
		let nearest = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'station_'"))
		XCTAssertTrue(app.staticTexts["nearbyStationSummary"].waitForExistence(timeout: 5))
		let sorted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'closest first'"), object: app.staticTexts["nearbyStationSummary"])
		XCTAssertEqual(XCTWaiter.wait(for: [sorted], timeout: 5), .completed)
		XCTAssertTrue(app.staticTexts["nearbyStationSummary"].label.contains("445 station complexes"), "Nearby shows the entire fixture catalog")
		XCTAssertEqual(nearest.element(boundBy: 0).identifier, "station_119", "The nearest station comes first even when it is not a favorite")
		XCTAssertTrue(app.buttons["Favorite 1 Av"].exists)
		screenshot("board-all-nearby-stations", app: app)
		nearest.element(boundBy: 0).tap()
		XCTAssertTrue(app.buttons["selectedStation"].waitForExistence(timeout: 5))
		XCTAssertTrue(app.buttons["selectedStation"].label.contains("1 Av"))
	}

	func testSearchAndNearbyRemainDistinctAcrossRepeatedOpenings() {
		let app = launch(location: "40.730953,-73.981628")
		app.buttons["findStation"].tap()
		XCTAssertTrue(app.navigationBars["Find a station"].waitForExistence(timeout: 5))
		let search = app.searchFields.firstMatch
		search.tap(); search.typeText("Times Sq")
		XCTAssertTrue(app.buttons["station_611"].waitForExistence(timeout: 10))
		app.buttons["station_611"].tap()
		XCTAssertTrue(app.buttons["selectedStation"].waitForExistence(timeout: 5))

		for _ in 0..<2 {
			app.buttons["nearbyFromBoard"].tap()
			XCTAssertTrue(app.navigationBars["Stations near you"].waitForExistence(timeout: 5))
			let sorted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'closest first'"), object: app.staticTexts["nearbyStationSummary"])
			XCTAssertEqual(XCTWaiter.wait(for: [sorted], timeout: 5), .completed)
			XCTAssertTrue(app.staticTexts["nearbyStationSummary"].label.contains("445 station complexes"), "A previous search must not narrow the nearby list")
			screenshot("nearby-mode", app: app)
			app.buttons["Done"].tap()

			app.buttons["findStation"].tap()
			XCTAssertTrue(app.navigationBars["Find a station"].waitForExistence(timeout: 5))
			XCTAssertTrue(app.staticTexts["nearbyStationSummary"].label.contains("favorites first"), "Search must not inherit nearby ordering")
			screenshot("search-mode", app: app)
			app.buttons["Done"].tap()
		}
	}

	func testNearbyLocationUnavailableStillListsEveryStation() {
		let app = launch()
		app.buttons["nearbyFromBoard"].tap()
		XCTAssertTrue(app.navigationBars["Stations near you"].waitForExistence(timeout: 5))
		XCTAssertTrue(app.staticTexts["Location is disabled. You can still search for any station."].waitForExistence(timeout: 5))
		let catalog = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS '445 station complexes'"), object: app.staticTexts["nearbyStationSummary"])
		XCTAssertEqual(XCTWaiter.wait(for: [catalog], timeout: 10), .completed)
		XCTAssertTrue(app.searchFields.firstMatch.exists)
		screenshot("nearby-location-unavailable", app: app)
	}

	// Run with simulator location set to 40.730953,-73.981628 and location granted.
	func testNearbyUsesSimulatorLocationService() throws {
		try XCTSkipUnless(ProcessInfo.processInfo.environment["SFN_SYSTEM_LOCATION_QA"] == "granted", "Requires the simulator's granted-location QA setup")
		let app = launch(systemLocation: true)
		app.buttons["nearbyFromBoard"].tap()
		XCTAssertTrue(app.navigationBars["Stations near you"].waitForExistence(timeout: 5))
		let sorted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'closest first'"), object: app.staticTexts["nearbyStationSummary"])
		XCTAssertEqual(XCTWaiter.wait(for: [sorted], timeout: 15), .completed)
		let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'station_'")).element(boundBy: 0)
		XCTAssertEqual(first.identifier, "station_119")
		screenshot("nearby-system-location", app: app)
	}

	// Run with the simulator's location permission revoked for this app.
	func testNearbySystemLocationDeniedKeepsSearchAvailable() throws {
		try XCTSkipUnless(ProcessInfo.processInfo.environment["SFN_SYSTEM_LOCATION_QA"] == "denied", "Requires the simulator's denied-location QA setup")
		let app = launch(systemLocation: true)
		app.buttons["nearbyFromBoard"].tap()
		XCTAssertTrue(app.staticTexts["Location permission is off. You can still search for any station, or allow location in the Settings app."].waitForExistence(timeout: 10))
		let search = app.searchFields.firstMatch
		search.tap(); search.typeText("Times Sq")
		XCTAssertTrue(app.buttons["station_611"].waitForExistence(timeout: 10))
		screenshot("nearby-system-location-denied", app: app)
		app.buttons["station_611"].tap()
		XCTAssertTrue(app.buttons["selectedStation"].label.contains("Times"))
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
		station.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5)).tap()
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
		station.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5)).tap()
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
		app.buttons["nearbyFromBoard"].tap()
		XCTAssertTrue(app.staticTexts["Location is disabled. You can still search for any station."].waitForExistence(timeout: 5))
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

	func testSettingsImportPreviewCancelAndRestore() {
		let encoded = Data("""
{
	"format": "subways-for-nerds",
	"version": 1,
	"exportedAt": "2026-10-06T12:00:00Z",
	"lastStation": "602",
	"settings": {
		"favorites": ["602", "future:station"],
		"theme": "hello-kitty",
		"stations": {"602": {"direction": "SOUTH", "routes": ["4", "6"], "view": "family"}},
		"widgets": {
			"matchAppFilters": false,
			"stations": {"future:station": {"direction": "ALL", "routes": ["Q"], "view": "corridor"}},
			"display": {"fields": ["carCount", "destination", "stationName"], "compact": false, "trainsPerDirection": 4, "timeStyle": "clock"}
		}
	}
}
""".utf8).base64EncodedString()
		let app = launch(settingsFile: encoded)
		XCTAssertTrue(app.navigationBars["Import settings"].waitForExistence(timeout: 10))
		app.buttons["Cancel"].tap()
		XCTAssertTrue(app.buttons["theme_subway"].waitForExistence(timeout: 5))
		XCTAssertTrue(app.buttons["theme_subway"].isSelected)
		app.terminate()
		let restored = launch(reset: false, settingsFile: encoded)
		XCTAssertTrue(restored.navigationBars["Import settings"].waitForExistence(timeout: 10))
		let confirm = restored.buttons["confirmSettingsImport"]
		scrollTo(confirm, in: restored); confirm.tap()
		XCTAssertTrue(restored.buttons["theme_hello-kitty"].waitForExistence(timeout: 5))
		XCTAssertTrue(restored.buttons["theme_hello-kitty"].isSelected)
		screenshot("settings-imported", app: restored)
		restored.terminate()
		let relaunched = launch(reset: false)
		relaunched.tab("Settings").tap()
		XCTAssertTrue(relaunched.buttons["theme_hello-kitty"].waitForExistence(timeout: 5))
		XCTAssertTrue(relaunched.buttons["theme_hello-kitty"].isSelected)
		let export = relaunched.buttons["exportSettings"]
		scrollTo(export, in: relaunched); export.tap()
		XCTAssertTrue(relaunched.buttons["Save"].waitForExistence(timeout: 45) || relaunched.navigationBars["Export"].exists)
		screenshot("settings-export", app: relaunched)
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
