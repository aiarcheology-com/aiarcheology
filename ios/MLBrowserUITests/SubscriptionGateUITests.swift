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

	/// AIA-0564: the centered, full-height stack clipped the paywall's upper and lower content in
	/// landscape. The free-access presentation has enough required copy and actions to overflow a
	/// short window, so it proves this is a real ScrollView rather than merely a shorter layout.
	func testGate_landscapeScrollsToRootAccountActions() {
		launch(
			LaunchConfig(featureFlagOverrides: ["isFreeAccessPeriodEnabled": true]),
			mockAuthGate: "ready",
			mockSubscription: "notSubscribed"
		)
		let paywall = app.scrollViews[AID.paywallContent]
		XCTAssertTrue(paywall.waitForExistence(timeout: 10), "Paywall content is not scrollable")

		XCUIDevice.shared.orientation = .landscapeLeft
		XCTAssertTrue(waitForLandscape(), "Paywall did not relayout in landscape")

		let signOut = app.buttons[AID.paywallSignOut]
		for _ in 0..<8 where !signOut.isHittable {
			paywall.swipeUp()
		}
		XCTAssertTrue(signOut.isHittable, "Landscape paywall never reached its root account actions")
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

	/// Apple 5.1.1(v): a non-subscriber must be able to leave their account from the root paywall.
	///
	/// **Inverted by AIA-0536.** Signing out used to eject the user to a sign-in screen, because auth
	/// was the outer gate. It no longer is: the user stays exactly where they are, and the paywall's
	/// account controls swap to Sign In. That swap is the whole 5.1.1(v) story now — without it a
	/// signed-out lapsed subscriber could not reach their account again without buying first.
	func testPaywallSignOut_staysOnPaywallAndOffersSignIn() {
		launch(mockAuthGate: "ready", mockSubscription: "notSubscribed")
		let signOut = app.buttons[AID.paywallSignOut]
		XCTAssertTrue(signOut.waitForExistence(timeout: 10), "Paywall sign-out affordance missing")
		signOut.tap()

		let signIn = app.buttons[AID.paywallSignIn]
		XCTAssertTrue(signIn.waitForExistence(timeout: 10), "Paywall did not offer sign-in after signing out")
		assertExists(AID.paywallSignOut, false)
		// Still the paywall, not the app: the entitlement did not change, so the gate did not move.
		assertExists(AID.cpu, false)
	}

	/// The other half of the 5.1.1(v) escape: delete the account from the root paywall.
	/// Confirms the dialog, since the destructive action is the whole point of the flow.
	func testPaywallDeleteAccount_confirmed_staysOnPaywallAndOffersSignIn() {
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

		// Same inversion as sign-out: deletion leaves the user on the paywall, now signed out.
		let signIn = app.buttons[AID.paywallSignIn]
		XCTAssertTrue(signIn.waitForExistence(timeout: 10), "Paywall did not offer sign-in after deletion")
		assertExists(AID.paywallSignOut, false)
	}
}
