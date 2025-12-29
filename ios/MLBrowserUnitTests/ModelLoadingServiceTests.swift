//
//  ModelLoadingServiceTests.swift
//  AI ArcheologyTests
//
//  Created by Agent on 2025-12-29.
//

import XCTest
import CoreML
@testable import ML_Browser

// MARK: - ExtractedModelInfo Tests

final class ExtractedModelInfoTests: XCTestCase {

    func test_init_withAllValues_setsProperties() {
        let info = ExtractedModelInfo(
            modelVersion: "1.0.0",
            modelDescription: "Test model",
            author: "Test Author",
            creationDateString: "2025-01-01",
            task: .detector
        )

        XCTAssertEqual(info.modelVersion, "1.0.0")
        XCTAssertEqual(info.modelDescription, "Test model")
        XCTAssertEqual(info.author, "Test Author")
        XCTAssertEqual(info.creationDateString, "2025-01-01")
        XCTAssertEqual(info.task, .detector)
    }

    func test_init_withNilValues_setsNilProperties() {
        let info = ExtractedModelInfo(
            modelVersion: nil,
            modelDescription: nil,
            author: nil,
            creationDateString: nil,
            task: .invalid
        )

        XCTAssertNil(info.modelVersion)
        XCTAssertNil(info.modelDescription)
        XCTAssertNil(info.author)
        XCTAssertNil(info.creationDateString)
        XCTAssertEqual(info.task, .invalid)
    }

    func test_equatable_withSameValues_returnsTrue() {
        let info1 = ExtractedModelInfo(
            modelVersion: "1.0",
            modelDescription: "Desc",
            author: "Author",
            creationDateString: "2025-01-01",
            task: .detector
        )
        let info2 = ExtractedModelInfo(
            modelVersion: "1.0",
            modelDescription: "Desc",
            author: "Author",
            creationDateString: "2025-01-01",
            task: .detector
        )

        XCTAssertEqual(info1, info2)
    }

    func test_equatable_withDifferentValues_returnsFalse() {
        let info1 = ExtractedModelInfo(
            modelVersion: "1.0",
            modelDescription: "Desc",
            author: "Author",
            creationDateString: "2025-01-01",
            task: .detector
        )
        let info2 = ExtractedModelInfo(
            modelVersion: "2.0",
            modelDescription: "Desc",
            author: "Author",
            creationDateString: "2025-01-01",
            task: .detector
        )

        XCTAssertNotEqual(info1, info2)
    }

    func test_equatable_withDifferentTask_returnsFalse() {
        let info1 = ExtractedModelInfo(
            modelVersion: "1.0",
            modelDescription: nil,
            author: nil,
            creationDateString: nil,
            task: .detector
        )
        let info2 = ExtractedModelInfo(
            modelVersion: "1.0",
            modelDescription: nil,
            author: nil,
            creationDateString: nil,
            task: .classificator
        )

        XCTAssertNotEqual(info1, info2)
    }
}

// MARK: - ModelLoadingError Tests

final class ModelLoadingErrorTests: XCTestCase {

    func test_modelLoadFailed_errorDescription_containsFilename() {
        let url = URL(fileURLWithPath: "/path/to/TestModel.mlmodel")
        let error = ModelLoadingError.modelLoadFailed(url)

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("TestModel.mlmodel"))
    }

    func test_metadataExtractionFailed_errorDescription_containsFilename() {
        let url = URL(fileURLWithPath: "/path/to/MyModel.mlpackage")
        let error = ModelLoadingError.metadataExtractionFailed(url)

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("MyModel.mlpackage"))
    }

    func test_compilationFailed_errorDescription_containsFilenameAndUnderlyingError() {
        let url = URL(fileURLWithPath: "/path/to/Model.mlmodel")
        let underlyingError = NSError(domain: "TestDomain", code: 42, userInfo: [NSLocalizedDescriptionKey: "Compilation error"])
        let error = ModelLoadingError.compilationFailed(url, underlyingError)

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("Model.mlmodel"))
        XCTAssertTrue(error.errorDescription!.contains("Compilation error"))
    }
}

// MARK: - ModelLoadingService Tests

final class ModelLoadingServiceTests: XCTestCase {

    var sut: ModelLoadingService!

    override func setUp() async throws {
        try await super.setUp()
        sut = ModelLoadingService()
    }

    override func tearDown() async throws {
        sut = nil
        try await super.tearDown()
    }

    // MARK: - Initialization Tests

    func test_init_createsInstance() {
        XCTAssertNotNil(sut)
    }

    // MARK: - loadAndExtractMetadata Tests with Demo Models

    func test_loadAndExtractMetadata_withBundledDemoModel_extractsMetadata() async throws {
        // Try to find a bundled demo model
        guard let modelURL = Bundle.main.url(forResource: "AIArcheology", withExtension: "mlmodelc") else {
            // Skip test if demo model not available in test bundle
            throw XCTSkip("Demo model not available in test bundle")
        }

        let info = try await sut.loadAndExtractMetadata(from: modelURL, demo: true)

        // Demo models should have a valid task type
        XCTAssertNotEqual(info.task, .invalid, "Demo model should have a valid task type")
    }

    func test_loadAndExtractMetadata_withInvalidURL_throwsError() async {
        let invalidURL = URL(fileURLWithPath: "/nonexistent/path/model.mlmodelc")

        do {
            _ = try await sut.loadAndExtractMetadata(from: invalidURL, demo: true)
            XCTFail("Expected error to be thrown for invalid URL")
        } catch {
            // Expected behavior - error should be thrown
            XCTAssertTrue(error is ModelLoadingError, "Error should be ModelLoadingError")
        }
    }

    // MARK: - validateModel Tests

    func test_validateModel_withInvalidURL_returnsFalse() async {
        let invalidURL = URL(fileURLWithPath: "/nonexistent/model.mlmodelc")

        let isValid = await sut.validateModel(at: invalidURL, demo: true)

        XCTAssertFalse(isValid)
    }

    func test_validateModel_withBundledDemoModel_returnsTrue() async throws {
        guard let modelURL = Bundle.main.url(forResource: "AIArcheology", withExtension: "mlmodelc") else {
            throw XCTSkip("Demo model not available in test bundle")
        }

        let isValid = await sut.validateModel(at: modelURL, demo: true)

        XCTAssertTrue(isValid)
    }

    // MARK: - Concurrency Tests

    func test_multipleLoadCalls_executeSerially() async throws {
        guard let modelURL = Bundle.main.url(forResource: "AIArcheology", withExtension: "mlmodelc") else {
            throw XCTSkip("Demo model not available in test bundle")
        }

        // Capture service in local constant to satisfy Swift 6 concurrency checks
        let service = sut!

        // Call multiple times - actor ensures serial execution
        async let result1 = service.loadAndExtractMetadata(from: modelURL, demo: true)
        async let result2 = service.loadAndExtractMetadata(from: modelURL, demo: true)

        let (info1, info2) = try await (result1, result2)

        // Both should return the same metadata
        XCTAssertEqual(info1, info2)
    }
}
