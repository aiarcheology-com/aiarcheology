//
//  FindingFlash.swift
//  AI Archeology
//
//  Created by Agent on 2026-07-02.
//

import SwiftUI
import UIKit

/// Style values for the finding flash, passed into `DetectableView` like the other
/// plain scalars (`showIdentifiers`) and refreshed by the call site via `.onReceive` —
/// the view never observes the whole `Settings` object, so unrelated settings writes
/// can't invalidate its body (AIA-0374).
struct FlashStyle: Equatable {
	var enabled: Bool
	var color: Color
	var duration: Double
	var size: Double

	@MainActor
	static func from(_ settings: Settings) -> FlashStyle {
		FlashStyle(
			enabled: settings.flashOnFindingEnabled,
			color: settings.flashColor,
			duration: settings.flashDuration,
			size: settings.flashSize
		)
	}
}

/// Pure trigger rule (AIA-0374): flash when qualifying classifications appear (0→n) or
/// their count increases — so a second model's new finding is never masked by an
/// already-qualifying first one.
enum FlashTrigger {
	static func shouldFlash(oldCount: Int, newCount: Int) -> Bool {
		newCount > 0 && newCount > oldCount
	}
}

/// Consumes classification passes as a parallel branch of the snapshot flow —
/// deliberately independent of the detection queue/appliedFrame machinery (AIA-0374):
/// classification says "there IS an object in this image" (no location), so its
/// presentation is the frame flash, not a bounding box.
@MainActor
final class ClassificationFlashController: ObservableObject {

	/// A driver qualifies when its TOP-1 confidence clears this. Fixed in v1. Model
	/// contract: a model carrying an explicit negative/background class ("no-mound")
	/// will misfire the flash — per-model negative-label handling is a follow-up.
	static let qualifyingConfidenceThreshold: Float = 0.5

	/// Monotonic count of fired flashes: the overlay's animation token and the UI-test
	/// checkpoint value (a counter can't be missed by polling, unlike a transient bool).
	@Published private(set) var flashCount = 0

	/// Number of drivers whose top-1 label currently qualifies — the trigger input and
	/// the `.classificationCount` checkpoint value.
	@Published private(set) var qualifyingCount = 0

	private var isBusy = false

	/// Runs one classification pass if idle. Skip-if-busy: at the 3–10 s snapshot
	/// cadence against a sub-second classify, a dropped frame is near-impossible;
	/// revisit with `SnapshotDetectionQueue`'s one-slot coalesce if this ever flakes.
	func classifyPass(drivers: DeepDrivers, image: UIImage, flashEnabled: Bool) {
		guard isBusy.not else { return }
		isBusy = true
		drivers.classify(on: image) { [weak self] results in
			guard let self else { return }
			self.isBusy = false
			self.ingest(results, flashEnabled: flashEnabled)
		}
	}

	/// Applies one pass's results: updates the qualifying count (publish only on
	/// change, so no-op passes don't re-evaluate observing bodies) and fires the
	/// flash per `FlashTrigger` when enabled.
	func ingest(_ results: [ClassificationResult], flashEnabled: Bool) {
		let newCount = results.count { result in
			(result.labels.map(\.confidence).max() ?? 0) >= Self.qualifyingConfidenceThreshold
		}
		let shouldFlash = FlashTrigger.shouldFlash(oldCount: qualifyingCount, newCount: newCount)
		if qualifyingCount != newCount {
			qualifyingCount = newCount
		}
		if shouldFlash && flashEnabled {
			flashCount += 1
		}
	}

	/// Interaction (scroll/zoom) invalidates what's on screen — mirror detection's
	/// clear semantics so a still-present finding flashes once more after the content
	/// settles and re-classifies (0→n again).
	func resetOnInteraction() {
		if qualifyingCount != 0 {
			qualifyingCount = 0
		}
	}
}

/// Border flash over the detection content. Hit-testing is disabled and the view is
/// hidden from accessibility — it must never intercept content gestures or read as
/// UI (acceptance-level requirements, AIA-0374).
struct FindingFlashOverlay: View {
	let style: FlashStyle
	/// Monotonic token: each increment fires one flash.
	let flashToken: Int

	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@State private var opacity: Double = 0
	@State private var animatingToken = 0

	var body: some View {
		Rectangle()
			.strokeBorder(style.color, lineWidth: style.size)
			.opacity(opacity)
			.allowsHitTesting(false)
			.accessibilityHidden(true)
			.onChange(of: flashToken) { _, newToken in
				guard style.enabled else { return }
				animatingToken = newToken
				var appear = Transaction()
				appear.disablesAnimations = true
				withTransaction(appear) { opacity = 1 }
				if reduceMotion {
					// Reduce Motion: hold the border for the duration, then remove it
					// without an animated fade.
					Task {
						try? await Task.sleep(for: .seconds(style.duration))
						guard animatingToken == newToken else { return } // superseded
						var end = Transaction()
						end.disablesAnimations = true
						withTransaction(end) { opacity = 0 }
					}
				} else {
					withAnimation(.easeOut(duration: style.duration)) {
						opacity = 0
					}
				}
			}
	}
}

#Preview("Finding flash — tap to fire") {
	struct FlashPreview: View {
		@State private var token = 0
		var body: some View {
			ZStack {
				Color(white: 0.9)
				Text("Tap to flash").font(.caption)
				FindingFlashOverlay(
					style: FlashStyle(enabled: true, color: .yellow, duration: 1.0, size: 8),
					flashToken: token
				)
			}
			.onTapGesture { token += 1 }
		}
	}
	return FlashPreview()
}
