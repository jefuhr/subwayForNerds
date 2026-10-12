import XCTest

@MainActor
final class CombinedStationsTests: XCTestCase {
	func testCreatingCombinedStationSelectsBoardAndPreservesOriginalStations() {
		let app = launch()
		selectStation("628", query: "Fulton", name: "Fulton St", in: app)
		app.buttons["direction_SOUTH"].tap()
		app.buttons["boardView_family"].tap()

		let name = "Downtown connection"
		createCombinedStation(name, in: app)
		assertSelectedStation(name, in: app)
		XCTAssertFalse(app.textFields["combinedStationName"].exists, "Saving dismisses the editor")
		XCTAssertFalse(app.buttons["addCombinedStation"].exists, "Saving leaves the group list and selects the Board tab")
		XCTAssertTrue(app.buttons["findStation"].isHittable)
		assertSelected(app.buttons["direction_ALL"])
		assertSelected(app.buttons["boardView_direction"])
		assertSelected(app.buttons["All lines"])
		screenshot("combined-stations-new-direction-board", app: app)
		let groupID = combinedStationID(named: name, in: app)

		selectStation("628", query: "Fulton", name: "Fulton St", in: app)
		assertSelected(app.buttons["direction_SOUTH"])
		assertSelected(app.buttons["boardView_family"])
		selectStation("624", query: "World Trade Center", name: "World Trade Center", in: app)
		selectStation("328", query: "WTC Cortlandt", name: "WTC Cortlandt", in: app)
		selectStation(groupID, query: name, name: name, in: app)
		assertSelected(app.buttons["direction_ALL"])
		assertSelected(app.buttons["boardView_direction"])
		screenshot("combined-stations-originals-remain-searchable", app: app)
	}

	func testCombinedFavoriteAndIndependentStationFiltersSurviveRelaunch() {
		var app = launch()
		selectStation("628", query: "Fulton", name: "Fulton St", in: app)
		app.buttons["toggleFavorite"].tap()
		app.buttons["direction_SOUTH"].tap()
		app.buttons["Filter line 4"].tap()
		assertSelected(app.buttons["Filter line 4"])

		let name = "Downtown favorites"
		createCombinedStation(name, in: app)
		let groupID = combinedStationID(named: name, in: app)
		app.buttons["toggleFavorite"].tap()
		XCTAssertEqual(app.buttons["toggleFavorite"].label, "Remove favorite station")
		app.buttons["direction_NORTH"].tap()
		app.buttons["Filter line 1"].tap()
		assertSelected(app.buttons["Filter line 1"])
		screenshot("combined-stations-favorite-own-filters", app: app)
		app.terminate()

		app = launch(reset: false)
		assertSelectedStation(name, in: app)
		assertSelected(app.buttons["direction_NORTH"])
		assertSelected(app.buttons["Filter line 1"])
		XCTAssertEqual(app.buttons["toggleFavorite"].label, "Remove favorite station")
		XCTAssertEqual(combinedStationID(named: name, in: app), groupID, "Relaunch retains the group's identity")
		selectStation("628", query: "Fulton", name: "Fulton St", in: app)
		assertSelected(app.buttons["direction_SOUTH"])
		assertSelected(app.buttons["Filter line 4"])
		XCTAssertEqual(app.buttons["toggleFavorite"].label, "Remove favorite station")
		let favorite = app.buttons["favoriteStation_" + groupID]
		XCTAssertTrue(favorite.waitForExistence(timeout: 5))
		favorite.tap()
		assertSelectedStation(name, in: app)
		assertSelected(app.buttons["direction_NORTH"])
		assertSelected(app.buttons["Filter line 1"])
		screenshot("combined-stations-favorite-and-filters-relaunch", app: app)
	}

	func testEditingAndConfirmedDeletionPreserveIdentityAndFallBackToRealMember() {
		var app = launch()
		let originalName = "Downtown editor"
		let editedName = "Fulton WTC and PATH"
		createCombinedStation(originalName, in: app)
		let groupID = combinedStationID(named: originalName, in: app)
		app.buttons["toggleFavorite"].tap()
		app.buttons["direction_NORTH"].tap()

		openCombinedStations(in: app)
		let edit = app.buttons["editCombinedStation_" + groupID]
		scrollTo(edit, in: app)
		edit.tap()
		let name = app.textFields["combinedStationName"]
		XCTAssertTrue(name.waitForExistence(timeout: 5))
		XCTAssertEqual(name.value as? String, originalName)
		replaceText(in: name, with: editedName)
		setMember("328", query: "WTC Cortlandt", selected: false, previouslySelected: true, in: app)
		setMember("path-wtc", query: "World Trade Center", selected: true, previouslySelected: false, in: app)
		assertMember("628", query: "Fulton", selected: true, in: app)
		assertMember("624", query: "World Trade Center", selected: true, in: app)
		finishSearch(forToolbar: "saveCombinedStation", in: app)
		app.buttons["saveCombinedStation"].tap()
		assertSelectedStation(editedName, in: app)
		XCTAssertEqual(combinedStationID(named: editedName, in: app), groupID, "Editing must not replace the group's ID")
		XCTAssertEqual(app.buttons["toggleFavorite"].label, "Remove favorite station")
		assertSelected(app.buttons["direction_NORTH"])
		selectStation("328", query: "WTC Cortlandt", name: "WTC Cortlandt", in: app)
		selectStation(groupID, query: editedName, name: editedName, in: app)
		screenshot("combined-stations-edited-members-and-name", app: app)

		openCombinedStations(in: app)
		scrollTo(app.buttons["editCombinedStation_" + groupID], in: app)
		app.buttons["editCombinedStation_" + groupID].tap()
		XCTAssertEqual(app.textFields["combinedStationName"].value as? String, editedName)
		assertMember("328", query: "WTC Cortlandt", selected: false, in: app)
		assertMember("path-wtc", query: "World Trade Center", selected: true, in: app)
		finishSearch(forToolbar: "saveCombinedStation", in: app)
		scrollTo(app.buttons["deleteCombinedStation"], in: app)
		app.buttons["deleteCombinedStation"].tap()
		let confirm = deletionConfirmation(in: app)
		XCTAssertTrue(confirm.waitForExistence(timeout: 5))
		screenshot("combined-stations-delete-confirmation", app: app)
		let cancel = app.alerts.buttons["Cancel"].exists ? app.alerts.buttons["Cancel"] : app.sheets.buttons["Cancel"]
		XCTAssertTrue(cancel.exists)
		cancel.tap()
		XCTAssertTrue(app.textFields["combinedStationName"].exists, "Cancel keeps the editor and group intact")
		XCTAssertEqual(app.textFields["combinedStationName"].value as? String, editedName)
		app.navigationBars.buttons.firstMatch.tap()
		let retainedGroup = app.buttons["editCombinedStation_" + groupID]
		XCTAssertTrue(retainedGroup.waitForExistence(timeout: 5), "Cancel must retain the actual saved group, not just its editor")
		retainedGroup.tap()
		XCTAssertTrue(app.textFields["combinedStationName"].waitForExistence(timeout: 5))
		XCTAssertEqual(app.textFields["combinedStationName"].value as? String, editedName)
		scrollTo(app.buttons["deleteCombinedStation"], in: app)
		app.buttons["deleteCombinedStation"].tap()
		deletionConfirmation(in: app).tap()
		tab("Board", in: app).tap()
		XCTAssertTrue(app.buttons["selectedStation"].waitForExistence(timeout: 10))
		let selectedName = app.buttons["selectedStation"].label
		let remainingMembers = ["Fulton St", "Cortlandt St / Chambers St / World Trade Center / Park Place", "World Trade Center (PATH)"]
		XCTAssertTrue(remainingMembers.contains { selectedName.contains($0) }, "Deleting the selected group falls back to a saved real member, got \(selectedName)")
		XCTAssertFalse(app.buttons["favoriteStation_" + groupID].exists)
		screenshot("combined-stations-deleted-real-member-fallback", app: app)
		assertGroupAbsent(groupID, query: editedName, in: app)
		openCombinedStations(in: app)
		XCTAssertTrue(app.buttons["addCombinedStation"].waitForExistence(timeout: 5))
		XCTAssertFalse(app.buttons["editCombinedStation_" + groupID].exists)
		app.terminate()

		app = launch(reset: false)
		XCTAssertFalse(app.buttons["selectedStation"].label.contains(editedName))
		XCTAssertFalse(app.buttons["favoriteStation_" + groupID].exists)
		assertGroupAbsent(groupID, query: editedName, in: app)
		selectStation("628", query: "Fulton", name: "Fulton St", in: app)
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

	private func createCombinedStation(_ name: String, in app: XCUIApplication) {
		openCombinedStations(in: app)
		let add = app.buttons["addCombinedStation"]
		XCTAssertTrue(add.waitForExistence(timeout: 5))
		add.tap()
		let field = app.textFields["combinedStationName"]
		XCTAssertTrue(field.waitForExistence(timeout: 5))
		replaceText(in: field, with: name)
		for (id, query) in [("628", "Fulton"), ("624", "World Trade Center"), ("328", "WTC Cortlandt")] {
			setMember(id, query: query, selected: true, previouslySelected: false, in: app)
		}
		finishSearch(forToolbar: "saveCombinedStation", in: app)
		let save = app.buttons["saveCombinedStation"]
		XCTAssertTrue(save.waitForExistence(timeout: 5))
		XCTAssertTrue(save.isEnabled)
		save.tap()
		assertSelectedStation(name, in: app)
	}

	private func openCombinedStations(in app: XCUIApplication) {
		tab("Settings", in: app).tap()
		if app.buttons["addCombinedStation"].exists { return }
		let groups = app.buttons["combinedStationsSettings"]
		scrollTo(groups, in: app)
		groups.tap()
		XCTAssertTrue(app.buttons["addCombinedStation"].waitForExistence(timeout: 5))
	}

	private func setMember(_ id: String, query: String, selected: Bool, previouslySelected: Bool, in app: XCUIApplication) {
		search(query, in: app)
		let member = app.buttons["combinedStationMember_" + id]
		scrollTo(member, in: app)
		XCTAssertEqual(member.isSelected, previouslySelected)
		member.tap()
		assertSelected(member, selected: selected)
	}

	private func assertMember(_ id: String, query: String, selected: Bool, in app: XCUIApplication) {
		search(query, in: app)
		assertSelected(app.buttons["combinedStationMember_" + id], selected: selected)
	}

	private func combinedStationID(named name: String, in app: XCUIApplication) -> String {
		app.buttons["findStation"].tap()
		search(name, in: app)
		let result = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'station_combined:' AND label CONTAINS %@", name)).firstMatch
		XCTAssertTrue(result.waitForExistence(timeout: 5))
		let id = String(result.identifier.dropFirst("station_".count))
		XCTAssertNotNil(UUID(uuidString: String(id.dropFirst("combined:".count))))
		result.tap()
		assertSelectedStation(name, in: app)
		return id
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

	private func assertGroupAbsent(_ id: String, query: String, in app: XCUIApplication) {
		app.buttons["findStation"].tap()
		search(query, in: app)
		XCTAssertFalse(app.buttons["station_" + id].waitForExistence(timeout: 2))
		finishSearch(forToolbar: "Done", in: app)
		app.buttons["Done"].tap()
	}

	private func deletionConfirmation(in app: XCUIApplication) -> XCUIElement {
		let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
			app.alerts.buttons["Delete combined station"].exists || app.sheets.buttons["Delete combined station"].exists
		}, object: app)
		XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
		return app.alerts.buttons["Delete combined station"].exists ? app.alerts.buttons["Delete combined station"] : app.sheets.buttons["Delete combined station"]
	}

	private func search(_ query: String, in app: XCUIApplication) {
		let search = app.textFields["combinedStationSearch"].exists ? app.textFields["combinedStationSearch"] : app.searchFields.firstMatch
		XCTAssertTrue(search.waitForExistence(timeout: 5))
		replaceText(in: search, with: query == "Fulton" ? "Fulton J Z" : query)
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
		// As in the existing UITests, iOS 27 can replace the sheet toolbar during search.
		if !app.buttons[identifier].isHittable {
			let close = app.buttons["close"].exists ? app.buttons["close"] : app.buttons["Cancel"]
			if close.exists { close.tap() }
		}
		XCTAssertTrue(app.buttons[identifier].waitForExistence(timeout: 5))
	}

	private func assertSelectedStation(_ name: String, in app: XCUIApplication) {
		let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS[c] %@", name), object: app.buttons["selectedStation"])
		XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 10), .completed)
	}

	private func assertSelected(_ element: XCUIElement, selected: Bool = true) {
		XCTAssertTrue(element.waitForExistence(timeout: 10))
		let state = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in element.isSelected == selected }, object: element)
		XCTAssertEqual(XCTWaiter.wait(for: [state], timeout: 5), .completed)
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
