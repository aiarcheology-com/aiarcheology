//
//  FreeAccessUITests.swift
//  MLBrowserUITests
//
//  AIA-0556: the app-managed free-access window in front of the StoreKit paywall. Drives the
//  DEBUG-only mock subscription provider with `-mockSubscription notSubscribed`, so every launch
//  here is a user who owns nothing and whose access depends entirely on the window.
//

import XCTest

/// The window's three presentations and the wall it eventually becomes.
///
/// Two harness facts shape every test below, and both are worth stating once rather than
/// rediscovering:
///
/// 1. **`isFreeAccessPeriodEnabled` is baselined `false` for UI tests** (`DependencyContainer`),
///    because it ships defaulted *on* and would otherwise hand a window to every paywall test in the
///    suite. Each test here opts in explicitly.
/// 2. **Every launch is a fresh install.** `Settings.init()` wipes the ephemeral defaults suite and
///    the Keychain mirror is swapped for an in-memory store, so nothing persists across a relaunch
///    and the day-7 and day-14 states are reachable only by seeding — see
///    `LaunchConfig.freeAccessAnchorAgeDays`.
///
/// Copy is deliberately never asserted: `.testability` mirrors the identifier onto the accessibility
/// label under UI testing, so "14 days free" and "7 days left" are indistinguishable from here.
/// `FreeAccessWindowTests` owns the day arithmetic; these tests own which screen the user meets.
final class FreeAccessUITests: UITestCase {

	/// A brand-new install with no entitlement lands in the **app**, not on the wall, and is told
	/// why by an informational paywall it can dismiss.
	///
	/// The single most important assertion in the suite: before AIA-0556 this exact launch produced
	/// a hard paywall (`SubscriptionGateUITests.testGate_notSubscribed_showsPaywall`, which still
	/// runs with the flag off and still expects that).
	func testDay0_offersTheWindowAndLetsTheUserPastItIntoTheApp() {
		launch(
			LaunchConfig(featureFlagOverrides: ["isFreeAccessPeriodEnabled": true]),
			mockAuthGate: "ready",
			mockSubscription: "notSubscribed"
		)

		assertExists(AID.paywallFreeAccessHeadline, true)
		let continueButton = app.buttons[AID.paywallContinue]
		XCTAssertTrue(continueButton.waitForExistence(timeout: 10), "Day-0 paywall offered no way past")

		continueButton.tap()

		XCTAssertTrue(waitForDisappearance(of: continueButton), "Continue left the paywall on screen")
		assertExists(AID.paywallFreeAccessHeadline, false)
		// The app proper, reached without paying — the whole point of the window.
		assertExists(AID.cpu, true)
	}

	/// Acceptance criterion 8: with the flag off the paywall is develop's screen, and nothing that
	/// exists only to explain a free period renders on it.
	///
	/// Runs on the suite baseline rather than an override, so it also pins that baseline: were the
	/// flag to be un-baselined, this fails rather than silently asserting a window nobody granted.
	func testFlagOff_theWallCarriesNothingAboutAFreePeriod() {
		launch(mockAuthGate: "ready", mockSubscription: "notSubscribed")

		// Paywall-as-root proof, as in SubscriptionGateUITests.
		assertExists(AID.paywallSignOut, true)
		assertExists(AID.paywallContinue, false)
		assertExists(AID.paywallFreeAccessHeadline, false)
	}

	/// Day 7: the reminder states what is left and hands the app straight back. It extends nothing,
	/// which is why the assertions after Continue are identical to day 0's.
	///
	/// The seeded anchor carries `day0Shown`, so the day-0 screen cannot be what is showing here —
	/// it outranks the reminder and would otherwise be indistinguishable.
	func testDay7_remindsAndReturnsTheUserToTheApp() {
		launch(
			LaunchConfig(
				featureFlagOverrides: ["isFreeAccessPeriodEnabled": true],
				freeAccessAnchorAgeDays: 7
			),
			mockAuthGate: "ready",
			mockSubscription: "notSubscribed"
		)

		assertExists(AID.paywallFreeAccessHeadline, true)
		let continueButton = app.buttons[AID.paywallContinue]
		XCTAssertTrue(continueButton.waitForExistence(timeout: 10), "Reminder offered no way back")

		continueButton.tap()

		XCTAssertTrue(waitForDisappearance(of: continueButton), "Continue left the reminder on screen")
		assertExists(AID.cpu, true)
	}

	/// Mid-window and owing nothing: no paywall at all, informational or otherwise. Without this the
	/// two tests above would pass equally well against a build that presented the paywall on every
	/// single launch of an open window.
	func testMidWindow_withNothingOwed_showsNoPaywallAtAll() {
		launch(
			LaunchConfig(
				featureFlagOverrides: ["isFreeAccessPeriodEnabled": true],
				freeAccessAnchorAgeDays: 3
			),
			mockAuthGate: "ready",
			mockSubscription: "notSubscribed"
		)

		assertExists(AID.cpu, true)
		assertExists(AID.paywallContinue, false)
		assertExists(AID.paywallFreeAccessHeadline, false)
	}

	/// Day 20: the window is spent and the wall is what the user meets — with no Continue, because
	/// there is nothing left to continue past.
	func testExpiredWindow_wallsTheUserWithNoWayPast() {
		launch(
			LaunchConfig(
				featureFlagOverrides: ["isFreeAccessPeriodEnabled": true],
				freeAccessAnchorAgeDays: 20
			),
			mockAuthGate: "ready",
			mockSubscription: "notSubscribed"
		)

		assertExists(AID.paywallSignOut, true)
		assertExists(AID.paywallContinue, false)
		// Nothing of the app behind it: a window that was never open this session is walled at the
		// root, not covered over.
		assertExists(AID.cpu, false)
	}

	/// Settings → Subscription becomes a real route to the paywall during the window (AIA-0556).
	/// Before this the row was an inert `HStack` and there was no way to subscribe from Settings.
	///
	/// The sheet is deliberately **not** a gate: no Continue (nothing to continue past — dismissal is
	/// the sheet's own) and no root-gate account controls, which is what keeps it develop's paywall
	/// exactly. Seeded mid-window so no informational presentation is competing for the screen.
	func testSettingsSubscriptionRow_duringTheWindow_opensAPaywallThatIsNotAGate() {
		launch(
			LaunchConfig(
				featureFlagOverrides: ["isFreeAccessPeriodEnabled": true],
				freeAccessAnchorAgeDays: 3
			),
			mockAuthGate: "ready",
			mockSubscription: "notSubscribed"
		)

		openSettings()
		XCTAssertTrue(scrollTo(AID.settingsUpgrade), "Settings has no Subscription row to tap")
		app.buttons[AID.settingsUpgrade].tap()

		// Restore is on every paywall, so it is the presence proof that does not depend on products
		// loading — the mock provider has none.
		assertExists(AID.paywallRestore, true)
		assertExists(AID.paywallContinue, false)
		assertExists(AID.paywallSignOut, false)
	}
}
