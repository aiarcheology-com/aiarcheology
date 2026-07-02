//
//  FindingFlashTests.swift
//  AI ArcheologyTests
//
//  Created by Agent on 2026-07-02.
//

import XCTest
@testable import ML_Browser

// MARK: - FlashTrigger Tests (AIA-0374)

final class FlashTriggerTests: XCTestCase {

    func testShouldFlash_ZeroToOne_Fires() {
        XCTAssertTrue(FlashTrigger.shouldFlash(oldCount: 0, newCount: 1))
    }

    func testShouldFlash_CountIncrease_Fires() {
        // A second model's new finding must not be masked by an already-qualifying first.
        XCTAssertTrue(FlashTrigger.shouldFlash(oldCount: 1, newCount: 2))
    }

    func testShouldFlash_SameCount_DoesNotFire() {
        XCTAssertFalse(FlashTrigger.shouldFlash(oldCount: 1, newCount: 1))
    }

    func testShouldFlash_CountDecrease_DoesNotFire() {
        XCTAssertFalse(FlashTrigger.shouldFlash(oldCount: 2, newCount: 1))
    }

    func testShouldFlash_ZeroToZero_DoesNotFire() {
        XCTAssertFalse(FlashTrigger.shouldFlash(oldCount: 0, newCount: 0))
    }
}

// MARK: - ClassificationFlashController Tests (AIA-0374)

@MainActor
final class ClassificationFlashControllerTests: XCTestCase {

    var sut: ClassificationFlashController!

    override func setUp() async throws {
        try await super.setUp()
        sut = ClassificationFlashController()
    }

    override func tearDown() async throws {
        sut = nil
        try await super.tearDown()
    }

    private func result(topConfidence: Float) -> ClassificationResult {
        (labels: [
            ClassifiedLabel(identifier: "object", confidence: topConfidence),
            ClassifiedLabel(identifier: "background", confidence: 0.01)
        ], params: DeepDriverParams(entityId: UUID()))
    }

    func testIngest_QualifyingResult_FiresFlashAndCounts() {
        sut.ingest([result(topConfidence: 0.9)], flashEnabled: true)

        XCTAssertEqual(sut.flashCount, 1)
        XCTAssertEqual(sut.qualifyingCount, 1)
    }

    func testIngest_SameQualifyingResultTwice_FlashesOnce() {
        sut.ingest([result(topConfidence: 0.9)], flashEnabled: true)
        sut.ingest([result(topConfidence: 0.9)], flashEnabled: true)

        XCTAssertEqual(sut.flashCount, 1, "A persisting finding must not strobe on every pass")
    }

    func testIngest_SecondDriverStartsQualifying_FiresAgain() {
        sut.ingest([result(topConfidence: 0.9)], flashEnabled: true)
        sut.ingest([result(topConfidence: 0.9), result(topConfidence: 0.8)], flashEnabled: true)

        XCTAssertEqual(sut.flashCount, 2)
        XCTAssertEqual(sut.qualifyingCount, 2)
    }

    func testIngest_BelowThresholdTopLabel_DoesNotQualify() {
        // Top-1 is 0.45: the 0.01 background label must not be summed or considered.
        sut.ingest([result(topConfidence: 0.45)], flashEnabled: true)

        XCTAssertEqual(sut.flashCount, 0)
        XCTAssertEqual(sut.qualifyingCount, 0)
    }

    func testIngest_ThresholdEdge_Qualifies() {
        sut.ingest([result(topConfidence: ClassificationFlashController.qualifyingConfidenceThreshold)], flashEnabled: true)

        XCTAssertEqual(sut.flashCount, 1)
    }

    func testIngest_EmptyResults_ClearsQualifyingWithoutFlash() {
        sut.ingest([result(topConfidence: 0.9)], flashEnabled: true)
        sut.ingest([], flashEnabled: true)

        XCTAssertEqual(sut.qualifyingCount, 0)
        XCTAssertEqual(sut.flashCount, 1)
    }

    func testIngest_FlashDisabled_CountsButNeverFlashes() {
        // The disable toggle freezes the flash, not the classification bookkeeping —
        // the UI test's negative case relies on classificationCount still changing.
        sut.ingest([result(topConfidence: 0.9)], flashEnabled: false)
        sut.ingest([], flashEnabled: false)
        sut.ingest([result(topConfidence: 0.9)], flashEnabled: false)

        XCTAssertEqual(sut.flashCount, 0)
        XCTAssertEqual(sut.qualifyingCount, 1)
    }

    func testResetOnInteraction_AllowsReflashAfterSettle() {
        sut.ingest([result(topConfidence: 0.9)], flashEnabled: true)
        XCTAssertEqual(sut.flashCount, 1)

        // Scroll: content invalidated, count clears (mirrors detection's clear).
        sut.resetOnInteraction()
        XCTAssertEqual(sut.qualifyingCount, 0)

        // Settle: the still-present finding re-qualifies 0→1 and flashes once more.
        sut.ingest([result(topConfidence: 0.9)], flashEnabled: true)
        XCTAssertEqual(sut.flashCount, 2)
    }
}
