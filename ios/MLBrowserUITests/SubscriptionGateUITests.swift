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

		// **The wall must stay a wall** (AIA-0616). AIA-0616 gave the paywall a close button so the
		// Settings presentation stops reading as "subscribe or nothing" during the free window. This
		// is the other half of that change: here both free phases are spent, there is nothing behind
		// this screen, and a dismiss control would close the app's only screen into nothing.
		//
		// It is asserted at the *gate* rather than trusted from the view's `isDeadEnd` check, because
		// the failure this guards against is someone later making the button unconditional — which
		// reads as a harmless tidy-up and would be invisible without this line.
		assertExists(AID.paywallDismiss, false)
	}

	/// AIA-0988: access lost mid-session lays the paywall *over* the app (`.wallOverContent`) rather
	/// than replacing it, so the browser stays mounted beneath — and must not stay reachable. The
	/// lapse arrives the way a real one does: the mock drops the entitlement while the app is in the
	/// background, and the gate's foreground re-check publishes it.
	///
	/// What this test can and cannot prove. It cannot show the covered app is hidden: unlike the
	/// Welcome screen, the paywall's content view is one full-screen accessibility element, so every
	/// hit-test point lands on it with or without the fix (measured by removing the fix), and
	/// VoiceOver's swipe order is not observable from XCUITest. The hiding mechanism is shared with
	/// the Welcome screen and proven by
	/// `FreeAccessUITests.testWelcome_hidesTheAppBeneathItFromAccessibility`; this paywall's swipe
	/// order is the manual VoiceOver check.
	///
	/// What it does prove is the risk that hiding adds: the Settings sheet, presented from inside the
	/// very content being hidden, must stay usable over the paywall, and a sheet the paywall itself
	/// presents must be reachable over it.
	func testPaywallOverContent_hidesTheAppAndKeepsSheetsReachable() {
		launch(mockAuthGate: "ready", mockSubscriptionLapsesInBackground: true)
		XCTAssertTrue(waitForHittable(element(AID.cpu), timeout: 15), "The app never became reachable")

		openSettings()
		XCUIDevice.shared.press(.home)
		app.activate()

		XCTAssertTrue(element(AID.paywallContent).waitForExistence(timeout: 15), "The lapse did not raise the paywall")
		let settingsDismiss = app.buttons[AID.settingsDismiss]
		XCTAssertTrue(
			waitForHittable(settingsDismiss),
			"The Settings sheet stopped being reachable when the content beneath the paywall was hidden"
		)
		settingsDismiss.tap()

		let restore = element(AID.paywallRestore)
		XCTAssertTrue(waitForHittable(restore), "The paywall laid over the app is not reachable")
		// The app is still mounted underneath — covered, not replaced — so this is `.wallOverContent`
		// and not the root wall, which has nothing beneath it to hide.
		XCTAssertTrue(element(AID.cpAppMode).exists, "The app is not mounted under the paywall")
		XCTAssertTrue(scrollTo(AID.paywallPrivacyPolicy), "Paywall has no Privacy Policy link")
		app.buttons[AID.paywallPrivacyPolicy].tap()
		let marker = app.staticTexts
			.matching(NSPredicate(format: "label CONTAINS[c] %@", "Data Controller"))
			.firstMatch
		XCTAssertTrue(waitForHittable(marker, timeout: 20), "A sheet presented over the paywall is not reachable")
	}

	/// **Schedule 2 §3.8(b) says the privacy-policy link must be *functional*, and this is what
	/// checks it** (AIA-0616).
	///
	/// It was not. The link opened a sheet that rendered the correct document invisibly — the HTML
	/// converted fine, but the view then replaced every attribute in the attributed string with a
	/// SwiftUI `Color` stored under a UIKit key, so 14 308 characters were laid out and drawn in
	/// nothing. A reviewer tapping this on the paywall got a blank page.
	///
	/// **Read this before strengthening the assertions.** A UI test cannot see the original bug.
	/// XCUITest walks the accessibility tree, not pixels, and the old renderer laid the text out
	/// perfectly and drew it in an unresolvable colour — so every word was present to a test and
	/// absent to a human. Asserting only on the document's text passes against the broken build;
	/// that was measured by reverting the renderer, not assumed.
	///
	/// So this pins two things that *are* mechanically checkable, and no more:
	///   1. the sheet contains the document (catches a missing file, a failed load, an empty sheet);
	///   2. it renders through a web view, which is the only path that honours the document's own
	///      stylesheet — including its `prefers-color-scheme` block, i.e. the thing whose absence
	///      made the text invisible.
	///
	/// The second is an implementation assertion, deliberately. It is the only signal available
	/// here, and it fails loudly if someone swaps in another renderer — at which point they should
	/// re-verify by eye, because this test cannot.
	func testPaywall_privacyPolicyLink_opensASheetThatActuallyHasTheDocument() {
		launch(mockSubscription: "notSubscribed")

		XCTAssertTrue(scrollTo(AID.paywallPrivacyPolicy), "Paywall has no Privacy Policy link")
		app.buttons[AID.paywallPrivacyPolicy].tap()

		// "Data Controller" is the §1 heading, far enough into the document that finding it proves
		// the body rendered rather than just a title bar.
		let marker = app.staticTexts
			.matching(NSPredicate(format: "label CONTAINS[c] %@", "Data Controller"))
			.firstMatch
		XCTAssertTrue(
			marker.waitForExistence(timeout: 20),
			"Privacy Policy sheet opened but contains none of the document"
		)

		XCTAssertTrue(
			app.webViews.firstMatch.waitForExistence(timeout: 10),
			"The policy must render in a web view — it is the only path that applies the document's "
				+ "own stylesheet, and rendering it any other way is what drew it invisibly before"
		)
	}

	/// AIA-0564: the centered, full-height stack clipped the paywall's upper and lower content in
	/// landscape. The tallest presentation is used deliberately, so this proves a real ScrollView
	/// rather than merely a shorter layout.
	///
	/// That used to be the day-0 free-access presentation. Since AIA-0567 split the screen, day 0 is
	/// `WelcomeView` — which carries no account actions and is not this screen at all — so the launch
	/// seeds an **expired** window instead. The wall is now the tallest paywall by some margin: it
	/// alone adds the findings escape hatch and the 5.1.1(v) account controls on top of the headline,
	/// the description, the benefit bullets and the required 3.1.2 disclosure.
	func testGate_landscapeScrollsToRootAccountActions() {
		launch(
			LaunchConfig(
				featureFlagOverrides: ["isFreeAccessPeriodEnabled": true],
				freeAccessAnchorAgeDays: 20
			),
			mockAuthGate: "ready",
			mockSubscription: "notSubscribed"
		)
		let paywall = app.scrollViews[AID.paywallContent]
		XCTAssertTrue(paywall.waitForExistence(timeout: 10), "Paywall content is not scrollable")
		let signOut = app.buttons[AID.paywallSignOut]
		XCTAssertTrue(signOut.waitForExistence(timeout: 10), "Paywall root account actions did not load")

		XCUIDevice.shared.orientation = .landscapeLeft
		XCTAssertTrue(waitForLandscape(), "Paywall did not relayout in landscape")

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

		// The billing warning ships with a remedy; this asserts the remedy is on screen (AIA-0528).
		// A dialog action that silently fails to render would leave the warning pointing at
		// nothing, and nothing else in the suite would notice.
		//
		// Asserting presence, not tapping: the tap leaves the app for the App Store and would
		// strand the test. Note what this therefore does *not* cover — that the action actually
		// opens the URL — which is why the implementation uses the documented `Button` construct
		// rather than a `Link` whose tap routing in an action sheet is unspecified.
		let manage = dialog.buttons.matching(identifier: AID.paywallDeleteAccountManage).firstMatch
		XCTAssertTrue(
			manage.waitForExistence(timeout: 5),
			"Delete-account confirmation is missing its Manage Subscription action"
		)

		// Export First… is conditional on this device holding findings (AIA-0779), and the
		// UI-testing launch path wipes the Caches store — so the empty-store branch is the only one
		// reachable from here, and its absence is the assertion. The populated branch is covered by
		// `PaywallAccountDeletionPromptTests`, which can state it without a simulator.
		XCTAssertFalse(
			dialog.buttons.matching(identifier: AID.paywallDeleteAccountExportFindings).firstMatch.exists,
			"Delete-account confirmation offered a findings export with nothing saved to export"
		)

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
