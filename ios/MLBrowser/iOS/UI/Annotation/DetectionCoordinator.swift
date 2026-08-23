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

	private let queue = SnapshotDetectionQueue()
	/// Invalidation token: a pass that started before an interaction/capture/geometry change must
	/// not apply. Bumped on every active invalidation; re-checked at apply.
	private var generation: UInt64 = 0
	/// Temporary correlation token for AIA-0702 pipeline diagnostics.
	private var tracePassSequence: UInt64 = 0
	/// Live-mirrored from the view (the tiling-scheme settings can change mid-session); read at
	/// pass start. A mid-burst toggle self-heals on the next snapshot.
	var tiling: TilingScheme

	/// Live apply-time guards. Default to "not interacting / not capturing" until bound; no snapshot
	/// arrives before the view appears and binds them (see `bindGuards`).
	private var isInteracting: () -> Bool = { false }
	private var isCapturing: () -> Bool = { false }

	init(
		tiling: TilingScheme = [],
		detect: @escaping @MainActor (
			UIImage,
			TilingScheme,
			@escaping @MainActor @Sendable ([DetectionResult]) -> Void
		) async -> [DetectionResult],
		onFrameChanged: ((AppliedDetectionFrame?) -> Void)? = nil
	) {
		self.tiling = tiling
		self.detect = detect
		self.onFrameChanged = onFrameChanged
	}

	/// Bind the live apply-time guards from the view's CONNECTED state. Call from `.onAppear`, NOT
	/// the initializer: a view's own `@State` is not wired to persistent storage at init time, so a
	/// closure captured there would read a dead initial value. Once bound from the installed view,
	/// the closures reach the same `@State`/`Binding` boxes the old in-view apply site read live.
	func bindGuards(isInteracting: @escaping () -> Bool, isCapturing: @escaping () -> Bool) {
		self.isInteracting = isInteracting
		self.isCapturing = isCapturing
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
		LoggingPolicy.debug(
			"[AIA-0702 TRACE] Detection ingest generation=\(generation) queueInFlight=\(queue.inFlight)",
			logger: .ui
		)
		queue.enqueue(image) { image, done in
			let startGeneration = self.generation
			self.tracePassSequence &+= 1
			let passSequence = self.tracePassSequence
			let passTiling = self.tiling
			let regionCount = TileLayout.regions(for: passTiling).count
			LoggingPolicy.debug(
				"[AIA-0702 TRACE] Detection pass started sequence=\(passSequence) generation=\(startGeneration) regions=\(regionCount)",
				logger: .ui
			)
			Task {
				let applyIfCurrent: @MainActor @Sendable ([DetectionResult]) -> Void = { [weak self] observations in
					guard let self else { return }
					// Discard if invalidated since this pass began (stale geometry/interaction/capture).
					guard self.generation == startGeneration else { return }
					// Live re-checks: interaction or a capture may have begun after the generation was
					// snapshotted but before SwiftUI delivered the matching `.onChange`.
					guard self.isInteracting() == false, self.isCapturing() == false else { return }
					// Image and results are applied as ONE value: the cached snapshot is always the exact
					// frame the displayed boxes came from.
					self.setApplied(AppliedDetectionFrame(image: image, results: observations))
				}
				let observations = await self.detect(image, passTiling, applyIfCurrent)
				let observationCount = observations.reduce(0) { $0 + $1.observations.count }
				LoggingPolicy.debug(
					"[AIA-0702 TRACE] Detection pass completed sequence=\(passSequence) groups=\(observations.count) observations=\(observationCount)",
					logger: .ui
				)
				done()
				guard self.generation == startGeneration else {
					LoggingPolicy.debug("[AIA-0702 TRACE] Detection pass dropped sequence=\(passSequence) reason=staleGeneration", logger: .ui)
					return
				}
				guard self.isInteracting() == false else {
					LoggingPolicy.debug("[AIA-0702 TRACE] Detection pass dropped sequence=\(passSequence) reason=interacting", logger: .ui)
					return
				}
				guard self.isCapturing() == false else {
					LoggingPolicy.debug("[AIA-0702 TRACE] Detection pass dropped sequence=\(passSequence) reason=capturing", logger: .ui)
					return
				}
				applyIfCurrent(observations)
			}
		}
	}

	/// Re-delivers the retained raw frame after a display-side preference changes. The view owns
	/// transforming it for presentation, so this deliberately neither reloads a detector nor starts
	/// a new detection pass.
	func refreshPresentation() {
		let rawGroupCount = appliedFrame?.results.count ?? 0
		let rawObservationCount = appliedFrame?.results.reduce(0) { $0 + $1.observations.count } ?? 0
		LoggingPolicy.debug(
			"[AIA-0702 TRACE] Presentation refresh rawGroups=\(rawGroupCount) rawObservations=\(rawObservationCount)",
			logger: .ui
		)
		onFrameChanged?(appliedFrame)
	}

	// MARK: - Internals

	private func invalidate(clearFrame: Bool) {
		generation &+= 1
		LoggingPolicy.debug("[AIA-0702 TRACE] Detection invalidated generation=\(generation) clearFrame=\(clearFrame)", logger: .ui)
		if clearFrame { setApplied(nil) }
		// A coalesced snapshot captured against the now-stale state must not start.
		queue.cancelPending()
	}

	/// Single write path for the displayed frame: the screen's mirror updates in the same statement,
	/// so the two can never diverge.
	private func setApplied(_ frame: AppliedDetectionFrame?) {
		appliedFrame = frame
		let rawGroupCount = frame?.results.count ?? 0
		let rawObservationCount = frame?.results.reduce(0) { $0 + $1.observations.count } ?? 0
		LoggingPolicy.debug(
			"[AIA-0702 TRACE] Detection frame applied rawGroups=\(rawGroupCount) rawObservations=\(rawObservationCount)",
			logger: .ui
		)
		onFrameChanged?(frame)
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
