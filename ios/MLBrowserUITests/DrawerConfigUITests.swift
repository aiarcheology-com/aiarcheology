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

    func testDrawer_listsTwoSeededDemoModels() {
        launch()
        openDrawer()
        XCTAssertTrue(waitForSeededConfigurations(), "Demo configurations were not seeded")
        // DemoDataManager seeds two demo models (AIArcheology + HroudaDetector15) sequentially
        // and asynchronously (CoreML metadata extraction), so wait for both toggles to appear
        // before asserting the count — otherwise the second model may still be seeding.
        let bothSeeded = NSPredicate(format: "count == 2")
        let expectation = XCTNSPredicateExpectation(predicate: bothSeeded, object: modelToggles())
        XCTAssertEqual(
            XCTWaiter().wait(for: [expectation], timeout: 20), .completed,
            "Expected two seeded demo models in the drawer"
        )
    }

    func testDrawer_toggleModelEnabled_flipsState() {
        launch()
        openDrawer()
        XCTAssertTrue(waitForSeededConfigurations())
        XCTAssertTrue(flipSwitch(AID.configEnabledToggle), "Model enabled toggle did not change state")
    }

    // Deferred. The model rows are real cells (description label + enabled switch are both
    // queryable), but a leftward swipe never reveals the row's delete action: the custom
    // drawer panel's own drag gesture intercepts the swipe. Confirmed via the accessibility
    // tree — the swipe leaves the drawer open and the delete button never appears. Re-enable
    // once the drawer exposes a non-swipe delete affordance or the gesture conflict is
    // resolved. (Model deletion itself is covered at the unit level.)
    func testDrawer_deleteModel_removesCell() throws {
        throw XCTSkip("Blocked by AIA-0308: drawer drag gesture intercepts the row swipe-to-delete in XCUITest. Re-enable when fixed.")
    }
}
