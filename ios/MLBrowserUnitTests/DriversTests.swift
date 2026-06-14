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

    func testDeepDriverLoadModel_InvalidPath() async {
        // Test static loadModel with an invalid path
        let invalidURL = URL(fileURLWithPath: "/invalid/path/to/model.mlmodel")
        
        do {
            let model = try await Detector.loadModel(from: invalidURL, demo: true)
            // It might return nil or throw depending on implementation.
            // Looking at DeepDriver.swift: it catches error and returns nil.
            XCTAssertNil(model, "Model should be nil for invalid path")
        } catch {
            XCTFail("Should not throw, but return nil: \(error)")
        }
    }

    // MARK: - Detector Tests

    func testDetectorInitialization() async {
        let id = UUID()
        let params = DeepDriverParams(entityId: id)
        let detector = Detector(params: params)
        
        let detectorId = await detector.id
        XCTAssertEqual(detectorId, id)
        
        let detectorParams = await detector.params
        XCTAssertEqual(detectorParams.entityId, id)
    }

    func testDetectorUpdateConfiguration() async {
		let id = UUID()
		let params = DeepDriverParams(annotationColor: .red, entityId: id)
        let detector = Detector(params: params)
        
        let newParams = DeepDriverParams(annotationColor: .blue, entityId: id)
        await detector.updateConfiguration(newParams)
        
        let updatedParams = await detector.params
        XCTAssertEqual(updatedParams.annotationColor, .blue)
    }
    
    func testDetectorProcessImage() async {
        let id = UUID()
        let params = DeepDriverParams(entityId: id)
        let detector = Detector(params: params)
        
        // Create a dummy image
        let image = UIImage(systemName: "star") ?? UIImage()
        
        await detector.process(image: image)
        
        // We can't easily check private properties like `ciImage` or `handler` without making them internal or adding test hooks.
        // However, we can verify that `detect()` doesn't crash after process.
    }
    
    func testDetectorDetect_NoModelLoaded() async {
        let id = UUID()
        let params = DeepDriverParams(entityId: id)
        let detector = Detector(params: params)
        
        let image = UIImage(systemName: "star") ?? UIImage()
        await detector.process(image: image)
        
        // Should not crash, just log errors/debug info
        await detector.detect()
        
        let observations = await detector.observations
        XCTAssertTrue(observations.isEmpty)
    }
}
