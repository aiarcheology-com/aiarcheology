//
//  DetectionEngineTests.swift
//  MLBrowserUnitTests
//
//  Integration coverage for the detection engine (AIA-0306). The app's central feature is
//  running CoreML/Vision object detection over LiDAR/hillshade terrain imagery, yet the
//  detect path had no test that fed a real image through a real model. These tests load the
//  bundled demo models into a `Detector` and assert the engine produces at least one
//  detection on representative terrain fixtures.
//
//  Assertions are intentionally `>= 1`, never exact boxes or counts: Vision results vary with
//  the active compute unit (CPU / GPU / Neural Engine) across machines and CI runners, so any
//  stricter expectation would be flaky (see AGENTS.md §6 "Cross-platform considerations").
//

import XCTest
import UIKit
@testable import ML_Browser

final class DetectionEngineTests: XCTestCase {

    /// Bundled demo models, by resource name (compiled to `.mlmodelc` in the app bundle).
    /// Both are object-detection models seeded by `DemoDataManager`.
    private static let demoModelResources = ["AIArcheology", "HroudaDetector15"]

    // MARK: - Helpers

    /// Loads a bundled demo model into a ready-to-run `Detector`, or returns nil if the
    /// compiled model is absent from the host bundle (caller turns that into an `XCTSkip`).
    private func makeDetector(modelResource: String) async throws -> Detector? {
        guard let url = Bundle.main.url(forResource: modelResource, withExtension: "mlmodelc") else {
            return nil
        }
        let params = DeepDriverParams(entityId: UUID(), file: url, demo: true)
        let detector = Detector(params: params)
        try await detector.loadFile()
        return detector
    }

    /// Loads a PNG fixture from the test bundle.
    private func fixture(_ name: String) throws -> UIImage {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: name, withExtension: "png"),
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else {
            throw XCTSkip("Fixture \(name).png not available in the test bundle")
        }
        return image
    }

    /// Runs every available demo model over the image with production tiling and returns the
    /// total detection count across models — the "did the engine find anything" signal. Skips
    /// if no demo model is bundled. Per-model counts are printed so a single-model regression
    /// stays visible even while the engine-level assertion still passes.
    private func totalDetections(in image: UIImage) async throws -> Int {
        let regions = TileLayout.regions(tiled: true)
        var total = 0
        var ranAtLeastOneModel = false
        for resource in Self.demoModelResources {
            guard let detector = try await makeDetector(modelResource: resource) else { continue }
            ranAtLeastOneModel = true
            let objects = await detector.detect(image: image, regions: regions)
            await detector.unload()
            let labels = objects.compactMap { $0.primaryLabelIdentifier }
            print("[DetectionEngineTests] \(resource): \(objects.count) detections; labels=\(labels)")
            total += objects.count
        }
        guard ranAtLeastOneModel else {
            throw XCTSkip("No demo models available in the host bundle")
        }
        return total
    }

    // MARK: - Tests

    func testDemoModels_detectAtLeastOneObject_iPhoneTerrain() async throws {
        let image = try fixture("terrain_iphone")
        let count = try await totalDetections(in: image)
        XCTAssertGreaterThan(count, 0, "Demo detection engine found nothing on the iPhone terrain fixture")
    }

    func testDemoModels_detectAtLeastOneObject_iPadTerrain() async throws {
        let image = try fixture("terrain_ipad")
        let count = try await totalDetections(in: image)
        XCTAssertGreaterThan(count, 0, "Demo detection engine found nothing on the iPad terrain fixture")
    }
}
