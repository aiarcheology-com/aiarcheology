//
//  TourState.swift
//  AI Archeology
//
//  AIA-0333: interactive onboarding spotlight tour — state machine.
//

import SwiftUI
import Observation

/// Drives the interactive onboarding tour: owns the ordered steps, the current index,
/// the per-step no-deadlock timeout, and the gate flag.
///
/// `@MainActor` (and named `*State`, so the architecture rule requires it): every mutation
/// touches UI-driving state and the `DrawerManager`, both main-actor isolated.
@Observable
@MainActor
final class TourState {

	/// UserDefaults key owning the "tour already seen" gate (AIA-0333). Read with
	/// `object(forKey:) != nil` — `bool(forKey:)` cannot distinguish absent from `false`.
	static let gateKey = "hasSeenOnboardingTour"

	/// Legacy key from the deleted slideshow. Used only by the one-shot migration.
	static let legacySlideshowKey = "keepSlideShowActive"

	/// The ordered slice of steps.
	let steps: [TourStep]

	/// Index into `steps`. Meaningful only while `isActive`.
	private(set) var currentIndex: Int = 0

	/// Whether the tour overlay is currently shown.
	private(set) var isActive: Bool = false

	/// Whether the current step's bubble shows its **Next** button. True immediately for teaching
	/// (`.scripted`) steps; for `.userAction` steps it flips to true only once the user performs
	/// the real action, so Next can never advance the tour out of sync with the UI (AIA-0333).
	private(set) var showsNextButton: Bool = false

	private let defaults: UserDefaults
	private weak var drawer: DrawerManager?
	private weak var guide: Guide?

	/// Enables a demo model for the overlay-driven enable step (the toggle can't be tapped
	/// through the overlay). The drawer registers this; the overlay calls it when its cutout is
	/// tapped. Returns `true` if a model was enabled.
	private var enableModelHook: (() -> Bool)?

	/// The current step, or `nil` when inactive / past the end.
	var currentStep: TourStep? {
		guard isActive, steps.indices.contains(currentIndex) else { return nil }
		return steps[currentIndex]
	}

	/// UI-test launches share the ephemeral suite `Settings` clears each launch, so the gate
	/// key never bleeds across scenarios (AIA-0298 isolation, mirrored here).
	private static let uiTestSuiteName = "com.aiarcheology.uitests"

	init(steps: [TourStep] = TourStep.slice, defaults: UserDefaults? = nil) {
		self.steps = steps
		if let defaults {
			self.defaults = defaults
		} else if AppEnvironment.isRunningUITests, let suite = UserDefaults(suiteName: Self.uiTestSuiteName) {
			self.defaults = suite
		} else {
			self.defaults = .standard
		}
	}

	/// Wires the live drawer so the tour can open/close it and observe its state. Called
	/// once from the view layer where the `DrawerManager` is created.
	func bind(drawer: DrawerManager, guide: Guide? = nil) {
		self.drawer = drawer
		if let guide { self.guide = guide }
	}

	/// Registers the drawer's "enable a demo model" action for the overlay-driven enable step.
	func bindEnableModel(_ hook: @escaping () -> Bool) {
		self.enableModelHook = hook
	}

	// MARK: - Gate & migration

	/// Whether the tour has already run to a terminal state for this install.
	var hasSeenTour: Bool {
		defaults.object(forKey: Self.gateKey) != nil
	}

	/// One-shot migration from the deleted slideshow + first-launch auto-start decision.
	///
	/// - If a legacy opt-out is present (`keepSlideShowActive == false`), seed the gate so
	///   we never re-onboard users who already dismissed the old slideshow.
	/// - Otherwise, if the gate is unseen, auto-start the tour.
	///
	/// Idempotent: once the gate exists this is a no-op.
	///
	/// - Returns: `true` if it started the tour, so the caller can stage the onboarding page.
	@discardableResult
	func migrateAndAutostartIfNeeded() -> Bool {
		if hasSeenTour { return false }

		// Legacy opt-out: the user turned the old slideshow off. Don't re-onboard them.
		if defaults.object(forKey: Self.legacySlideshowKey) != nil,
		   defaults.bool(forKey: Self.legacySlideshowKey) == false {
			markSeen()
			return false
		}

		start()
		return true
	}

	private func markSeen() {
		defaults.set(true, forKey: Self.gateKey)
	}

	// MARK: - Lifecycle

	/// Starts (or restarts) the tour from the first step. Does NOT flip the gate — an
	/// interrupted/backgrounded tour must re-arm; the gate flips only on finish/skip.
	func start() {
		guard steps.isEmpty == false else { return }
		// Reset to a clean state so the scripted flow isn't fighting live UI (esp. on Replay):
		// close the drawer, stop any running detection. Fullscreen is suppressed for the whole
		// active window via the `isActive` render gate in ContentView. (drawer/guide are nil on
		// the first-launch autostart — already clean — and bound by the time Replay runs.)
		drawer?.close()
		if guide?.ontheflyDetectionEnabled == true {
			guide?.ontheflyDetectionTapped()
		}
		currentIndex = 0
		isActive = true
		beginStep()
	}

	/// Advances to the next step, or finishes after the last one.
	func advance() {
		guard isActive else { return }
		let next = currentIndex + 1
		if steps.indices.contains(next) {
			currentIndex = next
			beginStep()
		} else {
			finish()
		}
	}

	/// Ends the tour gracefully (slice end / last Next). Flips the gate and cleans up.
	func finish() {
		terminate()
	}

	/// User dismissed the tour early. Same terminal handling as finish.
	func skip() {
		terminate()
	}

	private func terminate() {
		isActive = false
		showsNextButton = false
		markSeen()
	}

	// MARK: - Step setup & advance evaluation

	private func beginStep() {
		guard let step = currentStep else { return }
		// PLAY lives in the main chrome, so close the drawer the user opened on the prior step.
		if step.target == .playButton { drawer?.close() }

		switch step.advance {
		case .scripted:
			// Teaching step: Next is available immediately.
			showsNextButton = true
		case .userAction:
			// Action step: Next stays hidden until the user performs the real action, so it can
			// never advance the tour out of sync with the UI.
			showsNextButton = false
		}
	}

	/// Poked by the view layer when observed app state changes (drawer opened, detection started,
	/// capture mode entered). Reveals **Next** once the current action step's condition holds —
	/// the user then taps Next — or auto-advances the sheet-coupled steps (capture / save), which
	/// can't show a Next because the modal sheet covers the bubble.
	func evaluate() {
		guard isActive, let step = currentStep else { return }
		guard case .userAction(let condition) = step.advance, isSatisfied(condition) else { return }
		actionFulfilled(step)
	}

	/// Marks the current action step's required action as done: auto-advance for sheet steps,
	/// otherwise reveal Next for the user to tap.
	private func actionFulfilled(_ step: TourStep) {
		if step.autoAdvancesOnAction {
			advance()
		} else {
			showsNextButton = true
		}
	}

	private func isSatisfied(_ condition: AdvanceCondition) -> Bool {
		switch condition {
		case .drawerOpened:
			return drawer?.isOpen == true
		case .detectionStarted:
			return guide?.ontheflyDetectionEnabled == true
		case .pickModeEntered:
			return guide?.findModeRequested == true
		case .modelEnabled, .captureStarted, .findingSaved:
			// Event-driven (no app-state poll): signalled by userEnabledModel() / captureDidStart()
			// / findingDidSave() respectively.
			return false
		}
	}

	/// Performs the current step's overlay-driven action (its spotlighted control can't be tapped
	/// through the overlay). The action's effect then reveals **Next**: drawer/detection/pick-mode
	/// changes are observed by the view layer, which pokes `evaluate()`; the model-enable has no
	/// such observer, so it reveals Next directly. The user then taps Next to advance.
	func performCutoutAction() {
		guard isActive, let step = currentStep, case .userAction(let condition) = step.advance else { return }
		switch condition {
		case .drawerOpened:
			drawer?.open()
		case .detectionStarted:
			guide?.ontheflyDetectionTapped()
		case .pickModeEntered:
			guide?.findTapped()
		case .modelEnabled:
			if enableModelHook?() == true { actionFulfilled(step) }
		case .captureStarted, .findingSaved:
			break // not overlay-driven
		}
	}

	/// The highlighted model's enable toggle went on (real tap, if it ever reaches). Reveals Next.
	func userEnabledModel() {
		guard isActive, let step = currentStep, case .userAction(.modelEnabled) = step.advance else { return }
		actionFulfilled(step)
	}

	/// The finding-capture sheet appeared (the user tapped the map). Advances the capture step.
	func captureDidStart() {
		guard isActive, let step = currentStep, case .userAction(.captureStarted) = step.advance else { return }
		actionFulfilled(step)
	}

	/// A ready `Finding` was newly saved (the user tapped Save). Advances the in-sheet save step.
	func findingDidSave() {
		guard isActive, let step = currentStep, case .userAction(.findingSaved) = step.advance else { return }
		actionFulfilled(step)
	}

	/// The finding sheet was dismissed without saving (Cancel / swipe). If still on the in-sheet
	/// save step, step back to the capture step so the user can tap the map again. No-op once a
	/// finding was saved (the step has already advanced).
	func captureCancelled() {
		guard isActive, let step = currentStep, case .userAction(.findingSaved) = step.advance else { return }
		guard currentIndex > 0 else { return }
		currentIndex -= 1
		beginStep()
	}

	/// The bubble's **Next** button — only visible for teaching steps or once an action step's
	/// real action is done, so this simply advances.
	func bubblePrimaryTapped() {
		guard isActive else { return }
		advance()
	}
}
