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
/// 2. `SubscriptionGateView` is now the root (AIA-0536), and since AIA-0556 it opens on an
///    app-managed free-access window as well as on entitlement. It mirrors
///    ``RootGateDisplay/resolve(isPaymentsSurfaceEnabled:isSubscribed:freeAccess:hasEverShownContent:)``,
///    in that order:
///    - payments surface off, or subscribed → the app, **without consulting the window**
///      (an expired window must never subtract from an entitlement Apple is charging for);
///    - otherwise the window decides: ``FreeAccessAvailability/open`` → the app,
///      ``FreeAccessAvailability/closed`` → the paywall → **`.paywall`**, and
///      ``FreeAccessAvailability/undetermined`` → the gate's hold, a full-screen `ProgressView`
///      while the anchor stores are read → **nil**.
/// 3. `AnalyticsChoiceGate` (inside the passed subscription gate): anything but a resolved consent
///    — the question itself, or the hold before a scope is known — is a full-screen replacement
///    → **nil**; otherwise `ContentView` → **`.inApp`**.
///
/// ## Why the window has to be an input
/// A free-window user is `paymentsSurfaceEnabled == true, isSubscribed == false` and is sitting in
/// `ContentView`. Answering `.paywall` for them would fire every "Subscribe now, 40% off" banner
/// over the working app and withhold every `.inApp` message for the length of the window.
///
/// The gate presents an expired window as an overlay *over* retained content rather than a root
/// swap, so `.closed` resolves to `.paywall` either way: the paywall is what the user is looking at,
/// and it is what they are targetable as.
///
/// ## Why auth no longer appears here
/// Before the paywall-first cut-over, the since-deleted `AuthGateView` wrapped everything and its `.signedOut` branch
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
		freeAccess: FreeAccessAvailability,
		analyticsChoicePending: Bool
	) -> MessageSurface? {
		guard isReady else { return nil }
		// The subscription gate is *outside* the analytics gate (see the nesting in
		// MLBrowser.swift), so whatever it renders wins over a pending analytics choice.
		if paymentsSurfaceEnabled, isSubscribed == false {
			switch freeAccess {
			case .closed:
				return .paywall
			case .undetermined:
				// The gate is holding on a spinner. Not a messageable surface, and transient — it
				// lasts exactly as long as the two anchor stores take to answer.
				return nil
			case .open:
				// The gate is open on the window, so the app proper is mounted: fall through to the
				// analytics gate nested inside it.
				break
			}
		}
		if analyticsChoicePending { return nil }
		return .inApp
	}
}
