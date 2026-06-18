//
//  TourOverlay.swift
//  AI Archeology
//
//  AIA-0333: interactive onboarding spotlight tour — root overlay.
//

import SwiftUI

/// The single root overlay (attached once at `ContentView`). Reads the active step's target
/// anchor via `overlayPreferenceValue`, then renders the dim+cutout and the coach-mark
/// bubble positioned relative to the cutout.
///
/// The **bubble always renders** so a step can never become a dead-end blank dim: when the
/// target anchor hasn't settled yet (e.g. mid drawer-open animation) the cutout is withheld but
/// the bubble is centered instead of pointing at a hole. A `dimsBackground == false` step (the
/// map-capture step) renders only the bubble — no dim, no cutout — so the user's tap reaches the
/// live app beneath.
private struct TourOverlayModifier: ViewModifier {
	@Bindable var tour: TourState
	/// `false` for the root overlay (renders non-sheet steps); `true` for the overlay hosted
	/// inside the finding sheet (renders only `rendersInSheet` steps).
	var inSheet: Bool = false

	/// Measured height of the current bubble, read back via `TourBubbleHeightKey`. Used to
	/// clamp the bubble on-screen so long / localized / Dynamic-Type copy can't push it off.
	@State private var bubbleHeight: CGFloat = 0

	func body(content: Content) -> some View {
		content
			.overlayPreferenceValue(TourAnchorPreferenceKey.self) { anchors in
				// The sheet's `rendersInSheet` step is drawn only by the in-sheet overlay (the
				// sheet is modal above the root); the root draws every other step.
				if tour.isActive, let step = tour.currentStep, step.rendersInSheet == inSheet {
					GeometryReader { proxy in
						overlay(step: step, anchors: anchors, proxy: proxy)
					}
					// Resolve anchors and draw in full-screen coordinates. Without this the
					// GeometryReader sits in safe-area space while `TourSpotlight` draws with
					// `.ignoresSafeArea()`, so every cutout was shifted up by the top inset.
					.ignoresSafeArea()
					.transition(.opacity)
					// UI-test introspection: the active step's target id.
					.checkpoint(.tourStep, value: step.target.rawValue)
				}
			}
	}

	@ViewBuilder
	private func overlay(
		step: TourStep,
		anchors: [TourAnchorID: Anchor<CGRect>],
		proxy: GeometryProxy
	) -> some View {
		// Prefer the step's own target anchor; fall back to its `spotlightFallback` when that
		// anchor can't resolve (e.g. a List-cell target — see `TourStep.spotlightFallback`).
		let anchor = anchors[step.target] ?? step.spotlightFallback.flatMap { anchors[$0] }
		let rect = anchor.map { proxy[$0] }

		ZStack(alignment: .topLeading) {
			// A no-dim step (the map-capture step) renders ONLY the bubble — no dim, no hole-block —
			// so the user's tap reaches the live app beneath.
			if step.dimsBackground {
				// Four-rectangle dim with an open hole: the real control in the hole is tappable.
				TourSpotlight(cutout: rect, blocksTaps: step.dimBlocksTaps)

				// A transparent tap target over the cutout. Teaching (`.scripted`) steps swallow
				// the tap so the spotlighted element isn't interactive (the user just taps Next —
				// this also stops the address-bar step from opening the location sheet).
				// Overlay-driven action steps run the real action (a tap can't reach the toolbar
				// button / drawer toggle through the overlay); the action's effect then reveals
				// Next. See `TourState.performCutoutAction()`.
				if let rect, cutoutTapTarget(for: step) != nil {
					Color.clear
						.contentShape(Rectangle())
						.frame(width: rect.width, height: rect.height)
						.offset(x: rect.minX, y: rect.minY)
						.onTapGesture { cutoutTapTarget(for: step)?() }
				}
			}

			// The bubble (which carries Skip / Next) always renders so a step can never become
			// a dead-end blank dim — if the target anchor hasn't settled yet it is centered
			// instead of pointing at a cutout.
			bubble(step: step, cutout: step.dimsBackground ? rect : nil, container: proxy.size)
		}
	}

	/// The action (if any) for a transparent tap target over the cutout:
	/// - teaching (`.scripted`) → a no-op that swallows the tap (the element isn't interactive);
	/// - overlay-driven action → run the real action via `performCutoutAction()`;
	/// - non-overlay-driven action (map / in-sheet Save) → `nil` (the user taps the real control).
	private func cutoutTapTarget(for step: TourStep) -> (() -> Void)? {
		if case .scripted = step.advance { return { } }
		if case .userAction(let condition) = step.advance, condition.isOverlayDriven {
			return { tour.performCutoutAction() }
		}
		return nil
	}

	@ViewBuilder
	private func bubble(step: TourStep, cutout: CGRect?, container: CGSize) -> some View {
		let bubbleWidth: CGFloat = 300
		let spacing: CGFloat = 16
		// Clamp horizontally so the bubble stays on-screen near edge targets. With no settled
		// anchor, center it.
		let anchorX = cutout?.midX ?? container.width / 2
		let proposedX = anchorX - bubbleWidth / 2
		let clampedX = min(max(proposedX, spacing), max(spacing, container.width - bubbleWidth - spacing))

		TourBubble(
			text: step.bubbleText,
			nextTitle: step.primaryButtonTitle,
			showsNext: tour.showsNextButton,
			onNext: { tour.bubblePrimaryTapped() },
			onSkip: { tour.skip() }
		)
		.frame(width: bubbleWidth, alignment: .leading)
		.fixedSize(horizontal: false, vertical: true)
		.background(
			GeometryReader { geo in
				Color.clear.preference(key: TourBubbleHeightKey.self, value: geo.size.height)
			}
		)
		.onPreferenceChange(TourBubbleHeightKey.self) { bubbleHeight = $0 }
		.offset(x: clampedX)
		.modifier(BubbleVerticalOffset(
			placement: step.placement,
			cutout: cutout,
			container: container,
			spacing: spacing,
			bubbleHeight: bubbleHeight
		))
	}
}

/// The measured rendered height of `TourBubble`, used to clamp it on-screen.
private struct TourBubbleHeightKey: PreferenceKey {
	static let defaultValue: CGFloat = 0
	static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
		value = max(value, nextValue())
	}
}

/// Positions the bubble above or below the cutout, kept inside the container vertically.
private struct BubbleVerticalOffset: ViewModifier {
	let placement: TourBubblePlacement
	/// The resolved cutout, or `nil` when the target anchor hasn't settled (bubble centers).
	let cutout: CGRect?
	let container: CGSize
	let spacing: CGFloat
	/// Measured bubble height (0 until the first layout pass reports it).
	let bubbleHeight: CGFloat

	func body(content: Content) -> some View {
		content.alignmentGuide(.top) { _ in 0 }
			.offset(y: yOffset)
	}

	private var yOffset: CGFloat {
		switch placement {
		case .bottom:
			// Pinned near the bottom, clear of the home indicator, regardless of the cutout —
			// keeps top-anchored content (the drawer's model list) fully visible.
			return max(spacing, container.height - bubbleHeight - homeIndicatorClearance)
		case .below:
			guard let cutout else { return centeredY }
			// Keep the whole measured bubble inside the bottom edge.
			let maxTop = max(spacing, container.height - bubbleHeight - spacing)
			return min(cutout.maxY + spacing, maxTop)
		case .above:
			guard let cutout else { return centeredY }
			// Use the measured height so long / localized / Dynamic-Type copy can't go off the top.
			return max(cutout.minY - spacing - bubbleHeight, spacing)
		}
	}

	/// Centered vertically — used when a cutout-relative placement has no settled anchor.
	private var centeredY: CGFloat { max(spacing, (container.height - bubbleHeight) / 2) }

	/// Bottom margin that keeps the bubble (and its Skip/Next buttons) clear of the home indicator.
	private var homeIndicatorClearance: CGFloat { 44 }
}

extension View {
	/// Attaches the tour overlay once at the app root. Inert while the tour is inactive.
	/// `inSheet: true` is used inside the finding sheet to render the in-sheet step (Save) only.
	func tourOverlay(_ tour: TourState, inSheet: Bool = false) -> some View {
		modifier(TourOverlayModifier(tour: tour, inSheet: inSheet))
	}
}
