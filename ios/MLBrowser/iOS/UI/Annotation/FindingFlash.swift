//
//  FindingFlash.swift
//  AI Archeology
//
//  Created by Agent on 2026-07-02.
//

import SwiftUI
import UIKit

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

	/// Top labels of the first classificator's latest pass — shown in the label
	/// bubble when "Show labels" is on. Independent of the flash threshold, so the
	/// user can see what the model thinks even when nothing qualifies (AIA-0374).
	@Published private(set) var displayLabels: [ClassifiedLabel] = []

	/// Invalidation token: passes started before the last interaction/capture/geometry
	/// invalidation must not ingest (detection re-checks its generation at completion;
	/// this is the same guard for the parallel branch).
	private var generation = 0
	private var isBusy = false

	/// Runs one classification pass if idle. Skip-if-busy: at the 3–10 s snapshot
	/// cadence against a sub-second classify, a dropped frame is near-impossible;
	/// revisit with `SnapshotDetectionQueue`'s one-slot coalesce if this ever flakes.
	func classifyPass(drivers: DeepDrivers, image: UIImage) {
		guard isBusy.not else { return }
		isBusy = true
		let startedGeneration = generation
		drivers.classify(on: image) { [weak self] results in
			guard let self else { return }
			self.isBusy = false
			// The frame this pass classified was invalidated mid-flight
			// (scroll/capture/rotation) — its results must not drive the flash.
			guard startedGeneration == self.generation else { return }
			self.ingest(results)
		}
	}

	/// Applies one pass's results: updates the qualifying state and the active
	/// per-model flash style (publish only on change, so no-op passes don't
	/// re-evaluate observing bodies).
	func ingest(_ results: [ClassificationResult]) {
		let labels = (results.first?.labels ?? [])
			.filter { $0.confidence >= Self.displayConfidenceFloor }
			.sorted { $0.confidence > $1.confidence }
			.prefix(Self.displayLabelCount)
		let newDisplay = Array(labels)
		if displayLabels != newDisplay { displayLabels = newDisplay }

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
		if qualifyingCount != 0 {
			qualifyingCount = 0
		}
		if displayLabels.isEmpty.not {
			displayLabels = []
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

	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@State private var dimmed = false

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
				dimmed = isActive && reduceMotion.not
			}
			.onChange(of: period) { _, _ in
				// The config sheet pushes live driver updates; a running repeatForever
				// animation keeps its old duration, so re-toggle to restart the pulse
				// at the new period immediately (review: live-update gap).
				guard active, reduceMotion.not else { return }
				dimmed.toggle()
			}
	}

	private var overlayOpacity: Double {
		guard active else { return 0 }
		// Reduce Motion: steady border, no pulsing.
		if reduceMotion { return 0.8 }
		return dimmed ? 0.15 : 1.0
	}

	private var activeAnimation: Animation? {
		guard active, reduceMotion.not else { return nil }
		return .easeInOut(duration: period / 2).repeatForever(autoreverses: true)
	}
}

/// Classified-label bubble (AIA-0374, owner request): mirrors Apple's classification
/// sample presentation — top labels + confidence in a rounded panel, shown while the
/// global "Show labels" setting is on. Classification has no boxes to pin labels to,
/// so the bubble floats top-trailing over the content.
struct ClassificationLabelBubble: View {
	let labels: [ClassifiedLabel]

	var body: some View {
		VStack(alignment: .leading, spacing: 2) {
			ForEach(labels, id: \.identifier) { label in
				HStack(spacing: 4) {
					Text(label.identifier.capitalized)
						.lineLimit(1)
					Text(verbatim: ":")
					Text(Double(label.confidence), format: .percent.precision(.fractionLength(0)))
				}
				.font(.callout)
			}
		}
		.padding(10)
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
		.allowsHitTesting(false)
	}
}

#Preview("Finding flash — toggle pulse") {
	struct FlashPreview: View {
		@State private var active = false
		var body: some View {
			ZStack {
				Color(white: 0.9)
				Text("Tap to toggle the pulse").font(.caption)
				FindingFlashOverlay(active: active, color: .yellow, period: 2.0, size: 8)
			}
			.onTapGesture { active.toggle() }
		}
	}
	return FlashPreview()
}
