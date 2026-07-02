//
//  DrawerConfigUITests.swift
//  MLBrowserUITests
//
//  AIA-0305: drawer / configuration-list coverage. Exercises the demo-model list seeded into
//  the disposable UI-test Core Data store (see DataController UI-test isolation): the two demo
//  models render, their enabled toggle works, and a model can be deleted.
//

import XCTest

final class DrawerConfigUITests: UITestCase {

    /// Each model row owns exactly one enabled toggle, so the toggle count is the model count
    /// (a leaf element — unlike the row container, whose identifier SwiftUI propagates to
    /// children and over-counts).
    private func modelToggles() -> XCUIElementQuery {
        app.switches.matching(identifier: AID.configEnabledToggle)
    }

    func testDrawer_listsThreeSeededDemoModels() {
        launch()
        openDrawer()
        XCTAssertTrue(waitForSeededConfigurations(), "Demo configurations were not seeded")
        // DemoDataManager seeds three demo models (AIArcheology + HroudaDetector15 +
        // FastViTT8F16, AIA-0375) sequentially and asynchronously (CoreML metadata
        // extraction), so wait for all toggles to appear before asserting the count —
        // otherwise a later model may still be seeding.
        let allSeeded = NSPredicate(format: "count == 3")
        let expectation = XCTNSPredicateExpectation(predicate: allSeeded, object: modelToggles())
        XCTAssertEqual(
            XCTWaiter().wait(for: [expectation], timeout: 20), .completed,
            "Expected three seeded demo models in the drawer"
        )
    }

    func testDrawer_toggleModelEnabled_flipsState() {
        launch()
        openDrawer()
        XCTAssertTrue(waitForSeededConfigurations())
        XCTAssertTrue(flipSwitch(AID.configEnabledToggle), "Model enabled toggle did not change state")
    }

    // AIA-0308: a leftward swipe on a model row reveals the trailing delete action and removes that
    // row. Originally skipped at AIA-0305 because the swipe never revealed the delete under XCUITest
    // (suspected drawer-panel drag-gesture conflict). Re-investigated for AIA-0308: the swipe now
    // reveals reliably (5/5 iterations) with no app-code change — the row's swipe-actions and the
    // panel's swipe-to-close coexist under the current toolchain. This test re-enables and locks
    // that behavior. (On-device swipe feel is verified separately.)
    func testDrawer_deleteModel_removesCell() {
        launch()
        openDrawer()
        XCTAssertTrue(waitForSeededConfigurations(), "Demo configurations were not seeded")

        // All demo models seed asynchronously; wait for all toggles so the pre-delete count is
        // stable (same pattern as testDrawer_listsThreeSeededDemoModels).
        let allSeeded = NSPredicate(format: "count == 3")
        let seededExpectation = XCTNSPredicateExpectation(predicate: allSeeded, object: modelToggles())
        XCTAssertEqual(
            XCTWaiter().wait(for: [seededExpectation], timeout: 20), .completed,
            "Expected three seeded demo models before delete"
        )

        // Swipe the first model row to delete it. With `allowsFullSwipe: true` a fast swipe may
        // commit the delete outright without leaving the trailing button visible; a partial swipe
        // instead reveals the button to tap. Handle both: tap the button if it reveals, otherwise
        // the full swipe already deleted. The post-condition (one model remains) is the source of
        // truth either way — and still fails if the swipe does nothing (the AIA-0308 regression).
        let firstRow = app.staticTexts.matching(identifier: AID.configDescription).firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5), "No model row to swipe")
        firstRow.swipeLeft()

        let deleteButton = app.buttons[AID.configDelete]
        if deleteButton.waitForExistence(timeout: 5) {
            deleteButton.tap()
        }

        // Exactly two models should remain after deleting one.
        let twoRemain = NSPredicate(format: "count == 2")
        let deletedExpectation = XCTNSPredicateExpectation(predicate: twoRemain, object: modelToggles())
        XCTAssertEqual(
            XCTWaiter().wait(for: [deletedExpectation], timeout: 10), .completed,
            "Deleting one model should leave exactly two toggles"
        )
    }
}
