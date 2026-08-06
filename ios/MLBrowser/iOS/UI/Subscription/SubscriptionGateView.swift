//
//  SubscriptionGateView.swift
//  AI Archeology
//
//  Whole-app subscription gate (AIA-0343).
//

import SwiftUI
import UIKit

/// What the app root renders, resolved from entitlement and the free-access window (AIA-0556).
///
/// Extracted from ``SubscriptionGateView`` because one case here costs a paying customer if it
/// regresses and a view is a poor place to prove it: a user who taps Subscribe on day 13 of their
/// free window is `isSubscribed`, and on day 14 that window expires. Entitlement is therefore
/// answered **before** the window is consulted, and does not consult it at all.
enum RootGateDisplay: Equatable {
	/// The app proper.
	case content

	/// The paywall as the screen the user arrives at, with no app behind it.
	case wall

	/// The app proper, with the paywall laid over it. Access was lost while the user was in a
	/// session; swapping the root instead would destroy the `WKWebView` and with it the loaded
	/// page, the scroll position and the history.
	case wallOverContent

	/// Neither, for as long as the free-access anchor is still being read — see
	/// ``FreeAccessAvailability/undetermined``.
	case hold

	/// The gate order in one place: payments surface off, then StoreKit entitlement, then the
	/// app-managed window. `hasEverShownContent` decides only *how* a refusal is presented, never
	/// whether access exists.
	static func resolve(
		isPaymentsSurfaceEnabled: Bool,
		isSubscribed: Bool,
		freeAccess: FreeAccessAvailability,
		hasEverShownContent: Bool
	) -> RootGateDisplay {
		// Deliberately returns without looking at `freeAccess`: an expired app window must never
		// subtract from an entitlement Apple is charging for.
		if isPaymentsSurfaceEnabled == false || isSubscribed { return .content }

		switch freeAccess {
		case .open:
			return .content
		case .undetermined:
			// Never wall on "not yet". `FreeAccessWindow` reports `.notGranted` while its stores are
			// being reconciled, so treating that as a refusal would show the paywall to a valid
			// mid-window user on every launch, for as long as the Keychain took to answer.
			return hasEverShownContent ? .content : .hold
		case .closed:
			return hasEverShownContent ? .wallOverContent : .wall
		}
	}
}

/// Gates the whole app behind an active subscription. **This is the app root** (AIA-0536): it used
/// to sit inside an auth gate, so nothing here was reachable while signed out. Who you are no
/// longer decides whether the app renders — StoreKit's free trial counts as active, so trial users
/// pass through, and signing in is offered contextually instead.
///
/// AIA-0556 puts an app-managed free-access window in front of that: access is
/// `payments surface off || StoreKit entitled || free window open`. The order is the contract, and
/// ``RootGateDisplay/resolve(isPaymentsSurfaceEnabled:isSubscribed:freeAccess:hasEverShownContent:)``
/// is where it lives.
///
/// Otherwise the paywall is what the user meets, carrying the account controls a non-subscriber
/// needs to leave or recover their account (Apple 5.1.1(v)). Which controls those are depends on
/// whether anyone is signed in, which is why the auth context is forwarded: this view observes
/// `AuthState`, and `PaywallView` does not, so a sign-out that no longer tears down the tree still
/// has to swap Sign Out / Delete for Sign In in place.
///
/// Bypassed entirely when the payments flag is off, so the feature can ship dark. Note what that
/// now means with no auth gate above: a flag-off build is fully open. The flag comes from
/// `subscriptionState`, captured once at launch (AIA-0350) — this view is the app root, so it must
/// not swap under the user mid-session if a remote poll flips it.
struct SubscriptionGateView<Content: View>: View {
    @ObservedObject var subscriptionState: SubscriptionState
    @ObservedObject var authState: AuthState
	@ObservedObject var freeAccess: FreeAccessState

	/// The onboarding tour — which this view now **starts** rather than waits for (AIA-0567).
	///
	/// The relationship inverted. The day-0 screen used to wait for the tour to finish, because the
	/// tour was already running by the time this view existed; now the Welcome screen goes first and
	/// hands the tour the screen on Continue. `Appstate.initialize()` arms it, this view starts it —
	/// see ``startTourIfClear()`` for the conditions, which are subtler than they look.
	///
	/// `@Observable`, so reading it during `body` is all the tracking it needs.
	let tour: TourState

	/// The findings store, for the data-export escape hatch the hard wall owes a user who never pays
	/// (AIA-0556). Passed by initializer because it is not an `ObservableObject`, exactly as
	/// `SettingsForm` takes it.
	let findingRepository: FindingRepository

	let analytics: AnalyticsState
    @ViewBuilder var content: () -> Content

	/// Whether the app proper has ever been on screen this session. Mirrors `AnalyticsChoiceGate`'s
	/// `hasEverResolved` and for the same reason: once content is mounted, losing access must cover
	/// it rather than replace it. A free window that runs out at midnight while the user is reading
	/// a page would otherwise take the page with it.
	@State private var hasEverShownContent = false

	/// The free-access paywall currently laid over the app, or `nil` when none is (AIA-0556).
	///
	/// Held here rather than read straight off ``FreeAccessState/duePrompt`` because raising it
	/// *marks it shown*, which immediately makes it no longer due — see
	/// ``FreeAccessState/markPromptShown()`` for why the marker is written at presentation.
	@State private var presentedPrompt: FreeAccessPrompt?

	/// Whether the Welcome screen may go on screen right now.
	///
	/// Two conditions, each for its own reason. The app proper must be what is showing: there is
	/// nothing to lay it over otherwise, and an expired window already has a wall of its own. And the
	/// user must not be paying: a subscriber has no app-managed window to be told about, and the same
	/// condition is what takes the screen down when they buy from it.
	///
	/// The third condition — that the tour had finished — is gone with AIA-0567. The Welcome screen
	/// now precedes the tour, so waiting for it would deadlock: the tour waits for this screen, and
	/// this screen would be waiting for the tour.
	private var canPresentPrompt: Bool {
		display == .content && subscriptionState.isSubscribed == false
	}

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
	/// Called from both `onChange` handlers and from ``lowerPrompt()``, because between them they
	/// cover every way the screen can come free; ``TourState/startIfArmed()`` makes the repetition
	/// harmless.
	private func startTourIfClear() {
		guard display == .content,
			  presentedPrompt == nil,
			  freeAccess.duePrompt == nil || canPresentPrompt == false
		else { return }
		tour.startIfArmed()
	}

	private var display: RootGateDisplay {
		RootGateDisplay.resolve(
			isPaymentsSurfaceEnabled: subscriptionState.isPaymentsSurfaceEnabled,
			isSubscribed: subscriptionState.isSubscribed,
			freeAccess: freeAccess.availability,
			hasEverShownContent: hasEverShownContent
		)
	}

    var body: some View {
        Group {
			switch display {
			// One branch for both, so the expiry transition keeps the same structural identity and
			// SwiftUI does not remount the subtree it is only meant to cover.
			case .content, .wallOverContent:
                content()
			case .wall:
				paywall()
			case .hold:
				ProgressView()
					.frame(maxWidth: .infinity, maxHeight: .infinity)
			}
        }
		// An **overlay**, deliberately not a sheet or a `fullScreenCover`, for the reason
		// `AnalyticsChoiceGate` documents at length: this gate is an ancestor of every sheet the app
		// presents, and a sheet raised from an ancestor while a descendant's sheet is up
		// presents-then-auto-dismisses. Settings — where Restore Defaults lives — is one of those.
		// The informational presentations (AIA-0556) share this overlay rather than adding a second
		// one, so it is structurally impossible to show a paywall about an open window over the wall
		// that says it has run out. They are already mutually exclusive in time — the prompts need a
		// live window and the wall needs a spent one — and the `else` makes that a fact of the tree.
		.overlay {
			if display == .wallOverContent {
				paywall()
					.background(Color(uiColor: .systemBackground))
					.transition(.opacity)
			} else if let presentedPrompt {
				welcome(for: presentedPrompt)
					.background(Color(uiColor: .systemBackground))
					.transition(.opacity)
			}
		}
		.onChange(of: display, initial: true) { _, value in
			if value == .content { hasEverShownContent = true }
			// The tour's fallback start, for every launch where no Welcome is owed at all: an
			// install that has already seen one, a build with free access off, or a wall that was
			// just purchased past. Deliberately hung off `display` rather than `canPresentPrompt`
			// — see `startTourIfClear()`.
			startTourIfClear()
		}
		// Covers the arrival case — content becoming available on a fresh install — and every
		// reason a raised prompt has to come back down, purchase included: buying from the Welcome
		// screen flips `isSubscribed`, and `@Environment(\.dismiss)` is inert inside an overlay, so
		// the screen has to be taken away from out here.
		.onChange(of: canPresentPrompt, initial: true) { _, canPresent in
			if canPresent {
				raisePromptIfDue()
			} else if presentedPrompt != nil {
				lowerPrompt()
			}
			startTourIfClear()
		}
		// A prompt that only becomes due after this view has settled — the window is granted during
		// `FreeAccessState.start()`, and re-evaluated on every foreground — arrives here, at which
		// point `canPresentPrompt` has not moved at all.
		.onChange(of: freeAccess.duePrompt) { _, _ in
			raisePromptIfDue()
			startTourIfClear()
		}
        // Re-check entitlement on foreground: a subscription that lapses while backgrounded
        // may push no `Transaction.updates` event, so without this the gate could stay open
        // on a stale entitlement until the next cold launch.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            guard subscriptionState.isPaymentsSurfaceEnabled else { return }
            Task { await subscriptionState.start() }
        }
    }

	/// Raises whatever the window owes, and marks it shown in the same breath.
	private func raisePromptIfDue() {
		guard canPresentPrompt, presentedPrompt == nil, let due = freeAccess.duePrompt else { return }
		presentedPrompt = due
		freeAccess.markPromptShown()
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
		freeAccess.acknowledgeDay0Presentation()
		startTourIfClear()
	}

	/// The hard wall: the screen a user with no access and no window left arrives at.
	///
	/// Since AIA-0567 this is the *only* thing `PaywallView` renders from here. The day-0
	/// presentation it used to share is ``welcome(for:)``, and the reminder is gone, so every
	/// optional that used to distinguish them went with them.
	private func paywall() -> some View {
		PaywallView(
			subscriptionState: subscriptionState,
			analytics: analytics,
			authState: authState,
			// The escape hatch is the wall's alone, and the wall is now the only presentation this
			// builds — an unsubscribed user here has no other route to the findings they saved.
			findingRepository: findingRepository,
			isRootGate: true,
			// Passed as a value from here, where auth *is* observed, so the paywall's
			// account controls swap in place when the user signs out without leaving it
			// (AIA-0536) — previously a sign-out replaced the whole tree.
			authContext: authState.effectiveContext,
			// Only a window that actually ran out may be told it ran out. `availability` collapses
			// "expired" and "never granted" into `.closed` because the gate does not care which;
			// the copy does.
			statesExpiredFreeAccess: freeAccess.hasSpentWindow
		)
	}

	/// The day-0 welcome screen (AIA-0567), laid over the app the user already has.
	///
	/// `continueAction` is built here rather than inside the screen for the reason it always was:
	/// ``lowerPrompt()`` is *also* how this comes down when the user buys, or when something else
	/// reclaims the screen, and neither of those is somebody choosing to explore first. Only the
	/// button knows it was a decline, so only the button reports one.
	private func welcome(for prompt: FreeAccessPrompt) -> some View {
		WelcomeView(
			subscriptionState: subscriptionState,
			days: prompt.days,
			continueAction: {
				analytics.track(.freeAccessContinueTapped)
				lowerPrompt()
			}
		)
	}
}
