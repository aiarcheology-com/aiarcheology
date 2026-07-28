//
//  SubscriptionGateUITests.swift
//  MLBrowserUITests
//
//  AIA-0343: whole-app subscription gate. Drives the DEBUG-only mock subscription
//  provider via `-mockSubscription <state>` so the paywall-as-root behavior can be
//  asserted deterministically, with no StoreKit or App Store involved.
//

import XCTest

final class SubscriptionGateUITests: UITestCase {

	/// `notSubscribed` → the paywall is the root; the app proper stays hidden.
	/// (The mock provider has no StoreKit products, so the paywall renders its
	/// "unavailable" state plus the root-gate sign-out — no Subscribe button. The
	/// sign-out affordance is the reliable proof the paywall is the root, and it's
	/// the Apple 5.1.1(v) escape.)
	func testGate_notSubscribed_showsPaywall() {
		launch(mockSubscription: "notSubscribed")
		assertExists(AID.paywallSignOut, true)
		// The app chrome (side-menu button) must not be reachable behind the gate.
		assertExists(AID.cpu, false)
	}

	/// `subscribed` (the default) → the gate passes through to the app.
	func testGate_subscribed_entersApp() {
		launch(mockSubscription: "subscribed")
		assertExists(AID.cpu, true)
		assertExists(AID.paywallSubscribe, false)
	}

	/// The "ship dark" contract (AIA-0350): with `isPaymentsEnabled` off, the whole gate is
	/// bypassed — a user with **no** entitlement reaches the app and never sees the paywall.
	/// This is what makes the payments surface safe to ship before it is switched on, and it
	/// is the one combination the two tests above cannot produce (both run with the flag on).
	func testGate_paymentsFlagOff_bypassesPaywall() {
		launch(
			LaunchConfig(featureFlagOverrides: ["isPaymentsEnabled": false]),
			mockAuthGate: "ready",
			mockSubscription: "notSubscribed"
		)
		// The app proper is reachable despite there being no entitlement.
		assertExists(AID.cpu, true)
		// …and nothing of the paywall is on screen (the sign-out affordance is root-gate only,
		// so its absence is the proof the paywall is not the root).
		assertExists(AID.paywallSignOut, false)
		assertExists(AID.paywallSubscribe, false)
	}

	/// Apple 5.1.1(v): a non-subscriber stuck behind the root paywall must be able to leave.
	/// The control's *existence* was already asserted above; this actually taps it and proves
	/// the app returns to the sign-in screen, which is the part that has to work.
	func testPaywallSignOut_returnsToSignInScreen() {
		launch(mockAuthGate: "ready", mockSubscription: "notSubscribed")
		let signOut = app.buttons[AID.paywallSignOut]
		XCTAssertTrue(signOut.waitForExistence(timeout: 10), "Paywall sign-out affordance missing")
		signOut.tap()

		assertExists(AID.authSignIn, true)
		assertExists(AID.paywallSignOut, false)
	}

	/// The other half of the 5.1.1(v) escape: delete the account from behind the root paywall.
	/// Confirms the dialog, since the destructive action is the whole point of the flow.
	func testPaywallDeleteAccount_confirmed_returnsToSignInScreen() {
		launch(mockAuthGate: "ready", mockSubscription: "notSubscribed")

		// Both the button and the dialog's destructive action carry their own identifiers, so this
		// no longer depends on localized text — the two share a label and could not otherwise be
		// told apart.
		let delete = app.buttons[AID.paywallDeleteAccount]
		XCTAssertTrue(delete.waitForExistence(timeout: 10), "Paywall delete-account affordance missing")
		delete.tap()

		// `confirmationDialog` surfaces as an action sheet; accept an alert too rather than
		// pinning to one host representation. Scoping the confirm to the dialog matters: its
		// destructive action carries the *same* label as the button that opened it.
		let sheet = app.sheets.firstMatch
		let alert = app.alerts.firstMatch
		XCTAssertTrue(
			sheet.waitForExistence(timeout: 10) || alert.waitForExistence(timeout: 5),
			"Delete-account confirmation was not presented"
		)
		let dialog = sheet.exists ? sheet : alert
		// `.firstMatch`, not a subscript: under UI testing `.testability` mirrors the identifier into
		// the accessibility label too, so a plain lookup matches the same control twice and the tap
		// fails as ambiguous rather than as missing.
		let confirm = dialog.buttons.matching(identifier: AID.paywallDeleteAccountConfirm).firstMatch
		XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Confirmation is missing its destructive action")
		confirm.tap()

		assertExists(AID.authSignIn, true)
		assertExists(AID.paywallSignOut, false)
	}
}
