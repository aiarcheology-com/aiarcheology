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
	func testGate_notSubscribed_showsPaywall() throws {
		throw XCTSkip("Paywall-root path is dark under the AIA-0419 free public beta (FeatureFlags.isPaymentsEnabled == false): a non-subscriber now enters the app, so the paywall is no longer the root gate. Restore the paywall-root assertions when payments are re-enabled.")
	}

	/// `subscribed` (the default) → the gate passes through to the app.
	func testGate_subscribed_entersApp() {
		launch(mockSubscription: "subscribed")
		assertExists(AID.cpu, true)
		assertExists(AID.paywallSubscribe, false)
	}
}
