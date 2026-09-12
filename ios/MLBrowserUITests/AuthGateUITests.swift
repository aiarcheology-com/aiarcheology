//
//  AuthGateUITests.swift
//  MLBrowserUITests
//
//  AIA-0340 launch-gate coverage, inverted by the paywall-first cut-over (AIA-0536).
//  Drives the DEBUG-only mock auth provider via `-mockAuthGate <state>` so each auth state can be
//  asserted deterministically, with no Clerk SDK or network involved.
//

import XCTest

/// **These assertions are deliberately the opposite of what they used to be.**
///
/// Auth was the outermost gate: signed-out showed a sign-in screen, offline showed a fail-closed
/// "needs connection" screen, and neither let the app render. Entitlement is what gates now (#543),
/// so every auth state below reaches the app as long as the user is entitled — which is precisely
/// what these tests exist to hold. A regression toward the old behaviour is a paying user locked out.
final class AuthGateUITests: UITestCase {

	/// Signed out + entitled → straight into the app. There is no sign-in screen to land on.
	func testSignedOut_entitled_entersApp() {
		launch(mockAuthGate: "signedOut", mockSubscription: "subscribed")
		assertExists(AID.cpu, true)
		assertExists(AID.authSignIn, false)
	}

	/// Offline + entitled → straight into the app.
	///
	/// This is the case AIA-0536 exists to fix, and why consequence 3 in `AUTH-SUBSCRIPTION.md` is
	/// gone. A paying user foregrounding in airplane mode used to be held at "needs connection", in
	/// front of an app whose ML features are entirely on-device. An unverifiable session now surfaces
	/// as `.suspended`: it declines to tag purchases or select a consent scope, and blocks nothing.
	func testOffline_entitled_entersApp() {
		launch(mockAuthGate: "offline", mockSubscription: "subscribed")
		assertExists(AID.cpu, true)
	}

	/// The same offline case with **both analytics flags on**, which is the configuration that was
	/// actually broken — the plain test above passed while the app hung.
	///
	/// With the feature flag off the consent gate short-circuits to "resolved" and never holds; with
	/// `isCrossDeviceAnalyticsIdentityEnabled` off, consent uses the device-wide bucket, which needs
	/// no network, so an offline user is simply asked. Only when the scope depends on *who is signed
	/// in* does an unverifiable session leave nothing to select — and the gate then held on a spinner
	/// for a state that by definition never resolves, reinstating through the consent gate the very
	/// lockout the auth gate had stopped causing. Analytics is simply off until a scope exists.
	func testOffline_entitled_withAccountScopedAnalytics_stillEntersApp() {
		launch(
			LaunchConfig(
				featureFlagOverrides: [
					"isAnalyticsEnabled": true,
					"isCrossDeviceAnalyticsIdentityEnabled": true
				],
				analyticsScenario: .prompt
			),
			mockAuthGate: "offline",
			mockSubscription: "subscribed"
		)
		assertExists(AID.cpu, true)
		// No scope can be selected, so there is nothing to ask — and nothing to wait for either.
		assertExists(AID.analyticsChoiceNotNow, false)
	}

	/// Signed in + entitled → the app, as before. The one row the cut-over leaves alone.
	func testReady_entitled_entersApp() {
		launch(mockAuthGate: "ready", mockSubscription: "subscribed")
		assertExists(AID.cpu, true)
		assertExists(AID.authSignIn, false)
	}

	/// The drawer's bottom row is always "who am I" (AIA-0536): Sign In while signed out, the
	/// account while signed in — never an empty slot. It vanishing after sign-in read as a context
	/// cut in manual testing, so both directions are pinned.
	func testDrawerBottomRow_followsTheSession() {
		launch(mockAuthGate: "ready", mockSubscription: "subscribed")
		openDrawer()
		assertExists(AID.drawerAccount, true)
		assertExists(AID.drawerSignIn, false)
	}

	func testDrawerBottomRow_offersSignInWhileSignedOut() {
		launch(mockAuthGate: "signedOut", mockSubscription: "subscribed")
		openDrawer()
		assertExists(AID.drawerSignIn, true)
		assertExists(AID.drawerAccount, false)
	}

	/// Offline, the account must stay *visible* — signed in and unverifiable is a state to show,
	/// not to hide (an empty slot reads as broken, which is exactly how manual testing found it).
	/// Inert rather than absent: sign-in would fail with no network, and Clerk cannot render the
	/// profile, so neither actionable row appears — but the indicator does.
	func testOffline_entitled_drawerShowsTheAccountAsUnreachable() {
		launch(mockAuthGate: "offline", mockSubscription: "subscribed")
		openDrawer()
		assertExists(AID.drawerAccountOffline, true)
		assertExists(AID.drawerAccount, false)
		assertExists(AID.drawerSignIn, false)
	}

	func testOffline_entitled_settingsShowsTheAccountAsUnreachable() {
		launch(mockAuthGate: "offline", mockSubscription: "subscribed")
		openSettings()
		// The account section sits deep in the Form and SwiftUI creates rows lazily — an
		// off-screen row does not exist in the accessibility tree until scrolled to.
		XCTAssertTrue(scrollTo(AID.settingsAccountOffline), "account-offline row missing from Settings")
		assertExists(AID.settingsSignIn, false)
	}

	/// Not entitled → the paywall, whatever auth says. Entitlement is the gate, so this holds for a
	/// signed-out user exactly as it does for a signed-in one.
	func testSignedOut_notEntitled_showsPaywallWithSignIn() {
		launch(mockAuthGate: "signedOut", mockSubscription: "notSubscribed")
		assertExists(AID.cpu, false)
		// The signed-out account control, which is the only route to account recovery or deletion
		// for someone who has lapsed and signed out.
		assertExists(AID.paywallSignIn, true)
		assertExists(AID.paywallSignOut, false)
	}
}
