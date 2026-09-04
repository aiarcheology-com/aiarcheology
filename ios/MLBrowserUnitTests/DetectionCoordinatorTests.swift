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
	/// Whether a detector is registered. False models the model-swap window (AIA-0808).
	private var detectorsRegistered = true
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
			isCapturing: { [weak self] in self?.capturing ?? false },
			hasDetectors: { [weak self] in self?.detectorsRegistered ?? true }
		)
		return coordinator
	}

	/// A result carrying one **visible** observation.
	///
	/// It held `observations: []` until AIA-0840, which did not matter while the apply guard read
	/// `results.isEmpty`. It matters now: the guard asks whether an overlay is on screen, and the
	/// overlay is `DetectionPresentation.filteredResults`, which drops a group with no observations
	/// entirely. A zero-observation fixture therefore modelled a frame that displays *nothing* while
	/// every test using it meant "there are boxes here to protect".
	private func cannedResult(confidence: Float = 0.9) -> DetectionResult {
		(observations: [detectedObject(confidence: confidence)],
		 params: DeepDriverParams(entityId: UUID(), modelName: "Test Model"))
	}

	private func detectedObject(confidence: Float) -> DetectedObject {
		DetectedObject(
			uuid: UUID(),
			labels: [DetectedObject.Label(identifier: "artifact", confidence: confidence)],
			confidence: confidence,
			boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
			regionIndex: 0
		)
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
			isCapturing: { [weak self] in self?.capturing ?? false },
			hasDetectors: { [weak self] in self?.detectorsRegistered ?? true }
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

	// MARK: - The model-swap window (AIA-0808)

	/// The reported bug, reduced. Changing a model unregisters the old driver before loading the new
	/// one, and loading a YOLO package takes about two seconds. `DeepDrivers.detect` loops over the
	/// registered detectors, so with none registered it returns an empty array — and the snapshot
	/// timer keeps firing throughout, so every tick applied an empty frame and wiped the overlay.
	/// The user's log showed it plainly: `groups=0` passes bracketed by unload and register.
	///
	/// Nobody was asked, so nothing was answered. The displayed frame must survive untouched.
	func testEmptyResultWithNoDetectorRegistered_LeavesTheDisplayedFrameAlone() async {
		let coordinator = makeCoordinator()
		let firstSnapshot = await applyFrame(coordinator, results: [cannedResult()])
		XCTAssertEqual(coordinator.appliedFrame?.results.count, 1)

		// The swap begins: the old driver is unregistered and the new one is still loading.
		detectorsRegistered = false
		coordinator.ingest(snapshot: UIImage())
		await awaitDetectSuspended()
		resumeDetect(with: [])
		await settleForDiscard()

		XCTAssertEqual(coordinator.appliedFrame?.results.count, 1, "the empty pass wiped the overlay")
		XCTAssertTrue(coordinator.appliedFrame?.image === firstSnapshot, "the displayed frame was replaced")
		XCTAssertEqual(frameChanges.count, 1, "a no-answer pass must not reach the mirror at all")
	}

	/// The third arm: with no boxes displayed there is no overlay to protect, so the frame applies —
	/// and keeps applying (AIA-0840).
	///
	/// This is the classify-only setup, and the bundled FastViT demo is exactly one.
	/// `DeepDrivers.detect` loops the *detectors*; a classifier runs on its own parallel branch and
	/// answers no detect pass, so such a session reports "no detector" and "no results" on every pass,
	/// forever. Without this arm the guard refused every one of them and no frame was ever applied,
	/// measured as `applied=false` after 90 seconds and ten delivered snapshots — which cost the
	/// finding-pick flow the frozen snapshot it hit-tests.
	///
	/// **Two snapshots, and the second is the point.** Keying this on "no frame displayed" instead of
	/// "no results displayed" also turns the first assertion green, and is wrong: the empty frame it
	/// installs makes every later pass fail the same test, so the image freezes on snapshot one and a
	/// pick after navigating saves a stale page. Only the second half catches that.
	func testEmptyResultsWithNoDetector_KeepApplyingWhileNothingIsDisplayed() async {
		let coordinator = makeCoordinator()
		detectorsRegistered = false
		XCTAssertNil(coordinator.appliedFrame, "arrange: nothing is displayed yet")

		let first = UIImage()
		coordinator.ingest(snapshot: first)
		await awaitDetectSuspended()
		resumeDetect(with: [])
		// `settle(until:)`, never `settleForDiscard()`: this waits for something to HAPPEN, and the
		// discard helper cannot tell "ran and applied" from "has not run yet" — its own documentation
		// says its failure mode is a false pass.
		await settle(until: { coordinator.appliedFrame != nil }, "the classify-only pass applied no frame")

		XCTAssertTrue(coordinator.appliedFrame?.image === first, "the classify-only pass applied no frame")
		XCTAssertEqual(coordinator.appliedFrame?.results.count, 0, "a classifier has no boxes to show")

		let second = UIImage()
		coordinator.ingest(snapshot: second)
		await awaitDetectSuspended()
		resumeDetect(with: [])
		await settle(
			until: { coordinator.appliedFrame?.image === second },
			"the image froze on the first snapshot — a pick after navigating would save a stale page"
		)

		XCTAssertTrue(
			coordinator.appliedFrame?.image === second,
			"the image froze on the first snapshot — a pick after navigating would save a stale page"
		)
		XCTAssertEqual(frameChanges.count, 2, "the screen's mirror must see both")
	}

	/// The other half, and the reason this is a guard rather than a blanket "ignore empty results":
	/// a detector that ran and found nothing is a real answer, and the boxes must go.
	func testEmptyResultWithADetectorRegistered_StillClearsTheOverlay() async {
		let coordinator = makeCoordinator()
		await applyFrame(coordinator, results: [cannedResult()])
		XCTAssertEqual(coordinator.appliedFrame?.results.count, 1)

		coordinator.ingest(snapshot: UIImage())
		await awaitDetectSuspended()
		resumeDetect(with: [])
		await settle(
			until: { coordinator.appliedFrame?.results.isEmpty == true },
			"a detector that found nothing must clear the overlay"
		)

		XCTAssertEqual(coordinator.appliedFrame?.results.count, 0)
	}

	/// A non-empty result is always an answer, whatever the registry looked like when the pass
	/// began — the guard keys on emptiness too, so a late-registering driver's real findings are
	/// never suppressed.
	func testNonEmptyResultAppliesEvenIfThePassBeganWithNoDetector() async {
		let coordinator = makeCoordinator()
		detectorsRegistered = false

		let snapshot = UIImage()
		coordinator.ingest(snapshot: snapshot)
		await awaitDetectSuspended()
		resumeDetect(with: [cannedResult()])
		await settle(
			until: { coordinator.appliedFrame != nil },
			"a real result must apply regardless of the registry state at pass start"
		)

		XCTAssertEqual(coordinator.appliedFrame?.results.count, 1)
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

		/// The coordinator never reads this; the fake reports a healthy device so a settings-screen
		/// concern cannot leak into these detection-path assertions.
		func deviceOutputVolume() async -> Float { 1 }

		/// Backgrounding is driven from the scene, not from the coordinator under test here (#785).
		func suspend() async {}
		func resume() async {}
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

// MARK: - Annotation sound admission policy (AIA-0720)

/// The playback gate that replaced AIA-0716's two-voice FIFO. Surplus sounds are **dropped** rather
/// than queued, so what is heard always corresponds to detections happening now instead of trailing
/// them by the length of a backlog — and same-sound detections within one pass are **staggered**, so
/// a listener can hear that three things were found rather than one.
final class AnnotationSoundAdmissionPolicyTests: XCTestCase {
	private typealias Policy = AnnotationSoundAdmissionPolicy

	func testFirstOnsetPlaysImmediately() {
		var policy = Policy()
		XCTAssertEqual(policy.admissionDelay(for: .chime, activeVoices: 0, now: 100), 0)
	}

	func testRefusesEveryRequestWhileAllVoicesAreBusy() {
		var policy = Policy()
		XCTAssertNil(
			policy.admissionDelay(for: .chime, activeVoices: Policy.maximumActiveVoices, now: 100),
			"A saturated player must drop the request, not queue it behind a busy voice"
		)
	}

	/// The behaviour the reporter asked for: several objects in one pass are heard as a short run,
	/// not as a single tone. Firing identical waveforms simultaneously would sum into one louder
	/// tone, so spacing the onsets is the only way the count is audible at all.
	func testSameSoundDetectionsAreStaggeredIntoACountableRun() throws {
		var policy = Policy()
		let interval = Policy.minimumInterOnsetInterval

		let delays = (0..<3).map { _ in
			policy.admissionDelay(for: .chime, activeVoices: 0, now: 100)
		}

		// Compared with a tolerance rather than exactly: each delay is a difference between two
		// monotonic timestamps, so the accumulated representation error is real and harmless
		// (0.15 s arrives as 0.1499999999999773). A sub-microsecond tolerance still fails loudly if
		// the spacing itself regresses.
		XCTAssertEqual(delays.count, 3)
		for (index, delay) in delays.enumerated() {
			XCTAssertEqual(
				try XCTUnwrap(delay),
				interval * TimeInterval(index),
				accuracy: 1e-6,
				"Onset \(index) of a same-sound run must be spaced one interval from the previous one"
			)
		}
	}

	/// Deliberately run at a realistic device uptime rather than a tidy `now = 100`.
	///
	/// The original implementation derived the onset count from elapsed time and compared it against
	/// a `0.15 * 3` horizon. At a large uptime the fourth delay accumulated to 0.4499999999825377,
	/// slipped under the horizon, and a fourth tone played — a cap that held or broke depending on
	/// how long the device had been switched on. A round `now` rounded the other way and hid it.
	func testTheRunIsBoundedRegardlessOfDeviceUptime() {
		for uptime in [0, 100, 86_400, 1_234_567.891] as [TimeInterval] {
			var policy = Policy()

			for onset in 0..<Policy.maximumStaggeredOnsets {
				XCTAssertNotNil(
					policy.admissionDelay(for: .chime, activeVoices: 0, now: uptime),
					"Onset \(onset) must be granted at uptime \(uptime)"
				)
			}

			XCTAssertNil(
				policy.admissionDelay(for: .chime, activeVoices: 0, now: uptime),
				"A fourth onset must be dropped at uptime \(uptime); the cap must not depend on uptime"
			)
		}
	}

	/// The rolling window is intentional: a pass publishes partial results before final ones, so
	/// resetting per burst would grant two full runs to bursts milliseconds apart and reintroduce
	/// the density this bounds.
	func testABurstArrivingInsideAnExistingRunSharesItsBudget() {
		var policy = Policy()

		for _ in 0..<Policy.maximumStaggeredOnsets {
			_ = policy.admissionDelay(for: .chime, activeVoices: 0, now: 100)
		}

		XCTAssertNil(
			policy.admissionDelay(for: .chime, activeVoices: 0, now: 100.08),
			"A partial result arriving 80ms later must not be granted a second full run"
		)
	}

	/// The other half of the rolling window, and the one the user explicitly asked for: a stationary
	/// object keeps announcing itself on each ordinary pass, because passes arrive seconds apart and
	/// a run that has been heard out is over.
	func testAnOrdinaryLaterPassStartsAFreshRun() {
		var policy = Policy()

		for _ in 0..<Policy.maximumStaggeredOnsets {
			_ = policy.admissionDelay(for: .chime, activeVoices: 0, now: 100)
		}

		// Detection passes in the field arrive roughly every 1.5-3 seconds.
		XCTAssertEqual(
			policy.admissionDelay(for: .chime, activeVoices: 0, now: 101.5),
			0,
			"A later pass must sound immediately, not inherit the previous pass's backlog"
		)
	}

	/// The reason the gate is keyed per sound rather than globally.
	///
	/// `AnnotationSoundEventCoordinator` emits requests in driver-registration order, so a single
	/// global gate would let the first-registered model win every slot under saturation and a second
	/// model's tone would never be heard — defeating the point of telling models apart by ear.
	func testASecondModelsSoundIsNotStarvedByTheFirst() {
		var policy = Policy()

		XCTAssertEqual(policy.admissionDelay(for: .chime, activeVoices: 0, now: 100), 0)
		XCTAssertEqual(
			policy.admissionDelay(for: .sonar, activeVoices: 1, now: 100),
			0,
			"A different model's sound must not be delayed or dropped by another model's onset"
		)
	}
}

// MARK: - Annotation sound session category (AIA-0720)

final class AnnotationSoundCategoryTests: XCTestCase {
	/// #720 was reported as "no sound on iPhone" and proved to be Silent mode. The resolution was to
	/// keep respecting Silent mode and say so on the Sound screen, which makes `.ambient` a promise
	/// to the user rather than an implementation detail: `.playback` would keep playing through a
	/// silenced device and turn the shipped copy into a lie.
	func testPlaybackCategoryRespectsSilentMode() {
		XCTAssertEqual(
			AnnotationSoundPlayer.sessionCategory,
			.ambient,
			"L10n.Configuration.soundOutputNote promises detection sounds follow Silent mode; only .ambient honours that"
		)
	}
}
