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

@MainActor
private final class HeldSnapshotRenderer: SnapshotRendering {
    private var continuations: [CheckedContinuation<UIImage?, Never>] = []
    private(set) var snapshotCallCount = 0

    func snapshot() async -> UIImage? {
        snapshotCallCount += 1
        return await withCheckedContinuation { continuations.append($0) }
    }

    func completeNext(with image: UIImage?) {
        precondition(continuations.isEmpty.not, "No held snapshot to complete")
        continuations.removeFirst().resume(returning: image)
    }
}

@MainActor
private final class SnapshotRequestGate {
    var activeRunID: UInt64?

    init(activeRunID: UInt64?) {
        self.activeRunID = activeRunID
    }

    func accepts(_ request: SnapshotRequest) -> Bool {
        request.runID == activeRunID
    }
}

@MainActor
final class SnapshotWorkCoordinatorTests: XCTestCase {

    func testInitialRequest_WaitsForAttachedRendererAndConsumer() async {
        let renderer = HeldSnapshotRenderer()
        let sut = SnapshotWorkCoordinator(renderer: renderer)
        let request = SnapshotRequest(runID: 7, sequence: 1)
        var delivered: [SnapshotRequest] = []

        sut.enqueue(request)
        XCTAssertEqual(renderer.snapshotCallCount, 0, "A start request must survive until WebKit attaches")

        sut.rendererDidAttach()
        await Task.yield()
        XCTAssertEqual(renderer.snapshotCallCount, 0, "A request must also wait for a live SwiftUI consumer")

        sut.registerConsumer(
            id: UUID(),
            frame: .zero,
            acceptsRequest: { _ in true }
        ) { _, _, deliveredRequest in
            delivered.append(deliveredRequest)
        }
        await waitForSnapshotCall(renderer, count: 1)

        renderer.completeNext(with: UIImage())
        await waitForDeliveries(count: 1) { delivered }

        XCTAssertEqual(delivered, [request])
    }

    func testReplacementAndRestart_HoldOnePhysicalSnapshotUntilOldContinuationReturns() async {
        let renderer = HeldSnapshotRenderer()
        let sut = SnapshotWorkCoordinator(renderer: renderer)
        let firstConsumer = UUID()
        let replacementConsumer = UUID()
        let firstRun = SnapshotRequest(runID: 1, sequence: 1)
        let restartedRun = SnapshotRequest(runID: 3, sequence: 2)
        var firstConsumerDeliveries = 0
        var replacementDeliveries: [SnapshotRequest] = []

        sut.rendererDidAttach()
        sut.registerConsumer(
            id: firstConsumer,
            frame: .zero,
            acceptsRequest: { _ in true }
        ) { _, _, _ in
            firstConsumerDeliveries += 1
        }
        sut.enqueue(firstRun)
        await waitForSnapshotCall(renderer, count: 1)

        // A pause/restart plus a SwiftUI replacement can happen before WebKit completes the
        // original capture. The newest request wins, but it must wait for that continuation.
        sut.enqueue(restartedRun)
        sut.unregisterConsumer(id: firstConsumer)
        sut.registerConsumer(
            id: replacementConsumer,
            frame: .zero,
            acceptsRequest: { _ in true }
        ) { _, _, request in
            replacementDeliveries.append(request)
        }
        XCTAssertEqual(renderer.snapshotCallCount, 1, "Never overlap WKWebView.takeSnapshot calls")

        renderer.completeNext(with: UIImage())
        await waitForSnapshotCall(renderer, count: 2)
        XCTAssertEqual(firstConsumerDeliveries, 0)
        XCTAssertTrue(replacementDeliveries.isEmpty, "Old-run completion belongs to the departed consumer")

        renderer.completeNext(with: UIImage())
        await waitForDeliveries(count: 1) { replacementDeliveries }

        XCTAssertEqual(replacementDeliveries, [restartedRun])
    }

    func testRendererReattachment_DiscardsOldPageSnapshotAndReplaysLatestRequest() async {
        let renderer = HeldSnapshotRenderer()
        let sut = SnapshotWorkCoordinator(renderer: renderer)
        let request = SnapshotRequest(runID: 1, sequence: 1)
        var deliveries: [SnapshotRequest] = []

        sut.rendererDidAttach()
        sut.registerConsumer(
            id: UUID(),
            frame: .zero,
            acceptsRequest: { _ in true }
        ) { _, _, deliveredRequest in
            deliveries.append(deliveredRequest)
        }
        sut.enqueue(request)
        await waitForSnapshotCall(renderer, count: 1)

        // A recovered WebView replaces the renderer while the old page's capture is still in
        // flight. The old image must not be delivered to the current consumer.
        sut.rendererDidAttach()
        renderer.completeNext(with: UIImage())
        await waitForSnapshotCall(renderer, count: 2)
        XCTAssertTrue(deliveries.isEmpty)

        renderer.completeNext(with: UIImage())
        await waitForDeliveries(count: 1) { deliveries }

        XCTAssertEqual(deliveries, [request])
    }

    func testFindingCapture_DiscardsInFlightSnapshotUntilDetectionResumes() async {
        let renderer = HeldSnapshotRenderer()
        let sut = SnapshotWorkCoordinator(renderer: renderer)
        let requestBeforeCapture = SnapshotRequest(runID: 1, sequence: 1)
        let requestAfterCapture = SnapshotRequest(runID: 1, sequence: 2)
        var deliveries: [SnapshotRequest] = []

        sut.rendererDidAttach()
        sut.registerConsumer(
            id: UUID(),
            frame: .zero,
            acceptsRequest: { _ in true }
        ) { _, _, deliveredRequest in
            deliveries.append(deliveredRequest)
        }
        sut.enqueue(requestBeforeCapture)
        await waitForSnapshotCall(renderer, count: 1)

        sut.findingCaptureStarted()
        sut.enqueue(requestAfterCapture)
        renderer.completeNext(with: UIImage())
        await Task.yield()
        XCTAssertTrue(deliveries.isEmpty, "A pre-freeze snapshot must not replace the frozen frame")
        XCTAssertEqual(renderer.snapshotCallCount, 1, "Capture holds later requests until detection resumes")

        sut.findingCaptureEnded()
        sut.enqueue(requestAfterCapture)
        await waitForSnapshotCall(renderer, count: 2)
        renderer.completeNext(with: UIImage())
        await waitForDeliveries(count: 1) { deliveries }

        XCTAssertEqual(deliveries, [requestAfterCapture])
    }

    func testStoppedRun_DiscardsRetainedRequestBeforeRendererWorkStarts() async {
        let renderer = HeldSnapshotRenderer()
        let sut = SnapshotWorkCoordinator(renderer: renderer)
        let staleRequest = SnapshotRequest(runID: 1, sequence: 1)
        let requestGate = SnapshotRequestGate(activeRunID: staleRequest.runID)
        var deliveries: [SnapshotRequest] = []

        sut.registerConsumer(
            id: UUID(),
            frame: .zero,
            acceptsRequest: { requestGate.accepts($0) }
        ) { _, _, deliveredRequest in
            deliveries.append(deliveredRequest)
        }
        sut.enqueue(staleRequest)
        XCTAssertEqual(renderer.snapshotCallCount, 0, "The request waits while WebKit is detached")

        requestGate.activeRunID = nil
        sut.rendererDidAttach()
        await Task.yield()

        XCTAssertEqual(renderer.snapshotCallCount, 0, "A stopped run must not start retained work")
        XCTAssertTrue(deliveries.isEmpty)
    }

    private func waitForSnapshotCall(
        _ renderer: HeldSnapshotRenderer,
        count: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<20 where renderer.snapshotCallCount < count {
            await Task.yield()
        }
        XCTAssertEqual(renderer.snapshotCallCount, count, file: file, line: line)
    }

    private func waitForDeliveries(
        count: Int,
        deliveries: () -> [SnapshotRequest],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<20 where deliveries().count < count {
            await Task.yield()
        }
        XCTAssertEqual(deliveries().count, count, file: file, line: line)
    }
}
