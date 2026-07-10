//
//  DetectionCoordinatorTests.swift
//  AI ArcheologyTests
//
//  Created by Agent on 2026-07-10.
//

import XCTest
import UIKit
@testable import ML_Browser

// MARK: - DetectionCoordinator tests

/// Regression guard for the detection state machine extracted in AIA-0386. Drives the LIVE
/// apply path: the injected `detect` suspends on a continuation the test resumes, so state can be
/// mutated mid-flight (between the pass starting and its result applying) to prove the apply-time
/// generation / interaction / capture guards read live and discard correctly.
@MainActor
final class DetectionCoordinatorTests: XCTestCase {

	/// Stored so the test resumes the in-flight detect deterministically.
	private var continuation: CheckedContinuation<[DetectionResult], Never>?
	/// Live apply-time guard state, bound via `bindGuards` and read at apply time.
	private var interacting = false
	private var capturing = false
	/// Every write mirrored to `onFrameChanged`, in order (nil applies included).
	private var frameChanges: [AppliedDetectionFrame?] = []

	// MARK: Helpers

	private func makeCoordinator() -> DetectionCoordinator {
		let coordinator = DetectionCoordinator(
			detect: { [weak self] _, _ in
				await withCheckedContinuation { cont in
					self?.continuation = cont
				}
			},
			onFrameChanged: { [weak self] frame in
				self?.frameChanges.append(frame)
			}
		)
		coordinator.bindGuards(
			isInteracting: { [weak self] in self?.interacting ?? false },
			isCapturing: { [weak self] in self?.capturing ?? false }
		)
		return coordinator
	}

	private func cannedResult() -> DetectionResult {
		(observations: [], params: DeepDriverParams(entityId: UUID()))
	}

	/// Yield the main actor until the in-flight pass has reached the detect suspension point (the
	/// injected detect stores its continuation before suspending).
	private func awaitDetectSuspended() async {
		while continuation == nil { await Task.yield() }
	}

	private func resumeDetect(with results: [DetectionResult]) {
		let cont = continuation!
		continuation = nil
		cont.resume(returning: results)
	}

	/// The resumed detection task runs its apply-or-discard synchronously (no awaits after the
	/// continuation resumes), so draining the main-actor queue lets it finish before we assert.
	private func settle() async {
		await Task.yield()
		await Task.yield()
	}

	/// Runs one full happy-path apply and returns the snapshot that was applied.
	@discardableResult
	private func applyFrame(_ coordinator: DetectionCoordinator, results: [DetectionResult]) async -> UIImage {
		let snapshot = UIImage()
		coordinator.ingest(snapshot: snapshot)
		await awaitDetectSuspended()
		resumeDetect(with: results)
		await settle()
		return snapshot
	}

	// MARK: Tests

	func testHappyPath_appliesFrameAndMirrors() async {
		let coordinator = makeCoordinator()
		let snapshot = await applyFrame(coordinator, results: [cannedResult()])

		let applied = coordinator.appliedFrame
		XCTAssertNotNil(applied)
		XCTAssertEqual(applied?.results.count, 1)
		XCTAssertTrue(applied?.image === snapshot)
		// The mirror fired exactly once, with the same applied frame.
		XCTAssertEqual(frameChanges.count, 1)
		XCTAssertTrue(frameChanges.first??.image === snapshot)
		XCTAssertEqual(frameChanges.first??.results.count, 1)
	}

	func testLiveInteractionGuard_discards() async {
		let coordinator = makeCoordinator()
		coordinator.ingest(snapshot: UIImage())
		await awaitDetectSuspended()
		// Flip the LIVE guard var only — do NOT call setInteracting — so the apply-time read alone
		// must discard the result.
		interacting = true
		resumeDetect(with: [cannedResult()])
		await settle()

		XCTAssertNil(coordinator.appliedFrame)
	}

	func testLiveCaptureGuard_discards() async {
		let coordinator = makeCoordinator()
		coordinator.ingest(snapshot: UIImage())
		await awaitDetectSuspended()
		capturing = true
		resumeDetect(with: [cannedResult()])
		await settle()

		XCTAssertNil(coordinator.appliedFrame)
	}

	func testStaleGeneration_discards() async {
		let coordinator = makeCoordinator()
		coordinator.ingest(snapshot: UIImage())
		await awaitDetectSuspended()
		// Geometry changed after the pass began: its generation is now stale, result must not apply.
		coordinator.geometryChanged()
		resumeDetect(with: [cannedResult()])
		await settle()

		XCTAssertNil(coordinator.appliedFrame)
	}

	func testGeometryChange_clearsAppliedFrame() async {
		let coordinator = makeCoordinator()
		await applyFrame(coordinator, results: [cannedResult()])
		XCTAssertNotNil(coordinator.appliedFrame)

		coordinator.geometryChanged()
		XCTAssertNil(coordinator.appliedFrame)
	}

	func testSetCapturing_freezesWithoutClearing() async {
		let coordinator = makeCoordinator()
		let snapshot = await applyFrame(coordinator, results: [cannedResult()])
		XCTAssertNotNil(coordinator.appliedFrame)

		coordinator.setCapturing(true)
		// Capture freezes the displayed frame — it must NOT be cleared.
		XCTAssertNotNil(coordinator.appliedFrame)
		XCTAssertTrue(coordinator.appliedFrame?.image === snapshot)
	}
}
