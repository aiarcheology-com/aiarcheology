//
//  MessageSurfaceResolver.swift
//  AI Archeology
//
//  Which app-message surface (if any) is mounted right now, given the launch gates (AIA-0115).
//  Pure — no UI, no @MainActor — so the whole precedence truth table is unit-testable.
//

import Foundation

/// Resolves which ``MessageSurface`` the app-message banner may present on *right now*, mirroring
/// the gate nesting in `MLBrowser.swift` exactly. Returns `nil` whenever no messageable surface is
/// mounted — a loading screen, or a full-screen replacement like the analytics-consent gate —
/// because the banner must not appear over those.
///
/// ## Precedence (outermost gate wins), matching `MLBrowser.swift`
/// 1. `isReady == false` → the `ProgressView("Loading…")` root → **nil**.
/// 2. `SubscriptionGateView` is now the root (AIA-0536): `paymentsSurfaceEnabled && !isSubscribed`
///    → paywall root → **`.paywall`**.
/// 3. `AnalyticsChoiceGate` (inside the passed subscription gate): anything but a resolved consent
///    — the question itself, or the hold before a scope is known — is a full-screen replacement
///    → **nil**; otherwise `ContentView` → **`.inApp`**.
///
/// ## Why auth no longer appears here
/// Before the paywall-first cut-over, `AuthGateView` wrapped everything and its `.signedOut` branch
/// was a whole screen, so `.login` was a *mounted surface* a banner could sit on. Sign-in is now a
/// transient sheet reachable from four places, so there is no such surface: a signed-out user is
/// looking at the paywall or the app, and that is what they are targetable as.
///
/// **Consequence:** ``MessageSurface/login``-targeted messages are no longer deliverable. The case
/// remains so existing payloads still decode, but nothing returns it. Retarget such messages at
/// `.paywall` (pre-purchase) or `.inApp`. A banner stacked over a modal sheet would be the wrong
/// answer even if the presentation state were plumbed here to make it possible.
///
/// `.aboutApp` is never returned here either: it renders inline in the About screen, not as a banner.
enum MessageSurfaceResolver {
	static func surface(
		isReady: Bool,
		paymentsSurfaceEnabled: Bool,
		isSubscribed: Bool,
		analyticsChoicePending: Bool
	) -> MessageSurface? {
		guard isReady else { return nil }
		// The subscription gate is *outside* the analytics gate (see the nesting in
		// MLBrowser.swift), so the paywall wins over a pending analytics choice.
		if paymentsSurfaceEnabled && !isSubscribed { return .paywall }
		if analyticsChoicePending { return nil }
		return .inApp
	}
}
