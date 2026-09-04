//
//  DetectionCoordinator.swift
//  AI Archeology
//
//  Created by Agent on 2026-07-10.
//

import SwiftUI

/// The detection state machine, extracted from `DetectableView` (AIA-0386) so the
/// generation / coalesce / freeze / apply-guard logic is unit-testable without SwiftUI. Owns the
/// serial snapshot → detect → apply pipeline and publishes the single displayed
/// `AppliedDetectionFrame`. Behaviour is byte-for-byte the old in-view machine.
///
/// The apply-time interaction/capture guards are read LIVE (see `bindGuards`), not from cached
/// mirrors: the old apply site read `interactionState.isInteracting` and
/// `isCapturingFinding.wrappedValue` live, discarding a result produced in the window between "the
/// user scrolled / a capture began" and SwiftUI delivering the corresponding `.onChange`. A cached
/// mirror updates only on that `.onChange`, so it would miss the window and paint a stale frame.
/// `detect` is injected (the view wires it to `DeepDrivers.detect`, the AIA-0387 engine-actor
/// facade) so tests can drive final completion and incremental tile publication deterministically.
@MainActor
final class DetectionCoordinator: ObservableObject {
	/// The one displayed detection frame: the snapshot and the results detected ON it, applied
	/// together so a pick can never pair boxes with a newer image. Published so the view redraws;
	/// the private setter mirrors every write to `onFrameChanged`.
	@Published private(set) var appliedFrame: AppliedDetectionFrame?

	/// Off-main detection, injected for testability. `@MainActor` because `DeepDrivers` is — the
	/// heavy work hops to the engine actor inside `detect`; this coordinator only awaits it.
	private let detect: @MainActor (
		UIImage,
		TilingScheme,
		@escaping @MainActor @Sendable ([DetectionResult]) -> Void
	) async -> [DetectionResult]
	/// Mirrors every displayed-frame write to the presenting screen (the find-pick flow hit-tests
	/// the frozen frame's boxes and reuses its snapshot, so the mirror can never diverge).
	private let onFrameChanged: ((AppliedDetectionFrame?) -> Void)?
	/// Called only from the real apply path. Presentation-only refreshes deliberately do not reach
	/// this callback, so changing a display preference cannot replay an annotation sound (AIA-0716).
	private var onAppliedResults: ((UInt64, [DetectionResult]) -> Void)?

	private let queue = SnapshotDetectionQueue()
	/// Invalidation token: a pass that started before an interaction/capture/geometry change must
	/// not apply. Bumped on every active invalidation; re-checked at apply.
	private var generation: UInt64 = 0
	/// Monotonic identity for actual snapshot passes. A partial and its final result intentionally
	/// share one id, letting the sound coordinator suppress a second playback for the same pass.
	private var nextPassID: UInt64 = 0
	/// Live-mirrored from the view (the tiling-scheme settings can change mid-session); read at
	/// pass start. A mid-burst toggle self-heals on the next snapshot.
	var tiling: TilingScheme

	/// Live apply-time guards. Default to "not interacting / not capturing" until bound; no snapshot
	/// arrives before the view appears and binds them (see `bindGuards`).
	private var isInteracting: () -> Bool = { false }
	private var isCapturing: () -> Bool = { false }
	/// Whether any detector is registered right now.
	///
	/// Defaults to `true` — "assume there is one" — so an unbound coordinator behaves exactly as it
	/// did before this guard existed, and only a view that binds the real answer gets the new one.
	private var hasDetectors: () -> Bool = { true }

	init(
		tiling: TilingScheme = [],
		detect: @escaping @MainActor (
			UIImage,
			TilingScheme,
			@escaping @MainActor @Sendable ([DetectionResult]) -> Void
		) async -> [DetectionResult],
		onFrameChanged: ((AppliedDetectionFrame?) -> Void)? = nil,
		onAppliedResults: ((UInt64, [DetectionResult]) -> Void)? = nil
	) {
		self.tiling = tiling
		self.detect = detect
		self.onFrameChanged = onFrameChanged
		self.onAppliedResults = onAppliedResults
	}

	/// Bind the live apply-time guards from the view's CONNECTED state. Call from `.onAppear`, NOT
	/// the initializer: a view's own `@State` is not wired to persistent storage at init time, so a
	/// closure captured there would read a dead initial value. Once bound from the installed view,
	/// the closures reach the same `@State`/`Binding` boxes the old in-view apply site read live.
	/// - Parameter hasDetectors: defaults to "there is one", which is how this behaved before the
	///   guard existed — so a caller that does not care about the model-swap window, every existing
	///   test included, keeps exactly its old semantics rather than silently acquiring new ones.
	func bindGuards(
		isInteracting: @escaping () -> Bool,
		isCapturing: @escaping () -> Bool,
		hasDetectors: @escaping () -> Bool = { true }
	) {
		self.isInteracting = isInteracting
		self.isCapturing = isCapturing
		self.hasDetectors = hasDetectors
	}

	/// Binds the automatic-sound receiver after the view's environment is connected. As with the
	/// live capture/interaction guards, binding from `.onAppear` avoids capturing an uninstalled
	/// SwiftUI environment object during view initialization.
	func bindSoundEvents(_ receiver: @escaping (UInt64, [DetectionResult]) -> Void) {
		onAppliedResults = receiver
	}

	// MARK: - Active invalidation (driven from the view's lifecycle events)

	/// Layout changed (rotation, chrome shown/hidden): results captured against the previous
	/// geometry would draw misaligned boxes. The caller gates on `!isCapturingFinding` (a rotation
	/// under the save sheet merely misaligns the frozen boxes — cosmetic — while clearing them
	/// would defeat the freeze).
	func geometryChanged() {
		invalidate(clearFrame: true)
	}

	/// Interaction (scroll/drag/zoom) started: clear the displayed boxes immediately and drop
	/// in-flight work — but only when not capturing (the save sheet keeps the frame frozen even as
	/// interaction events arrive from the web view while the sheet animates in).
	func setInteracting(_ interacting: Bool) {
		if interacting && isCapturing() == false {
			invalidate(clearFrame: true)
		}
	}

	/// Entering a finding capture must invalidate work already in flight: the freeze gate alone only
	/// discards results WHILE it is set, so a pre-freeze pass finishing after the capture ends would
	/// briefly apply a stale frame over the fresh one. Does NOT clear — the displayed frame must
	/// stay frozen under the sheet.
	func setCapturing(_ capturing: Bool) {
		if capturing {
			invalidate(clearFrame: false)
		}
	}

	// MARK: - Detection entry point

	/// The single entry into detection. Serializes passes and coalesces snapshots arriving mid-pass
	/// to the newest (a tiled pass — 6 inferences × N detectors — can outlast the snapshot cadence,
	/// and overlapping passes would apply out of order). Each completed tile can update the current
	/// snapshot's overlay; every partial and final result receives the same live validity guards.
	func ingest(snapshot image: UIImage) {
		queue.enqueue(image) { image, done in
			let passID = self.nextPassID
			self.nextPassID &+= 1
			let startGeneration = self.generation
			let passTiling = self.tiling
			// Whether anything was registered to answer this pass, read BEFORE it runs. Read after,
			// and a driver that finished registering mid-pass would make an empty result look
			// authoritative — the one reading that must not happen (AIA-0808).
			let startedWithDetectors = self.hasDetectors()
			Task {
				let applyIfCurrent: @MainActor @Sendable ([DetectionResult]) -> Void = { [weak self] observations in
					guard let self else { return }
					// Discard if invalidated since this pass began (stale geometry/interaction/capture).
					guard self.generation == startGeneration else { return }
					// Live re-checks: interaction or a capture may have begun after the generation was
					// snapshotted but before SwiftUI delivered the matching `.onChange`.
					guard self.isInteracting() == false else { return }
					guard self.isCapturing() == false else { return }
					// "Nobody was asked" is not "nothing is there" (AIA-0808).
					//
					// `DeepDrivers.detect` snapshots the registered detectors and loops over them, so
					// with none registered it returns an empty array — indistinguishable, at this
					// point, from a detector that looked and found nothing. A model swap unregisters
					// before it loads, and loading a YOLO package takes ~2s, during which the timer
					// keeps firing: every tick applied an empty frame and wiped the overlay. That is
					// the reported "annotations disappear after changing the model", and the log
					// showed it exactly — `groups=0` passes bracketed by unload/register.
					//
					// An empty result from a pass that had no detector is therefore no answer at all,
					// and the displayed frame is left alone until a real one arrives. A pass that DID
					// have a detector and returned nothing still clears, because that is a genuine
					// answer.
					// ...and an overlay is *results*, not an image (AIA-0840).
					//
					// What the guard above protects is the boxes on screen, so it has work to do only
					// while some are displayed. A pass carrying none cannot wipe an overlay that is
					// already empty, and refusing it anyway is what broke a classify-only setup — the
					// bundled FastViT demo is exactly one. `DeepDrivers.detect` loops the *detectors*;
					// a classifier runs on its own parallel branch and answers no detect pass, so such
					// a session reports no detector and no results on every pass, forever. No frame was
					// ever applied, and the finding-pick flow lost the frozen snapshot it hit-tests.
					//
					// Keyed on the displayed results rather than on `appliedFrame == nil`, which was
					// the first attempt and was one-shot: the empty frame it installed made every
					// later pass fail the same test again, so the image froze on the first snapshot
					// and a pick after navigating would have saved that stale page. Keyed on the
					// results, a classify-only session keeps refreshing its image pass after pass.
					//
					// Deliberately NOT written as "a classificator counts as a detector" either.
					// During a model swap a mixed setup has no detectors for the ~2s the package
					// takes while its classificator stays registered, and counting it would make the
					// empty pass authoritative and wipe the boxes — the AIA-0808 regression itself.
					// Filtered, not raw: the overlay draws `DetectionPresentation.filteredResults`, so a
					// frame whose detections all sit below their model's confidence threshold shows no
					// boxes at all. Counting those as "displayed" would protect an overlay nobody can
					// see and freeze the image behind it, which is the same defect as keying on the
					// frame's mere existence.
					let displayed = DetectionPresentation.filteredResults(self.appliedFrame?.results ?? [])
					let displaysResults = displayed.isEmpty == false
					guard startedWithDetectors || observations.isEmpty == false || displaysResults == false
					else { return }
					// Image and results are applied as ONE value: the cached snapshot is always the exact
					// frame the displayed boxes came from.
					self.setApplied(AppliedDetectionFrame(image: image, results: observations), passID: passID)
				}
				let observations = await self.detect(image, passTiling, applyIfCurrent)
				done()
				applyIfCurrent(observations)
			}
		}
	}

	/// Re-delivers the retained raw frame after a display-side preference changes. The view owns
	/// transforming it for presentation, so this deliberately neither reloads a detector nor starts
	/// a new detection pass.
	func refreshPresentation() {
		onFrameChanged?(appliedFrame)
	}

	// MARK: - Internals

	private func invalidate(clearFrame: Bool) {
		generation &+= 1
		if clearFrame { setApplied(nil) }
		// A coalesced snapshot captured against the now-stale state must not start.
		queue.cancelPending()
	}

	/// Single write path for the displayed frame: the screen's mirror updates in the same statement,
	/// so the two can never diverge.
	private func setApplied(_ frame: AppliedDetectionFrame?, passID: UInt64? = nil) {
		appliedFrame = frame
		onFrameChanged?(frame)
		if let passID, let frame {
			onAppliedResults?(passID, frame.results)
		}
	}
}

/// Converts newly painted annotations into their individual annotation-sound requests.
///
/// The caller hands it detection/classification results in the drivers' registration order. Every
/// visible detector observation emits its model's selected sound. A detector pass's partial/final
/// writes share an id, so observations already painted by an earlier partial do not play again;
/// observations introduced by a later partial/final do.
@MainActor
final class AnnotationSoundEventCoordinator {
	private let player: any AnnotationSoundPlaying
	private var activeDetectionPassID: UInt64?
	private var paintedObservationIDs: Set<PaintedObservationID> = []

	private struct PaintedObservationID: Hashable {
		let modelID: UUID
		let observationID: UUID
	}

	init(player: any AnnotationSoundPlaying) {
		self.player = player
	}

	func detectionResultsApplied(
		passID: UInt64,
		results: [DetectionResult]
	) {
		if activeDetectionPassID != passID {
			activeDetectionPassID = passID
			paintedObservationIDs = []
		}
		let requests = results.flatMap { result -> [AnnotationSoundPlaybackRequest] in
			guard let request = AnnotationSoundPlaybackRequest(configuration: result.params.annotationSound) else {
				return []
			}
			return result.observations.compactMap { observation in
				paintedObservationIDs.insert(
					PaintedObservationID(modelID: result.params.entityId, observationID: observation.uuid)
				).inserted ? request : nil
			}
		}
		play(requests)
	}

	func classificationResultsBecameVisible(
		_ results: [ClassificationResult]
	) {
		play(results.compactMap { AnnotationSoundPlaybackRequest(configuration: $0.params.annotationSound) })
	}

	private func play(_ requests: [AnnotationSoundPlaybackRequest]) {
		guard requests.isEmpty.not else { return }
		Task { [player] in
			await player.play(requests)
		}
	}
}

/// Serializes detection passes: at most one in flight, with snapshots arriving mid-pass coalesced
/// to the newest (latest wins, no queue growth). Applying results in completion order is what made
/// overlapping passes able to deliver frame A's boxes after frame B's.
@MainActor
final class SnapshotDetectionQueue {
	typealias Pass = @MainActor (UIImage, _ done: @escaping @MainActor () -> Void) -> Void

	private(set) var inFlight = false
	private var pendingImage: UIImage?

	func enqueue(_ image: UIImage, pass: @escaping Pass) {
		guard inFlight.not else {
			pendingImage = image
			return
		}
		start(image, pass: pass)
	}

	/// Drops a coalesced snapshot (e.g. interaction started — its geometry is stale).
	func cancelPending() {
		pendingImage = nil
	}

	private func start(_ image: UIImage, pass: @escaping Pass) {
		inFlight = true
		pass(image) { [weak self] in
			guard let self else { return }
			self.inFlight = false
			if let next = self.pendingImage {
				self.pendingImage = nil
				self.start(next, pass: pass)
			}
		}
	}
}
