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

	/// Whether the current step has surfaced its **Next** fallback button. Always true for
	/// `.scripted` steps; flips to true for `.userAction` steps once the timeout fires.
	private(set) var showsNextButton: Bool = false

	/// Bumped on every step change / terminal transition. A timeout task captures the value
	/// it was scheduled under and re-checks it after `Task.sleep`, so a stale timeout from a
	/// previous step can never mutate a later one (Codex finding).
	private var stepGeneration: Int = 0

	/// The cancellable per-step timeout. Cancelled on advance/finish/skip.
	private var timeoutTask: Task<Void, Never>?

	private let defaults: UserDefaults
	private weak var drawer: DrawerManager?

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
	func bind(drawer: DrawerManager) {
		self.drawer = drawer
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
	func migrateAndAutostartIfNeeded() {
		if hasSeenTour { return }

		// Legacy opt-out: the user turned the old slideshow off. Don't re-onboard them.
		if defaults.object(forKey: Self.legacySlideshowKey) != nil,
		   defaults.bool(forKey: Self.legacySlideshowKey) == false {
			markSeen()
			return
		}

		start()
	}

	private func markSeen() {
		defaults.set(true, forKey: Self.gateKey)
	}

	// MARK: - Lifecycle

	/// Starts (or restarts) the tour from the first step. Does NOT flip the gate — an
	/// interrupted/backgrounded tour must re-arm; the gate flips only on finish/skip.
	func start() {
		guard steps.isEmpty == false else { return }
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
		cancelTimeout()
		isActive = false
		showsNextButton = false
		markSeen()
		// Drawer-staging cleanup returns when a future tour step opens the drawer itself; in
		// this slice the user always opens the drawer, so the tour never owns it and there is
		// nothing to revert on finish/skip.
	}

	// MARK: - Step setup & advance evaluation

	private func beginStep() {
		cancelTimeout()
		stepGeneration += 1
		guard let step = currentStep else { return }

		switch step.advance {
		case .scripted:
			// Teaching step: Next is available immediately.
			showsNextButton = true
		case .userAction:
			showsNextButton = false
			scheduleTimeout(for: step, generation: stepGeneration)
		}
	}

	/// Re-evaluates the current `.userAction` step against an app-state change. The view
	/// layer pokes this from the observers it already has (e.g. drawer open/close).
	func evaluate() {
		guard isActive, let step = currentStep else { return }
		guard case .userAction(let condition) = step.advance else { return }
		if isSatisfied(condition) {
			advance()
		}
	}

	private func isSatisfied(_ condition: AdvanceCondition) -> Bool {
		switch condition {
		case .drawerOpened:
			return drawer?.isOpen == true
		case .modelEnabled:
			// Driven by `userEnabledModel()`; there is no app-state poll for this, so a plain
			// `evaluate()` never satisfies it.
			return false
		}
	}

	/// Fallback path for the current `.userAction` step: the overlay drives the highlighted
	/// action itself when a tap inside the cutout cannot pass through to the real control
	/// (e.g. a toolbar button hosted in a separate layer). Documented trade-off: this bypasses
	/// the control's own disabled/accessibility state, so it is a fallback, not the default.
	func performCutoutAction() {
		guard isActive, let step = currentStep else { return }
		guard case .userAction(let condition) = step.advance else { return }
		switch condition {
		case .drawerOpened:
			// Opening via the manager flows through ContentView's drawer observer, which pokes
			// `evaluate()` and advances the step.
			drawer?.open()
		case .modelEnabled:
			// No overlay-driven enable: the user must flip the highlighted model's toggle. The
			// per-step timeout still surfaces Next, so the step can't deadlock.
			break
		}
	}

	// MARK: - Timeout (no-deadlock fallback)

	private func scheduleTimeout(for step: TourStep, generation: Int) {
		let delay = step.fallbackAfter
		// A non-finite or non-positive delay must never reach `UInt64(...)` (it traps on
		// NaN/∞/negative). Surface Next immediately instead of sleeping.
		guard delay.isFinite, delay > 0 else {
			showsNextButton = true
			return
		}
		let nanoseconds = UInt64(delay * 1_000_000_000)
		timeoutTask = Task { [weak self] in
			try? await Task.sleep(nanoseconds: nanoseconds)
			guard Task.isCancelled == false else { return }
			guard let self else { return }
			// Generation guard: a stale timeout must not surface Next on a later step.
			guard generation == self.stepGeneration else { return }
			self.showsNextButton = true
		}
	}

	private func cancelTimeout() {
		timeoutTask?.cancel()
		timeoutTask = nil
	}

	// MARK: - User-action hooks

	/// Called from the model row's enable toggle when the highlighted demo model goes
	/// false→true. Advances the enable-model step iff its condition is `.modelEnabled`. A
	/// no-op otherwise, so a stray enable elsewhere in the tour can't skip a step.
	func userEnabledModel() {
		guard isActive, let step = currentStep else { return }
		guard case .userAction(.modelEnabled) = step.advance else { return }
		advance()
	}
}
