//
//  ModelLoadingServiceTests.swift
//  AI ArcheologyTests
//
//  Created by Agent on 2025-12-29.
//

import XCTest
import CoreML
import NativeModelConverter
@testable import ML_Browser

// MARK: - ExtractedModelInfo Tests

final class ExtractedModelInfoTests: XCTestCase {

    func test_init_withAllValues_setsProperties() {
        let info = ExtractedModelInfo(
            modelVersion: "1.0.0",
            modelDescription: "Test model",
            author: "Test Author",
            license: "MIT",
            creationDateString: "2025-01-01",
            task: .detector,
            typeWasParsed: true
        )

        XCTAssertEqual(info.modelVersion, "1.0.0")
        XCTAssertEqual(info.modelDescription, "Test model")
        XCTAssertEqual(info.author, "Test Author")
        XCTAssertEqual(info.license, "MIT")
        XCTAssertEqual(info.creationDateString, "2025-01-01")
        XCTAssertEqual(info.task, .detector)
        XCTAssertTrue(info.typeWasParsed)
    }

    func test_init_withNilValues_setsNilProperties() {
        let info = ExtractedModelInfo(
            modelVersion: nil,
            modelDescription: nil,
            author: nil,
            creationDateString: nil,
            task: .invalid,
            typeWasParsed: false
        )

        XCTAssertNil(info.modelVersion)
        XCTAssertNil(info.modelDescription)
        XCTAssertNil(info.author)
        XCTAssertNil(info.license)
        XCTAssertNil(info.creationDateString)
        XCTAssertEqual(info.task, .invalid)
        XCTAssertFalse(info.typeWasParsed)
    }

    func test_equatable_withSameValues_returnsTrue() {
        let info1 = ExtractedModelInfo(
            modelVersion: "1.0",
            modelDescription: "Desc",
            author: "Author",
            creationDateString: "2025-01-01",
            task: .detector,
            typeWasParsed: true
        )
        let info2 = ExtractedModelInfo(
            modelVersion: "1.0",
            modelDescription: "Desc",
            author: "Author",
            creationDateString: "2025-01-01",
            task: .detector,
            typeWasParsed: true
        )

        XCTAssertEqual(info1, info2)
    }

    func test_equatable_withDifferentValues_returnsFalse() {
        let info1 = ExtractedModelInfo(
            modelVersion: "1.0",
            modelDescription: "Desc",
            author: "Author",
            creationDateString: "2025-01-01",
            task: .detector,
            typeWasParsed: true
        )
        let info2 = ExtractedModelInfo(
            modelVersion: "2.0",
            modelDescription: "Desc",
            author: "Author",
            creationDateString: "2025-01-01",
            task: .detector,
            typeWasParsed: true
        )

        XCTAssertNotEqual(info1, info2)
    }

    func test_equatable_withDifferentTask_returnsFalse() {
        let info1 = ExtractedModelInfo(
            modelVersion: "1.0",
            modelDescription: nil,
            author: nil,
            creationDateString: nil,
            task: .detector,
            typeWasParsed: true
        )
        let info2 = ExtractedModelInfo(
            modelVersion: "1.0",
            modelDescription: nil,
            author: nil,
            creationDateString: nil,
            task: .classificator,
            typeWasParsed: true
        )

        XCTAssertNotEqual(info1, info2)
    }

    func test_equatable_withDifferentTypeWasParsed_returnsFalse() {
        let base = ExtractedModelInfo(
            modelVersion: "1.0", modelDescription: nil, author: nil,
            creationDateString: nil, task: .detector, typeWasParsed: true
        )
        let other = ExtractedModelInfo(
            modelVersion: "1.0", modelDescription: nil, author: nil,
            creationDateString: nil, task: .detector, typeWasParsed: false
        )

        XCTAssertNotEqual(base, other)
    }

    func test_init_withBlankLicense_normalizesToNil() {
        let info = ExtractedModelInfo(
            modelVersion: nil,
            modelDescription: nil,
            author: nil,
            license: " \n ",
            creationDateString: nil,
            task: .invalid,
            typeWasParsed: false
        )

        XCTAssertNil(info.license)
    }

    func test_equatable_withDifferentLicense_returnsFalse() {
        let base = ExtractedModelInfo(
            modelVersion: "1.0", modelDescription: nil, author: nil, license: "MIT",
            creationDateString: nil, task: .detector, typeWasParsed: true
        )
        let other = ExtractedModelInfo(
            modelVersion: "1.0", modelDescription: nil, author: nil, license: "Apache-2.0",
            creationDateString: nil, task: .detector, typeWasParsed: true
        )

        XCTAssertNotEqual(base, other)
    }
}

final class ModelMetadataNormalizationTests: XCTestCase {

    func test_normalizedMetadataString_trimsNonEmptyTextAndRejectsBlankOrWrongType() {
        XCTAssertEqual(ModelLoadingService.normalizedMetadataString(" AGPL-3.0 \n"), "AGPL-3.0")
        XCTAssertNil(ModelLoadingService.normalizedMetadataString(" \t\n "))
        XCTAssertNil(ModelLoadingService.normalizedMetadataString(42))
        XCTAssertNil(ModelLoadingService.normalizedMetadataString(nil))
    }

    /// Covers the parser link `loadAndExtractMetadata` relies on for AIA-0478: the standard license
    /// key must survive `MLModelMetadataParser` and the normalization the extraction applies.
    func test_parserLicenseKey_roundTripsThroughNormalization() {
        let parser = MLModelMetadataParser(metadata: [.license: " AGPL-3.0 \n"])

        XCTAssertEqual(ModelLoadingService.normalizedMetadataString(parser.value(for: .license)), "AGPL-3.0")
    }

    func test_parserLicenseKey_missingOrBlank_yieldsNil() {
        XCTAssertNil(MLModelMetadataParser(metadata: [:]).value(for: .license))

        let blank = MLModelMetadataParser(metadata: [.license: " \t "])
        XCTAssertNil(ModelLoadingService.normalizedMetadataString(blank.value(for: .license)))
    }
}

// MARK: - Native Target Semantics Tests (AIA-0471)

final class NativeModelImportAssumptionTests: XCTestCase {

    func test_fallbackImageNetContract_returnsAssumption() {
        let assumption = ModelLoadingService.nativeModelImportAssumption(
            from: convertedMetadata(Contract(
                task: "classification",
                modelFormat: "neuralNetworkClassifier",
                classCount: "1000",
                labelProvenance: "convention",
                labelProfile: "imagenet-1k",
                preprocessingOrigin: "convention",
                preprocessingProfile: "image-net-rgb"
            ))
        )

        XCTAssertEqual(assumption?.labelProfile, .imageNet1K)
        XCTAssertEqual(assumption?.preprocessingProfile, .imageNetRGB)
    }

    func test_metadataBackedLabels_returnNoAssumptionEvenWithConverterPreprocessing() {
        let assumption = ModelLoadingService.nativeModelImportAssumption(
            from: convertedMetadata(Contract(
                task: "detection",
                modelFormat: "pipeline",
                labelProvenance: "metadata",
                labelProfile: "source-metadata",
                preprocessingOrigin: "convention",
                preprocessingProfile: "rgb-0-to-1"
            ))
        )

        XCTAssertNil(assumption, "Source-provided YOLO labels must not show a fallback warning.")
    }

    func test_incompleteOrMismatchedContract_returnsNoAssumption() {
        var userDefined = creatorDefined(Contract(
            task: "classification",
            modelFormat: "neuralNetworkClassifier",
            classCount: "1000",
            labelProvenance: "convention",
            labelProfile: "imagenet-1k",
            preprocessingOrigin: "convention",
            preprocessingProfile: "image-net-rgb"
        ))
        userDefined["com.aiarcheology.native.target.label-provenance"] = "metadata"

        XCTAssertNil(ModelLoadingService.nativeModelImportAssumption(from: [.creatorDefinedKey: userDefined]))

        // Restore the provenance so the second assertion isolates the missing-version case.
        userDefined["com.aiarcheology.native.target.label-provenance"] = "convention"
        userDefined.removeValue(forKey: "com.aiarcheology.native.target.semantics-version")
        XCTAssertNil(ModelLoadingService.nativeModelImportAssumption(from: [.creatorDefinedKey: userDefined]))
    }

    func test_fallbackImageNetContract_withWrongClassCount_returnsNoAssumption() {
        let assumption = ModelLoadingService.nativeModelImportAssumption(
            from: convertedMetadata(Contract(
                task: "classification",
                modelFormat: "neuralNetworkClassifier",
                classCount: "3",
                labelProvenance: "convention",
                labelProfile: "imagenet-1k",
                preprocessingOrigin: "convention",
                preprocessingProfile: "image-net-rgb"
            ))
        )

        XCTAssertNil(assumption, "An imagenet-1k contract without 1000 classes is untruthful and must not parse.")
    }

    /// The target-semantics contract a converted model carries.
    ///
    /// One value rather than seven arguments: these fields are a single contract that
    /// `nativeModelImportAssumption` reads together, and passing them separately made both helpers
    /// exceed the parameter-count limit while saying nothing about how they relate.
    private struct Contract {
        let task: String
        let modelFormat: String
        var classCount: String = "3"
        let labelProvenance: String
        let labelProfile: String
        let preprocessingOrigin: String
        let preprocessingProfile: String
    }

    private func convertedMetadata(_ contract: Contract) -> [MLModelMetadataKey: Any] {
        [.creatorDefinedKey: creatorDefined(contract)]
    }

    private func creatorDefined(_ contract: Contract) -> [String: String] {
        [
            "com.aiarcheology.native.converter.package-version": "1.0.0",
            "com.aiarcheology.native.target.semantics-version": "1",
            "com.aiarcheology.native.target.model-format": contract.modelFormat,
            "com.aiarcheology.native.target.task": contract.task,
            "com.aiarcheology.native.target.class-count": contract.classCount,
            "com.aiarcheology.native.target.label-provenance": contract.labelProvenance,
            "com.aiarcheology.native.target.label-profile": contract.labelProfile,
            "com.aiarcheology.native.target.preprocessing-origin": contract.preprocessingOrigin,
            "com.aiarcheology.native.target.preprocessing-profile": contract.preprocessingProfile
        ]
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

    func test_modelTypeNotDetermined_errorDescription_containsFilenameAndGuidance() {
        let url = URL(fileURLWithPath: "/path/to/YOLOv3.mlmodel")
        let error = ModelLoadingError.modelTypeNotDetermined(url)

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("YOLOv3.mlmodel"))
        XCTAssertTrue(error.errorDescription!.contains("Could not determine model type"))
        XCTAssertTrue(error.errorDescription!.contains("detector or classifier"))
    }
}

// MARK: - Converted-model Runtime Policy Tests (AIA-0688)

final class NativeModelRuntimePolicyTests: XCTestCase {

	func test_adafPolicy_requiresCPUPlacement() {
		let userDefined = [
			NativeModelRuntimePolicy.computeUnitsKey: NativeModelComputeUnitPolicy.cpuOnly.rawValue
		]

		XCTAssertEqual(
			NativeModelRuntimePolicy.computeUnitPolicy(from: userDefined),
			.cpuOnly
		)
		XCTAssertEqual(
			Detector.runtimeComputeUnits(from: userDefinedMetadata(userDefined)),
			.cpuOnly
		)
		XCTAssertEqual(
			NativeModelRuntimePolicy.computeUnitPolicy(
				forProducer: NativeModelRuntimePolicy.adafFasterRCNNProducerName
			),
			.cpuOnly
		)
	}

	/// `.cpuAndGPU` stays a representable policy even though no producer currently requests it. The
	/// enum is the converter's vocabulary for a measured requirement, not a record of one graph's
	/// answer, and a future graph may well measure GPU-safe.
	func test_gpuPolicy_remainsRepresentable() {
		let userDefined = [
			NativeModelRuntimePolicy.computeUnitsKey: NativeModelComputeUnitPolicy.cpuAndGPU.rawValue
		]

		XCTAssertEqual(
			NativeModelRuntimePolicy.computeUnitPolicy(from: userDefined),
			.cpuAndGPU
		)
		XCTAssertEqual(
			Detector.runtimeComputeUnits(from: userDefinedMetadata(userDefined)),
			.cpuAndGPU
		)
	}

	func test_unknownOrMissingPolicy_keepsDefaultPlacement() {
		XCTAssertNil(NativeModelRuntimePolicy.computeUnitPolicy(from: [:]))
		XCTAssertNil(
			NativeModelRuntimePolicy.computeUnitPolicy(from: [
				NativeModelRuntimePolicy.computeUnitsKey: "future-unit"
			])
		)
		XCTAssertNil(Detector.runtimeComputeUnits(from: userDefinedMetadata([:])))
	}

	func test_nonADAFProducer_hasNoPolicy() {
		XCTAssertNil(NativeModelRuntimePolicy.computeUnitPolicy(forProducer: "tests"))
	}

	private func userDefinedMetadata(_ values: [String: String]) -> [MLModelMetadataKey: Any] {
		[.creatorDefinedKey: values]
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
        // AIArcheology declares its type in metadata (CreateML preview type), so the parser decides
        // it — this is what makes the demo's type locked/read-only in settings (AIA-0402).
        XCTAssertTrue(info.typeWasParsed, "A declared-type demo model should be parser-decided")
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

    // MARK: - inferType (structural signature) Tests — AIA-0402

    func test_inferType_detectorFixture_returnsDetector() async throws {
        guard let url = Bundle.main.url(forResource: "AIArcheology", withExtension: "mlmodelc") else {
            throw XCTSkip("Detector demo model not available in test bundle")
        }
        let model = try await MLModel.load(contentsOf: url, configuration: MLModelConfiguration())
        XCTAssertEqual(ModelLoadingService.inferType(from: model.modelDescription), .detector,
                       "A model with confidence+coordinates outputs should infer as a detector")
    }

    func test_inferType_classifierFixture_returnsClassificator() async throws {
        guard let url = Bundle.main.url(forResource: "FastViTT8F16", withExtension: "mlmodelc") else {
            throw XCTSkip("Classifier demo model not available in test bundle")
        }
        let model = try await MLModel.load(contentsOf: url, configuration: MLModelConfiguration())
        XCTAssertEqual(ModelLoadingService.inferType(from: model.modelDescription), .classificator,
                       "A model exposing a predicted-feature name should infer as a classifier")
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
