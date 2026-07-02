//
//  FindingFlashTests.swift
//  AI ArcheologyTests
//
//  Created by Agent on 2026-07-02.
//

import XCTest
import SwiftUI
import Vision
import CoreML
import Combine
@testable import ML_Browser

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

    private func result(
        topConfidence: Float,
        color: Color = .red,
        period: Double = 2.5,
        size: Double = 10,
        flashEnabled: Bool = true
    ) -> ClassificationResult {
        (labels: [
            ClassifiedLabel(identifier: "object", confidence: topConfidence),
            ClassifiedLabel(identifier: "background", confidence: 0.01)
        ], params: DeepDriverParams(
            annotationColor: color,
            entityId: UUID(),
            phaseOutTime: period,
            flashEnabled: flashEnabled,
            flashSize: size
        ))
    }

    func testIngest_QualifyingResult_ActivatesWithModelStyle() {
        sut.ingest([result(topConfidence: 0.9, color: .blue, period: 3.0, size: 14)])

        XCTAssertEqual(sut.qualifyingCount, 1)
        XCTAssertEqual(sut.flashColor, .blue)
        XCTAssertEqual(sut.pulsePeriod, 3.0)
        XCTAssertEqual(sut.flashSize, 14)
        XCTAssertEqual(sut.qualifyingPassCount, 1)
    }

    func testIngest_ModelWithFlashDisabled_ShowsLabelsButNeverPulses() {
        // Per-model toggle (owner decision): a flash-disabled model still feeds the
        // label bubble but can't activate the pulse.
        sut.ingest([result(topConfidence: 0.9, flashEnabled: false)])

        XCTAssertEqual(sut.qualifyingCount, 0)
        XCTAssertEqual(sut.qualifyingPassCount, 0)
        XCTAssertFalse(sut.displayLabels.isEmpty)
    }

    func testIngest_QualifyingPassesAccumulateCount() {
        sut.ingest([result(topConfidence: 0.9)])
        sut.ingest([result(topConfidence: 0.9)])

        XCTAssertEqual(sut.qualifyingCount, 1)
        XCTAssertEqual(sut.qualifyingPassCount, 2, "The checkpoint counter tracks qualifying passes")
    }

    func testIngest_BelowThresholdTopLabel_DoesNotQualify() {
        // Top-1 is 0.2 (below the 0.25 threshold): no pulse — but the labels are
        // still published for the bubble.
        sut.ingest([result(topConfidence: 0.2)])

        XCTAssertEqual(sut.qualifyingCount, 0)
        XCTAssertEqual(sut.qualifyingPassCount, 0)
        XCTAssertEqual(sut.displayLabels.first?.confidence, 0.2, "Display is threshold-independent")
    }

    func testIngest_DisplayLabels_TopKSortedAboveFloor() {
        let params = DeepDriverParams(entityId: UUID())
        let labels = [
            ClassifiedLabel(identifier: "a", confidence: 0.30),
            ClassifiedLabel(identifier: "b", confidence: 0.40),
            ClassifiedLabel(identifier: "c", confidence: 0.20),
            ClassifiedLabel(identifier: "noise", confidence: 0.01),
            ClassifiedLabel(identifier: "d", confidence: 0.06)
        ]
        sut.ingest([(labels: labels, params: params)])

        XCTAssertEqual(sut.displayLabels.map(\.identifier), ["b", "a", "c"],
                       "Top-3 by confidence; the 0.01 noise label is below the floor")
    }

    func testResetOnInteraction_ClearsDisplayLabels() {
        sut.ingest([result(topConfidence: 0.9)])
        XCTAssertFalse(sut.displayLabels.isEmpty)

        sut.resetOnInteraction()

        XCTAssertTrue(sut.displayLabels.isEmpty)
    }

    func testIngest_ThresholdEdge_Qualifies() {
        sut.ingest([result(topConfidence: ClassificationFlashController.qualifyingConfidenceThreshold)])

        XCTAssertEqual(sut.qualifyingCount, 1)
    }

    func testIngest_EmptyResults_DeactivatesPulse() {
        sut.ingest([result(topConfidence: 0.9)])
        sut.ingest([])

        XCTAssertEqual(sut.qualifyingCount, 0, "No qualifying classification → the pulse stops")
    }

    func testIngest_OutOfRangePeriod_IsClamped() {
        sut.ingest([result(topConfidence: 0.9, period: 99.0)])

        XCTAssertEqual(sut.pulsePeriod, ClassificationFlashController.pulsePeriodRange.upperBound)
    }

    func testIngest_TwoQualifyingDrivers_StyleFromFirst() {
        sut.ingest([
            result(topConfidence: 0.9, color: .green, period: 1.0),
            result(topConfidence: 0.8, color: .purple, period: 4.0)
        ])

        XCTAssertEqual(sut.qualifyingCount, 2)
        XCTAssertEqual(sut.flashColor, .green)
        XCTAssertEqual(sut.pulsePeriod, 1.0)
    }

    func testResetOnInteraction_StopsPulseUntilRequalified() {
        sut.ingest([result(topConfidence: 0.9)])
        XCTAssertEqual(sut.qualifyingCount, 1)

        // Scroll: content invalidated, pulse stops (mirrors detection's clear).
        sut.resetOnInteraction()
        XCTAssertEqual(sut.qualifyingCount, 0)

        // Settle: the still-present finding re-qualifies and the pulse resumes.
        sut.ingest([result(topConfidence: 0.9)])
        XCTAssertEqual(sut.qualifyingCount, 1)
    }

    // MARK: In-flight invalidation (P4 review)

    func testClassifyPass_CompletionAfterInvalidation_IsDropped() async {
        let drivers = DeepDrivers()
        drivers.register(driver: FixedLabelClassifying(confidence: 0.9), along: .classificator)

        sut.classifyPass(drivers: drivers, image: UIImage())
        // Interaction starts while the pass is in flight: its results are stale.
        sut.resetOnInteraction()

        // Bounded negative assertion: the stale completion must never ingest.
        let noChange = expectation(description: "stale pass must not activate the pulse")
        noChange.isInverted = true
        let cancellable = sut.$qualifyingCount.dropFirst().sink { _ in noChange.fulfill() }
        await fulfillment(of: [noChange], timeout: 1.0)
        cancellable.cancel()

        XCTAssertEqual(sut.qualifyingCount, 0)
        XCTAssertEqual(sut.qualifyingPassCount, 0)
    }

    func testClassifyPass_WithoutInvalidation_Ingests() async {
        let drivers = DeepDrivers()
        drivers.register(driver: FixedLabelClassifying(confidence: 0.9), along: .classificator)

        let activated = expectation(description: "pass ingests and activates the pulse")
        let cancellable = sut.$qualifyingCount.dropFirst().sink { _ in activated.fulfill() }
        sut.classifyPass(drivers: drivers, image: UIImage())
        await fulfillment(of: [activated], timeout: 2.0)
        cancellable.cancel()

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

// MARK: - Detecting protocol symmetry (AIA-0374)

@MainActor
final class DeepDriversDetectProtocolTests: XCTestCase {

    /// The detect loop dispatches on `Detecting` (not the concrete `Detector`), the
    /// mirror of the classify loop's `Classifying` — a protocol conformer's results
    /// flow through like the real driver's.
    func testDetectOn_StubDetecting_ReturnsItsObjects() async {
        let drivers = DeepDrivers()
        let entityId = UUID()
        let stub = StubDetecting(params: DeepDriverParams(entityId: entityId))
        drivers.register(driver: stub, along: .detector)

        let expectation = XCTestExpectation(description: "Detection completed")
        drivers.detect(on: UIImage(), tiledDetection: false) { results in
            XCTAssertEqual(results.count, 1)
            XCTAssertEqual(results.first?.observations.first?.primaryLabelIdentifier, "stub-object")
            XCTAssertEqual(results.first?.params.entityId, entityId)
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 2.0)
    }
}

// MARK: - Stubs

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

/// Minimal `Detecting` conformer returning one fixed object per pass.
private actor StubDetecting: Detecting {
    let id: UUID
    var params: DeepDriverParams
    var observations: [VNObservation] = []

    init(params: DeepDriverParams) {
        self.id = params.entityId
        self.params = params
    }

    func detect(image: UIImage, regions: [CGRect]) async -> [DetectedObject] {
        [DetectedObject(
            uuid: UUID(),
            labels: [DetectedObject.Label(identifier: "stub-object", confidence: 0.9)],
            confidence: 0.9,
            boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
            regionIndex: 0
        )]
    }

    func metadata() -> [MLModelMetadataKey: Any]? { nil }
    func updateConfiguration(_ params: DeepDriverParams) async { self.params = params }
    func process(image: UIImage) async {}
    func loadFile() async throws {}
    func run() async {}
    func unload() async {}
}

// MARK: - Real demo classificator (AIA-0375: bundled FastViT-T8, no mocks)

final class RealClassifierDemoModelTests: XCTestCase {

    private func demoModelURL() throws -> URL {
        try XCTUnwrap(
            Bundle.main.url(forResource: "FastViTT8F16", withExtension: "mlmodelc"),
            "FastViT-T8 demo model missing from the app bundle"
        )
    }

    /// The metadata carries `com.apple.coreml.model.preview.type = imageClassifier`,
    /// which is what routes the demo through the classify pipeline at seeding time.
    func testDemoClassifier_MetadataTask_IsClassify() async throws {
        let info = try await ModelLoadingService().loadAndExtractMetadata(from: demoModelURL(), demo: true)
        XCTAssertEqual(info.task, .classificator)
    }

    /// Drives the REAL model through the atomic classify pass: labels come back
    /// non-empty, trimmed to the top-K, best-first.
    func testDemoClassifier_ClassifiesRenderedImage() async throws {
        let params = DeepDriverParams(entityId: UUID(), file: try demoModelURL(), demo: true)
        let classificator = Classificator(params: params)
        try await classificator.loadFile()

        let labels = await classificator.classify(image: Self.renderedSample())

        XCTAssertFalse(labels.isEmpty, "The real model must produce labels for a rendered image")
        XCTAssertLessThanOrEqual(labels.count, Classificator.topLabelCount)
        let confidences = labels.map(\.confidence)
        XCTAssertEqual(confidences, confidences.sorted(by: >), "Remap must preserve Vision's best-first order")
    }

    private static func renderedSample() -> UIImage {
        let size = CGSize(width: 256, height: 256)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let text = "ML Browser test page with some text content" as NSString
            text.draw(
                in: CGRect(x: 16, y: 16, width: 224, height: 224),
                withAttributes: [.font: UIFont.systemFont(ofSize: 18), .foregroundColor: UIColor.black]
            )
        }
    }
}

// MARK: - Fixture-pattern qualification (diagnostic + guard, AIA-0375)

/// Validates — at unit speed — that the procedural pattern used by the UI-test fixture
/// actually QUALIFIES (top-1 ≥ threshold) on the real bundled model, so the slow UI
/// test never bets on an unverified image. Prints the labels for diagnosis.
@MainActor
final class FixturePatternQualificationTests: XCTestCase {

    func testMazePattern_QualifiesOnDemoModel() async throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "FastViTT8F16", withExtension: "mlmodelc"))
        let classificator = Classificator(params: DeepDriverParams(entityId: UUID(), file: url, demo: true))
        try await classificator.loadFile()

        let labels = await classificator.classify(image: Self.mazeImage())
        print("FIXTURE-PATTERN LABELS:", labels.map { "\($0.identifier)=\($0.confidence)" })

        let top = try XCTUnwrap(labels.first)
        XCTAssertGreaterThanOrEqual(
            top.confidence, ClassificationFlashController.qualifyingConfidenceThreshold,
            "Fixture pattern must qualify; got \(labels.map { "\($0.identifier)=\($0.confidence)" })"
        )
    }

    /// Deterministic grid maze (seeded LCG): thick dark walls on white — mirrors the
    /// SVG in uitest_classify_page.html. ImageNet's "maze" class.
    static func mazeImage(size: CGFloat = 512) -> UIImage {
        var seed: UInt64 = 0x5EED
        func rand() -> Bool { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return (seed >> 33) & 1 == 1 }
        let cells = 12
        let cell = size / CGFloat(cells)
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
            UIColor.black.setStroke()
            let path = UIBezierPath()
            path.lineWidth = cell * 0.28
            // Border
            path.append(UIBezierPath(rect: CGRect(x: 0, y: 0, width: size, height: size)))
            for row in 0...cells {
                for col in 0...cells {
                    let x = CGFloat(col) * cell, y = CGFloat(row) * cell
                    if rand() { // horizontal wall segment
                        path.move(to: CGPoint(x: x, y: y)); path.addLine(to: CGPoint(x: x + cell, y: y))
                    }
                    if rand() { // vertical wall segment
                        path.move(to: CGPoint(x: x, y: y)); path.addLine(to: CGPoint(x: x, y: y + cell))
                    }
                }
            }
            path.stroke()
        }
    }
}
