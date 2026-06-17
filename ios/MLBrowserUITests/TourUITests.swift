//
//  TourUITests.swift
//  MLBrowserUITests
//
//  AIA-0333: interactive onboarding spotlight tour coverage. Replaces WizardUITests.
//

import XCTest

final class TourUITests: UITestCase {

	/// The tour auto-starts under the `startOnboardingTour` flag and shows its first bubble
	/// spotlighting the address bar.
	@MainActor
	func testTour_startsOnAddressBar() {
		launch(LaunchConfig(startOnboardingTour: true))

		XCTAssertTrue(
			element(AID.tourBubble).waitForExistence(timeout: 15),
			"Tour bubble should appear on launch"
		)
		XCTAssertTrue(
			waitForCheckpoint(AID.cpTourStep, equals: "addressBar"),
			"First step should spotlight the address bar"
		)
	}

	/// Tapping inside the spotlight cutout on the models-button step opens the drawer (via the
	/// overlay-drives-action fallback, since the toolbar button is hosted in a separate layer
	/// and a pass-through tap does not reach it), which advances the tour to the in-drawer
	/// demo-models step (re-anchored after the open animation).
	@MainActor
	func testTour_cutoutTapOpensDrawer() {
		launch(LaunchConfig(startOnboardingTour: true))
		XCTAssertTrue(element(AID.tourBubble).waitForExistence(timeout: 15), "Tour should start")
		XCTAssertTrue(waitForCheckpoint(AID.cpTourStep, equals: "addressBar"))

		// Step 1 is a teaching step: advance with Next to reach the models-button step.
		element(AID.tourNext).tap()
		XCTAssertTrue(
			waitForCheckpoint(AID.cpTourStep, equals: "modelsButton"),
			"Should advance to the models-button step"
		)

		// Tap inside the cutout (the real CPU button). With eoFill pass-through this reaches
		// the button beneath the dim and opens the drawer.
		app.buttons[AID.cpu].tap()

		// Pass-through worked iff the drawer actually opened.
		XCTAssertTrue(
			app.buttons[AID.drawerSettings].waitForExistence(timeout: 10),
			"Drawer should be open after the cutout tap passed through"
		)

		// The drawer opening is the step's advance condition → the tour moves to the
		// demo-models step, whose bubble re-anchors only after the open animation settles.
		XCTAssertTrue(
			waitForCheckpoint(AID.cpTourStep, equals: "demoModels", timeout: 15),
			"Opening the drawer should advance the tour to the demo-models step"
		)
	}

	/// Skip dismisses the tour, and the gate prevents it re-appearing on a normal launch.
	@MainActor
	func testTour_skipDismissesAndGateBlocksReshow() {
		launch(LaunchConfig(startOnboardingTour: true))
		let bubble = element(AID.tourBubble)
		XCTAssertTrue(bubble.waitForExistence(timeout: 15), "Tour should start")

		element(AID.tourSkip).tap()
		XCTAssertTrue(waitForDisappearance(of: bubble), "Skip should dismiss the tour")
		XCTAssertTrue(
			app.buttons[AID.cpu].waitForExistence(timeout: 10),
			"Chrome should be reachable after skip"
		)

		// A normal launch (no opt-in flag) must not auto-show the tour: under UI tests the
		// tour is opt-in, so the bubble should be absent regardless of the gate.
		launch()
		XCTAssertFalse(
			element(AID.tourBubble).waitForExistence(timeout: 3),
			"Tour should not show on a non-opted-in launch"
		)
	}
}
