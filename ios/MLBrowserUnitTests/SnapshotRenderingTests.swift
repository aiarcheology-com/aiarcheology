//
//  SnapshotRenderingTests.swift
//  MLBrowserUnitTests
//
//  Proves the AIA-0389 acceptance criteria at the port boundary:
//  (AC1) a `SnapshotRendering` fake conforms WITHOUT subclassing any renderer, and
//  (AC2) it is usable OFF the main actor in tests/CI. This test class is deliberately NOT
//  `@MainActor`: `await sut.snapshot()` runs off-main, which is only legal because
//  `SnapshotRendering` is a nonisolated protocol (the real `@MainActor WebSnapshotRenderer`
//  witnesses the async requirement via an absorbed hop; the fake witnesses it nonisolated).
//  The WKWebView-backed implementation itself is exercised by the UI suite — `takeSnapshot`
//  needs a live web view, so it is not unit-testable here.
//

import XCTest
import UIKit
@testable import ML_Browser

/// Minimal `SnapshotRendering` double — a plain conformer, no renderer subclassing (AC1). No
/// mutable state, so it stays trivially usable in the nonisolated test context (AC2).
private final class FakeSnapshotRenderer: SnapshotRendering {
    private let cannedImage: UIImage?

    init(cannedImage: UIImage?) {
        self.cannedImage = cannedImage
    }

    func snapshot() async -> UIImage? {
        cannedImage
    }
}

final class SnapshotRenderingTests: XCTestCase {

    /// AC1 + AC2: a non-subclass fake is swappable behind the port and returns its canned image
    /// when awaited off the main actor.
    func testFake_snapshot_returnsCannedImage_offMainActor() async {
        let image = UIImage()
        let sut: SnapshotRendering = FakeSnapshotRenderer(cannedImage: image)

        let result = await sut.snapshot()

        XCTAssertIdentical(result, image)
    }

    /// A failed snapshot surfaces as `nil` — the contract callers branch on.
    func testFake_snapshot_nilCanned_returnsNil() async {
        let sut: SnapshotRendering = FakeSnapshotRenderer(cannedImage: nil)

        let result = await sut.snapshot()

        XCTAssertNil(result)
    }
}
