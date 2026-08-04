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
/// to sit inside an auth gate, so nothing here was reachable while signed out. Entitlement is now
/// the only thing that decides whether the app renders — a 1-month free trial counts as active, so
/// trial users pass through — and signing in is offered contextually instead.
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
	let analytics: AnalyticsState
    @ViewBuilder var content: () -> Content

	/// Whether the app proper has ever been on screen this session. Mirrors `AnalyticsChoiceGate`'s
	/// `hasEverResolved` and for the same reason: once content is mounted, losing access must cover
	/// it rather than replace it. A free window that runs out at midnight while the user is reading
	/// a page would otherwise take the page with it.
	@State private var hasEverShownContent = false

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
				paywall
			case .hold:
				ProgressView()
					.frame(maxWidth: .infinity, maxHeight: .infinity)
			}
        }
		// An **overlay**, deliberately not a sheet or a `fullScreenCover`, for the reason
		// `AnalyticsChoiceGate` documents at length: this gate is an ancestor of every sheet the app
		// presents, and a sheet raised from an ancestor while a descendant's sheet is up
		// presents-then-auto-dismisses. Settings — where Restore Defaults lives — is one of those.
		.overlay {
			if display == .wallOverContent {
				paywall
					.background(Color(uiColor: .systemBackground))
					.transition(.opacity)
			}
		}
		.onChange(of: display, initial: true) { _, value in
			if value == .content { hasEverShownContent = true }
		}
        // Re-check entitlement on foreground: a subscription that lapses while backgrounded
        // may push no `Transaction.updates` event, so without this the gate could stay open
        // on a stale entitlement until the next cold launch.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            guard subscriptionState.isPaymentsSurfaceEnabled else { return }
            Task { await subscriptionState.start() }
        }
    }

	private var paywall: some View {
		PaywallView(
			subscriptionState: subscriptionState,
			analytics: analytics,
			authState: authState,
			isRootGate: true,
			// Passed as a value from here, where auth *is* observed, so the paywall's
			// account controls swap in place when the user signs out without leaving it
			// (AIA-0536) — previously a sign-out replaced the whole tree.
			authContext: authState.effectiveContext
		)
	}
}
