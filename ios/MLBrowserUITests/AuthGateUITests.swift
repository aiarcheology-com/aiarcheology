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

	/// `locked` → the "access pending" screen with a sign-out affordance.
	func testGate_locked_showsLockedScreen() {
		launch(mockAuthGate: "locked")
		assertExists(AID.authLockedSignOut, true)
		assertExists(AID.cpu, false)
	}

	/// `offline` → the fail-closed "needs connection" screen with a retry affordance.
	func testGate_offline_showsOfflineScreen() {
		launch(mockAuthGate: "offline")
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
