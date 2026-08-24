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
	private var appliedResultEvents: [(UInt64, [DetectionResult])] = []

	// MARK: Helpers

	private func makeCoordinator() -> DetectionCoordinator {
		let coordinator = DetectionCoordinator(
			detect: { [weak self] _, _, _ in
				await withCheckedContinuation { cont in
					self?.continuation = cont
				}
			},
			onFrameChanged: { [weak self] frame in
				self?.frameChanges.append(frame)
			},
			onAppliedResults: { [weak self] passID, results in
				self?.appliedResultEvents.append((passID, results))
			}
		)
		coordinator.bindGuards(
			isInteracting: { [weak self] in self?.interacting ?? false },
			isCapturing: { [weak self] in self?.capturing ?? false }
		)
		return coordinator
	}

	private func cannedResult() -> DetectionResult {
		(observations: [], params: DeepDriverParams(entityId: UUID(), modelName: "Test Model"))
	}

	/// Yield the main actor until the in-flight pass has reached the detect suspension point (the
	/// injected detect stores its continuation before suspending). Bounded so a broken seam fails
	/// fast and clearly instead of spinning until the xcodebuild test timeout.
	private func awaitDetectSuspended(timeout: TimeInterval = 2) async {
		let deadline = Date().addingTimeInterval(timeout)
		while continuation == nil {
			if Date() > deadline {
				XCTFail("detect was not invoked before the timeout")
				return
			}
			await Task.yield()
		}
	}

	private func resumeDetect(with results: [DetectionResult]) {
		guard let cont = continuation else {
			XCTFail("resumeDetect called with no suspended detect pass")
			return
		}
		continuation = nil
		cont.resume(returning: results)
	}

	/// Yields the main actor until `condition` holds, bounded like ``awaitDetectSuspended(timeout:)``
	/// so a broken seam fails fast and readably.
	///
	/// Replaces a pair of bare `Task.yield()` calls whose comment claimed the resumed pass "runs its
	/// apply-or-discard synchronously … so draining the main-actor queue lets it finish". `Task
	/// yield()` offers a suspension point; it does not drain a queue, and under parallel test load
	/// two of them were not reliably enough — which is how this file produced an intermittent
	/// failure that never reproduced when the test was run on its own.
	private func settle(
		until condition: () -> Bool,
		_ message: @autoclosure () -> String,
		timeout: TimeInterval = 2,
		file: StaticString = #filePath,
		line: UInt = #line
	) async {
		let deadline = Date().addingTimeInterval(timeout)
		while condition() == false {
			if Date() > deadline {
				XCTFail(message(), file: file, line: line)
				return
			}
			await Task.yield()
		}
	}

	/// For the discard paths, where success is the *absence* of a frame change.
	///
	/// Deliberately a separate name rather than a defaulted argument on ``settle(until:_:timeout:)``,
	/// because it is genuinely weaker and should not be mistaken for it: with nothing positive to
	/// wait for, a pass that has not run yet is indistinguishable from one that ran and correctly
	/// discarded. Its failure mode is a false pass, never a flake, so the yields are simply generous
	/// enough that the resumed pass has run in practice.
	private func settleForDiscard() async {
		for _ in 0..<20 { await Task.yield() }
	}

	/// Runs one full happy-path apply and returns the snapshot that was applied.
	@discardableResult
	private func applyFrame(_ coordinator: DetectionCoordinator, results: [DetectionResult]) async -> UIImage {
		let snapshot = UIImage()
		coordinator.ingest(snapshot: snapshot)
		await awaitDetectSuspended()
		resumeDetect(with: results)
		await settle(
			until: { coordinator.appliedFrame != nil },
			"the resumed pass never applied a frame"
		)
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

	func testIncrementalResult_appliesBeforePassCompletesAndFinalResultReplacesIt() async {
		let partial = cannedResult()
		let final = cannedResult()
		let coordinator = DetectionCoordinator(
			detect: { [weak self] _, _, publish in
				publish([partial])
				return await withCheckedContinuation { cont in
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

		coordinator.ingest(snapshot: UIImage())
		await settle(
			until: { coordinator.appliedFrame?.results.first?.params.entityId == partial.params.entityId },
			"the incremental result was not applied before detection completed"
		)
		XCTAssertNotNil(continuation, "the pass should remain in flight after its incremental result")

		resumeDetect(with: [final])
		await settle(
			until: { coordinator.appliedFrame?.results.first?.params.entityId == final.params.entityId },
			"the final result did not replace the incremental result"
		)
		XCTAssertEqual(frameChanges.count, 2)
	}

	func testAppliedResults_UsesOnePassIDForPartialAndFinalButRefreshNeverReplays() async {
		let partial = cannedResult()
		let final = cannedResult()
		let coordinator = DetectionCoordinator(
			detect: { [weak self] _, _, publish in
				publish([partial])
				return await withCheckedContinuation { cont in self?.continuation = cont }
			},
			onAppliedResults: { [weak self] passID, results in
				self?.appliedResultEvents.append((passID, results))
			}
		)
		coordinator.bindGuards(isInteracting: { false }, isCapturing: { false })

		coordinator.ingest(snapshot: UIImage())
		await settle(until: { self.appliedResultEvents.count == 1 }, "partial result did not apply")
		resumeDetect(with: [final])
		await settle(until: { self.appliedResultEvents.count == 2 }, "final result did not apply")
		let idsBeforeRefresh = appliedResultEvents.map(\.0)

		coordinator.refreshPresentation()
		XCTAssertEqual(appliedResultEvents.map(\.0), idsBeforeRefresh)
		XCTAssertEqual(Set(idsBeforeRefresh).count, 1, "partial/final writes identify one snapshot pass")
	}

	func testLiveInteractionGuard_discards() async {
		let coordinator = makeCoordinator()
		coordinator.ingest(snapshot: UIImage())
		await awaitDetectSuspended()
		// Flip the LIVE guard var only — do NOT call setInteracting — so the apply-time read alone
		// must discard the result.
		interacting = true
		resumeDetect(with: [cannedResult()])
		await settleForDiscard()

		XCTAssertNil(coordinator.appliedFrame)
	}

	func testLiveCaptureGuard_discards() async {
		let coordinator = makeCoordinator()
		coordinator.ingest(snapshot: UIImage())
		await awaitDetectSuspended()
		capturing = true
		resumeDetect(with: [cannedResult()])
		await settleForDiscard()

		XCTAssertNil(coordinator.appliedFrame)
	}

	func testStaleGeneration_discards() async {
		let coordinator = makeCoordinator()
		coordinator.ingest(snapshot: UIImage())
		await awaitDetectSuspended()
		// Geometry changed after the pass began: its generation is now stale, result must not apply.
		coordinator.geometryChanged()
		resumeDetect(with: [cannedResult()])
		await settleForDiscard()

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

// MARK: - Annotation sound event tests (AIA-0716)

@MainActor
final class AnnotationSoundEventCoordinatorTests: XCTestCase {
	private actor RecordingPlayer: AnnotationSoundPlaying {
		private var requests: [AnnotationSoundPlaybackRequest] = []

		func play(_ request: AnnotationSoundPlaybackRequest) async {
			requests.append(request)
		}

		func recordedRequests() -> [AnnotationSoundPlaybackRequest] { requests }
	}

	private func detection(
		id: UUID = UUID(),
		sound: AnnotationSound = .chime,
		enabled: Bool = true,
		observationIDs: [UUID] = [UUID()]
	) -> DetectionResult {
		let observations = observationIDs.map { observationID in
			DetectedObject(
				uuid: observationID,
				labels: [DetectedObject.Label(identifier: "artifact", confidence: 0.9)],
				confidence: 0.9,
				boundingBox: .zero,
				regionIndex: 0
			)
		}
		return (
			observations: observations,
			params: DeepDriverParams(
				entityId: id,
				modelName: "Model",
				annotationSound: .init(isEnabled: enabled, sound: sound, volume: 0.4)
			)
		)
	}

	private func classification(
		id: UUID = UUID(),
		sound: AnnotationSound = .chime,
		enabled: Bool = true
	) -> ClassificationResult {
		(
			labels: [ClassifiedLabel(identifier: "artifact", confidence: 0.9)],
			params: DeepDriverParams(
				entityId: id,
				modelName: "Model",
				annotationSound: .init(isEnabled: enabled, sound: sound, volume: 0.4)
			)
		)
	}

	private func settle(_ player: RecordingPlayer, count: Int) async {
		for _ in 0..<50 {
			if await player.recordedRequests().count == count { return }
			await Task.yield()
		}
	}

	func testDetectionResults_PartialAndFinalPlayEachPaintedObservationOnlyOnce() async {
		let player = RecordingPlayer()
		let sut = AnnotationSoundEventCoordinator(player: player)
		let modelID = UUID()
		let paintedID = UUID()
		let laterID = UUID()
		sut.detectionResultsApplied(
			passID: 4,
			results: [detection(id: modelID, sound: .croak, observationIDs: [paintedID])]
		)
		sut.detectionResultsApplied(
			passID: 4,
			results: [detection(id: modelID, sound: .croak, observationIDs: [paintedID, laterID])]
		)
		await settle(player, count: 2)

		let requests = await player.recordedRequests()
		XCTAssertEqual(requests.map(\.sound), [.croak, .croak])
	}

	func testDetectionResults_PlaysEveryAnnotationFromEveryEnabledModelInRegistrationOrder() async {
		let player = RecordingPlayer()
		let sut = AnnotationSoundEventCoordinator(player: player)
		sut.detectionResultsApplied(
			passID: 7,
			results: [
				detection(sound: .pulse, observationIDs: [UUID(), UUID()]),
				detection(sound: .croak, observationIDs: [UUID()])
			]
		)
		await settle(player, count: 3)

		let requests = await player.recordedRequests()
		XCTAssertEqual(requests.map(\.sound), [.pulse, .pulse, .croak])
	}

	func testAutomaticPlayback_IsSilentWhenModelsHaveSoundDisabled() async {
		let player = RecordingPlayer()
		let sut = AnnotationSoundEventCoordinator(player: player)
		sut.detectionResultsApplied(passID: 1, results: [detection(enabled: false)])
		sut.classificationResultsBecameVisible([classification(enabled: false)])
		for _ in 0..<10 { await Task.yield() }

		let requests = await player.recordedRequests()
		XCTAssertTrue(requests.isEmpty)
	}

	func testClassificationResults_PlaysEveryNewlyVisibleEnabledModelInBatchOrder() async {
		let player = RecordingPlayer()
		let sut = AnnotationSoundEventCoordinator(player: player)
		sut.classificationResultsBecameVisible(
			[classification(sound: .chime), classification(sound: .pulse)]
		)
		await settle(player, count: 2)

		let requests = await player.recordedRequests()
		XCTAssertEqual(requests.map(\.sound), [.chime, .pulse])
	}
}
