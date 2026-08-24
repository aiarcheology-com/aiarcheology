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
        // DemoDataManager seeds two demo models (AIArcheology + HroudaDetector15)
        // sequentially and asynchronously (CoreML metadata extraction); the FastViT
        // classify demo is TEST-ONLY and seeds solely under enableClassifyDemo
        // (AIA-0374 licensing). Wait for both toggles before asserting the count.
        let allSeeded = NSPredicate(format: "count == 2")
        let expectation = XCTNSPredicateExpectation(predicate: allSeeded, object: modelToggles())
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

        // Both demo models seed asynchronously; wait for both toggles so the pre-delete count is
        // stable (same pattern as testDrawer_listsTwoSeededDemoModels).
        let allSeeded = NSPredicate(format: "count == 2")
        let seededExpectation = XCTNSPredicateExpectation(predicate: allSeeded, object: modelToggles())
        XCTAssertEqual(
            XCTWaiter().wait(for: [seededExpectation], timeout: 20), .completed,
            "Expected two seeded demo models before delete"
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

        // Exactly one model should remain after deleting one.
        let oneRemains = NSPredicate(format: "count == 1")
        let deletedExpectation = XCTNSPredicateExpectation(predicate: oneRemains, object: modelToggles())
        XCTAssertEqual(
            XCTWaiter().wait(for: [deletedExpectation], timeout: 10), .completed,
            "Deleting one model should leave exactly one toggle"
        )
    }

    // MARK: - AIA-0402: model-type control

    /// Opens the first seeded model's settings and taps its description row.
    private func openFirstModelSettings() {
        openDrawer()
        XCTAssertTrue(waitForSeededConfigurations(), "Demo configurations were not seeded")
        let firstRow = app.staticTexts.matching(identifier: AID.configDescription).firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5), "No model row to open")
        firstRow.tap()
    }

    func testConfigForm_parsedType_isReadOnly() {
        launch()
        openFirstModelSettings()

        // The seeded demo declares its type (parser-decided), so the type is locked: shown read-only,
        // with no editable segmented control (AIA-0402).
        let picker = app.segmentedControls[AID.configModelTypePicker]
        XCTAssertFalse(picker.waitForExistence(timeout: 3),
                       "A parser-decided model's type must be read-only (no editable picker)")
        XCTAssertTrue(app.staticTexts["Detection"].waitForExistence(timeout: 5),
                      "A parser-decided detector should show its type read-only")
    }

    func testDrawer_modelRow_showsTypeCaption() {
        launch()
        openDrawer()
        XCTAssertTrue(waitForSeededConfigurations(), "Demo configurations were not seeded")
        // Every model row carries a type caption. The seeded demo models are detectors, so the
        // caption reads "Detection" (the caption is untagged, so its label is the displayed text).
        XCTAssertTrue(app.staticTexts["Detection"].waitForExistence(timeout: 10),
                      "Model row should show its type as a caption")
    }

	func testConfigForm_annotationSoundSubmenuShowsPerModelControls() {
		launch()
		openFirstModelSettings()
		XCTAssertTrue(scrollTo(AID.configSound), "Sound entry point was not rendered in Annotation")
		let sound = element(AID.configSound)
		XCTAssertTrue(sound.isHittable, "Sound entry point must be tappable")
		XCTAssertEqual(sound.value as? String, "Disabled", "Sound row must not imply its selected tone is active")
		sound.tap()

		XCTAssertTrue(element(AID.configSoundEnabled).waitForExistence(timeout: 5))
		XCTAssertTrue(element(AID.configSoundVolume).waitForExistence(timeout: 5))
		XCTAssertTrue(element(AID.configSoundChime).waitForExistence(timeout: 5))
		XCTAssertTrue(flipSwitch(AID.configSoundEnabled), "Per-model annotation sound toggle did not change")
	}

    // AIA-0402 (follow-up): after import, an UNPARSED-type model's settings auto-open in "type review"
    // mode so the user picks a type — no model runs on a type the app couldn't verify. The real file
    // import isn't scriptable under XCUITest, so `reviewFirstModelType` forces the first seeded model
    // to look unparsed and drives it into the same review presentation, exercising the editable picker,
    // the confirmation footnote, and the red Disabled warning.
    func testConfigForm_unparsedTypeReview_showsPickerConfirmationAndRedWarning() {
        var config = LaunchConfig()
        config.reviewFirstModelType = true
        _ = launch(config)
        openDrawer()

        // Once the first model seeds, its settings auto-open in review mode (covering the drawer).
        // Wait on the picker directly — the seeded-toggle helper would race the covering sheet.
        let picker = app.segmentedControls[AID.configModelTypePicker]
        XCTAssertTrue(picker.waitForExistence(timeout: 25),
                      "An unparsed model's review settings should auto-open with an editable picker")
        XCTAssertTrue(picker.buttons["Detection"].exists, "Detection segment missing")
        XCTAssertTrue(picker.buttons["Classification"].exists, "Classification segment missing")
        XCTAssertTrue(picker.buttons["Disabled"].exists, "Disabled segment missing")

        // The forced-unparsed model keeps its detector value pre-selected, so the confirm footnote shows.
        let confirmFootnote = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "Pre-selected as our best guess")
        ).firstMatch
        XCTAssertTrue(confirmFootnote.waitForExistence(timeout: 5),
                      "Type review should show the confirm-your-best-guess footnote")

        // Choosing Disabled during review swaps in the red "type isn't set" warning.
        picker.buttons["Disabled"].tap()
        let disabledWarning = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "This model's type isn't set")
        ).firstMatch
        XCTAssertTrue(disabledWarning.waitForExistence(timeout: 5),
                      "Choosing Disabled in review should show the red undetermined-type warning")

        // Dismiss back to the drawer: the caption reads "Disabled" and that model's toggle is greyed.
        let dismiss = app.buttons[AID.configFormDismiss]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5), "Config form dismiss button missing")
        dismiss.tap()
        XCTAssertTrue(app.staticTexts["Disabled"].waitForExistence(timeout: 10),
                      "Drawer caption should read Disabled after choosing Disabled")
        let disabledToggle = app.switches.matching(
            NSPredicate(format: "identifier == %@ AND enabled == false", AID.configEnabledToggle)
        ).firstMatch
        XCTAssertTrue(disabledToggle.waitForExistence(timeout: 5),
                      "A Disabled model's enable toggle must be non-interactive")
    }
}
