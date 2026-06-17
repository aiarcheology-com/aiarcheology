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
	/// The enable toggle of the first demo model.
	case enableModelToggle
}

/// Where the coach-mark bubble sits relative to the spotlight cutout.
enum TourBubblePlacement: Sendable {
	case above
	case below
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

	init(
		target: TourAnchorID,
		bubbleText: String,
		placement: TourBubblePlacement,
		advance: TourAdvance,
		fallbackAfter: TimeInterval = 8
	) {
		self.id = target
		self.bubbleText = bubbleText
		self.placement = placement
		self.advance = advance
		self.fallbackAfter = fallbackAfter
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
				placement: .below,
				advance: .scripted
			),
			TourStep(
				target: .enableModelToggle,
				bubbleText: L10n.Tour.EnableModel.text,
				placement: .above,
				advance: .scripted
			)
		]
	}
}
