//
//  AuthGateUITests.swift
//  MLBrowserUITests
//
//  AIA-0340: authentication launch-gate coverage. Drives the DEBUG-only mock auth
//  provider via the `-mockAuthGate <state>` launch argument so each gate state can be
//  asserted deterministically, with no Clerk SDK or network involved.
//

import XCTest

final class AuthGateUITests: UITestCase {

	/// `signedOut` → the branded sign-in screen, and the app proper stays hidden.
	func testGate_signedOut_showsSignInScreen() {
		launch(mockAuthGate: "signedOut")
		assertExists(AID.authSignIn, true)
		// The app chrome (side-menu button) must not be reachable behind the gate.
		assertExists(AID.cpu, false)
	}

	/// `offline` → the fail-closed "needs connection" screen with a retry affordance.
	///
	/// The entitlement is pinned explicitly: the intent is that a **paying** user is still held
	/// at the offline screen, because the auth gate sits outside the subscription gate and fails
	/// closed regardless of what they own. That was only ever covered by accident before — the
	/// mock subscription happens to default to `.subscribed`, so the case the test actually ran
	/// was invisible in its own source and one default change away from silently becoming a
	/// different test.
	func testGate_offline_showsOfflineScreen() {
		launch(mockAuthGate: "offline", mockSubscription: "subscribed")
		assertExists(AID.authOfflineRetry, true)
		assertExists(AID.cpu, false)
	}

	/// `ready` → the gate is satisfied and the app loads; no gate screen remains.
	func testGate_ready_entersApp() {
		launch(mockAuthGate: "ready")
		// App chrome appears (same anchor the other suites rely on for "loaded").
		assertExists(AID.cpu, true)
		assertExists(AID.authSignIn, false)
	}
}
