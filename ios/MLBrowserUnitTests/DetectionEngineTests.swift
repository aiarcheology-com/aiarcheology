//
//  DetectionEngineTests.swift
//  MLBrowserUnitTests
//
//  Integration coverage for the detection engine (AIA-0306). The app's central feature is
//  running CoreML/Vision object detection over LiDAR/hillshade terrain imagery, yet the
//  detect path had no test that fed a real image through a real model. These tests load each
//  bundled demo model into a `Detector` and assert it produces detections on representative
//  terrain fixtures.
//
//  Assertions are `>= 1` per model (summed across the fixtures), never exact boxes or counts:
//  Vision results vary with the active compute unit across machines/CI runners (see AGENTS.md
//  §6). The simulator has no Neural Engine, so detection runs on the host CPU/GPU; `>= 1` is
//  the stable floor. Per-model (not a single summed total) so one model regressing to zero is
//  caught even when the other still detects.
//

import XCTest
import UIKit
import Vision
import CoreML
import NativeModelConverter
@testable import ML_Browser

@MainActor
final class DetectionEngineTests: XCTestCase {

    private final class IncrementalUpdateRecorder {
        var count = 0
    }

    /// Bundled demo models, by resource name (compiled to `.mlmodelc` in the app bundle).
    /// Mirrors the set seeded by `DemoDataManager`; keep in sync if a demo model is added.
    private static let demoModelResources = ["AIArcheology", "HroudaDetector15"]

    /// Bundled terrain fixtures (iPhone + iPad hillshade screenshots).
    private static let fixtures = ["terrain_iphone", "terrain_ipad"]

    // MARK: - Helpers

    /// Loads a bundled demo model into a ready-to-run `Detector`. A missing model is a build
    /// integrity failure (the models are committed app resources), not a skippable condition.
    private func makeDetector(modelResource: String) async throws -> Detector {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: modelResource, withExtension: "mlmodelc"),
            "Demo model \(modelResource).mlmodelc is missing from the app bundle"
        )
        let detector = Detector(params: DeepDriverParams(entityId: UUID(), modelName: "Test Model", file: url))
        try await detector.loadFile()
        return detector
    }

    /// Loads a PNG fixture from the test bundle. A missing fixture is a build integrity failure.
    private func fixture(_ name: String) throws -> UIImage {
        let bundle = Bundle(for: type(of: self))
        let url = try XCTUnwrap(
            bundle.url(forResource: name, withExtension: "png"),
            "Fixture \(name).png is missing from the test bundle"
        )
        let data = try XCTUnwrap(try? Data(contentsOf: url), "Could not read \(name).png")
        return try XCTUnwrap(UIImage(data: data), "Could not decode \(name).png")
    }

    // MARK: - Tests

    /// Each bundled demo model must detect at least one object across the terrain fixtures,
    /// using the same tiled regions as production. Per-model (not summed) so a single model
    /// regressing to zero is caught even if the other still detects.
    func testEachDemoModel_detectsOnTerrain() async throws {
        // Load fixtures up front so nothing throws between a detector's load and its unload.
        let images = try Self.fixtures.map { try fixture($0) }
        let regions = TileLayout.regions(for: .pyramid)

        for resource in Self.demoModelResources {
            let detector = try await makeDetector(modelResource: resource)
            var perFixture: [Int] = []
            for image in images {
                let incrementalUpdates = IncrementalUpdateRecorder()
                let objects = await detector.detect(
                    image: image,
                    regions: regions,
                    onPartialResult: { _ in incrementalUpdates.count += 1 }
                )
                XCTAssertGreaterThan(
                    incrementalUpdates.count,
                    0,
                    "Demo model \(resource) did not publish a completed pyramid tile"
                )
                XCTAssertLessThanOrEqual(
                    incrementalUpdates.count,
                    regions.count,
                    "Demo model \(resource) published more updates than pyramid tiles"
                )
                perFixture.append(objects.count)
            }
            await detector.unload()

            let total = perFixture.reduce(0, +)
            XCTAssertGreaterThan(
                total, 0,
                "Demo model \(resource) produced no detections on any terrain fixture (per-fixture: \(perFixture))"
            )
        }
    }

    /// ``DetectionEngine.detect`` must invoke the partial-result callback when an incremental
    /// detector publishes tiles (AIA-0944).
    func testDetectionEngine_Detect_InvokesPartialResultCallback() async {
        let stub = StubIncrementalDetecting(
            params: DeepDriverParams(entityId: UUID(), modelName: "Test Model"),
            objects: [DetectedObject(
                uuid: UUID(),
                labels: [DetectedObject.Label(identifier: "stub-object", confidence: 0.9)],
                confidence: 0.9,
                boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
                regionIndex: 0
            )]
        )
        let recorder = IncrementalUpdateRecorder()
        let results = await DetectionEngine().detect(
            on: UIImage(),
            in: [stub],
            tiling: [],
            onPartialResults: { _ in recorder.count += 1 }
        )
        XCTAssertEqual(results.count, 1)
        XCTAssertGreaterThan(recorder.count, 0, "DetectionEngine.detect must publish partial results")
    }

    /// ``Detector.detectPreSized`` is called directly with a contract matching the demo model's
    /// canvas. A missing model fails the test rather than skipping (AIA-0944).
    func testDetectPreSized_InvokesPartialCallback() async throws {
        let modelURL = try XCTUnwrap(
            Bundle.main.url(forResource: "AIArcheology", withExtension: "mlmodelc"),
            "Demo model AIArcheology.mlmodelc is missing from the app bundle — fetch fixtures / build with AIA_INCLUDE_TEST_FIXTURES=YES"
        )
        let loadedModel = try await Detector.loadModel(from: modelURL)
        let mlModel = try XCTUnwrap(
            loadedModel,
            "Demo model AIArcheology.mlmodelc failed to load"
        )
        let imageConstraint = try XCTUnwrap(
            mlModel.modelDescription.inputDescriptionsByName.values.compactMap(\.imageConstraint).first,
            "Demo detector must declare an image input"
        )
        let canvas = NativeModelImageSize(
            width: imageConstraint.pixelsWide,
            height: imageConstraint.pixelsHigh
        )
        let maxEdge = min(canvas.width, canvas.height)
        let contract = NativeModelImageSizingContract(
            minSize: maxEdge,
            maxSize: maxEdge,
            canvas: canvas
        )
        let detector = Detector(params: DeepDriverParams(
            entityId: UUID(), modelName: "Pre-sized path", file: modelURL
        ))
        let image = try fixture("terrain_iphone")
        let recorder = IncrementalUpdateRecorder()
        _ = try await detector.detectPreSized(
            image: image,
            regions: [TileLayout.fullFrame],
            contract: contract,
            modelURL: modelURL,
            onPartialResult: { _ in recorder.count += 1 }
        )
        XCTAssertGreaterThan(
            recorder.count, 0,
            "detectPreSized must publish a partial result for the full-frame region"
        )
    }
}

// MARK: - Detecting stub (AIA-0387)

/// Minimal `Detecting` conformer that records whether the engine actually dispatched to it,
/// so cancellation-before-dispatch can be asserted. Returns the injected objects — mirrors
/// the conformance style of `StubClassifying` in DeepDriversTests.swift.
private actor StubDetecting: Detecting {
    let id: UUID
    var params: DeepDriverParams
    var observations: [VNObservation] = []
    private(set) var didRun = false
    /// The number of regions the engine dispatched — lets tests assert the tiling scheme
    /// reached the detector (AIA-0426).
    private(set) var receivedRegionCount = 0
    private let objects: [DetectedObject]

    init(params: DeepDriverParams, objects: [DetectedObject]) {
        self.id = params.entityId
        self.params = params
        self.objects = objects
    }

    func detect(image: UIImage, regions: [CGRect]) async -> [DetectedObject] {
        didRun = true
        receivedRegionCount = regions.count
        return objects
    }
    func metadata() -> [MLModelMetadataKey: Any]? { nil }
    func updateConfiguration(_ params: DeepDriverParams) async { self.params = params }
    func process(image: UIImage) async {}
    func loadFile() async throws {}
    func run() async {}
    func unload() async {}
}

/// Incremental counterpart so ``DetectionEngine.detect`` exercises its partial-result branch.
private actor StubIncrementalDetecting: IncrementalDetecting {
    let id: UUID
    var params: DeepDriverParams
    var observations: [VNObservation] = []
    private let objects: [DetectedObject]

    init(params: DeepDriverParams, objects: [DetectedObject]) {
        self.id = params.entityId
        self.params = params
        self.objects = objects
    }

    func detect(image: UIImage, regions: [CGRect]) async -> [DetectedObject] {
        await detect(image: image, regions: regions, onPartialResult: { _ in })
    }

    func detect(
        image: UIImage,
        regions: [CGRect],
        onPartialResult: @escaping @MainActor @Sendable ([DetectedObject]) -> Void
    ) async -> [DetectedObject] {
        await onPartialResult(objects)
        return objects
    }

    func metadata() -> [MLModelMetadataKey: Any]? { nil }
    func updateConfiguration(_ params: DeepDriverParams) async { self.params = params }
    func process(image: UIImage) async {}
    func loadFile() async throws {}
    func run() async {}
    func unload() async {}
}

/// Minimal `Classifying` conformer that records whether the engine dispatched to it —
/// the classify counterpart of `StubDetecting`.
private actor StubClassifyingRecording: Classifying {
    let id: UUID
    var params: DeepDriverParams
    var observations: [VNObservation] = []
    private(set) var didRun = false
    private let labels: [ClassifiedLabel]

    init(params: DeepDriverParams, labels: [ClassifiedLabel]) {
        self.id = params.entityId
        self.params = params
        self.labels = labels
    }

    func classify(image: UIImage) async -> [ClassifiedLabel] {
        didRun = true
        return labels
    }
    func metadata() -> [MLModelMetadataKey: Any]? { nil }
    func updateConfiguration(_ params: DeepDriverParams) async { self.params = params }
    func process(image: UIImage) async {}
    func loadFile() async throws {}
    func run() async {}
    func unload() async {}
}

// MARK: - Cancellation (AIA-0387)

@MainActor
final class DetectionEngineCancellationTests: XCTestCase {

    /// A pass cancelled before it starts must dispatch no driver. The class is `@MainActor`
    /// on purpose: the spawned `Task` inherits the main actor and cannot begin until this
    /// method suspends at `await task.value`, so the synchronous `cancel()` lands first. By
    /// the time the engine loop reaches its opening `Task.isCancelled` check it is already
    /// cancelled — it breaks before touching the stub, making the outcome deterministic. A
    /// nonisolated test would race the loop against `cancel()` and flake.
    func testDetect_CancelledBeforeStart_SkipsDrivers() async {
        let engine = DetectionEngine()
        let stub = StubDetecting(
            params: DeepDriverParams(entityId: UUID(), modelName: "Test Model"),
            objects: [DetectedObject(
                uuid: UUID(),
                labels: [DetectedObject.Label(identifier: "stub-object", confidence: 0.9)],
                confidence: 0.9,
                boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
                regionIndex: 0
            )]
        )

        let task = Task { await engine.detect(on: UIImage(), in: [stub], tiling: []) }
        task.cancel()
        let results = await task.value

        XCTAssertTrue(results.isEmpty)
        let didRun = await stub.didRun
        XCTAssertFalse(didRun)
    }

    func testDetect_NoDetectors_ReturnsEmpty() async {
        let results = await DetectionEngine().detect(on: UIImage(), in: [], tiling: [])

        XCTAssertTrue(results.isEmpty)
    }

    /// The enabled scheme's regions actually reach the detector: pyramid=6, 3x3=10, union=15,
    /// empty=1 (full frame). Guards the whole Settings→engine wiring, not just that it compiles.
    func testDetect_DispatchesSchemeRegionsToDetector() async {
        let cases: [(TilingScheme, Int)] = [([], 1), (.pyramid, 6), (.grid3x3, 10), ([.pyramid, .grid3x3], 15)]
        for (scheme, expected) in cases {
            let stub = StubDetecting(
                params: DeepDriverParams(entityId: UUID(), modelName: "Test Model"),
                objects: [DetectedObject(
                    uuid: UUID(),
                    labels: [DetectedObject.Label(identifier: "stub-object", confidence: 0.9)],
                    confidence: 0.9,
                    boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
                    regionIndex: 0
                )]
            )
            _ = await DetectionEngine().detect(on: UIImage(), in: [stub], tiling: scheme)
            let count = await stub.receivedRegionCount
            XCTAssertEqual(count, expected, "scheme rawValue \(scheme.rawValue) should dispatch \(expected) regions")
        }
    }

    /// Classify counterpart of the detect cancellation test — same deterministic @MainActor
    /// setup, exercising the `Task.isCancelled` guard on the classify loop.
    func testClassify_CancelledBeforeStart_SkipsDrivers() async {
        let engine = DetectionEngine()
        let stub = StubClassifyingRecording(
            params: DeepDriverParams(entityId: UUID(), modelName: "Test Model"),
            labels: [ClassifiedLabel(identifier: "stub-label", confidence: 0.9)]
        )

        let task = Task { await engine.classify(on: UIImage(), in: [stub]) }
        task.cancel()
        let results = await task.value

        XCTAssertTrue(results.isEmpty)
        let didRun = await stub.didRun
        XCTAssertFalse(didRun)
    }
}
