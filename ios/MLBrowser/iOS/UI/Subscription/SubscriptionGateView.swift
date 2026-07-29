//
//  SubscriptionGateView.swift
//  AI Archeology
//
//  Whole-app subscription gate (AIA-0343).
//

import SwiftUI
import UIKit

/// Gates the whole app behind an active subscription. **This is the app root** (AIA-0536): it used
/// to sit inside an auth gate, so nothing here was reachable while signed out. Entitlement is now
/// the only thing that decides whether the app renders — a 1-month free trial counts as active, so
/// trial users pass through — and signing in is offered contextually instead.
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
	let analytics: AnalyticsState
    @ViewBuilder var content: () -> Content

    var body: some View {
        Group {
            if subscriptionState.isPaymentsSurfaceEnabled == false || subscriptionState.isSubscribed {
                content()
            } else {
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
        // Re-check entitlement on foreground: a subscription that lapses while backgrounded
        // may push no `Transaction.updates` event, so without this the gate could stay open
        // on a stale entitlement until the next cold launch.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            guard subscriptionState.isPaymentsSurfaceEnabled else { return }
            Task { await subscriptionState.start() }
        }
    }
}
