//
//  SubscriptionGateCoordinator.swift
//  AI Archeology
//
//  The root gate's orchestration, moved out of `SubscriptionGateView` (AIA-0976).
//

import Foundation
import Observation

/// What the root gate *does*, as opposed to what it draws: which Welcome screen is up, when it goes
/// up and comes down, and when the onboarding tour may start (AIA-0556, AIA-0567, AIA-0955).
///
/// Moved here from ``SubscriptionGateView`` unchanged (AIA-0976) so that headless mode runs
/// the same orchestration instead of restating it. The view still owns *when* each step runs — its
/// `onChange` handlers call the matching method below, one method per handler — and it still owns
/// everything drawn.
///
/// **One per window.** The view holds this in `@State`, which is what keeps ``presentedPrompt`` and
/// the Welcome claim scene-local while ``FreeAccessState/welcomeClaims`` stays shared by the whole
/// `WindowGroup`. See ``TourStartDecision`` for why that distinction matters.
///
/// **Observation.** This type is `@Observable`, but the objects it reads are not all: `SubscriptionState`
/// and `FreeAccessState` are Combine `ObservableObject`s, and their `@Published` reads made through
/// ``display`` or ``canPresentPrompt`` are invisible to Observation. The view's `@ObservedObject`
/// wrappers on those same objects are what re-render it — and so what makes its `onChange` handlers
/// fire. Nothing here reacts to a change by itself; a state change does nothing until a handler runs.
@MainActor
@Observable
final class SubscriptionGateCoordinator {

	let subscriptionState: SubscriptionState
	let freeAccess: FreeAccessState
	let tour: TourState
	let analytics: AnalyticsState

	/// Deliberately side-effect free: the view builds this in `State(initialValue:)`, which evaluates
	/// on every parent render and keeps only the first instance.
	init(
		subscriptionState: SubscriptionState,
		freeAccess: FreeAccessState,
		tour: TourState,
		analytics: AnalyticsState
	) {
		self.subscriptionState = subscriptionState
		self.freeAccess = freeAccess
		self.tour = tour
		self.analytics = analytics
	}

	/// Whether the app proper has ever been on screen this session. Mirrors `AnalyticsChoiceGate`'s
	/// `hasEverResolved` and for the same reason: once content is mounted, losing access must cover
	/// it rather than replace it. A free window that runs out at midnight while the user is reading
	/// a page would otherwise take the page with it.
	private(set) var hasEverShownContent = false

	/// The free-access paywall currently laid over the app, or `nil` when none is (AIA-0556).
	///
	/// Held here rather than read straight off ``FreeAccessState/duePrompt`` because raising it
	/// *marks it shown*, which immediately makes it no longer due — see
	/// ``FreeAccessState/markPromptShown()`` for why the marker is written at presentation.
	private(set) var presentedPrompt: WelcomePresentation?

	/// This window's claim on the shared Welcome presentation, or `nil` when it has none.
	///
	/// Scene-local because the claim belongs to *this* window, while the set it joins is shared —
	/// which is what lets a release be attributed rather than merely counted.
	private var welcomeClaim: UUID?

	/// Whether the Welcome screen may go on screen right now.
	///
	/// Two conditions, each for its own reason. The app proper must be what is showing: there is
	/// nothing to lay it over otherwise, and an expired window already has a wall of its own. And the
	/// user must not be paying: a subscriber has no app-managed window to be told about, and the same
	/// condition is what takes the screen down if an entitlement lands while it is up — which happens
	/// out of band, since this screen sells nothing: an Ask-to-Buy approval, Family Sharing, or a
	/// purchase made on another device.
	///
	/// The third — that no tour is running — reads like the AIA-0556 condition this ticket removed,
	/// and is not. That one waited for a tour that had *already started*, which under the new
	/// ordering would deadlock: the tour waits for this screen and this screen would wait for the
	/// tour. This one cannot, because the tour only ever starts when nothing is owed the screen.
	/// It covers the reverse arrival: an entitlement revoked mid-session — a refund, a lapsed
	/// subscription — can make a window due again while onboarding is underway, and raising the
	/// Welcome screen over a running tour would leave Continue merely uncovering it. Deferring
	/// re-evaluates for free: `isActive` is observed, so the tour ending re-renders this.
	var canPresentPrompt: Bool {
		display == .content && subscriptionState.isSubscribed == false && tour.isActive == false
	}

	/// The Welcome screen owed right now — the one answer both ``raisePromptIfDue()`` and
	/// ``startTourIfClear()`` read (AIA-0955).
	var dueWelcome: WelcomePresentation? {
		WelcomePresentation.due(
			isPaymentsSurfaceEnabled: subscriptionState.isPaymentsSurfaceEnabled,
			freeAccessPrompt: freeAccess.duePrompt,
			isIntroductionOwed: tour.isIntroductionOwed
		)
	}

	var display: RootGateDisplay {
		RootGateDisplay.resolve(
			isPaymentsSurfaceEnabled: subscriptionState.isPaymentsSurfaceEnabled,
			isSubscribed: subscriptionState.isSubscribed,
			freeAccess: freeAccess.availability,
			hasEverShownContent: hasEverShownContent
		)
	}

	// MARK: - Handlers (one per `onChange` in the view)

	/// `onChange(of: display, initial: true)`.
	func displayChanged(to value: RootGateDisplay) {
		if value == .content { hasEverShownContent = true }
		// The tour's fallback start, for every launch where no Welcome is owed at all: an
		// install that has already seen one, a build with free access off, or a wall that was
		// just purchased past. Deliberately hung off `display` rather than `canPresentPrompt`
		// — see `startTourIfClear()`.
		startTourIfClear()
	}

	/// `onChange(of: canPresentPrompt, initial: true)`.
	///
	/// Covers the arrival case — content becoming available on a fresh install — and every
	/// reason a raised prompt has to come back down, an entitlement arriving included: it flips
	/// `isSubscribed`, and `@Environment(\.dismiss)` is inert inside an overlay, so the screen
	/// has to be taken away from out here. The Welcome screen itself sells nothing — such an
	/// entitlement always arrives from elsewhere.
	func canPresentPromptChanged(to canPresent: Bool) {
		if canPresent {
			raisePromptIfDue()
		} else if presentedPrompt != nil {
			lowerPrompt()
		}
		startTourIfClear()
	}

	/// `onChange(of: freeAccess.duePrompt)`.
	///
	/// A prompt that only becomes due after the view has settled — the window is granted during
	/// `FreeAccessState.start()`, and re-evaluated on every foreground — arrives here, at which
	/// point `canPresentPrompt` has not moved at all.
	func duePromptChanged() {
		raisePromptIfDue()
		startTourIfClear()
	}

	/// `onChange(of: tour.isIntroductionOwed)`.
	///
	/// The payments-off introduction's counterpart (AIA-0955). It is owed from the arm, before the
	/// first frame, so this mostly matters for the change that *clears* it: another window
	/// presenting the introduction must re-run this window's tour check.
	func introductionOwedChanged() {
		raisePromptIfDue()
		startTourIfClear()
	}

	/// `onChange(of: freeAccess.welcomeClaims)`.
	///
	/// The Welcome screen actually leaving the display is its own event, and the one the tour
	/// waits on. `lowerPrompt()` runs on the tap, while the view is still mounted — its
	/// `onDisappear`, and so the release of the shared count, comes a beat later. Without this the
	/// tour is refused at Continue for a count that is about to drop and never asked again.
	/// It is also how a *second window* learns that the window owning the Welcome screen has gone.
	func welcomeClaimsChanged() {
		startTourIfClear()
	}

	// MARK: - Intents

	/// The Welcome screen's Continue button.
	///
	/// Built here rather than inside the screen for the reason it always was: ``lowerPrompt()`` is
	/// *also* how this comes down when an entitlement arrives from elsewhere, or when something else
	/// reclaims the screen, and neither of those is somebody choosing to explore first. Only the
	/// button knows it was a decline, so only the button reports one.
	func continueWelcome(_ presentation: WelcomePresentation) {
		// Only the free-access offer is a funnel stage. The payments-off introduction declines
		// nothing, and counting it would read every free-mode user as a window turned down.
		if case .freeAccess = presentation {
			analytics.track(.freeAccessContinueTapped)
		}
		lowerPrompt()
	}

	/// Gives up this window's claim on the Welcome presentation, if it holds one.
	///
	/// Called from both the Continue tap and the screen's `onDisappear`, and idempotent so that
	/// costs nothing: whichever arrives first clears the token, and the other becomes a no-op. That
	/// pairing is deliberate — `onDisappear` alone is not guaranteed on scene teardown, and
	/// `lowerPrompt()` alone never runs for a window closed without tapping anything.
	func releaseWelcomeClaim() {
		guard let token = welcomeClaim else { return }
		welcomeClaim = nil
		freeAccess.releaseWelcomePresentation(token)
	}

	// MARK: - Orchestration

	/// Starts the armed onboarding tour once nothing else is owed the screen ahead of it (AIA-0567).
	///
	/// This is the whole ordering inversion in one predicate, and each clause closes a hole that
	/// actually existed in an earlier draft:
	///
	/// - `display == .content` and **not** `canPresentPrompt`. The latter carries
	///   `isSubscribed == false`, so keying off it would mean a first launch that resolves to the
	///   wall — payments on, free access off — and is then *purchased* never starts the tour, on
	///   that launch or any later one, because nothing would ever re-satisfy the condition.
	/// - `presentedPrompt == nil`, because ``FreeAccessState/markPromptShown()`` clears
	///   `duePrompt` at **presentation**. Guarding on `duePrompt` alone would start the tour
	///   underneath a Welcome screen that is on the display right now — which is precisely the
	///   arrangement this ticket exists to prevent.
	/// - `duePrompt == nil` **or** `canPresentPrompt == false` — "no Welcome is due, or none can be
	///   raised from here". The `or` is not slack. A subscriber whose window still owes an unshown
	///   day 0 can never have it raised (`canPresentPrompt` refuses), so a bare "something is owed,
	///   wait" would leave their tour armed forever — and with it, via
	///   ``TourState/isPendingOrRunning``, their consent question deferred forever.
	///
	/// - `freeAccess.isWelcomePresented == false` covers the same question across **other windows**.
	///   `presentedPrompt` is scene-local, while this object's inputs and the tour are shared by the
	///   whole `WindowGroup`; with two iPad windows open, the window that raised the Welcome screen is
	///   not the one that would otherwise start the tour underneath it.
	///
	/// Called from both `onChange` handlers and from ``lowerPrompt()``, because between them they
	/// cover every way the screen can come free; ``TourState/startIfArmed()`` makes the repetition
	/// harmless.
	private func startTourIfClear() {
		guard TourStartDecision.mayStart(
			isShowingContent: display == .content,
			isWelcomeOnScreenHere: presentedPrompt != nil,
			isWelcomeOnScreenAnywhere: freeAccess.isWelcomePresented,
			isWelcomeDue: dueWelcome != nil,
			canPresentWelcome: canPresentPrompt
		) else { return }
		tour.startIfArmed()
	}

	/// Raises whatever the window owes, and marks it shown in the same breath.
	private func raisePromptIfDue() {
		guard canPresentPrompt, presentedPrompt == nil, let due = dueWelcome else { return }
		presentedPrompt = due
		// Claimed before the screen is marked shown, never after. Marking clears what is due on this
		// same turn, and the resulting publish is what wakes the other window — so the claim has to
		// be visible by then or the guard is armed after the race it exists to prevent.
		welcomeClaim = freeAccess.claimWelcomePresentation()
		if case .freeAccess = due {
			freeAccess.markPromptShown()
		}
		// Either Welcome screen introduces the onboarding it precedes. Receipting only the payments-off
		// one would let a user who met the priced screen, then force-quit mid-tour, be welcomed a
		// second time by the neutral one if payments were switched off before their next launch.
		tour.markIntroductionShown()
	}

	/// Takes the Welcome screen down and hands the floor to the onboarding tour (AIA-0567).
	///
	/// `acknowledgeDay0Presentation()` releases the day-0 hold on the analytics consent question,
	/// but that no longer means the question gets asked: `AnalyticsChoiceGate` also waits on
	/// `TourState.isPendingOrRunning`, so the order the user actually experiences is
	/// Welcome → tour → consent. Two independent holds rather than one chained one, because they
	/// are released by different things and either can be absent.
	private func lowerPrompt() {
		presentedPrompt = nil
		releaseWelcomeClaim()
		freeAccess.acknowledgeDay0Presentation()
		startTourIfClear()
	}
}
