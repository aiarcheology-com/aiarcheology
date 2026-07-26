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
/// mounted — a loading/offline screen, or a full-screen replacement like the analytics-consent gate
/// — because the banner must not appear over those.
///
/// ## Precedence (outermost gate wins), matching `MLBrowser.swift`
/// 1. `isReady == false` → the `ProgressView("Loading…")` root → **nil**.
/// 2. `AuthGateView` branches on `gate`:
///    - `.checkingSession` / `.offline` → loading / offline screen → **nil**.
///    - `.signedOut` → the sign-in screen → **`.login`**.
///    - `.ready` → the app proper, which is itself the subscription gate below.
/// 3. `SubscriptionGateView` (inside `.ready`): `paymentsSurfaceEnabled && !isSubscribed`
///    → paywall root → **`.paywall`**; otherwise the analytics gate below.
/// 4. `AnalyticsChoiceGate` (inside the passed subscription gate): `analyticsChoicePending`
///    → full-screen consent → **nil**; otherwise `ContentView` → **`.inApp`**.
///
/// Because the subscription gate nests *outside* the analytics gate, the paywall takes precedence
/// over a pending analytics choice. `.aboutApp` is never returned here: it renders inline in the
/// About screen, not as a banner.
enum MessageSurfaceResolver {
	static func surface(
		isReady: Bool,
		gate: AuthGate,
		paymentsSurfaceEnabled: Bool,
		isSubscribed: Bool,
		analyticsChoicePending: Bool
	) -> MessageSurface? {
		guard isReady else { return nil }

		switch gate {
		case .checkingSession, .offline:
			return nil
		case .signedOut:
			return .login
		case .ready:
			// Subscription gate is *outside* the analytics gate (see the nesting in
			// MLBrowser.swift), so the paywall wins over a pending analytics choice.
			if paymentsSurfaceEnabled && !isSubscribed { return .paywall }
			if analyticsChoicePending { return nil }
			return .inApp
		}
	}
}
