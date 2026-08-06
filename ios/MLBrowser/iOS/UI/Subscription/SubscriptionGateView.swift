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

	/// The onboarding tour, read for exactly one bit: whether it still has the screen (AIA-0556).
	///
	/// The day-0 paywall explains a window the user has only just been given, and it has to land
	/// *after* the tour rather than on top of it. `TourState.start()` deliberately does not flip the
	/// seen gate, so the terminal transition is the only honest signal — and an install that has
	/// already seen the tour never starts one, which is the same `isActive == false`. That is what
	/// gives those users the paywall immediately instead of never: they would otherwise learn a clock
	/// was running only from the day-7 reminder, and then from being walled.
	///
	/// `@Observable`, so reading `isActive` during `body` is all the tracking it needs.
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
	/// ``FreeAccessState/markPromptShown(_:)`` for why the marker is written at presentation.
	@State private var presentedPrompt: FreeAccessPrompt?

	/// Whether a free-access paywall may go on screen right now.
	///
	/// Three conditions, each for its own reason. The app proper must be what is showing: there is
	/// nothing to lay it over otherwise, and an expired window already has a wall of its own. The
	/// user must not be paying: a subscriber has no app-managed window to be told about, and the same
	/// condition is what takes the screen down when they buy from it. And the tour must be finished
	/// with the screen — see ``tour``.
	private var canPresentPrompt: Bool {
		display == .content && subscriptionState.isSubscribed == false && tour.isActive == false
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
				paywall(prompt: presentedPrompt)
					.background(Color(uiColor: .systemBackground))
					.transition(.opacity)
			}
		}
		.onChange(of: display, initial: true) { _, value in
			if value == .content { hasEverShownContent = true }
		}
		// Covers both the arrival cases — the tour ending on a fresh install, and an install that
		// never started one — and every reason a raised prompt has to come back down, purchase
		// included: buying from this paywall flips `isSubscribed`, and `@Environment(\.dismiss)` is
		// inert inside an overlay, so the screen has to be taken away from out here.
		.onChange(of: canPresentPrompt, initial: true) { _, canPresent in
			if canPresent {
				raisePromptIfDue()
			} else if presentedPrompt != nil {
				lowerPrompt()
			}
		}
		// A reminder that came due while the app was backgrounded arrives on the foreground
		// re-evaluation, at which point `canPresentPrompt` has not moved at all.
		.onChange(of: freeAccess.duePrompt) { _, _ in
			raisePromptIfDue()
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
		freeAccess.markPromptShown(due)
	}

	/// Takes the paywall down and releases the analytics consent question queued behind it (AIA-0556).
	private func lowerPrompt() {
		presentedPrompt = nil
		freeAccess.acknowledgeDay0Presentation()
	}

	/// The root paywall. Passing a `prompt` turns it into an informational screen with a way past;
	/// passing none is the hard wall, which must stay develop's screen exactly (criterion 8).
	private func paywall(prompt: FreeAccessPrompt? = nil) -> some View {
		// The one free-access event that has to come from the view: `lowerPrompt()` is also how a
		// prompt comes down when the user *buys* from it, or when the tour takes the screen back, and
		// neither of those is somebody declining to subscribe for now. Only the button knows.
		let continueAction: (() -> Void)? = prompt == nil ? nil : {
			analytics.track(.freeAccessContinueTapped)
			lowerPrompt()
		}
		return PaywallView(
			subscriptionState: subscriptionState,
			analytics: analytics,
			authState: authState,
			// The findings escape hatch is the wall's alone; the view decides that from
			// `continueAction`, since an informational paywall has the whole app behind it.
			findingRepository: findingRepository,
			isRootGate: true,
			// Passed as a value from here, where auth *is* observed, so the paywall's
			// account controls swap in place when the user signs out without leaving it
			// (AIA-0536) — previously a sign-out replaced the whole tree.
			authContext: authState.effectiveContext,
			continueAction: continueAction,
			freeAccessOffer: prompt?.offer,
			// Criterion 9 wants the billing date at the wall — the screen a spent window leaves the
			// user on — but criterion 8 wants a flag-off build to be develop's paywall exactly. So
			// it follows the feature, not the gate: with the flag off this is false and nothing
			// about a free period renders here at all.
			showsBillingEstimate: freeAccess.isFeatureEnabled
		)
	}
}

private extension FreeAccessPrompt {
	/// The copy this prompt renders as.
	///
	/// The two enums stay separate on purpose: one is a fact about the window and belongs with the
	/// state machine, the other is what a screen says and belongs with the screen. This is the seam.
	var offer: FreeAccessOffer {
		switch self {
		case let .day0(days, endsOn): .offered(days: days, endsOn: endsOn)
		case let .reminder(days, endsOn): .remaining(days: days, endsOn: endsOn)
		}
	}
}
