//
//  TourStateTests.swift
//  MLBrowserUnitTests
//
//  AIA-0333: interactive onboarding spotlight tour — engine coverage.
//

import XCTest
@testable import ML_Browser

@MainActor
final class TourStateTests: XCTestCase {

	private var defaults: UserDefaults!
	private var suiteName: String!

	override func setUp() async throws {
		try await super.setUp()
		suiteName = "tour.tests.\(UUID().uuidString)"
		defaults = UserDefaults(suiteName: suiteName)
	}

	override func tearDown() async throws {
		defaults.removePersistentDomain(forName: suiteName)
		defaults = nil
		suiteName = nil
		try await super.tearDown()
	}

	// MARK: - Fixtures

	private func scriptedSteps(count: Int) -> [TourStep] {
		(0..<count).map { index in
			TourStep(
				target: TourAnchorID.allCases[index % TourAnchorID.allCases.count],
				bubbleText: "step \(index)",
				placement: .below,
				advance: .scripted
			)
		}
	}

	// MARK: - Sequence

	func testStart_activatesFirstStep() {
		let tour = TourState(steps: scriptedSteps(count: 3), defaults: defaults)
		tour.start()
		XCTAssertTrue(tour.isActive)
		XCTAssertEqual(tour.currentIndex, 0)
		// Scripted steps surface Next immediately.
		XCTAssertTrue(tour.showsNextButton)
	}

	func testAdvance_walksThroughSequenceThenFinishes() {
		let tour = TourState(steps: scriptedSteps(count: 3), defaults: defaults)
		tour.start()
		tour.advance()
		XCTAssertEqual(tour.currentIndex, 1)
		tour.advance()
		XCTAssertEqual(tour.currentIndex, 2)
		tour.advance() // past the end
		XCTAssertFalse(tour.isActive, "Advancing past the last step finishes the tour")
	}

	// MARK: - AdvanceCondition

	func testEvaluate_revealsNextWhenConditionMet_thenNextAdvances() {
		let drawer = DrawerManager()
		let steps = [
			TourStep(target: .modelsButton, bubbleText: "open it", placement: .below,
					 advance: .userAction(.drawerOpened)),
			TourStep(target: .demoModels, bubbleText: "models", placement: .below, advance: .scripted)
		]
		let tour = TourState(steps: steps, defaults: defaults)
		tour.bind(drawer: drawer)
		tour.start()
		XCTAssertFalse(tour.showsNextButton, "Action step hides Next until the real action")

		// Condition not yet met: evaluate is a no-op.
		tour.evaluate()
		XCTAssertFalse(tour.showsNextButton)
		XCTAssertEqual(tour.currentIndex, 0)

		// Drawer opens → evaluate reveals Next, but does NOT advance on its own.
		drawer.isOpen = true
		tour.evaluate()
		XCTAssertTrue(tour.showsNextButton, "Drawer opening reveals Next")
		XCTAssertEqual(tour.currentIndex, 0, "Revealing Next must not advance — the user taps Next")

		// The user taps Next → advance.
		tour.bubblePrimaryTapped()
		XCTAssertEqual(tour.currentIndex, 1)
	}

	// MARK: - Skip

	func testSkip_deactivatesAndFlipsGate() {
		let tour = TourState(steps: scriptedSteps(count: 3), defaults: defaults)
		tour.start()
		XCTAssertFalse(tour.hasSeenTour)
		tour.skip()
		XCTAssertFalse(tour.isActive)
		XCTAssertTrue(tour.hasSeenTour, "Skip is terminal: it flips the gate")
	}

	func testStart_doesNotFlipGate() {
		let tour = TourState(steps: scriptedSteps(count: 1), defaults: defaults)
		tour.start()
		XCTAssertFalse(tour.hasSeenTour, "Starting must not flip the gate (an interrupted tour re-arms)")
	}

	// MARK: - Drawer left untouched on finish

	func testFinish_leavesDrawerUntouched() {
		// This slice never opens the drawer itself, so finish/skip must not close a drawer the
		// user opened (no staging machinery to revert).
		let drawer = DrawerManager()
		let tour = TourState(steps: scriptedSteps(count: 1), defaults: defaults)
		tour.bind(drawer: drawer)
		tour.start()

		drawer.isOpen = true
		tour.finish()
		XCTAssertTrue(drawer.isOpen, "Finish must leave the drawer exactly as the user left it")
	}

	// MARK: - Enable step (reveal Next on the real action)

	func testEnableStep_userEnabledModel_revealsNext_thenNextAdvances() {
		let steps = [
			TourStep(target: .enableModelToggle, bubbleText: "enable", placement: .bottom,
					 advance: .userAction(.modelEnabled), spotlightFallback: .demoModels),
			TourStep(target: .playButton, bubbleText: "play", placement: .below,
					 advance: .userAction(.detectionStarted))
		]
		let tour = TourState(steps: steps, defaults: defaults)
		tour.start()
		XCTAssertFalse(tour.showsNextButton, "Enable step hides Next until a model is enabled")

		tour.userEnabledModel()
		XCTAssertTrue(tour.showsNextButton, "Enabling a model reveals Next")
		XCTAssertEqual(tour.currentIndex, 0, "Revealing Next must not advance — the user taps Next")

		tour.bubblePrimaryTapped()
		XCTAssertEqual(tour.currentIndex, 1)
	}

	func testUserEnabledModel_noopWhenNotOnEnableStep() {
		// A model enabled while the tour is on a different (e.g. drawer-open) step must do nothing.
		let steps = [
			TourStep(target: .modelsButton, bubbleText: "open", placement: .below,
					 advance: .userAction(.drawerOpened)),
			TourStep(target: .demoModels, bubbleText: "next", placement: .below, advance: .scripted)
		]
		let tour = TourState(steps: steps, defaults: defaults)
		tour.start()
		tour.userEnabledModel()
		XCTAssertFalse(tour.showsNextButton, "Enabling a model off the enable step must not reveal Next")
		XCTAssertEqual(tour.currentIndex, 0)
	}

	// MARK: - Sheet-coupled steps auto-advance

	func testPickModeDidStart_autoAdvancesFindStep() {
		let steps = [
			TourStep(target: .findButton, bubbleText: "find", placement: .below,
					 advance: .userAction(.pickModeEntered), autoAdvancesOnAction: true),
			TourStep(target: .captureArea, bubbleText: "tap map", placement: .bottom,
					 advance: .userAction(.captureStarted), dimsBackground: false, autoAdvancesOnAction: true)
		]
		let tour = TourState(steps: steps, defaults: defaults)
		tour.start()
		tour.pickModeDidStart()
		XCTAssertEqual(tour.currentIndex, 1, "Entering capture mode auto-advances the Find step to the map step")
	}

	func testCaptureDidStart_autoAdvancesCaptureStep() {
		let steps = [
			TourStep(target: .captureArea, bubbleText: "tap map", placement: .bottom,
					 advance: .userAction(.captureStarted), dimsBackground: false, autoAdvancesOnAction: true),
			TourStep(target: .saveButton, bubbleText: "save", placement: .below,
					 advance: .userAction(.findingSaved), autoAdvancesOnAction: true, rendersInSheet: true)
		]
		let tour = TourState(steps: steps, defaults: defaults)
		tour.start()
		tour.captureDidStart()
		XCTAssertEqual(tour.currentIndex, 1, "Capture starting auto-advances to the save step")
	}

	func testFindingDidSave_autoAdvancesSaveStep() {
		let steps = [
			TourStep(target: .saveButton, bubbleText: "save", placement: .below,
					 advance: .userAction(.findingSaved), autoAdvancesOnAction: true, rendersInSheet: true),
			TourStep(target: .finished, bubbleText: "done", placement: .bottom, advance: .scripted)
		]
		let tour = TourState(steps: steps, defaults: defaults)
		tour.start()
		tour.findingDidSave()
		XCTAssertEqual(tour.currentIndex, 1, "Saving a finding auto-advances the save step")
	}

	func testCaptureCancelled_revertsSaveStepToCapture() {
		let steps = [
			TourStep(target: .captureArea, bubbleText: "tap map", placement: .bottom,
					 advance: .userAction(.captureStarted), dimsBackground: false, autoAdvancesOnAction: true),
			TourStep(target: .saveButton, bubbleText: "save", placement: .below,
					 advance: .userAction(.findingSaved), autoAdvancesOnAction: true, rendersInSheet: true)
		]
		let tour = TourState(steps: steps, defaults: defaults)
		tour.start()
		tour.captureDidStart()
		XCTAssertEqual(tour.currentIndex, 1)
		tour.captureCancelled()
		XCTAssertEqual(tour.currentIndex, 0, "Cancelling the sheet returns to the capture step")
	}

	func testCaptureCancelled_noopAfterSave() {
		let steps = [
			TourStep(target: .saveButton, bubbleText: "save", placement: .below,
					 advance: .userAction(.findingSaved), autoAdvancesOnAction: true, rendersInSheet: true),
			TourStep(target: .finished, bubbleText: "done", placement: .bottom, advance: .scripted)
		]
		let tour = TourState(steps: steps, defaults: defaults)
		tour.start()
		tour.findingDidSave()
		XCTAssertEqual(tour.currentIndex, 1)
		tour.captureCancelled()
		XCTAssertEqual(tour.currentIndex, 1, "A dismiss after save must not rewind")
	}

	// MARK: - Gate & migration (object(forKey:))

	func testMigration_noLegacyKey_autostarts() {
		let tour = TourState(steps: scriptedSteps(count: 1), defaults: defaults)
		tour.migrateAndAutostartIfNeeded()
		XCTAssertTrue(tour.isActive, "Fresh install with no legacy key auto-starts the tour")
	}

	func testMigration_legacyOptOut_seedsGateWithoutStarting() {
		defaults.set(false, forKey: TourState.legacySlideshowKey) // user disabled old slideshow
		let tour = TourState(steps: scriptedSteps(count: 1), defaults: defaults)
		tour.migrateAndAutostartIfNeeded()
		XCTAssertFalse(tour.isActive, "Legacy opt-out users are not re-onboarded")
		XCTAssertTrue(tour.hasSeenTour, "The gate is seeded so they are never re-shown")
	}

	func testMigration_legacyOptIn_autostarts() {
		defaults.set(true, forKey: TourState.legacySlideshowKey) // slideshow was still on
		let tour = TourState(steps: scriptedSteps(count: 1), defaults: defaults)
		tour.migrateAndAutostartIfNeeded()
		XCTAssertTrue(tour.isActive, "Non-opt-out users see the tour once on upgrade")
	}

	func testMigration_gateAlreadySeen_doesNothing() {
		defaults.set(true, forKey: TourState.gateKey)
		let tour = TourState(steps: scriptedSteps(count: 1), defaults: defaults)
		tour.migrateAndAutostartIfNeeded()
		XCTAssertFalse(tour.isActive, "An already-seen gate suppresses auto-start")
	}

	func testGate_distinguishesAbsentFromFalse() {
		// `object(forKey:) != nil` must treat an explicit `false` as "seen", which a plain
		// `bool(forKey:)` could not.
		let tour = TourState(steps: scriptedSteps(count: 1), defaults: defaults)
		XCTAssertFalse(tour.hasSeenTour, "Absent key → not seen")
		defaults.set(false, forKey: TourState.gateKey)
		XCTAssertTrue(tour.hasSeenTour, "Present key (even false) → seen")
	}
}
