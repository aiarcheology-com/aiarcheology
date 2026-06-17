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
/// The drawer-step bubble (and any in-drawer target) is gated on a **non-nil resolved
/// anchor**: `anchorPreference` reports in-flight frames during the drawer-open animation,
/// so the bubble only appears once the target has a settled, resolvable frame.
private struct TourOverlayModifier: ViewModifier {
	@Bindable var tour: TourState

	func body(content: Content) -> some View {
		content
			.overlayPreferenceValue(TourAnchorPreferenceKey.self) { anchors in
				if tour.isActive, let step = tour.currentStep {
					GeometryReader { proxy in
						overlay(step: step, anchors: anchors, proxy: proxy)
					}
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
		let rect = anchors[step.target].map { proxy[$0] }

		ZStack(alignment: .topLeading) {
			TourSpotlight(cutout: rect, onDimTap: { tour.skip() })

			// Cutout-tap fallback for `.userAction` steps: a transparent button over the hole
			// drives the action when a pass-through tap cannot reach the real control (e.g. a
			// toolbar button hosted in a separate layer). `.scripted` steps keep pure
			// pass-through. See `TourState.performCutoutAction()`.
			if let rect, case .userAction = step.advance {
				Color.clear
					.contentShape(Rectangle())
					.frame(width: rect.width, height: rect.height)
					.offset(x: rect.minX, y: rect.minY)
					.onTapGesture { tour.performCutoutAction() }
			}

			// Gate the bubble on a settled, non-nil anchor (mid-animation caveat): no anchor
			// yet → dim only, no mis-placed bubble.
			if let rect {
				bubble(step: step, cutout: rect, container: proxy.size)
			}
		}
	}

	@ViewBuilder
	private func bubble(step: TourStep, cutout: CGRect, container: CGSize) -> some View {
		let bubbleWidth: CGFloat = 300
		let spacing: CGFloat = 16
		// Clamp horizontally so the bubble stays on-screen near edge targets.
		let proposedX = cutout.midX - bubbleWidth / 2
		let x = min(max(proposedX, spacing), max(spacing, container.width - bubbleWidth - spacing))

		TourBubble(
			text: step.bubbleText,
			showsNext: tour.showsNextButton,
			onNext: { tour.advance() },
			onSkip: { tour.skip() }
		)
		.frame(width: bubbleWidth, alignment: .leading)
		.fixedSize(horizontal: false, vertical: true)
		.offset(x: x)
		.modifier(BubbleVerticalOffset(placement: step.placement, cutout: cutout, container: container, spacing: spacing))
	}
}

/// Positions the bubble above or below the cutout, kept inside the container vertically.
private struct BubbleVerticalOffset: ViewModifier {
	let placement: TourBubblePlacement
	let cutout: CGRect
	let container: CGSize
	let spacing: CGFloat

	func body(content: Content) -> some View {
		content.alignmentGuide(.top) { _ in 0 }
			.offset(y: yOffset)
	}

	private var yOffset: CGFloat {
		switch placement {
		case .below:
			return min(cutout.maxY + spacing, container.height - 120)
		case .above:
			// Estimate bubble height; clamp so it never goes off the top.
			return max(cutout.minY - spacing - 120, spacing)
		}
	}
}

extension View {
	/// Attaches the tour overlay once at the app root. Inert while the tour is inactive.
	func tourOverlay(_ tour: TourState) -> some View {
		modifier(TourOverlayModifier(tour: tour))
	}
}
