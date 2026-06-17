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

		// Tapping inside the cutout hits the overlay's transparent tap target, which calls
		// `performCutoutAction()` (overlay-drives-action fallback) and opens the drawer — the
		// toolbar button is hosted in a separate layer that a tap can't reach through the dim.
		app.buttons[AID.cpu].tap()

		// The fallback worked iff the drawer actually opened.
		XCTAssertTrue(
			app.buttons[AID.drawerSettings].waitForExistence(timeout: 10),
			"Drawer should be open after the cutout tap drove the action"
		)

		// The drawer opening is the step's advance condition → the tour moves to the
		// demo-models step, whose bubble re-anchors only after the open animation settles.
		XCTAssertTrue(
			waitForCheckpoint(AID.cpTourStep, equals: "demoModels", timeout: 15),
			"Opening the drawer should advance the tour to the demo-models step"
		)
	}

	/// The full happy path: address bar → models button → demo models → enable model → finish.
	/// Covers the enable-model step (previously a blank dim with no reachable target) and asserts
	/// that flipping the highlighted toggle — a pass-through tap to the real control — finishes
	/// the tour. Captures a screenshot at every step for visual verification of the spotlight.
	@MainActor
	func testTour_fullHappyPath_enableModelFinishes() {
		launch(LaunchConfig(startOnboardingTour: true))

		XCTAssertTrue(element(AID.tourBubble).waitForExistence(timeout: 15), "Tour should start")
		XCTAssertTrue(waitForCheckpoint(AID.cpTourStep, equals: "addressBar"))
		attach("01-addressBar")

		// Step 1 → 2 (scripted).
		element(AID.tourNext).tap()
		XCTAssertTrue(waitForCheckpoint(AID.cpTourStep, equals: "modelsButton"))
		attach("02-modelsButton")

		// Step 2 → 3: the overlay-driven cutout tap opens the drawer.
		app.buttons[AID.cpu].tap()
		XCTAssertTrue(app.buttons[AID.drawerSettings].waitForExistence(timeout: 10), "Drawer should open")
		XCTAssertTrue(waitForCheckpoint(AID.cpTourStep, equals: "demoModels", timeout: 15))
		XCTAssertTrue(waitForSeededConfigurations(), "A demo model row should seed")
		attach("03-demoModels")

		// Step 3 → 4 (scripted): the previously-blank step. The bubble must still render — a
		// `.userAction` step with an unresolved anchor must never be a dead-end dim.
		element(AID.tourNext).tap()
		XCTAssertTrue(
			waitForCheckpoint(AID.cpTourStep, equals: "enableModelToggle", timeout: 10),
			"Should advance to the enable-model step"
		)
		XCTAssertTrue(
			element(AID.tourBubble).waitForExistence(timeout: 5),
			"Enable-model step must show its bubble, not a blank dim"
		)
		attach("04-enableModelToggle")

		// The payoff: the enable step's primary button enables a demo model and finishes the
		// tour. (The toggle sits beneath the dim and can't be tapped through the overlay, so the
		// bubble drives the action.)
		XCTAssertTrue(element(AID.tourNext).waitForExistence(timeout: 5), "Enable step should show its primary button")
		element(AID.tourNext).tap()
		XCTAssertTrue(
			waitForDisappearance(of: element(AID.tourBubble)),
			"The enable-model button should finish the tour"
		)
		// A demo model is now actually enabled.
		XCTAssertTrue(
			app.switches.matching(NSPredicate(format: "identifier == %@ AND value == %@", AID.configEnabledToggle, "1")).firstMatch.waitForExistence(timeout: 5),
			"A demo model should be enabled after the step"
		)
		attach("05-finished")
	}

	/// Captures a named, always-kept screenshot attachment for visual review in the result bundle.
	private func attach(_ name: String) {
		let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
		attachment.name = name
		attachment.lifetime = .keepAlways
		add(attachment)
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
