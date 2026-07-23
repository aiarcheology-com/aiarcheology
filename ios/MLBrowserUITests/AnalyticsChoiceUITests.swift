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
		XCTAssertTrue(scrollTo(AID.settingsRestoreDefaults), "Restore Defaults is missing")
		element(AID.settingsRestoreDefaults).tap()
		let restoreAlert = app.alerts.firstMatch
		XCTAssertTrue(restoreAlert.waitForExistence(timeout: 5), "Restore Defaults confirmation is missing")
		restoreAlert.buttons["Restore"].tap()

		assertExists(AID.analyticsChoiceNotNow, true)
	}
}
