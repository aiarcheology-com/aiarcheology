//
//  DriversTests.swift
//  AI ArcheologyTests
//
//  Created by AI Assistant on 20.11.25.
//

import XCTest
import Vision
import CoreML
@testable import ML_Browser

final class DriversTests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    // MARK: - DeepDriver Protocol Tests (via Detector)

    /// A compiled bundle skips compilation and goes straight to the load step, whose failures the
    /// driver swallows into `nil` (logged and crash-reported) rather than throwing.
    func testDeepDriverLoadModel_MissingCompiledBundle_ReturnsNilWithoutThrowing() async {
        let invalidURL = URL(fileURLWithPath: "/invalid/path/to/model.mlmodelc")

        do {
            let model = try await Detector.loadModel(from: invalidURL)
            XCTAssertNil(model, "Model should be nil for a missing compiled bundle")
        } catch {
            XCTFail("Should not throw, but return nil: \(error)")
        }
    }

    /// A source model is compiled first, and a compile failure propagates to the caller — the
    /// behaviour every imported `.mlmodel` has always had (AIA-0844 kept it, and only re-routed
    /// `.mlmodelc` bundles around the compile step).
    func testDeepDriverLoadModel_MissingSourceModel_ThrowsFromCompilation() async {
        let invalidURL = URL(fileURLWithPath: "/invalid/path/to/model.mlmodel")

        do {
            _ = try await Detector.loadModel(from: invalidURL)
            XCTFail("Compiling a missing .mlmodel should throw")
        } catch {
            // Expected: MLModel.compileModel(at:) rejects the missing source.
        }
    }

    // MARK: - Detector Tests

    func testDetectorInitialization() async {
        let id = UUID()
        let params = DeepDriverParams(entityId: id, modelName: "Test Model")
        let detector = Detector(params: params)
        
        let detectorId = await detector.id
        XCTAssertEqual(detectorId, id)
        
        let detectorParams = await detector.params
        XCTAssertEqual(detectorParams.entityId, id)
    }

    func testDetectorUpdateConfiguration() async {
		let id = UUID()
		let params = DeepDriverParams(annotationColor: .red, entityId: id, modelName: "Test Model")
        let detector = Detector(params: params)
        
        let newParams = DeepDriverParams(annotationColor: .blue, entityId: id, modelName: "Test Model")
        await detector.updateConfiguration(newParams)
        
        let updatedParams = await detector.params
        XCTAssertEqual(updatedParams.annotationColor, .blue)
    }
    
    func testDetectorProcessImage() async {
        let id = UUID()
        let params = DeepDriverParams(entityId: id, modelName: "Test Model")
        let detector = Detector(params: params)
        
        // Create a dummy image
        let image = UIImage(systemName: "star") ?? UIImage()
        
        await detector.process(image: image)
        
        // We can't easily check private properties like `ciImage` or `handler` without making them internal or adding test hooks.
        // However, we can verify that `detect()` doesn't crash after process.
    }
    
    func testDetectorDetect_NoModelLoaded() async {
        let id = UUID()
        let params = DeepDriverParams(entityId: id, modelName: "Test Model")
        let detector = Detector(params: params)
        
        let image = UIImage(systemName: "star") ?? UIImage()
        await detector.process(image: image)
        
        // Should not crash, just log errors/debug info
        await detector.detect()
        
        let observations = await detector.observations
        XCTAssertTrue(observations.isEmpty)
    }
}
