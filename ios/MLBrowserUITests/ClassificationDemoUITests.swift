//
//  ClassificationDemoUITests.swift
//  MLBrowserUITests
//
//  AIA-0374/AIA-0375: end-to-end classification through the REAL bundled demo model
//  (FastViT-T8, Apple model gallery) — no mocks. The local HTML fixture renders as a
//  web page, and a deterministic seeded maze qualifies it (ImageNet "maze"; pattern pre-validated at unit speed by FixturePatternQualificationTests), so the finding flash pulses
//  and qualifying passes accumulate. Exercises the real seeding/insert-registration
//  path, the real classify pipeline, and the checkpoint surface.
//  All waits are checkpoint-predicate based (no sleeps, AIA-0312).
//

import XCTest

final class ClassificationDemoUITests: UITestCase {

    func testClassifyDemo_fullscreenDetection_appliesInitialFrameBeforeTimer() throws {
        launch(LaunchConfig(
            pageScenario: .localFixture,
            fullscreenDetection: true,
            snapFrequency: 10,
            fixtureName: "uitest_classify_page",
            enableClassifyDemo: true
        ))

        let play = app.buttons[AID.play]
        XCTAssertTrue(play.waitForExistence(timeout: 10), "Play button missing")
        play.tap()

        XCTAssertTrue(
            waitForCheckpoint(AID.cpSnapshotDeliveryCount, minimum: 1, timeout: 8),
            "Fullscreen PLAY should deliver an initial WebView snapshot before the 10-second timer cadence, without panning"
        )
        XCTAssertTrue(
            waitForCheckpoint(AID.cpDetectionFrameApplied, equals: "true", timeout: 8),
            "Fullscreen PLAY should apply a detection frame before the 10-second timer cadence, without panning"
        )
    }

    func testClassifyDemo_seededEnabled_qualifiesOnFixturePage() throws {
        // The classify demo seeds ENABLED via launch config (real seeding + insert-
        // registration path; drawer-enable flow coverage belongs to AIA-0322).
        launch(LaunchConfig(
            pageScenario: .localFixture,
            // The start request must be delivered before the next timer cadence. Ten seconds
            // leaves a clear gap without exceeding Settings' production validation range.
            snapFrequency: 10,
            fixtureName: "uitest_classify_page",
            enableClassifyDemo: true
        ))

        // Start the snapshot timer.
        let play = app.buttons[AID.play]
        XCTAssertTrue(play.waitForExistence(timeout: 10), "Play button missing")
        play.tap()

        XCTAssertTrue(
            waitForCheckpoint(AID.cpSnapshotDeliveryCount, minimum: 1, timeout: 8),
            "PLAY should deliver the initial WebView snapshot before the 10-second timer cadence, without panning"
        )

        // The enable path loads the model asynchronously. Its registration requests a second
        // immediate pass in the same run, rather than waiting for the 10-second timer tick.
        XCTAssertTrue(
            waitForCheckpoint(AID.cpClassificationCount, equals: "1", timeout: 60),
            "The real classificator should qualify on the rendered fixture page — top: \(checkpointValue(AID.cpTopClassification, timeout: 2) ?? "<none>")"
        )
        // Qualifying passes accumulate while the finding stays on screen (the pulse's
        // driving signal) — proves recurrence, not a one-shot.
        XCTAssertTrue(
            waitForCheckpoint(AID.cpFlashCount, minimum: 2, timeout: 30),
            "Qualifying passes should accumulate while the finding persists"
        )

        // Owner-reported regression: pausing detection must clear the presentation
        // immediately — with no further snapshots the steady-state pulse/bubble
        // would otherwise freeze on screen forever.
        let pause = app.buttons[AID.pause]
        XCTAssertTrue(pause.waitForExistence(timeout: 10), "Pause button missing")
        pause.tap()
        XCTAssertTrue(
            waitForCheckpoint(AID.cpClassificationCount, equals: "0", timeout: 10),
            "Pausing detection must clear the classification presentation"
        )
    }
}
