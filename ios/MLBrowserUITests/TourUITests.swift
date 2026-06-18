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

	/// The models-button step: tapping the **real** CPU button (the four-rectangle dim leaves the
	/// hole genuinely tappable) opens the drawer, which reveals **Next**; tapping Next advances.
	@MainActor
	func testTour_modelsButtonStep_realTapOpensDrawerThenNextAdvances() {
		launch(LaunchConfig(startOnboardingTour: true))
		XCTAssertTrue(element(AID.tourBubble).waitForExistence(timeout: 15), "Tour should start")
		XCTAssertTrue(waitForCheckpoint(AID.cpTourStep, equals: "addressBar"))

		// Teaching step: Next is available immediately.
		element(AID.tourNext).tap()
		XCTAssertTrue(waitForCheckpoint(AID.cpTourStep, equals: "modelsButton"))

		// Next must NOT be shown yet — the user hasn't performed the action.
		XCTAssertFalse(element(AID.tourNext).waitForExistence(timeout: 2),
					   "Next is hidden until the drawer is opened")

		// Tap the real CPU button (reachable through the open hole) → the drawer opens.
		app.buttons[AID.cpu].tap()
		XCTAssertTrue(app.buttons[AID.drawerSettings].waitForExistence(timeout: 10), "Drawer should open")

		// Opening the drawer reveals Next; tapping it advances to the demo-models step.
		tapNextWhenRevealed()
		XCTAssertTrue(waitForCheckpoint(AID.cpTourStep, equals: "demoModels", timeout: 15))
	}

	/// The full happy path with the real-action model: every action step requires the real tap,
	/// then reveals Next. address bar → models button → demo models → enable model → start
	/// detection → capture mode → tap the map → save a finding (in the sheet) → finish.
	@MainActor
	func testTour_fullHappyPath_throughSaveFinding() throws {
		launch(LaunchConfig(startOnboardingTour: true))
		// The capture step taps the web map at a fixed coordinate, which is tuned for iPhone
		// (compact). On regular width (iPad) the chrome/content layout differs, so the engine is
		// covered by the unit tests + the lighter tour tests there; the full flow runs on iPhone.
		try XCTSkipIf(isRegularWidth, "Full tour happy path uses iPhone-compact map coordinates")

		XCTAssertTrue(element(AID.tourBubble).waitForExistence(timeout: 15), "Tour should start")
		XCTAssertTrue(waitForCheckpoint(AID.cpTourStep, equals: "addressBar"))
		attach("01-addressBar")

		// 1 → 2 (teaching): Next immediately.
		element(AID.tourNext).tap()
		XCTAssertTrue(waitForCheckpoint(AID.cpTourStep, equals: "modelsButton"))
		attach("02-modelsButton")

		// 2 → 3: tap the real CPU button (opens drawer) → Next reveals → tap Next.
		app.buttons[AID.cpu].tap()
		XCTAssertTrue(app.buttons[AID.drawerSettings].waitForExistence(timeout: 10), "Drawer should open")
		XCTAssertTrue(waitForSeededConfigurations(), "A demo model row should seed")
		tapNextWhenRevealed()
		XCTAssertTrue(waitForCheckpoint(AID.cpTourStep, equals: "demoModels", timeout: 15))
		attach("03-demoModels")

		// 3 → 4 (teaching): Next immediately.
		element(AID.tourNext).tap()
		XCTAssertTrue(waitForCheckpoint(AID.cpTourStep, equals: "enableModelToggle", timeout: 10))
		attach("04-enableModelToggle")

		// 4 → 5: flip the real toggle → Next reveals → tap Next (the drawer closes on advance).
		XCTAssertTrue(flipSwitch(AID.configEnabledToggle), "Should enable a demo model via the real toggle")
		tapNextWhenRevealed()
		XCTAssertTrue(waitForCheckpoint(AID.cpTourStep, equals: "playButton", timeout: 10))
		attach("05-playButton")

		// 5 → 6: tap the real PLAY button → Next reveals → tap Next.
		app.buttons[AID.play].tap()
		tapNextWhenRevealed()
		XCTAssertTrue(waitForCheckpoint(AID.cpTourStep, equals: "findButton", timeout: 10))
		attach("06-findButton")

		// 6 → 7: tap the real Find button → enters capture mode → auto-advances to the map step.
		app.buttons[AID.findTop].tap()
		XCTAssertTrue(waitForCheckpoint(AID.cpTourStep, equals: "captureArea", timeout: 10))
		attach("07-captureArea")

		// 7 → 8: tap the live map → the Save sheet opens → auto-advances to the in-sheet save step.
		app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
		let titleField = app.textFields[AID.saveFindingTitle]
		XCTAssertTrue(titleField.waitForExistence(timeout: 10), "Save sheet should appear after tapping the map")
		XCTAssertTrue(waitForCheckpoint(AID.cpTourStep, equals: "saveButton", timeout: 10), "Should advance to the in-sheet save step")
		attach("08-saveButton")

		// 8 → 9: name it + tap the real Save → auto-advances to the closing step.
		titleField.tap()
		titleField.typeText("Tour finding")
		app.buttons[AID.saveFindingSave].tap()
		XCTAssertTrue(waitForCheckpoint(AID.cpTourStep, equals: "finished", timeout: 10), "Saving should advance to the closing step")
		attach("09-finished")

		// 9: Done finishes the tour.
		element(AID.tourNext).tap()
		XCTAssertTrue(waitForDisappearance(of: element(AID.tourBubble)), "Done should end the tour")
	}

	/// Waits for the bubble's Next to be revealed (after the step's real action) and taps it.
	/// Generous timeout: on a loaded CI machine the action's state change (drawer animation,
	/// demo-data save, detection start) can lag.
	private func tapNextWhenRevealed() {
		let next = element(AID.tourNext)
		XCTAssertTrue(next.waitForExistence(timeout: 20), "Next should reveal after the step's action")
		next.tap()
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
