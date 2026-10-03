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

	func testCaptureCancelled_rewindsToFindStepToReArmPickMode() {
		// Dismissing the sheet tears down pick mode, so the cancel path rewinds to the Find step
		// (not the map step) — re-tapping Find re-arms capture mode. (Codex review finding.)
		let steps = [
			TourStep(target: .findButton, bubbleText: "tap find", placement: .below,
					 advance: .userAction(.pickModeEntered), autoAdvancesOnAction: true),
			TourStep(target: .captureArea, bubbleText: "tap map", placement: .bottom,
					 advance: .userAction(.captureStarted), dimsBackground: false, autoAdvancesOnAction: true),
			TourStep(target: .saveButton, bubbleText: "save", placement: .below,
					 advance: .userAction(.findingSaved), autoAdvancesOnAction: true, rendersInSheet: true)
		]
		let tour = TourState(steps: steps, defaults: defaults)
		tour.start()
		tour.pickModeDidStart()
		XCTAssertEqual(tour.currentIndex, 1, "Entering pick mode auto-advances to the map step")
		tour.captureDidStart()
		XCTAssertEqual(tour.currentIndex, 2, "Tapping the map auto-advances to the save step")
		tour.captureCancelled()
		XCTAssertEqual(tour.currentIndex, 0, "Cancelling the sheet rewinds to the Find step to re-arm pick mode")
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

	func testMigration_noLegacyKey_arms() {
		let tour = TourState(steps: scriptedSteps(count: 1), defaults: defaults)
		tour.migrateAndArmIfNeeded()
		XCTAssertTrue(tour.isArmed, "Fresh install with no legacy key arms the tour")
		XCTAssertFalse(tour.isActive, "Arming must not start it — the Welcome screen goes first (AIA-0567)")
	}

	func testMigration_legacyOptOut_seedsGateWithoutArming() {
		defaults.set(false, forKey: TourState.legacySlideshowKey) // user disabled old slideshow
		let tour = TourState(steps: scriptedSteps(count: 1), defaults: defaults)
		tour.migrateAndArmIfNeeded()
		XCTAssertFalse(tour.isArmed, "Legacy opt-out users are not re-onboarded")
		XCTAssertFalse(tour.isActive)
		XCTAssertTrue(tour.hasSeenTour, "The gate is seeded so they are never re-shown")
	}

	func testMigration_legacyOptIn_arms() {
		defaults.set(true, forKey: TourState.legacySlideshowKey) // slideshow was still on
		let tour = TourState(steps: scriptedSteps(count: 1), defaults: defaults)
		tour.migrateAndArmIfNeeded()
		XCTAssertTrue(tour.isArmed, "Non-opt-out users see the tour once on upgrade")
	}

	func testMigration_gateAlreadySeen_doesNothing() {
		defaults.set(true, forKey: TourState.gateKey)
		let tour = TourState(steps: scriptedSteps(count: 1), defaults: defaults)
		tour.migrateAndArmIfNeeded()
		XCTAssertFalse(tour.isArmed, "An already-seen gate suppresses arming")
		XCTAssertFalse(tour.isActive)
	}

	// MARK: - Arm / start split (AIA-0567)

	func testStartIfArmed_withoutAnArm_doesNothing() {
		let tour = TourState(steps: scriptedSteps(count: 1), defaults: defaults)
		tour.startIfArmed()
		XCTAssertFalse(tour.isActive, "Nothing was owed, so nothing starts")
	}

	func testStartIfArmed_consumesTheArm() {
		let tour = TourState(steps: scriptedSteps(count: 1), defaults: defaults)
		tour.migrateAndArmIfNeeded()
		tour.startIfArmed()
		XCTAssertTrue(tour.isActive)
		XCTAssertFalse(tour.isArmed, "The arm is consumed, or every later screen change restarts the tour")
	}

	func testStartIfArmed_whileRunning_doesNotRestart() {
		// The gate calls this from several lifecycle handlers, any of which can fire again while
		// the tour is mid-step. A second `start()` would reset the index and close the drawer.
		let tour = TourState(steps: scriptedSteps(count: 3), defaults: defaults)
		tour.arm()
		tour.startIfArmed()
		tour.advance()
		XCTAssertEqual(tour.currentIndex, 1)
		tour.arm()          // a stray re-arm must not be honoured while running
		tour.startIfArmed()
		XCTAssertEqual(tour.currentIndex, 1, "A running tour is never restarted from under the user")
	}

	func testIsPendingOrRunning_spansArmedThroughTermination() {
		// What `AnalyticsChoiceGate` reads to hold the consent question back. It has to be true
		// from the arm — before anything renders — and stay true until the tour is genuinely done,
		// with no gap in the middle where consent could slip in over a starting tour.
		let tour = TourState(steps: scriptedSteps(count: 1), defaults: defaults)
		XCTAssertFalse(tour.isPendingOrRunning)
		tour.arm()
		XCTAssertTrue(tour.isPendingOrRunning, "Armed but not started still owes the user a turn")
		tour.startIfArmed()
		XCTAssertTrue(tour.isPendingOrRunning, "Running")
		tour.skip()
		XCTAssertFalse(tour.isPendingOrRunning, "Terminal — consent may now be asked")
	}

	func testTerminate_clearsAStrayArm() {
		// Settings → Replay calls `start()` directly, bypassing the arm. If an arm were still
		// outstanding, `isPendingOrRunning` would stay true forever and defer consent for good.
		let tour = TourState(steps: scriptedSteps(count: 1), defaults: defaults)
		tour.arm()
		tour.start()
		tour.finish()
		XCTAssertFalse(tour.isArmed)
		XCTAssertFalse(tour.isPendingOrRunning)
	}

	// MARK: - Payments-off introduction receipt (AIA-0955)

	func testArm_owesTheIntroduction_untilItIsShown() {
		let tour = TourState(steps: scriptedSteps(count: 1), defaults: defaults)
		XCTAssertFalse(tour.isIntroductionOwed, "Nothing armed, nothing to introduce")
		tour.migrateAndArmIfNeeded()
		XCTAssertTrue(tour.isIntroductionOwed)
		tour.markIntroductionShown()
		XCTAssertFalse(tour.isIntroductionOwed)
	}

	func testIntroductionReceipt_survivesAForceQuitMidTour() {
		// Welcome shown, tour started, app killed before the tour's terminal state: the next launch
		// re-arms the tour (its gate is written only at the end) but must not re-introduce it.
		let first = TourState(steps: scriptedSteps(count: 2), defaults: defaults)
		first.migrateAndArmIfNeeded()
		first.markIntroductionShown()
		first.startIfArmed()

		let relaunched = TourState(steps: scriptedSteps(count: 2), defaults: defaults)
		XCTAssertTrue(relaunched.migrateAndArmIfNeeded(), "precondition: the unfinished tour is owed again")
		XCTAssertFalse(relaunched.isIntroductionOwed, "The introduction was already presented")
	}

	func testIntroduction_isNotOwedWhenTheTourIsNot() {
		defaults.set(false, forKey: TourState.legacySlideshowKey)
		let legacyOptOut = TourState(steps: scriptedSteps(count: 1), defaults: defaults)
		legacyOptOut.migrateAndArmIfNeeded()
		XCTAssertFalse(legacyOptOut.isIntroductionOwed, "A user never re-onboarded is never re-introduced")

		let returning = TourState(steps: scriptedSteps(count: 1), defaults: defaults)
		returning.migrateAndArmIfNeeded()
		XCTAssertFalse(returning.isIntroductionOwed, "A seen tour owes no introduction")
	}

	// MARK: - Priced Welcome recorded before the receipt existed (AIA-1036)

	func testAdoptEarlierWelcomeReceipt_pricedWelcomeMetBefore109_isNotIntroducedAgain() {
		// The upgrade from 1.0.7/1.0.8: the priced Welcome was shown (only `day0Shown` recorded), the
		// tour never reached its end, so this launch re-arms with no introduction receipt.
		let upgraded = TourState(steps: scriptedSteps(count: 2), defaults: defaults)
		XCTAssertTrue(upgraded.migrateAndArmIfNeeded(), "precondition: the unfinished tour is owed again")
		XCTAssertTrue(upgraded.isIntroductionOwed, "precondition: no receipt before 1.0.9")

		upgraded.adoptEarlierWelcomeReceipt(dayZeroWelcomeShown: true)
		XCTAssertFalse(upgraded.isIntroductionOwed, "A user who met the priced Welcome was introduced again")

		let relaunched = TourState(steps: scriptedSteps(count: 2), defaults: defaults)
		relaunched.migrateAndArmIfNeeded()
		XCTAssertFalse(relaunched.isIntroductionOwed, "The carried-over receipt must be durable")
	}

	func testAdoptEarlierWelcomeReceipt_noWelcomeEverShown_stillOwesTheIntroduction() {
		let tour = TourState(steps: scriptedSteps(count: 1), defaults: defaults)
		tour.migrateAndArmIfNeeded()
		tour.adoptEarlierWelcomeReceipt(dayZeroWelcomeShown: false)
		XCTAssertTrue(tour.isIntroductionOwed, "A user who never saw a Welcome must still be introduced")
		XCTAssertNil(defaults.object(forKey: TourState.introductionShownKey))
	}

	func testAdoptEarlierWelcomeReceipt_withNoArmedTour_writesNothing() {
		let tour = TourState(steps: scriptedSteps(count: 1), defaults: defaults)
		tour.adoptEarlierWelcomeReceipt(dayZeroWelcomeShown: true)
		XCTAssertNil(
			defaults.object(forKey: TourState.introductionShownKey),
			"A returning install's defaults must be left untouched"
		)
	}

	func testReplay_doesNotOweTheIntroduction_andClearsAnOutstandingOne() {
		let tour = TourState(steps: scriptedSteps(count: 1), defaults: defaults)
		tour.start()
		XCTAssertFalse(tour.isIntroductionOwed, "Replay starts directly and never introduces")

		let armedThenReplayed = TourState(steps: scriptedSteps(count: 1), defaults: defaults)
		armedThenReplayed.arm()
		armedThenReplayed.start()
		armedThenReplayed.finish()
		XCTAssertFalse(armedThenReplayed.isIntroductionOwed, "Nothing is introduced after the tour it precedes")
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
