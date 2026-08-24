//
//  FindingFlash.swift
//  AI Archeology
//
//  Created by Agent on 2026-07-02.
//

import SwiftUI
import UIKit

/// One model's contribution to the classification label bubble (AIA-0472): its top labels,
/// attributed to the model's name and annotation color so several enabled classifiers can be
/// compared side by side. Identity is the model's `entityId`; the classify pass yields at most
/// one result per registered driver, so ids are unique within a pass.
struct ClassificationDisplayGroup: Equatable, Identifiable {
	let id: UUID
	let modelName: String
	let color: Color
	let labels: [ClassifiedLabel]
}

/// Consumes classification passes as a parallel branch of the snapshot flow —
/// deliberately independent of the detection queue/appliedFrame machinery (AIA-0374):
/// classification says "there IS an object in this image" (no location), so its
/// presentation is the pulsing frame flash, not a bounding box.
@MainActor
final class ClassificationFlashController: ObservableObject {

	/// A driver qualifies when its TOP-1 confidence clears this. Fixed in v1 and
	/// deliberately modest: real many-class models (e.g. 1000-class ImageNet
	/// classifiers like FastViT) rarely exceed ~0.4 top-1 on arbitrary content, so
	/// 0.5 never fired (owner-tested). Per-model thresholds are a follow-up. Model
	/// contract: an explicit negative/background class will misfire the flash.
	static let qualifyingConfidenceThreshold: Float = 0.25

	/// Labels the bubble shows (gated on the global "Show labels" setting) and the
	/// floor below which a label is noise, not information.
	static let displayLabelCount = 3
	static let displayConfidenceFloor: Float = 0.05

	/// The pulse period is the model's `phaseOutTime`; clamp to the config form's own
	/// slider bounds so a stale persisted value can't freeze or strobe the animation.
	static let pulsePeriodRange: ClosedRange<Double> = 0.2...10.0

	/// Number of drivers whose top-1 label currently qualifies. The flash overlay
	/// pulses while this is > 0 (and the setting is enabled).
	@Published private(set) var qualifyingCount = 0

	/// Style of the active flash, from the FIRST qualifying driver's per-model
	/// configuration (Annotation → Color / Fade Out Time / Flash size in the config
	/// sheet — every flash option is per-model, AIA-0374 owner decision).
	@Published private(set) var flashColor: Color = .yellow
	@Published private(set) var pulsePeriod: Double = 1.0
	@Published private(set) var flashSize: Double = DeepConfiguration.flashSizeDefault

	/// Monotonic count of qualifying passes — UI-test/introspection checkpoint value
	/// (a counter can't be missed by polling).
	@Published private(set) var qualifyingPassCount = 0

	/// Per-model label groups of the latest pass — every enabled classificator that has at least
	/// one label above the floor contributes one group, in registration order (AIA-0472: with
	/// several models enabled, all of them are visible and each label set is attributed to its
	/// model, so candidates can be compared side by side). Independent of the flash threshold, so
	/// the user can see what a model thinks even when nothing qualifies (AIA-0374).
	///
	/// No total row cap across groups (each group is already capped at `displayLabelCount`): the
	/// classificator count is user-bounded and small in practice. Revisit if >4 concurrent
	/// classifiers becomes a real workflow.
	@Published private(set) var displayGroups: [ClassificationDisplayGroup] = []

	/// The first group's labels. Compatibility surface for the UI-test checkpoint and the
	/// single-model bubble path; updates ride `displayGroups`' change notification.
	///
	/// Note one DELIBERATE behaviour change vs AIA-0374 (pinned by test): when the first
	/// registered model has no label above the floor but a later model does, this now shows the
	/// later model's labels — previously the bubble stayed empty while paid-for results were
	/// silently dropped.
	var displayLabels: [ClassifiedLabel] { displayGroups.first?.labels ?? [] }

	/// Invalidation token: passes started before the last interaction/capture/geometry
	/// invalidation must not ingest (detection re-checks its generation at completion;
	/// this is the same guard for the parallel branch).
	private var generation = 0
	private var isBusy = false
	/// The model IDs currently contributing a visible classifier presentation. A sound is emitted
	/// only as a model moves from absent to visible, not for every repeated classification pass.
	private var visiblePresentationModelIDs: Set<UUID> = []

	/// Runs one classification pass if idle. Skip-if-busy: at the 3–10 s snapshot
	/// cadence against a sub-second classify, a dropped frame is near-impossible;
	/// revisit with `SnapshotDetectionQueue`'s one-slot coalesce if this ever flakes.
	func classifyPass(
		drivers: DeepDrivers,
		image: UIImage,
		showIdentifiers: Bool = false,
		onResultsBecameVisible: @escaping @MainActor ([ClassificationResult]) -> Void = { _ in }
	) {
		guard isBusy.not else { return }
		isBusy = true
		let startedGeneration = generation
		Task { [weak self] in
			let results = await drivers.classify(on: image)
			guard let self else { return }
			self.isBusy = false
			// The frame this pass classified was invalidated mid-flight
			// (scroll/capture/rotation) — its results must not drive the flash.
			guard startedGeneration == self.generation else { return }
			self.ingest(
				results,
				showIdentifiers: showIdentifiers,
				onResultsBecameVisible: onResultsBecameVisible
			)
		}
	}

	/// Applies one pass's results: updates the qualifying state and the active
	/// per-model flash style (publish only on change, so no-op passes don't
	/// re-evaluate observing bodies).
	func ingest(
		_ results: [ClassificationResult],
		showIdentifiers: Bool = false,
		onResultsBecameVisible: @escaping @MainActor ([ClassificationResult]) -> Void = { _ in }
	) {
		// One group per model (registration order), the floor/sort/cap applied PER MODEL, models
		// with nothing above the floor dropped. Every model the user enabled — and paid an
		// inference for — is represented, each attributed to its own name and color (AIA-0472).
		let groups: [ClassificationDisplayGroup] = results.compactMap { result in
			let labels = result.labels
				.filter { $0.confidence >= Self.displayConfidenceFloor }
				.sorted { $0.confidence > $1.confidence }
				.prefix(Self.displayLabelCount)
			guard !labels.isEmpty else { return nil }
			return ClassificationDisplayGroup(
				id: result.params.entityId,
				modelName: result.params.modelName,
				color: result.params.annotationColor,
				labels: Array(labels)
			)
		}
		if displayGroups != groups { displayGroups = groups }

		// A model participates in the flash only when ITS OWN toggle is on — display
		// labels above stay independent, so disabled models remain visible in the bubble.
		let qualifying = results.filter { result in
			result.params.flashEnabled &&
			(result.labels.map(\.confidence).max() ?? 0) >= Self.qualifyingConfidenceThreshold
		}
		if let first = qualifying.first {
			qualifyingPassCount += 1
			let color = first.params.annotationColor
			let period = first.params.phaseOutTime.clamped(to: Self.pulsePeriodRange)
			let size = first.params.flashSize
			if flashColor != color { flashColor = color }
			if pulsePeriod != period { pulsePeriod = period }
			if flashSize != size { flashSize = size }
		}
		if qualifyingCount != qualifying.count {
			qualifyingCount = qualifying.count
		}

		// Classifications have no rectangle/point/circle overlay. Their equivalent visual event is a
		// model beginning to contribute either the flash or a label bubble. A continuously visible
		// model remains silent on repeated passes; clearing it during interaction/pause lets a later
		// false→true transition sound again once fresh results are visible.
		let labelVisibleIDs = Set(groups.map(\.id))
		let qualifyingIDs = Set(qualifying.map { $0.params.entityId })
		let visible = results.filter { result in
			qualifyingIDs.contains(result.params.entityId)
				|| (showIdentifiers && labelVisibleIDs.contains(result.params.entityId))
		}
		let newlyVisible = visible.filter { visiblePresentationModelIDs.contains($0.params.entityId).not }
		visiblePresentationModelIDs = Set(visible.map { $0.params.entityId })
		if newlyVisible.isEmpty.not {
			onResultsBecameVisible(newlyVisible)
		}
	}

	/// Interaction (scroll/zoom) invalidates what's on screen — mirror detection's
	/// clear semantics: the pulse stops during interaction and resumes when the
	/// settled content re-qualifies. Also invalidates any in-flight pass.
	func resetOnInteraction() {
		clearPresentation()
	}

	/// Clears the pulse and label bubble immediately and drops any in-flight pass.
	/// Called when the presentation can no longer refresh itself: detection paused
	/// (no more snapshots → the steady-state UI would freeze forever) or the last
	/// classificator unregistered (owner-reported bug, AIA-0374).
	func clearPresentation() {
		invalidateInFlight()
		visiblePresentationModelIDs = []
		if qualifyingCount != 0 {
			qualifyingCount = 0
		}
		if displayGroups.isEmpty.not {
			displayGroups = []
		}
	}

	/// Drops the results of any pass currently in flight (capture entry, geometry
	/// change) without resetting the qualifying state.
	func invalidateInFlight() {
		generation &+= 1
	}
}

private extension Comparable {
	func clamped(to range: ClosedRange<Self>) -> Self {
		min(max(self, range.lowerBound), range.upperBound)
	}
}

/// Softly blurred border that PULSES while a qualifying classification is on screen
/// (owner: "it should not flash just once when there is an object"). Hit-testing is
/// disabled and the view is hidden from accessibility — it must never intercept
/// content gestures or read as UI (acceptance-level requirements, AIA-0374).
struct FindingFlashOverlay: View {
	/// Pulse while true; hide otherwise.
	let active: Bool
	let color: Color
	/// Full pulse cycle length (the model's Fade Out Time).
	let period: Double
	/// Border width; the blur radius scales with it.
	let size: Double
	/// Whether detection overlays animate. `false` (settings.disableDetectionAnimations on)
	/// renders a steady, non-pulsing border — the finding still shows and clears with the data.
	let animateDetections: Bool

	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@State private var dimmed = false

	/// Pulse only when animations are enabled and Reduce Motion is off; otherwise render a
	/// steady border (static marker), matching the detection-animations setting.
	private var pulses: Bool { animateDetections && reduceMotion.not }

	var body: some View {
		Rectangle()
			.strokeBorder(color, lineWidth: size)
			.blur(radius: size / 3)
			.opacity(overlayOpacity)
			.allowsHitTesting(false)
			.accessibilityHidden(true)
			.animation(activeAnimation, value: dimmed)
			.animation(.easeOut(duration: 0.2), value: active)
			.onChange(of: active, initial: true) { _, isActive in
				// Toggling `dimmed` under a repeatForever animation produces the pulse;
				// when inactive, freeze it (the 0-opacity fade above hides the border).
				// `initial: true` arms the pulse even if the overlay first appears with
				// `active` already true (review: latent static-border bug).
				dimmed = isActive && pulses
			}
			.onChange(of: period) { _, _ in
				// The config sheet pushes live driver updates; a running repeatForever
				// animation keeps its old duration, so re-toggle to restart the pulse
				// at the new period immediately (review: live-update gap).
				guard active, pulses else { return }
				dimmed.toggle()
			}
			.onChange(of: pulses) { _, arePulsing in
				// Toggling the disable-detection-animations setting (or Reduce Motion) mid-flash
				// changes `pulses` without changing `active`; re-arm so an ON flip resumes the
				// pulse immediately instead of waiting for `active` to cycle (AIA-0461 review).
				dimmed = active && arePulsing
			}
	}

	private var overlayOpacity: Double {
		guard active else { return 0 }
		// Reduce Motion or animations disabled: steady border, no pulsing.
		if pulses.not { return 0.8 }
		return dimmed ? 0.15 : 1.0
	}

	private var activeAnimation: Animation? {
		guard active, pulses else { return nil }
		return .easeInOut(duration: period / 2).repeatForever(autoreverses: true)
	}
}

/// Classified-label bubble (AIA-0374, owner request): mirrors Apple's classification
/// sample presentation — top labels + confidence in a rounded panel, shown while the
/// global "Show labels" setting is on. Classification has no boxes to pin labels to,
/// so the bubble floats top-trailing over the content.
struct ClassificationLabelBubble: View {
	let groups: [ClassificationDisplayGroup]

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			ForEach(groups) { group in
				VStack(alignment: .leading, spacing: 2) {
					// With one model the bubble renders exactly as before (no header). The header
					// exists for the comparison workflow: several models enabled at once, each label
					// set attributed to its model by name and by the SAME color its flash/annotations
					// use — so labels can never read as another model's output (AIA-0472).
					if groups.count > 1 {
						HStack(spacing: 4) {
							Circle()
								.fill(group.color)
								.frame(width: 8, height: 8)
								// Decorative: the adjacent model name carries the attribution;
								// VoiceOver reading "circle" here would be noise.
								.accessibilityHidden(true)
							Text(group.modelName)
								.lineLimit(1)
						}
						.font(.caption.weight(.semibold))
						.foregroundStyle(.secondary)
					}
					ForEach(group.labels, id: \.identifier) { label in
						HStack(spacing: 4) {
							Text(label.identifier.capitalized)
								.lineLimit(1)
							Text(verbatim: ":")
							Text(Double(label.confidence), format: .percent.precision(.fractionLength(0)))
						}
						.font(.callout)
					}
				}
			}
		}
		.padding(10)
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
		.allowsHitTesting(false)
	}
}

#if DEBUG
#Preview("Finding flash — toggle pulse") {
	struct FlashPreview: View {
		@State private var active = false
		var body: some View {
			ZStack {
				Color(white: 0.9)
				Text("Tap to toggle the pulse").font(.caption)
				FindingFlashOverlay(active: active, color: .yellow, period: 2.0, size: 8, animateDetections: true)
			}
			.onTapGesture { active.toggle() }
		}
	}
	return FlashPreview()
}
#endif
