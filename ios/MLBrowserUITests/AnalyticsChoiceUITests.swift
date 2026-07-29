//
//  AnalyticsChoiceUITests.swift
//  MLBrowserUITests
//

import XCTest

/// The optional analytics choice sits behind the paywall (AIA-0447), and since the paywall-first
/// cut-over that is the *only* thing in front of it (AIA-0536). These tests also prove a UI-test app
/// process can render the flow without ever initializing TelemetryDeck.
final class AnalyticsChoiceUITests: UITestCase {

	/// **Inverted by AIA-0536.** Consent used to require an account: the prompt demanded one and a
	/// signed-out user met the sign-in screen instead. Entitled anonymous users exist now, and the
	/// question — "may we attribute your usage" — is one they can answer, so they are asked.
	func testChoiceIsAskedOfAnEntitledAnonymousUser() {
		launch(
			LaunchConfig(
				featureFlagOverrides: ["isAnalyticsEnabled": true],
				analyticsScenario: .prompt
			),
			mockAuthGate: "signedOut",
			mockSubscription: "subscribed"
		)

		assertExists(AID.analyticsChoiceNotNow, true)
		// There is no sign-in screen that could have been shown instead.
		assertExists(AID.authSignIn, false)
	}

	func testChoiceIsGatedBehindPaywall() {
		// Signed in but not subscribed → the paywall is the root; the choice stays hidden behind it.
		launch(
			LaunchConfig(
				featureFlagOverrides: ["isAnalyticsEnabled": true],
				analyticsScenario: .prompt
			),
			mockAuthGate: "ready",
			mockSubscription: "notSubscribed"
		)

		assertExists(AID.paywallSignOut, true)   // paywall-as-root proof (see SubscriptionGateUITests)
		assertExists(AID.analyticsChoiceNotNow, false)
	}

	func testChoiceAppearsAfterThePaywall() {
		// Entitled → the choice surfaces. Signing in is no longer part of reaching it.
		launch(
			LaunchConfig(
				featureFlagOverrides: ["isAnalyticsEnabled": true],
				analyticsScenario: .prompt
			),
			mockAuthGate: "ready",
			mockSubscription: "subscribed"
		)

		assertExists(AID.analyticsChoiceNotNow, true)
		assertExists(AID.authSignIn, false)
	}

	func testNotNowLeavesAnalyticsDisabledInSettings() {
		launch(
			LaunchConfig(
				featureFlagOverrides: ["isAnalyticsEnabled": true],
				analyticsScenario: .prompt
			)
		)

		app.buttons[AID.analyticsChoiceNotNow].tap()
		openSettings()
		XCTAssertTrue(scrollTo(AID.settingsAnalytics), "Analytics toggle is missing")
		let analyticsToggle = app.switches.matching(identifier: AID.settingsAnalytics).firstMatch
		XCTAssertEqual(analyticsToggle.value as? String, "0", "Not now must keep analytics disabled")
	}

	func testRestoreDefaultsTurnsAnalyticsOffAndShowsChoiceAgain() {
		launch(
			LaunchConfig(
				featureFlagOverrides: ["isAnalyticsEnabled": true],
				analyticsScenario: .enabled
			)
		)
		openSettings()
		// Restore Defaults now lives behind the "Reset" entry in the ML Browser section.
		XCTAssertTrue(scrollTo(AID.settingsReset), "Reset row missing from ML Browser section")
		element(AID.settingsReset).tap()
		XCTAssertTrue(scrollTo(AID.settingsRestoreDefaults), "Restore Defaults is missing")
		element(AID.settingsRestoreDefaults).tap()
		let restoreAlert = app.alerts.firstMatch
		XCTAssertTrue(restoreAlert.waitForExistence(timeout: 5), "Restore Defaults confirmation is missing")
		restoreAlert.buttons["Restore"].tap()

		// The question is raised at once but waits *behind* Settings rather than tearing it away
		// (AIA-0536). It used to appear instantly only because resetting swapped the app root out,
		// which destroyed this sheet as a side effect — along with whatever the user was browsing.
		//
		// Hittability, not existence: the overlay is in the accessibility tree the moment it renders,
		// it simply is not reachable while a sheet covers it. Asserting absence would pass for the
		// wrong reason if the overlay never rendered at all, so existence is asserted first.
		let choice = element(AID.analyticsChoiceNotNow)
		XCTAssertTrue(choice.waitForExistence(timeout: 5), "Restore Defaults should raise the choice again")
		XCTAssertFalse(choice.isHittable, "the choice must wait behind Settings, not tear it away")

		// Restore Defaults lives on a pushed sub-screen, so leave it before the sheet can be closed.
		let back = app.navigationBars.buttons.element(boundBy: 0)
		XCTAssertTrue(back.waitForExistence(timeout: 5), "Reset screen has no back button")
		back.tap()
		// `.firstMatch`, not a subscript: under UI testing `.testability` mirrors the identifier into
		// the accessibility label too, so a plain lookup matches the same control twice and the tap
		// fails as ambiguous rather than as missing (same trap as `SubscriptionGateUITests`).
		let dismiss = app.buttons.matching(identifier: AID.settingsDismiss).firstMatch
		XCTAssertTrue(dismiss.waitForExistence(timeout: 5), "Settings root did not come back")
		dismiss.tap()

		XCTAssertTrue(choice.waitForExistence(timeout: 5), "the choice should survive Settings closing")
		XCTAssertTrue(choice.isHittable, "once Settings is closed the choice is answerable")
	}

	// MARK: - Account-scoped consent (AIA-0437)

	/// The flag-ON path, which every other test in this file leaves untouched: with the cross-device
	/// identity feature enabled the choice is account-scoped, so it may only be asked of a signed-in
	/// account, and answering it must actually dismiss it.
	///
	/// **Deliberately does not assert the cross-launch half** ("A is not asked twice, B is asked for
	/// itself"), even though that is the heart of the feature. Two harness properties make it
	/// unreliable rather than merely slow: `UITestLaunchConfiguration.applyIfNeeded` re-applies a
	/// full settings baseline on *every* launch, and `XCUIApplication.launch()` terminates the
	/// previous instance abruptly, so a `UserDefaults` write from the prior launch is not guaranteed
	/// to have flushed. That behaviour is covered where it can be asserted honestly — see
	/// `AnalyticsTests.testFunnelEvents_AcrossARelaunch_AreNotReportedASecondTime` and the
	/// account-switch tests beside it, which construct a second `AnalyticsState` over the same
	/// `Settings` instead of relying on process death.
	func testChoice_WithAccountIdentityEnabled_IsAskedAndAnsweredForTheSignedInAccount() {
		launch(
			LaunchConfig(
				featureFlagOverrides: [
					"isAnalyticsEnabled": true,
					"isCrossDeviceAnalyticsIdentityEnabled": true
				],
				analyticsScenario: .prompt
			),
			mockAuthGate: "ready",
			mockSubscription: "subscribed",
			mockAccountID: "user_2aaaaaaaaaaaaaaaaaaaaaaaaa"
		)

		assertExists(AID.analyticsChoiceEnable, true)
		element(AID.analyticsChoiceEnable).tap()
		// A consent screen that survives its own answer strands the user with no way forward. With
		// the feature on, answering also requires an account to record the choice against, so this
		// is what proves the account actually reached `AnalyticsState` before the tap.
		assertExists(AID.analyticsChoiceEnable, false)
	}
}
