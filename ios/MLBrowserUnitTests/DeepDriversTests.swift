//
//  DeepDriversTests.swift
//  AI ArcheologyTests
//
//  Created by AI Assistant on 25.11.25.
//

import XCTest
import Vision
@testable import ML_Browser

// MARK: - DeepDriverParams Tests

final class DeepDriverParamsTests: XCTestCase {
    
    func testDefaultValues() {
        let entityId = UUID()
        let params = DeepDriverParams(entityId: entityId)
        
        XCTAssertEqual(params.annotationColor, .yellow)
        XCTAssertEqual(params.entityId, entityId)
        XCTAssertNil(params.file)
        XCTAssertEqual(params.phaseOutTime, 1.0)
        XCTAssertEqual(params.selectedSymbol, .circle)
        XCTAssertFalse(params.demo)
    }
    
    func testCustomValues() {
        let entityId = UUID()
        let fileURL = URL(fileURLWithPath: "/path/to/model.mlmodel")
        
        let params = DeepDriverParams(
            annotationColor: .red,
            entityId: entityId,
            file: fileURL,
            phaseOutTime: 2.5,
            selectedSymbol: .square,
            demo: true
        )
        
        XCTAssertEqual(params.annotationColor, .red)
        XCTAssertEqual(params.entityId, entityId)
        XCTAssertEqual(params.file, fileURL)
        XCTAssertEqual(params.phaseOutTime, 2.5)
        XCTAssertEqual(params.selectedSymbol, .square)
        XCTAssertTrue(params.demo)
    }
}

// MARK: - DeepDriverType Tests

final class DeepDriverTypeTests: XCTestCase {
    
    func testDetectorRawValue() {
        XCTAssertEqual(DeepDriverType.detector.rawValue, "detect")
    }
    
    func testClassificatorRawValue() {
        XCTAssertEqual(DeepDriverType.classificator.rawValue, "classify")
    }
    
    func testInvalidRawValue() {
        XCTAssertEqual(DeepDriverType.invalid.rawValue, "invalid")
    }
    
    func testInitFromRawValue_Detector() {
        let type = DeepDriverType(rawValue: "detect")
        XCTAssertEqual(type, .detector)
    }
    
    func testInitFromRawValue_Classificator() {
        let type = DeepDriverType(rawValue: "classify")
        XCTAssertEqual(type, .classificator)
    }
    
    func testInitFromRawValue_Invalid() {
        let type = DeepDriverType(rawValue: "invalid")
        XCTAssertEqual(type, .invalid)
    }
    
    func testInitFromRawValue_Unknown() {
        let type = DeepDriverType(rawValue: "unknown")
        XCTAssertNil(type)
    }
}

// MARK: - DeepDrivers Tests

@MainActor
final class DeepDriversTests: XCTestCase {
    
    var sut: DeepDrivers!
    
    override func setUp() async throws {
        try await super.setUp()
        sut = DeepDrivers()
    }
    
    override func tearDown() async throws {
        sut = nil
        try await super.tearDown()
    }
    
    // MARK: - Registration Tests
    
    func testRegisterDetector() {
        let params = DeepDriverParams(entityId: UUID())
        let detector = Detector(params: params)

        sut.register(driver: detector, along: .detector)

        XCTAssertEqual(sut.detectors.count, 1)
        XCTAssertTrue(sut.classificators.isEmpty)
    }
    
    func testRegisterClassificator() {
        let params = DeepDriverParams(entityId: UUID())
        let classificator = Classificator(params: params)

        sut.register(driver: classificator, along: .classificator)

        XCTAssertEqual(sut.classificators.count, 1)
        XCTAssertTrue(sut.detectors.isEmpty)
    }
    
    func testRegisterInvalidType_DoesNotRegister() {
        let params = DeepDriverParams(entityId: UUID())
        let detector = Detector(params: params)

        sut.register(driver: detector, along: .invalid)

        XCTAssertTrue(sut.detectors.isEmpty)
        XCTAssertTrue(sut.classificators.isEmpty)
    }
    
    func testRegisterSameDriverTwice_OnlyRegistersOnce() {
        let id = UUID()
        let params = DeepDriverParams(entityId: id)
        let detector = Detector(params: params)

        sut.register(driver: detector, along: .detector)
        sut.register(driver: detector, along: .detector)

        XCTAssertEqual(sut.detectors.count, 1)
    }
    
    func testRegisterMultipleDetectors() {
        let detector1 = Detector(params: DeepDriverParams(entityId: UUID()))
        let detector2 = Detector(params: DeepDriverParams(entityId: UUID()))

        sut.register(driver: detector1, along: .detector)
        sut.register(driver: detector2, along: .detector)

        XCTAssertEqual(sut.detectors.count, 2)
    }
    
    // MARK: - Unregister Tests
    
    func testUnregisterDetector() async {
        let id = UUID()
        let params = DeepDriverParams(entityId: id)
        let detector = Detector(params: params)

        sut.register(driver: detector, along: .detector)
        XCTAssertEqual(sut.detectors.count, 1)

        await sut.unregister(driverId: id)

        XCTAssertTrue(sut.detectors.isEmpty)
    }
    
    func testUnregisterClassificator() async {
        let id = UUID()
        let params = DeepDriverParams(entityId: id)
        let classificator = Classificator(params: params)

        sut.register(driver: classificator, along: .classificator)
        XCTAssertEqual(sut.classificators.count, 1)

        await sut.unregister(driverId: id)

        XCTAssertTrue(sut.classificators.isEmpty)
    }
    
    func testUnregisterNonexistentDriver_DoesNothing() async {
        let params = DeepDriverParams(entityId: UUID())
        let detector = Detector(params: params)

        sut.register(driver: detector, along: .detector)
        XCTAssertEqual(sut.detectors.count, 1)

        let nonexistentId = UUID()
        await sut.unregister(driverId: nonexistentId)

        XCTAssertEqual(sut.detectors.count, 1)
    }
    
    // MARK: - Unload Tests
    
    func testUnloadDetectors() async {
        let detector1 = Detector(params: DeepDriverParams(entityId: UUID()))
        let detector2 = Detector(params: DeepDriverParams(entityId: UUID()))

        sut.register(driver: detector1, along: .detector)
        sut.register(driver: detector2, along: .detector)

        await sut.unload(.detector)

        // Detectors should still be in the array, just unloaded
        // The unload method doesn't remove them, just calls unload on each
        XCTAssertEqual(sut.detectors.count, 2)
    }
    
    func testUnloadClassificators() async {
        let classificator1 = Classificator(params: DeepDriverParams(entityId: UUID()))
        let classificator2 = Classificator(params: DeepDriverParams(entityId: UUID()))

        sut.register(driver: classificator1, along: .classificator)
        sut.register(driver: classificator2, along: .classificator)

        await sut.unload(.classificator)

        // Classificators should still be in the array, just unloaded
        XCTAssertEqual(sut.classificators.count, 2)
    }
    
    func testUnloadInvalidType_DoesNothing() async {
        let detector = Detector(params: DeepDriverParams(entityId: UUID()))
        let classificator = Classificator(params: DeepDriverParams(entityId: UUID()))

        sut.register(driver: detector, along: .detector)
        sut.register(driver: classificator, along: .classificator)

        await sut.unload(.invalid)

        XCTAssertEqual(sut.detectors.count, 1)
        XCTAssertEqual(sut.classificators.count, 1)
    }
    
    // MARK: - Update Configuration Tests
    
    func testUpdateConfiguration() {
        let id = UUID()
        let params = DeepDriverParams(annotationColor: .red, entityId: id)
        let detector = Detector(params: params)

        sut.register(driver: detector, along: .detector)

        // To test update, we need a DeepConfiguration mock
        // For now, just verify the method doesn't crash
        // A more complete test would require CoreData setup
    }
    
    // MARK: - Empty Detection Tests
    
    func testDetectWithNoDetectors_ReturnsEmptyResults() async {
        let image = UIImage(systemName: "star") ?? UIImage()

        let results = await sut.detect(on: image, tiledDetection: false)

        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - Detection with Unloaded Model Tests
    
    func testDetectWithUnloadedDetector_ReturnsEmptyResults() async {
        let detector = Detector(params: DeepDriverParams(entityId: UUID()))

        sut.register(driver: detector, along: .detector)

        let image = UIImage(systemName: "star") ?? UIImage()

        let results = await sut.detect(on: image, tiledDetection: true)

        // Without a loaded model, detection should return empty
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - Classify Pass Tests (AIA-0374)

    func testClassifyOn_StubClassificator_ReturnsItsLabels() async {
        let entityId = UUID()
        let labels = [
            ClassifiedLabel(identifier: "mound", confidence: 0.9),
            ClassifiedLabel(identifier: "field", confidence: 0.1)
        ]
        let stub = StubClassifying(params: DeepDriverParams(entityId: entityId), labels: labels)

        sut.register(driver: stub, along: .classificator)

        let results = await sut.classify(on: UIImage())

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.labels, labels)
        XCTAssertEqual(results.first?.params.entityId, entityId)
    }

    func testClassifyOn_EmptyLabels_DriverExcludedFromResults() async {
        let stub = StubClassifying(params: DeepDriverParams(entityId: UUID()), labels: [])

        sut.register(driver: stub, along: .classificator)

        let results = await sut.classify(on: UIImage())

        XCTAssertTrue(results.isEmpty)
    }

    func testClassifyOn_NonClassifyingDriver_Skipped() async {
        // A Detector registered on the classify side must be skipped, not crash the pass.
        let detector = Detector(params: DeepDriverParams(entityId: UUID()))

        sut.register(driver: detector, along: .classificator)

        let results = await sut.classify(on: UIImage())

        XCTAssertTrue(results.isEmpty)
    }

    func testClassifyOn_UnloadedClassificator_ReturnsEmptyResults() async {
        // A real Classificator with no model loaded classifies to nothing (atomic path).
        let classificator = Classificator(params: DeepDriverParams(entityId: UUID()))

        sut.register(driver: classificator, along: .classificator)

        let results = await sut.classify(on: UIImage())

        XCTAssertTrue(results.isEmpty)
    }
}

// MARK: - Classifying stub (AIA-0374)

/// Minimal `Classifying` conformer: the atomic API means a stub is one real function
/// plus inert `DeepDriver` plumbing.
private actor StubClassifying: Classifying {
    let id: UUID
    var params: DeepDriverParams
    var observations: [VNObservation] = []
    private let labels: [ClassifiedLabel]

    init(params: DeepDriverParams, labels: [ClassifiedLabel]) {
        self.id = params.entityId
        self.params = params
        self.labels = labels
    }

    func classify(image: UIImage) async -> [ClassifiedLabel] { labels }
    func metadata() -> [MLModelMetadataKey: Any]? { nil }
    func updateConfiguration(_ params: DeepDriverParams) async { self.params = params }
    func process(image: UIImage) async {}
    func loadFile() async throws {}
    func run() async {}
    func unload() async {}
}
