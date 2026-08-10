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
/// facade) so tests can drive completion deterministically.
@MainActor
final class DetectionCoordinator: ObservableObject {
	/// The one displayed detection frame: the snapshot and the results detected ON it, applied
	/// together so a pick can never pair boxes with a newer image. Published so the view redraws;
	/// the private setter mirrors every write to `onFrameChanged`.
	@Published private(set) var appliedFrame: AppliedDetectionFrame?

	/// Off-main detection, injected for testability. `@MainActor` because `DeepDrivers` is — the
	/// heavy work hops to the engine actor inside `detect`; this coordinator only awaits it.
	private let detect: @MainActor (UIImage, TilingScheme) async -> [DetectionResult]
	/// Mirrors every displayed-frame write to the presenting screen (the find-pick flow hit-tests
	/// the frozen frame's boxes and reuses its snapshot, so the mirror can never diverge).
	private let onFrameChanged: ((AppliedDetectionFrame?) -> Void)?

	private let queue = SnapshotDetectionQueue()
	private var tracePassSequence: UInt64 = 0
	/// Invalidation token: a pass that started before an interaction/capture/geometry change must
	/// not apply. Bumped on every active invalidation; re-checked at apply.
	private var generation: UInt64 = 0
	/// Live-mirrored from the view (the tiling-scheme settings can change mid-session); read at
	/// pass start. A mid-burst toggle self-heals on the next snapshot.
	var tiling: TilingScheme

	/// Live apply-time guards. Default to "not interacting / not capturing" until bound; no snapshot
	/// arrives before the view appears and binds them (see `bindGuards`).
	private var isInteracting: () -> Bool = { false }
	private var isCapturing: () -> Bool = { false }

	init(
		tiling: TilingScheme = [],
		detect: @escaping @MainActor (UIImage, TilingScheme) async -> [DetectionResult],
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
		LoggingPolicy.debug("[AIA-0587 TRACE] DetectionCoordinator bound live guards", logger: .drivers)
	}

	// MARK: - Active invalidation (driven from the view's lifecycle events)

	/// Layout changed (rotation, chrome shown/hidden): results captured against the previous
	/// geometry would draw misaligned boxes. The caller gates on `!isCapturingFinding` (a rotation
	/// under the save sheet merely misaligns the frozen boxes — cosmetic — while clearing them
	/// would defeat the freeze).
	func geometryChanged() {
		LoggingPolicy.debug(
			"[AIA-0587 TRACE] DetectionCoordinator geometryChanged generation=\(generation)",
			logger: .drivers
		)
		invalidate(clearFrame: true)
	}

	/// Interaction (scroll/drag/zoom) started: clear the displayed boxes immediately and drop
	/// in-flight work — but only when not capturing (the save sheet keeps the frame frozen even as
	/// interaction events arrive from the web view while the sheet animates in).
	func setInteracting(_ interacting: Bool) {
		LoggingPolicy.debug(
			"[AIA-0587 TRACE] DetectionCoordinator setInteracting=\(interacting) capturingNow=\(isCapturing()) generation=\(generation)",
			logger: .drivers
		)
		if interacting && isCapturing() == false {
			invalidate(clearFrame: true)
		}
	}

	/// Entering a finding capture must invalidate work already in flight: the freeze gate alone only
	/// discards results WHILE it is set, so a pre-freeze pass finishing after the capture ends would
	/// briefly apply a stale frame over the fresh one. Does NOT clear — the displayed frame must
	/// stay frozen under the sheet.
	func setCapturing(_ capturing: Bool) {
		LoggingPolicy.debug(
			"[AIA-0587 TRACE] DetectionCoordinator setCapturing=\(capturing) generation=\(generation)",
			logger: .drivers
		)
		if capturing {
			invalidate(clearFrame: false)
		}
	}

	// MARK: - Detection entry point

	/// The single entry into detection. Serializes passes and coalesces snapshots arriving mid-pass
	/// to the newest (a tiled pass — 6 inferences × N detectors — can outlast the snapshot cadence,
	/// and overlapping passes would apply out of order). Applies results only if still valid at
	/// completion.
	func ingest(snapshot image: UIImage) {
		LoggingPolicy.debug(
			"[AIA-0587 TRACE] DetectionCoordinator ingest image=\(image.size.width)x\(image.size.height) generation=\(generation) queueInFlight=\(queue.inFlight) interacting=\(isInteracting()) capturing=\(isCapturing())",
			logger: .drivers
		)
		queue.enqueue(image) { image, done in
			self.tracePassSequence &+= 1
			let pass = self.tracePassSequence
			let startGeneration = self.generation
			LoggingPolicy.debug(
				"[AIA-0587 TRACE] DetectionCoordinator pass started pass=\(pass) generation=\(startGeneration) image=\(image.size.width)x\(image.size.height) regionCount=\(TileLayout.regions(for: self.tiling).count)",
				logger: .drivers
			)
			Task {
				let observations = await self.detect(image, self.tiling)
				let observationCount = observations.reduce(0) { $0 + $1.observations.count }
				LoggingPolicy.debug(
					"[AIA-0587 TRACE] DetectionCoordinator pass completed pass=\(pass) groups=\(observations.count) observations=\(observationCount) currentGeneration=\(self.generation)",
					logger: .drivers
				)
				done()
				// Discard if invalidated since this pass began (stale geometry/interaction/capture).
				guard self.generation == startGeneration else {
					LoggingPolicy.debug(
						"[AIA-0587 TRACE] DetectionCoordinator discarded pass=\(pass) reason=generationChanged start=\(startGeneration) current=\(self.generation)",
						logger: .drivers
					)
					return
				}
				// Live re-checks: interaction or a capture may have begun after the generation was
				// snapshotted but before SwiftUI delivered the matching `.onChange`.
				guard self.isInteracting() == false else {
					LoggingPolicy.debug(
						"[AIA-0587 TRACE] DetectionCoordinator discarded pass=\(pass) reason=interacting",
						logger: .drivers
					)
					return
				}
				guard self.isCapturing() == false else {
					LoggingPolicy.debug(
						"[AIA-0587 TRACE] DetectionCoordinator discarded pass=\(pass) reason=capturing",
						logger: .drivers
					)
					return
				}
				// Image and results are applied as ONE value: the cached snapshot is always the exact
				// frame the displayed boxes came from.
				self.setApplied(AppliedDetectionFrame(image: image, results: observations))
				LoggingPolicy.debug("[AIA-0587 TRACE] DetectionCoordinator applied pass=\(pass)", logger: .drivers)
			}
		}
	}

	// MARK: - Internals

	private func invalidate(clearFrame: Bool) {
		let previousGeneration = generation
		generation &+= 1
		LoggingPolicy.debug(
			"[AIA-0587 TRACE] DetectionCoordinator invalidated generation=\(previousGeneration)->\(generation) clearFrame=\(clearFrame)",
			logger: .drivers
		)
		if clearFrame { setApplied(nil) }
		// A coalesced snapshot captured against the now-stale state must not start.
		queue.cancelPending()
	}

	/// Single write path for the displayed frame: the screen's mirror updates in the same statement,
	/// so the two can never diverge.
	private func setApplied(_ frame: AppliedDetectionFrame?) {
		let observationCount = frame?.results.reduce(0) { $0 + $1.observations.count } ?? 0
		LoggingPolicy.debug(
			"[AIA-0587 TRACE] DetectionCoordinator setApplied hasFrame=\(frame != nil) observations=\(observationCount)",
			logger: .drivers
		)
		appliedFrame = frame
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
		LoggingPolicy.debug(
			"[AIA-0587 TRACE] SnapshotDetectionQueue enqueue inFlight=\(inFlight) pending=\(pendingImage != nil) image=\(image.size.width)x\(image.size.height)",
			logger: .drivers
		)
		guard inFlight.not else {
			pendingImage = image
			LoggingPolicy.debug("[AIA-0587 TRACE] SnapshotDetectionQueue coalesced newest pending image", logger: .drivers)
			return
		}
		start(image, pass: pass)
	}

	/// Drops a coalesced snapshot (e.g. interaction started — its geometry is stale).
	func cancelPending() {
		LoggingPolicy.debug(
			"[AIA-0587 TRACE] SnapshotDetectionQueue cancelPending hadPending=\(pendingImage != nil) inFlight=\(inFlight)",
			logger: .drivers
		)
		pendingImage = nil
	}

	private func start(_ image: UIImage, pass: @escaping Pass) {
		inFlight = true
		LoggingPolicy.debug(
			"[AIA-0587 TRACE] SnapshotDetectionQueue starting pass image=\(image.size.width)x\(image.size.height)",
			logger: .drivers
		)
		pass(image) { [weak self] in
			guard let self else { return }
			self.inFlight = false
			LoggingPolicy.debug(
				"[AIA-0587 TRACE] SnapshotDetectionQueue pass done pending=\(self.pendingImage != nil)",
				logger: .drivers
			)
			if let next = self.pendingImage {
				self.pendingImage = nil
				LoggingPolicy.debug("[AIA-0587 TRACE] SnapshotDetectionQueue starting coalesced image", logger: .drivers)
				self.start(next, pass: pass)
			}
		}
	}
}
