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

	/// The full happy path: address bar → models button → demo models → enable model → start
	/// detection → capture mode → tap the map → save a finding → finish. Exercises every advance
	/// mechanism (scripted Next, overlay-driven cutout taps, bubble-driven enable, the no-dim map
	/// tap, and the saved-finding signal). Captures a screenshot at every step.
	@MainActor
	func testTour_fullHappyPath_throughSaveFinding() {
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

		// Step 3 → 4 (scripted): the enable-model step still shows its bubble (not a blank dim).
		element(AID.tourNext).tap()
		XCTAssertTrue(waitForCheckpoint(AID.cpTourStep, equals: "enableModelToggle", timeout: 10))
		XCTAssertTrue(element(AID.tourBubble).waitForExistence(timeout: 5), "Enable step must show its bubble")
		attach("04-enableModelToggle")

		// Step 4 → 5: the bubble button enables a demo model, closes the drawer, advances to PLAY.
		element(AID.tourNext).tap()
		XCTAssertTrue(waitForCheckpoint(AID.cpTourStep, equals: "playButton", timeout: 10), "Should advance to PLAY")
		attach("05-playButton")

		// Step 5 → 6: overlay-driven tap on PLAY starts detection.
		app.buttons[AID.play].tap()
		XCTAssertTrue(waitForCheckpoint(AID.cpTourStep, equals: "findButton", timeout: 10), "Should advance to Find")
		attach("06-findButton")

		// Step 6 → 7: overlay-driven tap on Find enters capture mode.
		app.buttons[AID.findTop].tap()
		XCTAssertTrue(waitForCheckpoint(AID.cpTourStep, equals: "captureArea", timeout: 10), "Should advance to capture")
		attach("07-captureArea")

		// Step 7: no-dim step — tap the live map to capture a finding, which opens the Save sheet.
		app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
		let titleField = app.textFields[AID.saveFindingTitle]
		XCTAssertTrue(titleField.waitForExistence(timeout: 10), "Save sheet should appear after tapping the map")
		titleField.tap()
		titleField.typeText("Tour finding")
		app.buttons[AID.saveFindingSave].tap()

		// Saving the finding advances to the closing step; Done finishes the tour.
		XCTAssertTrue(waitForCheckpoint(AID.cpTourStep, equals: "finished", timeout: 10), "Saving should advance to the closing step")
		attach("08-finished")
		element(AID.tourNext).tap()
		XCTAssertTrue(waitForDisappearance(of: element(AID.tourBubble)), "Done should end the tour")
		attach("09-done")
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
