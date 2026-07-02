//
//  FindingFlashUITests.swift
//  MLBrowserUITests
//
//  AIA-0374: end-to-end flash-on-classification via the DEBUG mock classificator
//  (`-mockClassification`). The mock alternates one qualifying label ↔ none per pass,
//  so the flash fires on every odd pass while enabled — and the disable-case can prove
//  the flash froze while classification demonstrably kept running. All waits are
//  checkpoint-predicate based (no sleeps, AIA-0312).
//

import XCTest

final class FindingFlashUITests: UITestCase {

    func testFindingFlash_firesWithMockClassification_andFreezesWhenDisabled() {
        launch(extraArguments: ["-mockClassification"])

        // Start the snapshot timer (the UI-test baseline keeps detection off at launch).
        let play = app.buttons[AID.play]
        XCTAssertTrue(play.waitForExistence(timeout: 10), "Play button missing")
        play.tap()

        // Pass 1 (qualifying): the first flash fires.
        XCTAssertTrue(
            waitForCheckpoint(AID.cpFlashCount, equals: "1", timeout: 30),
            "First qualifying classification should fire the flash"
        )
        // Pass 3 (qualifying again after pass 2's none): the flash RECURS — a
        // constant-result mock would stop here, which is exactly why it alternates.
        XCTAssertTrue(
            waitForCheckpoint(AID.cpFlashCount, equals: "2", timeout: 30),
            "Flash should recur on each fresh 0→n classification transition"
        )

        // Disable the flash through the Settings UI itself (not a config delta), so the
        // toggle → Settings → controller path is what's under test.
        openSettings()
        XCTAssertTrue(scrollTo(AID.settingsFlashOnFinding), "Flash toggle missing in Classification section")
        XCTAssertTrue(flipSwitch(AID.settingsFlashOnFinding), "Flash toggle did not change state")
        app.buttons[AID.settingsDismiss].tap()

        // Classification keeps alternating 0↔1 after the disable; observing the cycle
        // 1 → 0 → 1 guarantees at least one qualifying transition that WOULD have
        // flashed. The flash count must not move across it.
        let frozen = checkpointValue(AID.cpFlashCount)
        XCTAssertNotNil(frozen, "Flash-count checkpoint unreadable")
        XCTAssertTrue(
            waitForCheckpoint(AID.cpClassificationCount, equals: "1", timeout: 30),
            "Mock classification should keep qualifying after the flash is disabled"
        )
        XCTAssertTrue(
            waitForCheckpoint(AID.cpClassificationCount, equals: "0", timeout: 30),
            "Mock classification should keep alternating after the flash is disabled"
        )
        XCTAssertTrue(
            waitForCheckpoint(AID.cpClassificationCount, equals: "1", timeout: 30),
            "A second qualifying transition should occur while disabled"
        )
        // Direct read, NOT waitForCheckpoint(equals:): a wait-for-equality returns
        // immediately while the value is still frozen and would pass even if the
        // count incremented one tick later. The observed 1→0→1 classification cycle
        // above IS the elapsed time; equality after it is the real assertion.
        XCTAssertEqual(
            checkpointValue(AID.cpFlashCount), frozen,
            "Flash count must stay frozen while disabled"
        )
    }
}
