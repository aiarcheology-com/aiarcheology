//
//  SubscriptionGateView.swift
//  AI Archeology
//
//  Whole-app subscription gate (AIA-0343).
//

import SwiftUI
import UIKit

/// Gates the whole app behind an active subscription. Sits *inside* the auth gate: once
/// the user is signed in, the app proper is shown only while they hold an active
/// subscription — and a 1-month free trial counts as active, so trial users pass through.
/// Otherwise the paywall is the root (mirrors the auth gate's pattern), with sign-out /
/// delete-account available so a non-subscriber can still leave (Apple 5.1.1(v)).
///
/// Bypassed entirely when `FeatureFlags.isPaymentsEnabled` is off, so the feature can ship
/// dark and existing flows are unaffected until payments are turned on.
struct SubscriptionGateView<Content: View>: View {
    @ObservedObject var subscriptionState: SubscriptionState
    @ObservedObject var authState: AuthState
    @ViewBuilder var content: () -> Content

    var body: some View {
        Group {
            if FeatureFlags.isPaymentsEnabled == false || subscriptionState.isSubscribed {
                content()
            } else {
                PaywallView(subscriptionState: subscriptionState, authState: authState, isRootGate: true)
            }
        }
        // Re-check entitlement on foreground: a subscription that lapses while backgrounded
        // may push no `Transaction.updates` event, so without this the gate could stay open
        // on a stale entitlement until the next cold launch.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            guard FeatureFlags.isPaymentsEnabled else { return }
            Task { await subscriptionState.start() }
        }
    }
}
