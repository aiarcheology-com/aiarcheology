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

/// Whether the armed onboarding tour may start right now (AIA-0567).
///
/// Extracted from ``SubscriptionGateView`` for the same reason ``RootGateDisplay`` was: every clause
/// here closes a hole that a review actually found, three of them in a draft that looked obviously
/// correct, and a SwiftUI view is a poor place to prove a four-way conjunction. The failure modes
/// are silent — a tour that never runs again, or one running underneath the screen that is supposed
/// to precede it — so none of them announces itself in manual testing.
enum TourStartDecision {

	/// - Parameters:
	///   - isShowingContent: the app proper is what is on screen. Deliberately **not**
	///     "a Welcome screen could be presented": that condition carries `isSubscribed == false`,
	///     so keying off it would mean a first launch that meets the wall and is then *purchased*
	///     never starts the tour, on that launch or any later one.
	///   - isWelcomeOnScreenHere: a Welcome screen is up in **this** window. The marker is written
	///     when it is raised, which clears `isWelcomeDue` immediately, so the due flag alone would
	///     start the tour underneath a screen that is on the display right now.
	///   - isWelcomeOnScreenAnywhere: a Welcome screen is up in **another** window. The app supports
	///     multiple scenes; the window that raised it is not necessarily the one that would
	///     otherwise start the shared tour.
	///   - isWelcomeDue: the window still owes a Welcome screen.
	///   - canPresentWelcome: this gate could actually raise it. Paired with `isWelcomeDue` as an
	///     **or**, because a subscriber whose window still owes an unshown day 0 can never have it
	///     raised — and a bare "something is owed, wait" would leave their tour armed forever, and
	///     with it their analytics consent question deferred forever.
	static func mayStart(
		isShowingContent: Bool,
		isWelcomeOnScreenHere: Bool,
		isWelcomeOnScreenAnywhere: Bool,
		isWelcomeDue: Bool,
		canPresentWelcome: Bool
	) -> Bool {
		guard isShowingContent else { return false }
		guard isWelcomeOnScreenHere == false, isWelcomeOnScreenAnywhere == false else { return false }
		return isWelcomeDue == false || canPresentWelcome == false
	}
}

/// Which Welcome screen the root gate owes right now, if any (AIA-0955).
///
/// Two sources, and the payments flag picks exactly one. With payments on, the free-access window
/// owes its day-0 offer. With payments off there is no window and no offer, and the screen instead
/// introduces the onboarding tour — once, on the first run. Resolving both here, from one place, is
/// what lets the gate's presentation and the tour's start read the same answer: a due screen that
/// one of them saw and the other did not would either stall the tour for good or start it
/// underneath the screen.
enum WelcomePresentation: Equatable {
	/// The free-access window's day-0 offer (AIA-0567).
	case freeAccess(FreeAccessPrompt)

	/// The payments-off introduction to the app and its tour, naming no price (AIA-0955).
	case introduction

	static func due(
		isPaymentsSurfaceEnabled: Bool,
		freeAccessPrompt: FreeAccessPrompt?,
		isIntroductionOwed: Bool
	) -> WelcomePresentation? {
		if isPaymentsSurfaceEnabled {
			return freeAccessPrompt.map(WelcomePresentation.freeAccess)
		}
		// Never the priced screen with payments off, whatever a window persisted under payments on
		// still owes — `FreeAccessState` withholds it too, and this is the second lock.
		return isIntroductionOwed ? .introduction : nil
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
	/// hands the tour the screen on Continue. `AppState.initialize()` arms it, this view starts it —
	/// see ``SubscriptionGateCoordinator`` for the conditions, which are subtler than they look.
	///
	/// `@Observable`, so reading it during `body` is all the tracking it needs.
	let tour: TourState

	/// The findings store, for the data-export escape hatch the hard wall owes a user who never pays
	/// (AIA-0556). Passed by initializer because it is not an `ObservableObject`, exactly as
	/// `SettingsForm` takes it.
	let findingRepository: FindingRepository

	let analytics: AnalyticsState
    @ViewBuilder var content: () -> Content

	/// This window's gate orchestration: which Welcome screen is up, and when the tour may start
	/// (AIA-0976 moved it out of this view unchanged). `@State` because it is per window — see
	/// ``SubscriptionGateCoordinator``. Each `onChange` below calls the method named for it.
	///
	/// The `@ObservedObject` wrappers above stay load-bearing: the coordinator reads their
	/// `@Published` values, which Observation cannot see, so they are what re-renders this view and
	/// fires the handlers.
	@State private var coordinator: SubscriptionGateCoordinator

	init(
		subscriptionState: SubscriptionState,
		authState: AuthState,
		freeAccess: FreeAccessState,
		tour: TourState,
		findingRepository: FindingRepository,
		analytics: AnalyticsState,
		@ViewBuilder content: @escaping () -> Content
	) {
		self.subscriptionState = subscriptionState
		self.authState = authState
		self.freeAccess = freeAccess
		self.tour = tour
		self.findingRepository = findingRepository
		self.analytics = analytics
		self.content = content
		_coordinator = State(initialValue: SubscriptionGateCoordinator(
			subscriptionState: subscriptionState,
			freeAccess: freeAccess,
			tour: tour,
			analytics: analytics
		))
	}

	private var display: RootGateDisplay { coordinator.display }

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
			} else if let presentedPrompt = coordinator.presentedPrompt {
				welcome(for: presentedPrompt)
					.background(Color(uiColor: .systemBackground))
					.transition(.opacity)
			}
		}
		.onChange(of: display, initial: true) { _, value in
			coordinator.displayChanged(to: value)
		}
		.onChange(of: coordinator.canPresentPrompt, initial: true) { _, canPresent in
			coordinator.canPresentPromptChanged(to: canPresent)
		}
		.onChange(of: freeAccess.duePrompt) { _, _ in
			coordinator.duePromptChanged()
		}
		.onChange(of: tour.isIntroductionOwed) { _, _ in
			coordinator.introductionOwedChanged()
		}
		.onChange(of: freeAccess.welcomeClaims) { _, _ in
			coordinator.welcomeClaimsChanged()
		}
		// The foreground entitlement re-check that used to hang off this view runs in `AppRuntime`
		// (AIA-0993), so headless mode does it too.
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
			statesExpiredFreeAccess: freeAccess.hasSpentWindow,
			// The real accessor, not a hardcoded `nil` (AIA-0623). It reads `nil` here anyway —
			// `RootGateDisplay.resolve` returns `.content` for an open window, so this screen cannot
			// render while one is running — and that is exactly why passing the truth is better than
			// asserting the answer: "no confirmation on the wall" then holds by construction, and a
			// future presentation that does put this screen over an open window inherits the
			// confirmation instead of silently forfeiting the days.
			freeAccessDaysRemaining: { freeAccess.windowDaysRemaining }
		)
	}

	/// The day-0 welcome screen (AIA-0567), laid over the app the user already has. Continue is
	/// ``SubscriptionGateCoordinator/continueWelcome(_:)``, which says why only the button reports a
	/// decline.
	private func welcome(for presentation: WelcomePresentation) -> some View {
		WelcomeView(
			subscriptionState: subscriptionState,
			offer: Self.offer(for: presentation),
			continueAction: { coordinator.continueWelcome(presentation) }
		)
		// Tied to the screen's own lifecycle rather than to the coordinator's raise/lower pair, so a
		// window closed while the Welcome screen is up still releases the shared guard. Driving it
		// from the raise/lower pair would leak on scene teardown and block onboarding everywhere.
		// The claim is taken when the screen is raised, not here — see `welcomeClaims`. This only has
		// to cover the exits that never reach the lowering: the window being closed with the
		// screen still up.
		.onDisappear { coordinator.releaseWelcomeClaim() }
	}

	private static func offer(for presentation: WelcomePresentation) -> WelcomeView.Offer {
		switch presentation {
		case let .freeAccess(prompt): .freeAccess(days: prompt.days)
		case .introduction: .introduction
		}
	}
}
