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
@testable import ML_Browser

final class DetectionEngineTests: XCTestCase {

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
        let detector = Detector(params: DeepDriverParams(entityId: UUID(), file: url, demo: true))
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
        let regions = TileLayout.regions(tiled: true)

        for resource in Self.demoModelResources {
            let detector = try await makeDetector(modelResource: resource)
            var perFixture: [Int] = []
            for image in images {
                perFixture.append(await detector.detect(image: image, regions: regions).count)
            }
            await detector.unload()

            let total = perFixture.reduce(0, +)
            XCTAssertGreaterThan(
                total, 0,
                "Demo model \(resource) produced no detections on any terrain fixture (per-fixture: \(perFixture))"
            )
        }
    }
}
