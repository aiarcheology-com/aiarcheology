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
	/// The PLAY / start-detection button in the top toolbar.
	case playButton
	/// The Find button in the top toolbar (enters finding-capture mode).
	case findButton
	/// The capture step's logical identity (no published anchor — a no-dim step where the user
	/// taps the live map). Used for the step's checkpoint only.
	case captureArea
	/// The Save button inside the finding sheet. Published by `SaveFindingSheet`, which hosts its
	/// own tour layer (the sheet is modal above the root overlay).
	case saveButton
	/// The closing step's logical identity (no anchor — a centered "you're all set" bubble).
	case finished
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
	/// The user performs the real action; the bubble's **Next** appears only once `condition`
	/// holds (or, for sheet-coupled steps, the step auto-advances). The user does the real thing.
	case userAction(AdvanceCondition)
}

/// Explicit, named completion predicate for a `.userAction` step. The user performs the real
/// action on the real control; these signal when it's done (revealing Next, or auto-advancing).
enum AdvanceCondition: Sendable {
	/// The drawer transitioned to open (the user tapped the models button).
	case drawerOpened
	/// The highlighted demo model's enable toggle went false→true (the user flipped it).
	case modelEnabled
	/// Detection started (the user tapped PLAY) — `guide.ontheflyDetectionEnabled`.
	case detectionStarted
	/// Finding-capture mode entered (the user tapped Find) — `guide.findModeRequested`.
	case pickModeEntered
	/// The finding-capture sheet appeared (the user tapped the map). Auto-advances the step.
	case captureStarted
	/// A finding was saved (the user tapped Save inside the sheet). Auto-advances the step.
	case findingSaved

	/// Whether the overlay performs this action via a transparent tap target over the cutout.
	/// True for controls a tap can't reach through the overlay (toolbar buttons; the drawer
	/// toggle): tapping the spotlight runs the real action, which then reveals **Next**. False
	/// for `.captureStarted` (no-dim map tap) and `.findingSaved` (the real Save, reachable under
	/// the in-sheet step's non-blocking dim).
	var isOverlayDriven: Bool {
		switch self {
		case .drawerOpened, .detectionStarted, .pickModeEntered, .modelEnabled: return true
		case .captureStarted, .findingSaved: return false
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
	/// Anchor to spotlight when `target`'s own anchor doesn't resolve. Needed because an
	/// `anchorPreference` published from *inside* a `List` cell (e.g. a model row's toggle)
	/// does not propagate to the root overlay. The enable step keeps its own identity
	/// (`.enableModelToggle`, for checkpoints) but spotlights `.demoModels`.
	let spotlightFallback: TourAnchorID?
	/// Whether this step dims the background. `false` for a step where the user must tap the live
	/// app (the map capture step): the overlay then renders only the bubble, blocking nothing.
	let dimsBackground: Bool
	/// Whether the dim swallows taps on the dimmed area. `false` makes the dim **visual only** so
	/// the user can still interact with everything beneath it — used for the in-sheet save step,
	/// where Save is spotlighted but the title field must stay reachable.
	let dimBlocksTaps: Bool
	/// When the step's action fires, advance immediately instead of revealing **Next**. True for
	/// the two sheet-coupled steps (capture / save), where the modal sheet covers the bubble so a
	/// Next is impossible — the real map/Save tap is the advance.
	let autoAdvancesOnAction: Bool
	/// Rendered by the finding sheet's own tour layer, not the root overlay (the sheet is modal
	/// above the root). The root overlay skips these steps.
	let rendersInSheet: Bool
	/// Title of the bubble's primary button (defaults to "Next"; the closing step uses "Done").
	let primaryButtonTitle: String

	init(
		target: TourAnchorID,
		bubbleText: String,
		placement: TourBubblePlacement,
		advance: TourAdvance,
		spotlightFallback: TourAnchorID? = nil,
		dimsBackground: Bool = true,
		dimBlocksTaps: Bool = true,
		autoAdvancesOnAction: Bool = false,
		rendersInSheet: Bool = false,
		primaryButtonTitle: String = L10n.Tour.next
	) {
		self.id = target
		self.bubbleText = bubbleText
		self.placement = placement
		self.advance = advance
		self.spotlightFallback = spotlightFallback
		self.dimsBackground = dimsBackground
		self.dimBlocksTaps = dimBlocksTaps
		self.autoAdvancesOnAction = autoAdvancesOnAction
		self.rendersInSheet = rendersInSheet
		self.primaryButtonTitle = primaryButtonTitle
	}
}

extension TourStep {
	/// The full onboarding flow (AIA-0333): address bar → models button → demo models →
	/// enable a model → start detection → capture mode → tap the map → save a finding → done.
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
				// The payoff: enabling a demo model. Overlay-driven (a tap can't reach the toggle
				// through the overlay), so tapping the spotlight enables a model and reveals Next.
				// The toggle anchor can't escape the List, so spotlight the demo-models (drawer).
				advance: .userAction(.modelEnabled),
				spotlightFallback: .demoModels
			),
			TourStep(
				target: .playButton,
				bubbleText: L10n.Tour.Play.text,
				placement: .below,
				// Overlay-driven: tapping the spotlighted PLAY button starts detection.
				advance: .userAction(.detectionStarted)
			),
			TourStep(
				target: .findButton,
				bubbleText: L10n.Tour.Find.text,
				placement: .below,
				// Overlay-driven: tapping Find enters capture (pick) mode. Find + the map tap are
				// one continuous pick interaction, so this auto-advances straight to the (tappable)
				// map step rather than asking for a Next in between.
				advance: .userAction(.pickModeEntered),
				autoAdvancesOnAction: true
			),
			TourStep(
				target: .captureArea,
				bubbleText: L10n.Tour.Capture.text,
				placement: .bottom,
				// No dim: the user taps the live map. The Save sheet then opens and covers the
				// bubble, so this step auto-advances the instant capture starts.
				advance: .userAction(.captureStarted),
				dimsBackground: false,
				autoAdvancesOnAction: true
			),
			TourStep(
				target: .saveButton,
				bubbleText: L10n.Tour.Save.text,
				placement: .below,
				// Spotlit inside the finding sheet (the sheet hosts its own tour layer). Tapping
				// the real Save saves the finding and dismisses the sheet, so this auto-advances.
				// Visual-only dim so the title field stays reachable (Save is disabled until named).
				advance: .userAction(.findingSaved),
				dimBlocksTaps: false,
				autoAdvancesOnAction: true,
				rendersInSheet: true
			),
			TourStep(
				target: .finished,
				bubbleText: L10n.Tour.Finished.text,
				placement: .bottom,
				advance: .scripted,
				primaryButtonTitle: L10n.Common.done
			)
		]
	}
}
