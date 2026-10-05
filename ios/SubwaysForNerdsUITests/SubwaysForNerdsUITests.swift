import XCTest

@MainActor
final class SubwaysForNerdsUITests: XCTestCase {
	private func launch(reset: Bool = true, offline: Bool = false, location: String? = nil, systemLocation: Bool = false) -> XCUIApplication {
		continueAfterFailure = false
		let app = XCUIApplication()
		app.launchEnvironment["SFN_API_BASE_URL"] = offline
			? "http://127.0.0.1:1/subwaysForNerds/api/v1/"
			: (ProcessInfo.processInfo.environment["SFN_WIDGET_QA_API"] ?? "http://127.0.0.1:8092/subwaysForNerds/api/v1/")
		app.launchEnvironment["SFN_RESET_STATE"] = reset ? "1" : "0"
		app.launchEnvironment["SFN_DISABLE_LOCATION"] = location == nil && !systemLocation ? "1" : "0"
		app.launchEnvironment["SFN_TEST_LOCATION"] = location
		app.launchEnvironment["SFN_TEST_NOW"] = String(ISO8601DateFormatter().date(from: "2026-09-06T00:59:40Z")!.timeIntervalSince1970)
		app.launch()
		XCTAssertTrue(app.buttons["selectedStation"].waitForExistence(timeout: 20))
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
		station.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
		XCTAssertEqual(station.value as? String, "0")
		let cars = app.switches["widgetField_carCount"]
		scrollTo(cars, in: app)
		cars.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
		XCTAssertEqual(cars.value as? String, "1")
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
				XCTAssertEqual(app.staticTexts["widgetInlineDepartures"].label, "↑B2m Q4m  ↓Q3m B5m")
			} else {
				for direction in ["NORTH", "SOUTH"] {
					for index in 0..<2 {
						let slot = app.descendants(matching: .any)["widgetDeparture_\(direction)_\(index)"]
						XCTAssertTrue(slot.isHittable, "Both departures must fit in each direction")
					}
				}
			}
			screenshot("widget-two-departures-\(family)", app: app)
		}
		app.buttons["widgetPreviewScenario"].tap(); app.buttons["Saved"].tap()
		XCTAssertTrue(app.staticTexts["last est."].exists)
		screenshot("widget-two-departures-saved", app: app)
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
