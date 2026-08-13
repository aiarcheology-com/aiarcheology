//
//  FreeAccessUITests.swift
//  MLBrowserUITests
//
//  AIA-0556: the app-managed free-access window in front of the StoreKit paywall. Drives the
//  DEBUG-only mock subscription provider with `-mockSubscription notSubscribed`, so every launch
//  here is a user who owns nothing and whose access depends entirely on the window.
//
//  AIA-0567 split that one screen in two: the day-0 offer is `WelcomeView` (`welcome*`), the hard
//  wall is `PaywallView` (`paywall*`), and the day-7 reminder is gone. The tour now runs *after*
//  Welcome, which is why the ordering tests live here rather than in `TourUITests` — the screen
//  that has to go first is this feature's.
//

import XCTest

/// The window's one presentation, the wall it eventually becomes, and the order it hands the
/// screen to onboarding.
///
/// Three harness facts shape every test below, and all three are worth stating once rather than
/// rediscovering:
///
/// 1. **`isFreeAccessPeriodEnabled` is baselined `false` for UI tests** (`DependencyContainer`),
///    because it ships defaulted *on* and would otherwise hand a window to every paywall test in the
///    suite. Each test here opts in explicitly — a launch that sets only `startOnboardingTour` will
///    never see a Welcome screen at all.
/// 2. **Every launch is a fresh install.** `Settings.init()` wipes the ephemeral defaults suite and
///    the Keychain mirror is swapped for an in-memory store, so nothing persists across a relaunch
///    and the day-14 state is reachable only by seeding — see `LaunchConfig.freeAccessAnchorAgeDays`.
/// 3. **The mock subscription provider has no `Product`s** (one cannot be constructed outside
///    StoreKit), so no paywall in this suite renders a Subscribe button. `paywallContent` is the
///    wall's presence proof, and `paywallRestore` — present on every presentation — is the route by
///    which a walled user acquires an entitlement here.
///
/// Copy is deliberately never asserted: `.testability` mirrors the identifier onto the accessibility
/// label under UI testing, so "14 days free" and "7 days left" are indistinguishable from here.
/// `FreeAccessWindowTests` owns the day arithmetic; these tests own which screen the user meets.
final class FreeAccessUITests: UITestCase {

	/// The launch every ordering test shares: a fresh install with an open window and onboarding
	/// armed but not yet started. Free access must be enabled explicitly (see fact 1) or there is no
	/// Welcome screen for the tour to queue behind, and the test would prove nothing.
	private func launchFirstRunWithTourArmed() {
		launch(
			LaunchConfig(
				startOnboardingTour: true,
				featureFlagOverrides: ["isFreeAccessPeriodEnabled": true]
			),
			mockAuthGate: "ready",
			mockSubscription: "notSubscribed"
		)
	}

	/// A brand-new install with no entitlement lands in the **app**, not on the wall, and is told
	/// why by a Welcome screen it can dismiss.
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

		assertExists(AID.welcomeHeadline, true)
		// Restore is on every `PaywallView` presentation, so its absence is what proves AIA-0567
		// actually swapped the screen rather than merely relabelling the old one.
		assertExists(AID.paywallRestore, false)
		let continueButton = app.buttons[AID.welcomeContinue]
		XCTAssertTrue(continueButton.waitForExistence(timeout: 10), "Day-0 welcome offered no way past")

		continueButton.tap()

		XCTAssertTrue(waitForDisappearance(of: continueButton), "Continue left the welcome screen on screen")
		assertExists(AID.welcomeHeadline, false)
		// The app proper, reached without paying — the whole point of the window.
		assertExists(AID.cpu, true)
	}

	/// Acceptance criterion 8: with the flag off the paywall is develop's screen, and the Welcome
	/// screen — which exists only to explain a free period — is never reached.
	///
	/// Runs on the suite baseline rather than an override, so it also pins that baseline: were the
	/// flag to be un-baselined, this fails rather than silently asserting a window nobody granted.
	///
	/// AIA-0567 retargeted the two absence assertions: they named the day-0 paywall's Continue and
	/// headline identifiers, which the split deleted — absences that could no longer fail.
	func testFlagOff_theWallCarriesNothingAboutAFreePeriod() {
		launch(mockAuthGate: "ready", mockSubscription: "notSubscribed")

		// Paywall-as-root proof, as in SubscriptionGateUITests.
		assertExists(AID.paywallSignOut, true)
		assertExists(AID.welcomeContinue, false)
		assertExists(AID.welcomeContent, false)
	}

	/// Mid-window and owing nothing: no screen at all in front of the app, informational or
	/// otherwise. Without this the day-0 test would pass equally well against a build that presented
	/// the Welcome screen on every single launch of an open window.
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
		assertExists(AID.welcomeContinue, false)
		// Restore is on every paywall presentation, so its absence covers both of them at once.
		assertExists(AID.paywallRestore, false)
	}

	/// Day 20: the window is spent and the wall is what the user meets — `PaywallView`, with no
	/// Welcome screen, because there is no window left to welcome anyone into.
	func testExpiredWindow_wallsTheUserWithNoWayPast() {
		launch(
			LaunchConfig(
				featureFlagOverrides: ["isFreeAccessPeriodEnabled": true],
				freeAccessAnchorAgeDays: 20
			),
			mockAuthGate: "ready",
			mockSubscription: "notSubscribed"
		)

		assertExists(AID.paywallContent, true)
		assertExists(AID.paywallSignOut, true)
		assertExists(AID.welcomeContinue, false)
		// Nothing of the app behind it: a window that was never open this session is walled at the
		// root, not covered over.
		assertExists(AID.cpu, false)
	}

	/// Settings → Subscription becomes a real route to the paywall during the window (AIA-0556).
	/// Before this the row was an inert `HStack` and there was no way to subscribe from Settings.
	///
	/// The sheet is deliberately **not** a gate: no root-gate account controls, which is what keeps
	/// it develop's paywall exactly, and no Welcome screen — that is the day-0 overlay, not this.
	/// Seeded mid-window so nothing else is competing for the screen.
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
		assertExists(AID.welcomeContinue, false)
		assertExists(AID.paywallSignOut, false)

		// The name of this test is a claim, and until AIA-0616 nothing checked it: opened mid-window
		// this screen is an *offer*, and it has to look like one. There was no visible way out — only
		// an undiscoverable swipe — so a user with eleven days left could reasonably read it as
		// "subscribe or nothing".
		let dismiss = app.buttons[AID.paywallDismiss]
		XCTAssertTrue(dismiss.waitForExistence(timeout: 5), "A paywall that is not a gate must offer a way out")
		dismiss.tap()

		// The way out has to actually lead back, and proving that needs care: waiting for the
		// Settings row to *exist* proves nothing, because the whole Settings hierarchy still exists
		// underneath while the sheet covers it. So wait for the paywall itself to go, then require
		// Settings to be **hittable** rather than merely present.
		XCTAssertTrue(
			waitForDisappearance(of: app.descendants(matching: .any)[AID.paywallContent]),
			"Dismiss did not take the paywall down"
		)
		let subscriptionRow = app.buttons[AID.settingsUpgrade]
		XCTAssertTrue(subscriptionRow.waitForExistence(timeout: 10), "Settings did not come back")
		XCTAssertTrue(subscriptionRow.isHittable, "Settings came back but is still covered")
	}

	// MARK: - Welcome → tour ordering (AIA-0567)

	/// The inversion itself: on a first run that owes both, the Welcome screen goes first and the
	/// tour waits.
	///
	/// Before AIA-0567 the tour started from `Appstate.initialize()`, so it was already running by
	/// the time the day-0 screen could be raised — the user met an overlay with a spotlight bubble
	/// stranded behind it.
	func testFirstRun_welcomeComesBeforeTheTour() {
		launchFirstRunWithTourArmed()

		assertExists(AID.welcomeContent, true)

		// The negative assertion has to outlast the launch, not just the two seconds
		// `assertExists(_, false)` waits. The tour is started from the gate's `onChange` handlers,
		// which fire as `display`, `duePrompt` and the entitlement settle — several seconds in on a
		// cold launch — so a short window would report "not started yet" as "never starts".
		Thread.sleep(forTimeInterval: 8)

		assertExists(AID.welcomeContent, true)
		assertExists(AID.tourBubble, false)
		// The bubble is the tour's UI; this checkpoint is the tour's *engine*. Asserting both means
		// a tour running invisibly behind the overlay fails the test too.
		assertExists(AID.cpTourStep, false)
	}

	/// The same launch, asserted the other way round: the tour is not merely invisible behind the
	/// Welcome screen, it has not started.
	///
	/// `cpTourStep` is rendered by `TourOverlay` only while `TourState.isActive`, so it answers a
	/// question the bubble's absence alone cannot — an overlay hidden by z-order would still exist
	/// in the accessibility tree (the app *is* mounted underneath: this is `.content` with the
	/// Welcome screen laid over it, not a root swap). Asserting Welcome is still up afterwards is
	/// what pins the absence to the window in which it matters.
	func testFirstRun_theTourDoesNotRunUnderneathTheWelcomeScreen() {
		launchFirstRunWithTourArmed()

		XCTAssertTrue(element(AID.welcomeContent).waitForExistence(timeout: 15), "Welcome screen never appeared")
		assertExists(AID.tourBubble, false)
		assertExists(AID.cpTourStep, false)
		XCTAssertTrue(element(AID.welcomeContent).exists, "Welcome screen left before the tour was checked")
	}

	/// Continue is the hand-over: it takes the Welcome screen down and starts the tour that was
	/// armed at launch. Without `SubscriptionGateView.startTourIfClear()` the tour would stay armed
	/// forever, and with it — via `TourState.isPendingOrRunning` — the analytics consent question.
	func testWelcomeContinue_handsTheScreenToTheTour() {
		launchFirstRunWithTourArmed()

		let continueButton = app.buttons[AID.welcomeContinue]
		XCTAssertTrue(continueButton.waitForExistence(timeout: 15), "Welcome screen offered no way past")
		continueButton.tap()

		XCTAssertTrue(
			element(AID.tourBubble).waitForExistence(timeout: 15),
			"Continue did not hand the screen to the tour"
		)
		assertExists(AID.welcomeContent, false)
	}

	/// The regression this ordering rework could most easily have introduced: a first launch that
	/// resolves to the **wall** — payments on, free access off — and is then paid for must still run
	/// its onboarding.
	///
	/// An earlier draft keyed the start off a condition carrying `isSubscribed == false`, so this
	/// user's tour could never start again, on this launch or any later one: nothing would ever
	/// re-satisfy it. `startTourIfClear()` keys off `display` instead, which is exactly what this
	/// asserts.
	///
	/// The entitlement is acquired via **Restore**, not Subscribe: the mock provider exposes no
	/// `Product`, so `paywallSubscribe` is never rendered under UI testing (see fact 3). Both routes
	/// land on the same `SubscriptionState.sync()` and publish the same `isSubscribed`, which is the
	/// transition under test.
	func testWallThenEntitlement_stillRunsTheTour() {
		launch(
			LaunchConfig(startOnboardingTour: true),
			mockAuthGate: "ready",
			mockSubscription: "notSubscribed"
		)

		// The hard wall, with nothing of the app — and so no tour — behind it.
		assertExists(AID.paywallContent, true)
		assertExists(AID.cpu, false)
		assertExists(AID.tourBubble, false)

		let restore = app.buttons[AID.paywallRestore]
		XCTAssertTrue(restore.waitForExistence(timeout: 10), "The wall offers no way to acquire an entitlement")
		restore.tap()

		// The gate opens on the entitlement, and the armed tour finally gets its turn.
		XCTAssertTrue(
			element(AID.tourBubble).waitForExistence(timeout: 20),
			"The tour never started for a user who paid past the wall"
		)
		assertExists(AID.paywallContent, false)
	}
}
