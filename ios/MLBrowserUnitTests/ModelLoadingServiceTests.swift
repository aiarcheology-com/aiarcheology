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

    func test_compiledModelLoadFailed_errorDescription_containsFilenameUnderlyingErrorAndRecovery() throws {
        let url = URL(fileURLWithPath: "/path/to/Model.mlmodelc")
        let underlyingError = NSError(domain: "TestDomain", code: 7, userInfo: [NSLocalizedDescriptionKey: "Unable to load model"])
        let error = ModelLoadingError.compiledModelLoadFailed(url, underlyingError)

        let description = try XCTUnwrap(error.errorDescription)
        XCTAssertTrue(description.contains("Model.mlmodelc"))
        // Core ML's wording is quoted, not spliced, so the recovery hint is a sentence of its own
        // whether or not the underlying message ends in a period.
        XCTAssertTrue(description.contains("(Unable to load model). Compiled"))

        let punctuated = NSError(domain: "TestDomain", code: 7, userInfo: [NSLocalizedDescriptionKey: " Unable to load model. \n"])
        let punctuatedDescription = try XCTUnwrap(ModelLoadingError.compiledModelLoadFailed(url, punctuated).errorDescription)
        XCTAssertTrue(punctuatedDescription.contains("(Unable to load model). Compiled"), "A trailing period and whitespace in Core ML's message must not double up: \(punctuatedDescription)")
        XCTAssertTrue(description.contains("platform-specific"), "The recovery hint must explain why a compiled bundle can fail here")
        XCTAssertTrue(description.contains(".mlmodel or .mlpackage"), "The recovery hint must say what to import instead")
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

        let info = try await sut.loadAndExtractMetadata(from: modelURL)

        // Demo models should have a valid task type
        XCTAssertNotEqual(info.task, .invalid, "Demo model should have a valid task type")
        // AIArcheology declares its type in metadata (CreateML preview type), so the parser decides
        // it — this is what makes the demo's type locked/read-only in settings (AIA-0402).
        XCTAssertTrue(info.typeWasParsed, "A declared-type demo model should be parser-decided")
    }

    func test_loadAndExtractMetadata_withInvalidURL_throwsError() async {
        let invalidURL = URL(fileURLWithPath: "/nonexistent/path/model.mlmodelc")

        do {
            _ = try await sut.loadAndExtractMetadata(from: invalidURL)
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

        let isValid = await sut.validateModel(at: invalidURL)

        XCTAssertFalse(isValid)
    }

    func test_validateModel_withBundledDemoModel_returnsTrue() async throws {
        guard let modelURL = Bundle.main.url(forResource: "AIArcheology", withExtension: "mlmodelc") else {
            throw XCTSkip("Demo model not available in test bundle")
        }

        let isValid = await sut.validateModel(at: modelURL)

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
        async let result1 = service.loadAndExtractMetadata(from: modelURL)
        async let result2 = service.loadAndExtractMetadata(from: modelURL)

        let (info1, info2) = try await (result1, result2)

        // Both should return the same metadata
        XCTAssertEqual(info1, info2)
    }
}

// MARK: - Compiled artifact routing Tests — AIA-0844

/// An imported `.mlmodelc` is not a demo, yet it is already compiled — and Core ML refuses to compile
/// a compiled bundle a second time. Both loaders therefore route on the artifact's format, and these
/// tests drive a real compiled bundle through the non-demo service and driver paths: actual loading
/// and a real prediction, not an extension helper. Under the previous code every "compiled" case here
/// failed with `ModelLoadingError.compilationFailed` (service) or threw from `compileModel` (driver).
///
/// Not `final`: the class-level `setUp`/`tearDown` overrides below must stay `class func`.
class CompiledCoreMLArtifactRoutingTests: XCTestCase {

    private enum FixtureError: Error {
        case probeMissingFromTestBundle
    }

    /// The probe compiled ONCE for the whole class — compiling is the expensive step and every test
    /// needs the same artifact — then copied out of the test bundle into a scratch directory, the way
    /// an import lands in the app's Documents rather than in the app bundle. `Result` rather than a
    /// skip: a probe that cannot compile on the simulator is a real regression, not an environment
    /// condition. `nonisolated(unsafe)`: XCTest runs the class-level `setUp`/`tearDown` before and after
    /// every test in the class, and the tests themselves only read.
    nonisolated(unsafe) private static var importedCompiledProbe: Result<URL, Error> = .failure(FixtureError.probeMissingFromTestBundle)
    nonisolated(unsafe) private static var scratchDirectory: URL?

    override class func setUp() {
        super.setUp()
        importedCompiledProbe = Result {
            let bundle = Bundle(for: CompiledCoreMLArtifactRoutingTests.self)
            let compiled: URL
            if let source = bundle.url(forResource: "VisionScaleFitProbe", withExtension: "mlmodel") {
                compiled = try MLModel.compileModel(at: source)
            } else if let prebuilt = bundle.url(forResource: "VisionScaleFitProbe", withExtension: "mlmodelc") {
                compiled = prebuilt
            } else {
                throw FixtureError.probeMissingFromTestBundle
            }
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("AIA-0844-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            scratchDirectory = scratch
            let imported = scratch.appendingPathComponent("ImportedProbe.mlmodelc", isDirectory: true)
            try FileManager.default.copyItem(at: compiled, to: imported)
            return imported
        }
    }

    override class func tearDown() {
        if let scratch = scratchDirectory {
            try? FileManager.default.removeItem(at: scratch)
        }
        scratchDirectory = nil
        importedCompiledProbe = .failure(FixtureError.probeMissingFromTestBundle)
        super.tearDown()
    }

    private func importedCompiledProbe() throws -> URL {
        try Self.importedCompiledProbe.get()
    }

    /// A directory that merely wears the extension: what a truncated copy or a foreign bundle looks
    /// like to the loader before Core ML reads its manifest.
    private func makeMalformedCompiledBundle() throws -> URL {
        let scratch = try XCTUnwrap(Self.scratchDirectory)
        let broken = scratch.appendingPathComponent("Broken-\(UUID().uuidString).mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: broken) }
        return broken
    }

    /// Runs a real prediction on the probe: a blank pixel buffer in the model's own input format.
    /// The output is asserted to exist and to have the probe's pass-through shape, which only a
    /// loaded, runnable model can produce.
    private func assertPredicts(_ model: MLModel, file: StaticString = #filePath, line: UInt = #line) throws {
        let constraint = try XCTUnwrap(
            model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint,
            "the probe presents a single image input", file: file, line: line
        )
        var buffer: CVPixelBuffer?
        // IOSurface-backed, as in VisionScaleFitProbeTests: the buffer layout Core ML and Vision
        // accept on every simulator runtime.
        let status = CVPixelBufferCreate(
            nil, constraint.pixelsWide, constraint.pixelsHigh, constraint.pixelFormatType,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &buffer
        )
        XCTAssertEqual(status, kCVReturnSuccess, "CVPixelBufferCreate failed with status \(status)", file: file, line: line)
        let pixelBuffer = try XCTUnwrap(buffer, file: file, line: line)
        let input = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: pixelBuffer)])
        let output = try model.prediction(from: input)
        let passthrough = try XCTUnwrap(output.featureValue(for: "passthrough")?.multiArrayValue, file: file, line: line)
        XCTAssertEqual(passthrough.count, 3 * constraint.pixelsWide * constraint.pixelsHigh, file: file, line: line)
    }

    // MARK: Service (import validation + metadata)

    func test_service_loadsImportedCompiledBundle_withoutRecompiling() async throws {
        let compiled = try importedCompiledProbe()

        let info = try await ModelLoadingService().loadAndExtractMetadata(from: compiled)

        // The probe declares no task metadata, so the type falls back to the structural signature
        // (AIA-0402); what matters here is that the compiled bundle loaded at all.
        XCTAssertFalse(info.typeWasParsed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: compiled.path), "loading must not consume the imported bundle")
    }

    func test_service_validatesImportedCompiledBundle() async throws {
        let compiled = try importedCompiledProbe()

        let isValid = await ModelLoadingService().validateModel(at: compiled)

        XCTAssertTrue(isValid)
    }

    /// The source route is unchanged: an `.mlmodel` still goes to the compiler first, so a missing
    /// one fails *there* — not at the load step a compiled bundle would reach. (The test bundle
    /// carries only Xcode's precompiled probe, so a real compile success cannot be staged here; the
    /// distinct error case is what pins the routing.)
    func test_service_sourceModel_stillTakesTheCompileRoute() async {
        let missingSource = URL(fileURLWithPath: "/nonexistent/AIA-0844/model.mlmodel")

        do {
            _ = try await ModelLoadingService().loadAndExtractMetadata(from: missingSource)
            XCTFail("A missing .mlmodel must fail")
        } catch ModelLoadingError.compilationFailed(let url, _) {
            XCTAssertEqual(url, missingSource)
        } catch {
            XCTFail("Expected compilationFailed for a source model, got \(error)")
        }
    }

    func test_service_malformedCompiledBundle_throwsCompiledModelLoadFailed_withUnderlyingError() async throws {
        let broken = try makeMalformedCompiledBundle()

        do {
            _ = try await ModelLoadingService().loadAndExtractMetadata(from: broken)
            XCTFail("An empty .mlmodelc directory must not load")
        } catch ModelLoadingError.compiledModelLoadFailed(let url, let underlying) {
            XCTAssertEqual(url, broken)
            XCTAssertFalse(underlying.localizedDescription.isEmpty, "Core ML's reason must travel with the error")
        } catch {
            XCTFail("Expected compiledModelLoadFailed, got \(error)")
        }
    }

    // MARK: Drivers (runtime loading + inference)

    func test_detectorDriver_loadsImportedCompiledBundle_andPredicts() async throws {
        let compiled = try importedCompiledProbe()

        let loaded = try await Detector.loadModel(from: compiled)
        let model = try XCTUnwrap(loaded)

        try assertPredicts(model)
    }

    func test_classificatorDriver_loadsImportedCompiledBundle_andPredicts() async throws {
        let compiled = try importedCompiledProbe()

        let loaded = try await Classificator.loadModel(from: compiled)
        let model = try XCTUnwrap(loaded)

        try assertPredicts(model)
    }

    func test_driver_malformedCompiledBundle_returnsNilWithoutThrowing() async throws {
        let broken = try makeMalformedCompiledBundle()

        do {
            let model = try await Detector.loadModel(from: broken)
            XCTAssertNil(model, "A compiled bundle Core ML cannot load is answered with nil, as every load failure is")
        } catch {
            XCTFail("A load failure must not throw from the driver: \(error)")
        }
    }
}
