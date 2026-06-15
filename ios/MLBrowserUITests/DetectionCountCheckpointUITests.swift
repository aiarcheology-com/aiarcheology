//
//  DetectionCountCheckpointUITests.swift
//  MLBrowserUITests
//
//  AIA-0317: smoke test for the live detection-count checkpoint harness. Scope: prove the
//  checkpoint is wired and readable, reflecting the current count (0 at launch — demo models are
//  seeded disabled and there is no auto-snapshot, so no annotations are drawn). The
//  >= 1-after-detection / recompute proof is deferred to AIA-0322, which composes this harness with
//  the local-page loader (AIA-0316) and a model-enable path.
//

import XCTest

final class DetectionCountCheckpointUITests: UITestCase {

    func testDetectionCountCheckpoint_readableAndZeroWithoutDetections() {
        launch()
        XCTAssertTrue(
            waitForCheckpoint(AID.cpDetectionCount, equals: "0"),
            "Detection-count checkpoint should exist and read 0 when no annotations are drawn"
        )
    }
}
