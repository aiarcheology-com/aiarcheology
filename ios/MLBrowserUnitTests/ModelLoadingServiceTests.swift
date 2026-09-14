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
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: DemoDataManager.TestModelResource.fastViT, withExtension: "mlmodelc"),
            "Fetch Apple test fixtures and build with AIA_INCLUDE_TEST_FIXTURES=YES"
        )
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

// MARK: - Load-time memory admission (AIA-0889)

/// The gate that turns "the process vanished inside `MLModel.load`" into a real error.
///
/// `decide` is pure precisely so these run without a device: the simulator reports no per-process
/// limit, so the live path is `.unavailable` there and only the decision logic is observable.
final class ModelLoadMemoryPreflightTests: XCTestCase {

    private let factor = ModelLoadMemoryPreflight.loadFootprintFactor

    // MARK: Fail open — an unknown input must never block a load that would have worked

    func test_decide_withUnreadableModelSize_admits() {
        let decision = ModelLoadMemoryPreflight.decide(modelByteCount: nil, headroom: .bytes(1))
        XCTAssertEqual(decision, .admit, "An unreadable size is a measurement failure, not a refusal")
    }

    func test_decide_withUnavailableHeadroom_admits() {
        let decision = ModelLoadMemoryPreflight.decide(modelByteCount: .max, headroom: .unavailable)
        XCTAssertEqual(decision, .admit, "No applicable per-process limit must not refuse any model")
    }

    // MARK: Fail closed — only on numbers it can actually compare

    func test_decide_withHeadroomBelowRequirement_refusesWithBothCounts() {
        let modelByteCount: UInt64 = 200 * 1024 * 1024
        let required = modelByteCount * factor
        let available = required - 1

        let decision = ModelLoadMemoryPreflight.decide(
            modelByteCount: modelByteCount,
            headroom: .bytes(available)
        )

        XCTAssertEqual(decision, .refuse(requiredByteCount: required, availableByteCount: available))
    }

    func test_decide_withHeadroomExactlyMeetingRequirement_admits() {
        let modelByteCount: UInt64 = 64 * 1024 * 1024
        let decision = ModelLoadMemoryPreflight.decide(
            modelByteCount: modelByteCount,
            headroom: .bytes(modelByteCount * factor)
        )
        XCTAssertEqual(decision, .admit, "Exactly enough is enough; the boundary must not refuse")
    }

    func test_decide_withHeadroomOneByteAboveRequirement_admits() {
        let modelByteCount: UInt64 = 64 * 1024 * 1024
        let decision = ModelLoadMemoryPreflight.decide(
            modelByteCount: modelByteCount,
            headroom: .bytes(modelByteCount * factor + 1)
        )
        XCTAssertEqual(decision, .admit)
    }

    /// On a real device a reported zero means the process has already exceeded its limit. Admitting
    /// there would disable the gate at exactly the moment it is needed.
    func test_decide_withZeroHeadroom_refuses() {
        let decision = ModelLoadMemoryPreflight.decide(modelByteCount: 1, headroom: .bytes(0))
        XCTAssertEqual(decision, .refuse(requiredByteCount: factor, availableByteCount: 0))
    }

    /// A zero-byte file says nothing about what loading it costs, and the budget is known spent.
    /// The requirement is clamped above zero: a refusal that claims it needed nothing contradicts
    /// itself, and would reach the user as "needed about 0 MB".
    func test_decide_withZeroSizedModelAndZeroHeadroom_refusesWithANonZeroRequirement() {
        let decision = ModelLoadMemoryPreflight.decide(modelByteCount: 0, headroom: .bytes(0))
        XCTAssertEqual(decision, .refuse(requiredByteCount: 1, availableByteCount: 0))
    }

    /// No refusal may report a zero requirement, whatever the inputs.
    func test_decide_neverRefusesWithAZeroRequirement() {
        let cases: [(UInt64?, UInt64)] = [(0, 0), (nil, 0), (1, 0), (.max, 0), (.max, 1024)]
        for (modelByteCount, availableByteCount) in cases {
            let decision = ModelLoadMemoryPreflight.decide(
                modelByteCount: modelByteCount,
                headroom: .bytes(availableByteCount)
            )
            guard case .refuse(let requiredByteCount, _) = decision else {
                XCTFail("Expected a refusal for size \(String(describing: modelByteCount)), headroom \(availableByteCount)")
                continue
            }
            XCTAssertGreaterThan(requiredByteCount, 0, "A refusal must never claim it needed nothing")
        }
    }

    /// Exhausted is not unknown. An unreadable size is no reason to disbelieve a budget the OS
    /// has reported as spent, so this must refuse even though the size fallback normally admits.
    func test_decide_withUnreadableSizeAndZeroHeadroom_refuses() {
        let decision = ModelLoadMemoryPreflight.decide(modelByteCount: nil, headroom: .bytes(0))
        XCTAssertEqual(decision, .refuse(requiredByteCount: 1, availableByteCount: 0))
    }

    func test_decide_withUnreadableSizeAndRealHeadroom_admits() {
        let decision = ModelLoadMemoryPreflight.decide(modelByteCount: nil, headroom: .bytes(1_000_000))
        XCTAssertEqual(decision, .admit, "With real headroom, an unknown size must fail open")
    }

    /// An unrepresentable requirement exceeds every possible headroom, so it must refuse rather
    /// than wrap around into a small number and admit.
    func test_decide_withOverflowingRequirement_refusesAtSaturation() {
        let decision = ModelLoadMemoryPreflight.decide(
            modelByteCount: UInt64.max,
            headroom: .bytes(1024)
        )
        XCTAssertEqual(decision, .refuse(requiredByteCount: .max, availableByteCount: 1024))
    }

    /// Saturating to `.max` and then comparing would admit here, because `.max > .max` is false —
    /// failing open on exactly the absurd input the saturation exists to catch.
    func test_decide_withOverflowingRequirement_refusesEvenAgainstMaximumHeadroom() {
        let decision = ModelLoadMemoryPreflight.decide(
            modelByteCount: UInt64.max,
            headroom: .bytes(.max)
        )
        XCTAssertEqual(decision, .refuse(requiredByteCount: .max, availableByteCount: .max))
    }

    /// The counterpart: a requirement that fits must still be admitted against huge headroom.
    func test_decide_withRepresentableRequirement_admitsAgainstMaximumHeadroom() {
        let decision = ModelLoadMemoryPreflight.decide(
            modelByteCount: 200 * 1024 * 1024,
            headroom: .bytes(.max)
        )
        XCTAssertEqual(decision, .admit)
    }

    // MARK: The false positive that would be unrecoverable

    /// `DemoDataManager` skips *all* demo creation once any demo exists, so a demo refused on one
    /// launch is never created again. Every bundled demo must clear the gate against a floor far
    /// below any supported device's headroom.
    func test_decide_admitsEveryBundledDemoModel_atAConservativeHeadroomFloor() throws {
        let conservativeFloor: UInt64 = 512 * 1024 * 1024
        let names = [
            DemoDataManager.DemoModelResource.aiArcheology,
            DemoDataManager.DemoModelResource.hroudaDetector
        ]

        for name in names {
            // Required, not best-effort: a `continue` here would let this test pass while the very
            // models it exists to protect went unchecked.
            let url = try XCTUnwrap(
                Bundle.main.url(forResource: name, withExtension: "mlmodelc"),
                "Bundled demo \(name) is missing from the test bundle"
            )
            let byteCount = try XCTUnwrap(
                ModelLoadingService.byteCount(at: url),
                "Bundled demo \(name) has an unreadable size"
            )
            XCTAssertEqual(
                ModelLoadMemoryPreflight.decide(modelByteCount: byteCount, headroom: .bytes(conservativeFloor)),
                .admit,
                "Demo \(name) (\(byteCount) bytes) must not be refused: a false positive drops it permanently"
            )
        }
    }

    // MARK: byteCount — the input the gate is only as good as

    /// A compiled model is a *directory*. A plain `fileSizeKey` on one returns a few hundred bytes,
    /// which would silently pass exactly the bundles the gate exists to weigh.
    func test_byteCount_forADirectory_sumsItsContentsRatherThanTheDirectoryEntry() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aia0889-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 3_000).write(to: root.appendingPathComponent("a.bin"))
        try Data(repeating: 0, count: 5_000).write(to: nested.appendingPathComponent("b.bin"))

        XCTAssertEqual(ModelLoadingService.byteCount(at: root), 8_000)
    }

    func test_byteCount_forAMissingPath_isNil() {
        let missing = URL(fileURLWithPath: "/nonexistent/aia0889/model.mlmodelc")
        XCTAssertNil(ModelLoadingService.byteCount(at: missing))
    }

    // MARK: Instrumentation helpers

    func test_footprintIncrease_returnsTheDelta() {
        XCTAssertEqual(ModelLoadingService.footprintIncrease(from: 100, to: 350), 250)
    }

    func test_footprintIncrease_withAFallingFootprint_isNil() {
        XCTAssertNil(
            ModelLoadingService.footprintIncrease(from: 350, to: 100),
            "A negative increase is a sampling artefact, not a measurement"
        )
    }

    func test_footprintIncrease_withAMissingSample_isNil() {
        XCTAssertNil(ModelLoadingService.footprintIncrease(from: nil, to: 100))
        XCTAssertNil(ModelLoadingService.footprintIncrease(from: 100, to: nil))
    }

    func test_headroomDescription_distinguishesUnavailableFromZero() {
        XCTAssertEqual(ModelLoadingService.headroomDescription(.unavailable), "unavailable")
        XCTAssertEqual(ModelLoadingService.headroomDescription(.bytes(0)), "0")
    }
}

// MARK: - Conversion diagnostic mapping and its privacy rail (AIA-0889)

/// `NativeModelConversionDiagnostic.message` is rendered verbatim, written into the exported
/// conversion log, and shared. `ModelLoadingError.errorDescription` embeds the file name and Core
/// ML's own wording, so any mapping that reached for `localizedDescription` would publish both.
///
/// These assert **equality** against fixed literals rather than the absence of a slash: Core ML
/// error strings routinely contain no path separator, so an absence check passes while leaking.
final class NativeConversionDiagnosticMappingTests: XCTestCase {

    private static let secretFilename = "aia0889-secret-model-name.mlmodel"
    private static let secretURL = URL(fileURLWithPath: "/private/var/mobile/aia0889-secret-path/\(secretFilename)")
    private static let secretUnderlying = NSError(
        domain: "com.apple.CoreML",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: "aia0889-secret-coreml-wording"]
    )

    private func message(for error: Error) -> String {
        ModelImportView.nativeConversionDiagnostic(for: error).message
    }

    private func code(for error: Error) -> String {
        ModelImportView.nativeConversionDiagnostic(for: error).code
    }

    // MARK: Codes — the stage is now nameable instead of collapsing into one catch-all

    func test_insufficientMemory_mapsToItsOwnCode() {
        let error = ModelLoadingError.insufficientMemory(
            Self.secretURL,
            requiredByteCount: 600 * 1024 * 1024,
            availableByteCount: 300 * 1024 * 1024
        )
        XCTAssertEqual(code(for: error), "app.insufficientMemoryForModelLoad")
        XCTAssertEqual(
            message(for: error),
            "The device did not have enough free memory to load the converted model (needed about 600 MB, about 300 MB available)."
        )
    }

    func test_compilationFailed_mapsToItsOwnCode() {
        let error = ModelLoadingError.compilationFailed(Self.secretURL, Self.secretUnderlying)
        XCTAssertEqual(code(for: error), "app.modelCompilationFailed")
        XCTAssertEqual(message(for: error), "The emitted model could not be compiled by Core ML.")
    }

    func test_modelLoadFailed_mapsToItsOwnCode() {
        let error = ModelLoadingError.modelLoadFailed(Self.secretURL)
        XCTAssertEqual(code(for: error), "app.modelLoadFailed")
        XCTAssertEqual(message(for: error), "The emitted model compiled but could not be loaded by Core ML.")
    }

    func test_compiledModelLoadFailed_mapsToItsOwnCode() {
        let error = ModelLoadingError.compiledModelLoadFailed(Self.secretURL, Self.secretUnderlying)
        XCTAssertEqual(code(for: error), "app.modelLoadFailed")
        XCTAssertEqual(message(for: error), "The emitted model compiled but could not be loaded by Core ML.")
    }

    func test_unmappedModelLoadingError_keepsTheExistingCatchAll() {
        let error = ModelLoadingError.modelTypeNotDetermined(Self.secretURL)
        XCTAssertEqual(code(for: error), "app.modelValidationOrRegistrationFailed")
    }

    func test_unrelatedError_keepsTheExistingCatchAll() {
        XCTAssertEqual(code(for: Self.secretUnderlying), "app.modelValidationOrRegistrationFailed")
    }

    func test_cancellation_isStillReportedAsCancellation() {
        XCTAssertEqual(code(for: CancellationError()), "cancelled")
    }

    // MARK: The rail itself — no case may carry the file name, the path, or Core ML's wording

    func test_noMappedDiagnosticMessageCarriesTheFilenamePathOrUnderlyingErrorText() {
        let errors: [Error] = [
            ModelLoadingError.insufficientMemory(Self.secretURL, requiredByteCount: 1, availableByteCount: 0),
            ModelLoadingError.compilationFailed(Self.secretURL, Self.secretUnderlying),
            ModelLoadingError.modelLoadFailed(Self.secretURL),
            ModelLoadingError.compiledModelLoadFailed(Self.secretURL, Self.secretUnderlying),
            ModelLoadingError.metadataExtractionFailed(Self.secretURL),
            ModelLoadingError.modelTypeNotDetermined(Self.secretURL),
            Self.secretUnderlying
        ]

        for error in errors {
            let message = message(for: error)
            XCTAssertFalse(message.contains("aia0889-secret-model-name"), "Leaked the file name: \(message)")
            XCTAssertFalse(message.contains("aia0889-secret-path"), "Leaked the path: \(message)")
            XCTAssertFalse(message.contains("aia0889-secret-coreml-wording"), "Leaked Core ML's wording: \(message)")
            XCTAssertFalse(message.contains("/"), "Leaked a path separator: \(message)")
        }
    }

    // MARK: The import alert is a different surface and may name the file, like its siblings

    func test_insufficientMemory_errorDescription_namesTheFileForTheAlert() throws {
        let error = ModelLoadingError.insufficientMemory(
            Self.secretURL,
            requiredByteCount: 600 * 1024 * 1024,
            availableByteCount: 300 * 1024 * 1024
        )
        let description = try XCTUnwrap(error.errorDescription)
        XCTAssertTrue(description.contains(Self.secretFilename))
        XCTAssertTrue(description.contains("600 MB"))
        XCTAssertTrue(description.contains("300 MB"))
        XCTAssertFalse(description.contains("aia0889-secret-path"), "The alert names the file, never the path")
    }

    func test_megabytes_rendersWholeMegabytes() {
        XCTAssertEqual(ModelLoadingError.megabytes(0), "0 MB")
        XCTAssertEqual(ModelLoadingError.megabytes(1024 * 1024), "1 MB")
        XCTAssertEqual(ModelLoadingError.megabytes(199_788_861), "190 MB")
    }

    /// Truncating a real amount to "0 MB" would make a refusal contradict the reason it gives.
    func test_megabytes_neverRendersANonZeroAmountAsZero() {
        XCTAssertEqual(ModelLoadingError.megabytes(1), "less than 1 MB")
        XCTAssertEqual(ModelLoadingError.megabytes(1024 * 1024 - 1), "less than 1 MB")
        XCTAssertEqual(ModelLoadingError.megabytes(0), "0 MB", "An actual zero reading stays zero")
    }
}

// MARK: - The gate is actually wired in (AIA-0889)

/// The pure `decide` tests prove the arithmetic; these prove the arithmetic is *reached*.
/// Without them, deleting the call from `loadAndExtractMetadata` would leave the suite green —
/// and on a simulator the live headroom reads `.unavailable`, so the seam is the only way in.
final class ModelLoadAdmissionWiringTests: XCTestCase {

    private func demoModelURL() throws -> URL {
        try XCTUnwrap(
            Bundle.main.url(forResource: DemoDataManager.DemoModelResource.aiArcheology, withExtension: "mlmodelc"),
            "Bundled demo model is required to exercise the load path"
        )
    }

    func test_enforcedPolicy_withExhaustedHeadroom_refusesBeforeLoading() async throws {
        let url = try demoModelURL()
        let sut = ModelLoadingService(headroom: { .bytes(0) })

        do {
            _ = try await sut.loadAndExtractMetadata(from: url, admission: .enforced)
            XCTFail("A load with no headroom must be refused")
        } catch let error as ModelLoadingError {
            XCTAssertTrue(error.isInsufficientMemory, "Expected a memory refusal, got \(error)")
        }
    }

    /// Bundled demos must load however tight memory is: their seeding is not retryable.
    func test_exemptPolicy_withExhaustedHeadroom_stillLoads() async throws {
        let url = try demoModelURL()
        let sut = ModelLoadingService(headroom: { .bytes(0) })

        let info = try await sut.loadAndExtractMetadata(from: url, admission: .exempt)

        XCTAssertNotEqual(info.task, .invalid)
    }

    func test_enforcedPolicy_withAmpleHeadroom_loads() async throws {
        let url = try demoModelURL()
        let sut = ModelLoadingService(headroom: { .bytes(.max) })

        let info = try await sut.loadAndExtractMetadata(from: url, admission: .enforced)

        XCTAssertNotEqual(info.task, .invalid)
    }

    /// The default entry point — the one the protocol and every existing caller use — must enforce.
    func test_defaultEntryPoint_enforcesTheGate() async throws {
        let url = try demoModelURL()
        let sut = ModelLoadingService(headroom: { .bytes(0) })

        do {
            _ = try await sut.loadAndExtractMetadata(from: url)
            XCTFail("The default entry point must enforce the gate")
        } catch let error as ModelLoadingError {
            XCTAssertTrue(error.isInsufficientMemory)
        }
    }

    /// A refusal must reach the user as its own diagnostic, not the pre-existing catch-all.
    func test_aRefusalSurfacesAsItsOwnDiagnostic() async throws {
        let url = try demoModelURL()
        let sut = ModelLoadingService(headroom: { .bytes(0) })

        do {
            _ = try await sut.loadAndExtractMetadata(from: url)
            XCTFail("Expected a refusal")
        } catch {
            XCTAssertEqual(
                ModelImportView.nativeConversionDiagnostic(for: error).code,
                "app.insufficientMemoryForModelLoad"
            )
        }
    }

    func test_isInsufficientMemory_isFalseForOtherCases() {
        let url = URL(fileURLWithPath: "/tmp/model.mlmodel")
        XCTAssertFalse(ModelLoadingError.modelLoadFailed(url).isInsufficientMemory)
        XCTAssertFalse(ModelLoadingError.modelTypeNotDetermined(url).isInsufficientMemory)
        XCTAssertTrue(
            ModelLoadingError.insufficientMemory(url, requiredByteCount: 1, availableByteCount: 0).isInsufficientMemory
        )
    }
}
