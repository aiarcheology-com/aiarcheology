//
//  TourState.swift
//  AI Archeology
//
//  AIA-0333: interactive onboarding spotlight tour — state machine.
//

import SwiftUI
import Observation

/// Drives the interactive onboarding tour: owns the ordered steps, the current index, whether
/// the bubble's **Next** is shown, and the "seen" gate. Action steps reveal Next only once the
/// user performs the real action (signalled by the view layer); Skip is the only dismissal.
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

	/// UserDefaults key recording that the payments-off Welcome screen has been presented
	/// (AIA-0955). Read with `object(forKey:) != nil`, like ``gateKey``.
	static let introductionShownKey = "hasShownOnboardingIntroduction"

	/// The ordered slice of steps.
	let steps: [TourStep]

	/// Index into `steps`. Meaningful only while `isActive`.
	private(set) var currentIndex: Int = 0

	/// Whether the tour overlay is currently shown.
	private(set) var isActive: Bool = false

	/// Whether a first-launch tour has been decided on but not yet started (AIA-0567).
	///
	/// The tour used to start the instant `AppState.initialize()` decided it should, which is why it
	/// ran *before* the day-0 paywall: it was simply already going. AIA-0567 puts the Welcome screen
	/// first, so the decision and the start had to come apart — the decision still happens in
	/// `initialize()`, before `isReady` and before anything renders, and the start waits for whoever
	/// owns the screen to hand it over.
	///
	/// Armed **before the first frame** on purpose. Every consumer of ``isPendingOrRunning`` asks
	/// "does onboarding still owe this user a turn", and a flag that only became true later would
	/// answer no on exactly the launch where it matters.
	private(set) var isArmed: Bool = false

	/// Whether onboarding still owes this user its turn — armed and waiting, or running (AIA-0567).
	///
	/// Both halves are stored properties, so `@Observable` tracks them and a view reading this
	/// re-renders when either moves. That is the whole reason this is not `hasSeenTour`, which reads
	/// `UserDefaults` — observation does not see that write, so a gate deferring on it would never
	/// learn the tour had finished.
	var isPendingOrRunning: Bool { isArmed || isActive }

	/// Whether this onboarding still owes the user the Welcome screen that introduces it when
	/// payments are off (AIA-0955).
	///
	/// With payments on, the Welcome screen belongs to the free-access window, which records its
	/// own presentation durably. With payments off there is no window, so the introduction needs a
	/// receipt of its own — and it belongs here, because it lives and dies with onboarding: owed
	/// only when a tour is armed, so a returning install whose tour is long done is never
	/// introduced to an app it already uses.
	///
	/// **Written at presentation, and durably.** ``gateKey`` is written only when the tour reaches
	/// a terminal state, so an in-memory receipt would put the Welcome screen back in front of a
	/// tour the user had already started, after a force-quit halfway through it — the payments-on
	/// path, whose `day0Shown` marker is also written at presentation, shows only the tour again.
	///
	/// **Either Welcome counts, including one recorded before this receipt existed.** 1.0.7 and
	/// 1.0.8 kept the priced Welcome's receipt only in the free-access window;
	/// ``adoptEarlierWelcomeReceipt(dayZeroWelcomeShown:)`` carries it over at launch, before the
	/// first frame (AIA-1036).
	///
	/// Stored, so `@Observable` tracks it; the gate reads it next to the payments flag, which is
	/// the half that decides whether the introduction is the screen to show at all.
	private(set) var isIntroductionOwed = false

	/// Whether the run in progress is this install's first, as opposed to a Settings → Replay
	/// (AIA-0567). Gates the terminal funnel events; see ``startIfArmed()``.
	private var isFirstRun = false

	/// Whether the current step's bubble shows its **Next** button. True immediately for teaching
	/// (`.scripted`) steps; for `.userAction` steps it flips to true only once the user performs
	/// the real action, so Next can never advance the tour out of sync with the UI (AIA-0333).
	private(set) var showsNextButton: Bool = false

	private let defaults: UserDefaults
	private weak var drawer: DrawerManager?
	private weak var chromeState: AppChromeState?
	private weak var detectionState: DetectionSessionState?

	/// Enables a demo model for the overlay-driven enable step (the toggle can't be tapped
	/// through the overlay). The drawer registers this; the overlay calls it when its cutout is
	/// tapped. Returns `true` if a model was enabled.
	private var enableModelHook: (() -> Bool)?

	/// Whether the drawer is currently ringing a specific model switch (AIA-0757 A4).
	///
	/// The root overlay reads it to decide whether *it* should ring the cutout as well. A step that
	/// spotlights through `spotlightFallback` has the whole drawer as its cutout, so ringing that
	/// says only "press somewhere in here" — worth suppressing while a single switch is pointed at,
	/// but the only affordance there is when none can be. That happens on a replay where every demo
	/// model is already enabled: the step's goal already holds, and the drawer has no off switch to
	/// ring, yet the user still has to tap to move on.
	private(set) var drawerHighlightsModelSwitch = false

	/// Told by the drawer as its pulse target appears and disappears.
	func setDrawerHighlightsModelSwitch(_ isHighlighting: Bool) {
		guard drawerHighlightsModelSwitch != isHighlighting else { return }
		drawerHighlightsModelSwitch = isHighlighting
	}

	/// The current step, or `nil` when inactive / past the end.
	var currentStep: TourStep? {
		guard isActive, steps.indices.contains(currentIndex) else { return nil }
		return steps[currentIndex]
	}

	/// Whether the tour is currently on the in-sheet "save the finding" step — the finding sheet
	/// reads this to pre-fill a title so its spotlighted Save button is immediately enabled.
	var isOnSaveStep: Bool { currentStep?.target == .saveButton }

	/// UI-test launches share the ephemeral suite `Settings` clears each launch, so the gate
	/// key never bleeds across scenarios (AIA-0298 isolation, mirrored here).
	private static let uiTestSuiteName = "com.aiarcheology.uitests"

	/// The funnel this onboarding feeds (AIA-0567). Optional and defaulted, the same bolt-on pattern
	/// ``FreeAccessState`` uses: analytics is something the feature must work without, and every test
	/// that is not about reporting can leave it out.
	private let analytics: AnalyticsState?

	init(
		steps: [TourStep] = TourStep.slice,
		defaults: UserDefaults? = nil,
		analytics: AnalyticsState? = nil
	) {
		self.steps = steps
		self.analytics = analytics
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
	func bind(drawer: DrawerManager, chromeState: AppChromeState? = nil, detectionState: DetectionSessionState? = nil) {
		self.drawer = drawer
		if let chromeState { self.chromeState = chromeState }
		if let detectionState { self.detectionState = detectionState }
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

	/// One-shot migration from the deleted slideshow + first-launch **arming** decision (AIA-0567).
	///
	/// - If a legacy opt-out is present (`keepSlideShowActive == false`), seed the gate so
	///   we never re-onboard users who already dismissed the old slideshow.
	/// - Otherwise, if the gate is unseen, arm the tour.
	///
	/// Idempotent: once the gate exists this is a no-op.
	///
	/// This used to call ``start()`` directly, and the rename is the ticket. The tour now runs
	/// *after* the day-0 Welcome screen, so the caller can no longer both decide and begin — see
	/// ``isArmed``. The return value is unchanged in meaning: `true` says onboarding is owed, which
	/// is still what tells the caller to stage the demo page.
	///
	/// - Returns: `true` if it armed the tour, so the caller can stage the onboarding page.
	@discardableResult
	func migrateAndArmIfNeeded() -> Bool {
		if hasSeenTour { return false }

		// Legacy opt-out: the user turned the old slideshow off. Don't re-onboard them.
		if defaults.object(forKey: Self.legacySlideshowKey) != nil,
		   defaults.bool(forKey: Self.legacySlideshowKey) == false {
			markSeen()
			return false
		}

		arm()
		return true
	}

	/// Marks onboarding as owed without starting it. Also the UI-test entry point (AIA-0567).
	///
	/// Separate from ``migrateAndArmIfNeeded()`` because UI tests opt in explicitly by launch flag
	/// and must not run the migration — but they must arm through the *same* mechanism the app uses,
	/// or the suite would exercise a start path production does not have.
	func arm() {
		guard steps.isEmpty == false, isActive == false else { return }
		isArmed = true
		isIntroductionOwed = defaults.object(forKey: Self.introductionShownKey) == nil
	}

	/// Records that a Welcome screen — either one — is on screen ahead of this onboarding, so the
	/// payments-off introduction is never owed again (AIA-0955). Called at presentation, for the
	/// reason ``isIntroductionOwed`` gives.
	func markIntroductionShown() {
		defaults.set(true, forKey: Self.introductionShownKey)
		isIntroductionOwed = false
	}

	/// Carries over a priced Welcome screen that was recorded before this receipt existed
	/// (AIA-1036).
	///
	/// 1.0.7 and 1.0.8 showed the priced Welcome ahead of the tour and recorded it only in the
	/// free-access window (`day0Shown`); ``introductionShownKey`` arrived in 1.0.9. A user of those
	/// builds who met that screen and never finished the tour is armed again here with no receipt,
	/// so once payments are off ``arm()`` alone would owe them the introduction — a second Welcome.
	/// Writing the existing key leaves them exactly where a 1.0.9 user who met the priced screen
	/// already is.
	///
	/// A no-op unless an introduction is currently owed, so installs with no armed tour gain no write.
	/// Called once per launch, after the free-access window has been reconciled and before the root
	/// gate's first frame — a durable back-fill rather than another input to the gate's
	/// presentation decision, which is read during `body` and could not observe the window's record.
	func adoptEarlierWelcomeReceipt(dayZeroWelcomeShown: Bool) {
		guard dayZeroWelcomeShown, isIntroductionOwed else { return }
		markIntroductionShown()
	}

	/// Starts an armed tour, once whatever had the screen has given it up (AIA-0567).
	///
	/// A no-op unless a tour is actually owed *and* none is running. Both guards earn their place:
	/// this is called from view lifecycle handlers that fire more than once, and ``start()`` resets
	/// the step index and closes the drawer — so an unguarded second call would restart a tour the
	/// user is halfway through. Settings → Replay and the UI-test flag can both leave one running.
	///
	/// The arm is cleared **after** `start()` returns, in this one synchronous body. If the clear
	/// ever moved into a `Task`, ``isPendingOrRunning`` would read false for a frame between the two
	/// — long enough for `AnalyticsChoiceGate` to decide the coast was clear and put the consent
	/// question over a tour that was starting.
	func startIfArmed() {
		guard isArmed, isActive == false else { return }
		start()
		isArmed = false
		// Only a run that began from an arm is a first run, and only a first run is a funnel stage.
		// Settings → Replay calls `start()` directly and never sets this, so replays cannot inflate
		// a stage that is read against `freeAccessWindowGranted` — which is once-per-window by
		// construction. Same discipline as `markExpiryReported`.
		isFirstRun = true
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
		// active window via the `isActive` render gate in ContentView.
		//
		// These resets used to be inert on the first launch: the tour started from
		// `AppState.initialize()` before `ContentView` existed, so there was no drawer to close and
		// no detection to stop. AIA-0567 moved the start to *after* the Welcome screen, by which
		// point `ContentView` is mounted and its references are bound — so this is now a live reset
		// on every path, first launch included. `ContentView` withholds its launch auto-detect while
		// `isPendingOrRunning`, which is what stops that reset from becoming a visible
		// start-then-stop of detection underneath the Welcome screen.
		drawer?.close()
		if detectionState?.ontheflyDetectionEnabled == true {
			detectionState?.ontheflyDetectionTapped()
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
		terminate(skipped: false)
	}

	/// User dismissed the tour early. Same terminal handling as finish.
	func skip() {
		terminate(skipped: true)
	}

	private func terminate(skipped: Bool) {
		isActive = false
		showsNextButton = false
		if isFirstRun {
			analytics?.track(skipped ? .onboardingTourSkipped : .onboardingTourCompleted)
			isFirstRun = false
		}
		// Belt and braces with ``startIfArmed()``, which clears the arm as it consumes it. That is
		// the path this normally takes; this covers a tour begun some other way — Settings → Replay
		// calls ``start()`` directly — while an arm was still outstanding, which would otherwise
		// leave `isPendingOrRunning` true forever and, via `AnalyticsChoiceGate`, defer the consent
		// question for good.
		isArmed = false
		// A tour that ended without its introduction — begun by Settings → Replay while one was
		// still owed — has nothing left to introduce. Left set, it would raise the Welcome screen
		// after the onboarding it exists to precede.
		isIntroductionOwed = false
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
			return detectionState?.ontheflyDetectionEnabled == true
		case .pickModeEntered, .modelEnabled, .captureStarted, .findingSaved:
			// Event-driven rather than polled: these are edges, not conditions — re-reading
			// `findPickActive` later would also see a pick the user started for their own reasons.
			// Signalled by pickModeDidStart() / userEnabledModel() / captureDidStart() /
			// findingDidSave() respectively.
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
			detectionState?.ontheflyDetectionTapped()
		case .pickModeEntered:
			// Never cancelling: this step's fulfilment (`pickModeDidStart()`) does not re-arm, so a
			// tap that toggled pick mode back off would strand the tour on a step it cannot satisfy.
			chromeState?.findTapped(allowsCancel: false)
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

	/// Finding-capture (pick) mode was entered (the user tapped Find). The view layer signals the
	/// entering edge of `chromeState.findPickActive`; a cancel must not reach this (AIA-0880).
	func pickModeDidStart() {
		guard isActive, let step = currentStep, case .userAction(.pickModeEntered) = step.advance else { return }
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

	/// The finding sheet was dismissed without saving (Cancel / swipe). No-op once a finding was
	/// saved (the step has already advanced). Otherwise rewind to the **Find** step rather than the
	/// map step: dismissing the sheet tears down capture (pick) mode, so the map step would have no
	/// pick overlay listening; re-tapping the spotlighted Find re-arms capture mode and
	/// auto-advances back to the map step. (Codex review finding.)
	func captureCancelled() {
		guard isActive, let step = currentStep, case .userAction(.findingSaved) = step.advance else { return }
		guard let findIndex = steps[..<currentIndex].lastIndex(where: {
			if case .userAction(.pickModeEntered) = $0.advance { return true }
			return false
		}) else { return }
		currentIndex = findIndex
		beginStep()
	}

	/// The bubble's **Next** button — only visible for teaching steps or once an action step's
	/// real action is done, so this simply advances.
	func bubblePrimaryTapped() {
		guard isActive else { return }
		advance()
	}
}
