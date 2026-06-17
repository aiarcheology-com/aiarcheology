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

	func testEvaluate_advancesOnlyWhenDrawerConditionMet() {
		let drawer = DrawerManager()
		let steps = [
			TourStep(target: .modelsButton, bubbleText: "open it", placement: .below,
					 advance: .userAction(.drawerOpened)),
			TourStep(target: .demoModels, bubbleText: "models", placement: .below, advance: .scripted)
		]
		let tour = TourState(steps: steps, defaults: defaults)
		tour.bind(drawer: drawer)
		tour.start()

		// Condition not yet met: evaluate is a no-op.
		tour.evaluate()
		XCTAssertEqual(tour.currentIndex, 0)

		// Drawer opens → re-evaluating advances the step.
		drawer.isOpen = true
		tour.evaluate()
		XCTAssertEqual(tour.currentIndex, 1, "Drawer opening should satisfy .drawerOpened and advance")
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

	// MARK: - Timeout + generation guard

	func testTimeout_surfacesNextOnUserActionStep() async {
		let drawer = DrawerManager()
		let steps = [
			TourStep(target: .modelsButton, bubbleText: "act", placement: .below,
					 advance: .userAction(.drawerOpened), fallbackAfter: 0.1)
		]
		let tour = TourState(steps: steps, defaults: defaults)
		tour.bind(drawer: drawer)
		tour.start()
		XCTAssertFalse(tour.showsNextButton, "User-action step hides Next until the timeout")

		try? await Task.sleep(nanoseconds: 300_000_000)
		XCTAssertTrue(tour.showsNextButton, "Timeout should surface the Next fallback")
	}

	func testTimeout_generationGuard_staleTimeoutDoesNotMutateLaterStep() async {
		let drawer = DrawerManager()
		let steps = [
			// Step 0: user-action with a slow timeout we will outrun by advancing.
			TourStep(target: .modelsButton, bubbleText: "0", placement: .below,
					 advance: .userAction(.drawerOpened), fallbackAfter: 0.2),
			// Step 1: scripted (Next shown immediately).
			TourStep(target: .demoModels, bubbleText: "1", placement: .below, advance: .scripted),
			// Step 2: user-action, long timeout — should stay false while step 0's stale
			// timeout fires.
			TourStep(target: .enableModelToggle, bubbleText: "2", placement: .below,
					 advance: .userAction(.drawerOpened), fallbackAfter: 5)
		]
		let tour = TourState(steps: steps, defaults: defaults)
		tour.bind(drawer: drawer)
		tour.start()

		// Advance to step 1 then step 2 before step 0's 0.2s timeout fires.
		tour.advance() // → step 1 (scripted, Next true)
		tour.advance() // → step 2 (user-action, Next false)
		XCTAssertEqual(tour.currentIndex, 2)
		XCTAssertFalse(tour.showsNextButton)

		// Wait past step 0's original timeout.
		try? await Task.sleep(nanoseconds: 400_000_000)
		XCTAssertFalse(
			tour.showsNextButton,
			"A stale step-0 timeout must not surface Next on step 2 (generation guard)"
		)
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

	// MARK: - Zero / non-positive fallback (no UInt64 trap)

	func testTimeout_zeroFallback_surfacesNextImmediately() {
		let steps = [
			TourStep(target: .modelsButton, bubbleText: "act", placement: .below,
					 advance: .userAction(.drawerOpened), fallbackAfter: 0)
		]
		let tour = TourState(steps: steps, defaults: defaults)
		tour.start()
		XCTAssertTrue(tour.showsNextButton, "A zero fallback must surface Next immediately, never trap UInt64")
	}

	func testTimeout_negativeFallback_surfacesNextImmediately() {
		let steps = [
			TourStep(target: .modelsButton, bubbleText: "act", placement: .below,
					 advance: .userAction(.drawerOpened), fallbackAfter: -5)
		]
		let tour = TourState(steps: steps, defaults: defaults)
		tour.start()
		XCTAssertTrue(tour.showsNextButton, "A negative fallback must surface Next immediately, never trap UInt64")
	}

	// MARK: - modelEnabled advance (step 4 payoff)

	func testUserEnabledModel_advancesOnEnableStep() {
		let steps = [
			TourStep(target: .enableModelToggle, bubbleText: "enable", placement: .above,
					 advance: .userAction(.modelEnabled), fallbackAfter: 5),
			TourStep(target: .demoModels, bubbleText: "done", placement: .below, advance: .scripted)
		]
		let tour = TourState(steps: steps, defaults: defaults)
		tour.start()
		XCTAssertEqual(tour.currentIndex, 0)
		// The enable step is driven by the bubble's primary button (the toggle can't be tapped
		// through the overlay), so the button is available immediately — not gated on a timeout.
		XCTAssertTrue(tour.showsNextButton, "Enable step shows its primary button immediately")

		tour.userEnabledModel()
		XCTAssertEqual(tour.currentIndex, 1, "Enabling the highlighted model advances the enable step")
	}

	func testBubblePrimary_onEnableStep_invokesEnableHookAndFinishes() {
		let steps = [
			TourStep(target: .enableModelToggle, bubbleText: "enable", placement: .above,
					 advance: .userAction(.modelEnabled))
		]
		let tour = TourState(steps: steps, defaults: defaults)
		var enableCalls = 0
		tour.bindEnableModel { enableCalls += 1; return true }
		tour.start()

		tour.bubblePrimaryTapped()
		XCTAssertEqual(enableCalls, 1, "The enable step's primary button enables a demo model")
		XCTAssertFalse(tour.isActive, "Tapping it finishes the tour (last step)")
		XCTAssertTrue(tour.hasSeenTour, "Finishing seeds the gate")
	}

	func testUserEnabledModel_noopWhenNotOnEnableStep() {
		// A model enabled while the tour is on a different (e.g. drawer-open) step must not advance.
		let steps = [
			TourStep(target: .modelsButton, bubbleText: "open", placement: .below,
					 advance: .userAction(.drawerOpened), fallbackAfter: 5),
			TourStep(target: .demoModels, bubbleText: "next", placement: .below, advance: .scripted)
		]
		let tour = TourState(steps: steps, defaults: defaults)
		tour.start()
		tour.userEnabledModel()
		XCTAssertEqual(tour.currentIndex, 0, "Enabling a model off the enable step must not advance")
	}

	func testOverlayDrivenStep_timeoutStillSurfacesNext() async {
		// The overlay-driven step (drawer open) hides Next until acted on, but a timeout must
		// still surface it so the step can never deadlock.
		let steps = [
			TourStep(target: .modelsButton, bubbleText: "open", placement: .below,
					 advance: .userAction(.drawerOpened), fallbackAfter: 0.1)
		]
		let tour = TourState(steps: steps, defaults: defaults)
		tour.start()
		XCTAssertFalse(tour.showsNextButton, "Overlay-driven step hides Next until acted on or timed out")

		try? await Task.sleep(nanoseconds: 300_000_000)
		XCTAssertTrue(tour.showsNextButton, "The timeout must still surface Next (no deadlock)")
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
