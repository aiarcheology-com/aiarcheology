//
//  AnalyticsChoiceUITests.swift
//  MLBrowserUITests
//

import XCTest

/// The optional analytics choice is the outermost user-facing gate. This also proves a UI-test
/// app process can render the flow without ever initializing TelemetryDeck.
final class AnalyticsChoiceUITests: UITestCase {
	func testChoiceAppearsBeforeAuthenticationAndNotNowKeepsAnalyticsOff() {
		launch(
			LaunchConfig(
				featureFlagOverrides: ["isAnalyticsEnabled": true],
				analyticsScenario: .prompt
			),
			mockAuthGate: "signedOut"
		)

		assertExists(AID.analyticsChoiceNotNow, true)
		assertExists(AID.authSignIn, false)

		app.buttons[AID.analyticsChoiceNotNow].tap()
		assertExists(AID.authSignIn, true)
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
