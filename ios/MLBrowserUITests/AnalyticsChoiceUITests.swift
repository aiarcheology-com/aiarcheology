//
//  AnalyticsChoiceUITests.swift
//  MLBrowserUITests
//

import XCTest

/// The optional analytics choice is now gated behind login + paywall (AIA-0447). These tests also
/// prove a UI-test app process can render the flow without ever initializing TelemetryDeck.
final class AnalyticsChoiceUITests: UITestCase {
	func testChoiceIsGatedBehindSignIn() {
		// AIA-0447: consent no longer fronts the app. Signed out → the sign-in screen shows and
		// the analytics choice stays hidden behind it.
		launch(
			LaunchConfig(
				featureFlagOverrides: ["isAnalyticsEnabled": true],
				analyticsScenario: .prompt
			),
			mockAuthGate: "signedOut"
		)

		assertExists(AID.authSignIn, true)
		assertExists(AID.analyticsChoiceNotNow, false)
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

	func testChoiceAppearsAfterSignInAndPaywall() {
		// Auth ready and subscription satisfied → the choice finally surfaces, after both gates.
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

		assertExists(AID.analyticsChoiceNotNow, true)
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
