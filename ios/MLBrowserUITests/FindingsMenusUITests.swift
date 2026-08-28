//
//  FindingsMenusUITests.swift
//  MLBrowserUITests
//
//  AIA-0748: the Findings toolbar's two menus — Data (export + import) and the sort control.
//

import XCTest

/// Covers the Findings toolbar rearrangement: export and import moved behind one **Data** menu, and
/// a new sort menu offering three orders plus Reverse.
///
/// The UI-test app seeds no findings, so these tests deliberately assert **structure and state**
/// — which controls exist, what they expose to VoiceOver, what a selection does to them — rather
/// than row ordering. The ordering rule itself is covered exhaustively and cheaply by
/// `FindingsListOrderingTests` in the unit suite; re-testing it by driving a simulator would be
/// slower and prove less.
final class FindingsMenusUITests: UITestCase {

	/// A `Menu` maps onto more than one underlying element, so `descendants(matching: .any)[id]`
	/// is an ambiguous query and raises "Multiple matching elements found" the moment it is tapped.
	/// Resolve to the first match explicitly.
	private func control(_ id: String) -> XCUIElement {
		app.descendants(matching: .any).matching(identifier: id).firstMatch
	}

	/// Existence, resolved the same way, so an ambiguous query cannot make `.exists` unreliable.
	private func isPresent(_ id: String) -> Bool {
		control(id).exists
	}

	/// Opens the drawer and taps through to the Findings sheet.
	///
	/// Retries the tap once for the same reason `openSettings` does: on a slow runner the first tap
	/// can land while the drawer is still animating and be dropped.
	private func openFindings(file: StaticString = #filePath, line: UInt = #line) {
		openDrawer(file: file, line: line)
		let findings = app.buttons[AID.drawerFindings]
		let dismiss = app.buttons[AID.findingsDismiss]
		for _ in 0..<2 {
			let hittable = NSPredicate(format: "exists == true && hittable == true")
			_ = XCTWaiter().wait(
				for: [XCTNSPredicateExpectation(predicate: hittable, object: findings)],
				timeout: 8
			)
			if findings.isHittable {
				findings.tap()
			}
			if dismiss.waitForExistence(timeout: 8) {
				return
			}
		}
		XCTAssertTrue(dismiss.exists, "Findings sheet did not appear", file: file, line: line)
	}

	// MARK: - Data menu

	/// Export and import are no longer top-level toolbar buttons: they are reachable only after
	/// opening Data. Asserting their *absence* first is what actually pins the grouping — without
	/// it this test would still pass if the old buttons had been left in place beside the menu.
	func testFindingsToolbar_exportAndImportAreBehindTheDataMenu() {
		launch()
		openFindings()

		let dataMenu = control(AID.findingsDataMenu)
		XCTAssertTrue(dataMenu.waitForExistence(timeout: 10), "Data menu missing from the Findings toolbar")

		XCTAssertFalse(
			isPresent(AID.findingsExport),
			"Export is still a top-level toolbar button; it should be inside the Data menu"
		)
		XCTAssertFalse(
			isPresent(AID.findingsImport),
			"Import is still a top-level toolbar button; it should be inside the Data menu"
		)

		dataMenu.tap()

		XCTAssertTrue(
			control(AID.findingsExport).waitForExistence(timeout: 5),
			"Export missing from the Data menu"
		)
		XCTAssertTrue(
			isPresent(AID.findingsImport),
			"Import missing from the Data menu"
		)
	}

	/// The UI-test app seeds no findings, so export has nothing to write and must be unavailable,
	/// while import — which is how you would get findings in — stays available.
	func testFindingsDataMenu_exportIsDisabledWithNoFindings_importIsNot() {
		launch()
		openFindings()

		control(AID.findingsDataMenu).tap()

		let export = control(AID.findingsExport)
		XCTAssertTrue(export.waitForExistence(timeout: 5), "Export missing from the Data menu")
		XCTAssertFalse(export.isEnabled, "Export should be disabled when there are no findings")
		XCTAssertTrue(control(AID.findingsImport).isEnabled, "Import should stay available")
	}

	// MARK: - Sort menu

	func testFindingsSortMenu_offersThreeOrdersAndReverse() {
		launch()
		openFindings()

		let sortMenu = control(AID.findingsSortOrder)
		XCTAssertTrue(sortMenu.waitForExistence(timeout: 10), "Sort menu missing from the Findings toolbar")
		sortMenu.tap()

		// Addressed by identifier, never by visible text: the titles are localized into sixteen
		// languages, and a test that matches English would only ever be right by accident.
		let orders = [
			(AID.findingsSortByDate, "Date"),
			(AID.findingsSortByTitle, "Alphabetical"),
			(AID.findingsSortByHost, "Website")
		]
		for (id, name) in orders {
			XCTAssertTrue(
				control(id).waitForExistence(timeout: 5),
				"Sort menu is missing the \(name) order"
			)
		}
		XCTAssertTrue(
			isPresent(AID.findingsSortReverse),
			"Sort menu is missing the Reverse item"
		)

		// Date is the default, and says so.
		XCTAssertTrue(
			control(AID.findingsSortByDate).isSelected,
			"The active order does not report itself as selected"
		)
		XCTAssertFalse(control(AID.findingsSortByTitle).isSelected, "Alphabetical should not be active")
	}

	/// The sort button names the active order as its accessibility **value**, so VoiceOver reports
	/// which order is in force without the label having to change.
	func testFindingsSortMenu_selectingAnOrderUpdatesTheAccessibilityValue() {
		launch()
		openFindings()

		let sortMenu = control(AID.findingsSortOrder)
		XCTAssertTrue(sortMenu.waitForExistence(timeout: 10), "Sort menu missing")
		XCTAssertEqual(sortMenu.value as? String, "Date", "Findings should open sorted by date")

		sortMenu.tap()
		control(AID.findingsSortByTitle).tap()

		let becomesAlphabetical = NSPredicate(format: "value == %@", "Alphabetical")
		let settled = XCTWaiter().wait(
			for: [XCTNSPredicateExpectation(predicate: becomesAlphabetical, object: sortMenu)],
			timeout: 5
		)
		XCTAssertEqual(settled, .completed, "Sort control did not report the newly selected order")
	}

	/// Reverse is a `Button` carrying its state in a symbol, which VoiceOver treats as decorative —
	/// so the direction is exposed through the `.isSelected` trait instead. This is the test that
	/// the trait is actually applied: without it the control would be visually stateful and
	/// audibly stateless.
	func testFindingsSortMenu_reverseReportsItsStateAsSelected() {
		launch()
		openFindings()

		let sortMenu = control(AID.findingsSortOrder)
		XCTAssertTrue(sortMenu.waitForExistence(timeout: 10), "Sort menu missing")

		sortMenu.tap()
		let reverse = control(AID.findingsSortReverse)
		XCTAssertTrue(reverse.waitForExistence(timeout: 5), "Reverse item missing")
		XCTAssertFalse(reverse.isSelected, "Reverse should start unselected")
		reverse.tap()

		// Re-open: tapping a menu item dismisses the menu.
		sortMenu.tap()
		let reverseAgain = control(AID.findingsSortReverse)
		XCTAssertTrue(reverseAgain.waitForExistence(timeout: 5), "Reverse item missing after reopening")
		XCTAssertTrue(
			reverseAgain.isSelected,
			"Reverse did not report itself as selected, so VoiceOver cannot tell the two directions apart"
		)
	}
}
