//
//  TourStep.swift
//  AI Archeology
//
//  AIA-0333: interactive onboarding spotlight tour — step model.
//

import SwiftUI

/// Stable identity for each element the tour can spotlight. Marked on a view with
/// `.tourTarget(_:)` and read back through anchor preferences by `TourOverlay`.
///
/// A plain enum (not a stringly typed identifier): the overlay matches the active step's
/// `target` against these cases, so identity survives release builds / symbol stripping.
enum TourAnchorID: String, Hashable, CaseIterable, Sendable {
	/// The web address bar in the top toolbar.
	case addressBar
	/// The CPU / models button that opens the drawer.
	case modelsButton
	/// The list of demo detection models inside the drawer.
	case demoModels
	/// The enable-model step's logical identity. Not published as a `.tourTarget` (an anchor
	/// inside a `List` cell wouldn't reach the overlay); the step spotlights `.demoModels` via
	/// `TourStep.spotlightFallback` instead.
	case enableModelToggle
}

/// Where the coach-mark bubble sits relative to the spotlight cutout.
enum TourBubblePlacement: Sendable {
	case above
	case below
	/// Pinned near the bottom of the screen, independent of the cutout. Used when the cutout is
	/// near the top (e.g. the drawer's model list) so the bubble doesn't cover the very content
	/// it describes.
	case bottom
}

/// How a step is allowed to advance to the next one.
enum TourAdvance: Sendable {
	/// A pure/teaching transition: the bubble shows a **Next** button immediately.
	case scripted
	/// The user performs a real action; advance fires when `condition` becomes true.
	/// A per-step timeout still surfaces **Next** so the step can never deadlock.
	case userAction(AdvanceCondition)
}

/// Explicit, named completion predicate for a `.userAction` step. Evaluated on the main
/// actor whenever `TourState.evaluate()` is poked by an observed app-state change.
enum AdvanceCondition: Sendable {
	/// The drawer transitioned to open (step 2: tapping the models button).
	case drawerOpened
	/// The highlighted demo model's enable toggle went false→true (step 4). Driven by
	/// `TourState.userEnabledModel()`, not by a polled app-state change.
	case modelEnabled

	/// Whether the overlay drives this action via a transparent tap target over the cutout.
	/// `.drawerOpened` is overlay-driven: a tap on the spotlighted models button opens the
	/// drawer (the button itself is in a separate UIKit layer a pass-through tap can't reach,
	/// and the drawer is closed so the overlay tap target works). `.modelEnabled` is **not**:
	/// the toggle sits inside the open drawer beneath the dim, where neither a pass-through tap
	/// nor an overlay tap target reaches it — that step is driven by the bubble's button instead.
	var isOverlayDriven: Bool {
		switch self {
		case .drawerOpened: return true
		case .modelEnabled: return false
		}
	}
}

/// One scripted step of the tour.
struct TourStep: Identifiable, Sendable {
	let id: TourAnchorID
	/// Element the spotlight cuts out and the bubble points at.
	var target: TourAnchorID { id }
	/// Localized coach-mark copy.
	let bubbleText: String
	/// Bubble position relative to the cutout.
	let placement: TourBubblePlacement
	/// How this step advances.
	let advance: TourAdvance
	/// Seconds before the step surfaces a **Next** button as a no-deadlock fallback.
	/// `.scripted` steps show **Next** immediately, so this only matters for `.userAction`.
	let fallbackAfter: TimeInterval
	/// Anchor to spotlight when `target`'s own anchor doesn't resolve. Needed because an
	/// `anchorPreference` published from *inside* a `List` cell (e.g. a model row's toggle)
	/// does not propagate to the root overlay — only `Section`-level anchors do. The enable
	/// step keeps its own identity (`.enableModelToggle`, for checkpoints) but spotlights the
	/// `.demoModels` section, whose hole covers the toggles so the real tap passes through.
	let spotlightFallback: TourAnchorID?

	init(
		target: TourAnchorID,
		bubbleText: String,
		placement: TourBubblePlacement,
		advance: TourAdvance,
		fallbackAfter: TimeInterval = 8,
		spotlightFallback: TourAnchorID? = nil
	) {
		self.id = target
		self.bubbleText = bubbleText
		self.placement = placement
		self.advance = advance
		self.fallbackAfter = fallbackAfter
		self.spotlightFallback = spotlightFallback
	}
}

extension TourStep {
	/// The first vertical slice (AIA-0333): address bar → models button → demo models →
	/// enable toggle. Remaining steps are explicit follow-ups.
	@MainActor
	static var slice: [TourStep] {
		[
			TourStep(
				target: .addressBar,
				bubbleText: L10n.Tour.AddressBar.text,
				placement: .below,
				advance: .scripted
			),
			TourStep(
				target: .modelsButton,
				bubbleText: L10n.Tour.ModelsButton.text,
				placement: .below,
				// The real action — tapping the button opens the drawer.
				advance: .userAction(.drawerOpened)
			),
			TourStep(
				target: .demoModels,
				bubbleText: L10n.Tour.DemoModels.text,
				// Bottom-pinned: the model list sits at the top of the drawer, so a bubble next to
				// it would cover the very models it describes.
				placement: .bottom,
				advance: .scripted
			),
			TourStep(
				target: .enableModelToggle,
				bubbleText: L10n.Tour.EnableModel.text,
				placement: .bottom,
				// The payoff action: enabling a demo model advances the tour. The toggle's own
				// anchor can't escape the List, so spotlight the demo-models section instead —
				// its hole covers the toggles, so the user's tap passes through to one.
				advance: .userAction(.modelEnabled),
				spotlightFallback: .demoModels
			)
		]
	}
}
