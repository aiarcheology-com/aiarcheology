//
//  FindingFlashTests.swift
//  AI ArcheologyTests
//
//  Created by Agent on 2026-07-02.
//

import XCTest
import Vision
import CoreML
import Combine
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
        sut.ingest([result(topConfidence: 0.9)])

        XCTAssertEqual(sut.flashCount, 1)
        XCTAssertEqual(sut.qualifyingCount, 1)
    }

    func testIngest_SameQualifyingResultTwice_FlashesOnce() {
        sut.ingest([result(topConfidence: 0.9)])
        sut.ingest([result(topConfidence: 0.9)])

        XCTAssertEqual(sut.flashCount, 1, "A persisting finding must not strobe on every pass")
    }

    func testIngest_SecondDriverStartsQualifying_FiresAgain() {
        sut.ingest([result(topConfidence: 0.9)])
        sut.ingest([result(topConfidence: 0.9), result(topConfidence: 0.8)])

        XCTAssertEqual(sut.flashCount, 2)
        XCTAssertEqual(sut.qualifyingCount, 2)
    }

    func testIngest_BelowThresholdTopLabel_DoesNotQualify() {
        // Top-1 is 0.45: the 0.01 background label must not be summed or considered.
        sut.ingest([result(topConfidence: 0.45)])

        XCTAssertEqual(sut.flashCount, 0)
        XCTAssertEqual(sut.qualifyingCount, 0)
    }

    func testIngest_ThresholdEdge_Qualifies() {
        sut.ingest([result(topConfidence: ClassificationFlashController.qualifyingConfidenceThreshold)])

        XCTAssertEqual(sut.flashCount, 1)
    }

    func testIngest_EmptyResults_ClearsQualifyingWithoutFlash() {
        sut.ingest([result(topConfidence: 0.9)])
        sut.ingest([])

        XCTAssertEqual(sut.qualifyingCount, 0)
        XCTAssertEqual(sut.flashCount, 1)
    }

    func testIngest_FlashDisabled_CountsButNeverFlashes() {
        // The disable toggle freezes the flash, not the classification bookkeeping —
        // the UI test's negative case relies on classificationCount still changing.
        sut.flashEnabled = false
        sut.ingest([result(topConfidence: 0.9)])
        sut.ingest([])
        sut.ingest([result(topConfidence: 0.9)])

        XCTAssertEqual(sut.flashCount, 0)
        XCTAssertEqual(sut.qualifyingCount, 1)
    }

    func testFlashEnabled_ReadAtIngestTime_NotCapturedAtPassStart() {
        // P4 review: a toggle flipped while a pass is in flight must take effect on
        // that pass's completion. Ingest after the flip must not flash.
        sut.flashEnabled = true
        sut.flashEnabled = false
        sut.ingest([result(topConfidence: 0.9)])

        XCTAssertEqual(sut.flashCount, 0)
    }

    func testEnablingOntoQualifyingPage_RearmsAndFlashes() {
        // P4 review: disabled → page qualifies (count 1, no flash) → enable. Without
        // re-arming, every later pass is 1→1 and the user never gets a flash.
        sut.flashEnabled = false
        sut.ingest([result(topConfidence: 0.9)])
        XCTAssertEqual(sut.qualifyingCount, 1)

        sut.flashEnabled = true
        XCTAssertEqual(sut.qualifyingCount, 0, "Enable edge must re-arm the 0→n transition")

        sut.ingest([result(topConfidence: 0.9)])
        XCTAssertEqual(sut.flashCount, 1)
    }

    func testResetOnInteraction_AllowsReflashAfterSettle() {
        sut.ingest([result(topConfidence: 0.9)])
        XCTAssertEqual(sut.flashCount, 1)

        // Scroll: content invalidated, count clears (mirrors detection's clear).
        sut.resetOnInteraction()
        XCTAssertEqual(sut.qualifyingCount, 0)

        // Settle: the still-present finding re-qualifies 0→1 and flashes once more.
        sut.ingest([result(topConfidence: 0.9)])
        XCTAssertEqual(sut.flashCount, 2)
    }

    // MARK: In-flight invalidation (P4 review)

    func testClassifyPass_CompletionAfterInvalidation_IsDropped() async {
        let drivers = DeepDrivers()
        drivers.register(driver: FixedLabelClassifying(confidence: 0.9), along: .classificator)

        sut.classifyPass(drivers: drivers, image: UIImage())
        // Interaction starts while the pass is in flight: its results are stale.
        sut.resetOnInteraction()

        // Bounded negative assertion: the stale completion must never ingest.
        let noChange = expectation(description: "stale pass must not count or flash")
        noChange.isInverted = true
        let cancellable = sut.$qualifyingCount.dropFirst().sink { _ in noChange.fulfill() }
        await fulfillment(of: [noChange], timeout: 1.0)
        cancellable.cancel()

        XCTAssertEqual(sut.flashCount, 0)
        XCTAssertEqual(sut.qualifyingCount, 0)
    }

    func testClassifyPass_WithoutInvalidation_Ingests() async {
        let drivers = DeepDrivers()
        drivers.register(driver: FixedLabelClassifying(confidence: 0.9), along: .classificator)

        let flashed = expectation(description: "pass ingests and flashes")
        let cancellable = sut.$flashCount.dropFirst().sink { _ in flashed.fulfill() }
        sut.classifyPass(drivers: drivers, image: UIImage())
        await fulfillment(of: [flashed], timeout: 2.0)
        cancellable.cancel()

        XCTAssertEqual(sut.flashCount, 1)
        XCTAssertEqual(sut.qualifyingCount, 1)
    }
}

// MARK: - Multi-driver aggregation (AIA-0374 P4 review)

@MainActor
final class DeepDriversClassifyAggregationTests: XCTestCase {

    func testClassifyOn_TwoClassificators_AggregatesBothInOrder() async {
        let drivers = DeepDrivers()
        let first = FixedLabelClassifying(confidence: 0.9, identifier: "first")
        let second = FixedLabelClassifying(confidence: 0.8, identifier: "second")
        drivers.register(driver: first, along: .classificator)
        drivers.register(driver: second, along: .classificator)

        let expectation = XCTestExpectation(description: "Classification completed")
        drivers.classify(on: UIImage()) { results in
            XCTAssertEqual(results.count, 2)
            XCTAssertEqual(results.first?.labels.first?.identifier, "first")
            XCTAssertEqual(results.last?.labels.first?.identifier, "second")
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 2.0)
    }
}

// MARK: - Classifying stub

/// Minimal `Classifying` conformer returning one fixed label per pass.
private actor FixedLabelClassifying: Classifying {
    let id: UUID
    var params: DeepDriverParams
    var observations: [VNObservation] = []
    private let label: ClassifiedLabel

    init(confidence: Float, identifier: String = "object") {
        let entityId = UUID()
        self.id = entityId
        self.params = DeepDriverParams(entityId: entityId)
        self.label = ClassifiedLabel(identifier: identifier, confidence: confidence)
    }

    func classify(image: UIImage) async -> [ClassifiedLabel] { [label] }
    func metadata() -> [MLModelMetadataKey: Any]? { nil }
    func updateConfiguration(_ params: DeepDriverParams) async { self.params = params }
    func process(image: UIImage) async {}
    func loadFile() async throws {}
    func run() async {}
    func unload() async {}
}
