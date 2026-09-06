//
//  NavigationUITests.swift
//  MLBrowserUITests
//
//  Navigation-bar composition (device-idiom adaptive), fullscreen capsule, and
//  home/blank page. (AIA-0189 foundation; chrome matrix updated for AIA-0294.)
//

import XCTest

final class NavigationUITests: UITestCase {

	/// AIA-0868: Find opens an alignment mode over a *live* web view, not the old full-screen tap
	/// catcher. Only a fingertip-sized core at the centre takes touches; everything else must reach
	/// the page, because panning the page under the target is the interaction the feature exists
	/// for. The element's own frame is asserted, since a regression here would most likely be the
	/// interactive area growing back to the size of the drawn glyph — which no tap assertion in the
	/// middle of the screen would notice.
	@MainActor
	func testFind_alignmentCrosshairLeavesTheContentPannable() {
		enterAlignmentMode()
		let crosshair = element(AID.findingAlignmentCrosshair)

		let core = crosshair.frame
		XCTAssertEqual(core.width, 44, accuracy: 4, "The crosshair's touch area is not the 44pt core")
		XCTAssertEqual(core.height, 44, accuracy: 4, "The crosshair's touch area is not the 44pt core")

		// A pan that starts well clear of that core is the ordinary aiming gesture. It must neither
		// end the mode nor be mistaken for a capture — with the old overlay it was a pick.
		app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
			.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)))
		XCTAssertTrue(crosshair.exists, "A pan next to the crosshair ended alignment mode")
		XCTAssertFalse(
			app.textFields[AID.saveFindingTitle].waitForExistence(timeout: 2),
			"A pan next to the crosshair was taken as a capture"
		)

		let cancel = app.buttons[AID.findPickCancel]
		XCTAssertTrue(cancel.waitForExistence(timeout: 5), "Alignment mode offered no Cancel button")
		cancel.tap()
		XCTAssertTrue(
			waitForDisappearance(of: crosshair),
			"Cancelling alignment mode left the crosshair on screen"
		)
	}

	/// AIA-0868 (owner follow-up): the crosshair stores a finding whether or not it is green. With
	/// no model enabled nothing is ever detected, so this runs the red path end to end — including
	/// the branch that has to take its own snapshot, because with detection off there is no
	/// displayed frame to reuse. That is what makes "record something no model found" work.
	@MainActor
	func testFind_redCrosshairStoresThePlaceUnderIt() {
		enterAlignmentMode()

		element(AID.findingAlignmentCrosshair).tap()
		XCTAssertTrue(
			app.textFields[AID.saveFindingTitle].waitForExistence(timeout: 15),
			"Tapping the red crosshair did not open the finding form"
		)

		let cancel = app.buttons[AID.saveFindingCancel]
		XCTAssertTrue(cancel.waitForExistence(timeout: 5), "Finding form offered no Cancel button")
		cancel.tap()
		XCTAssertTrue(
			waitForDisappearance(of: element(AID.findingAlignmentCrosshair)),
			"Dismissing the finding form left alignment mode on screen"
		)
	}

	/// Loads the plain local fixture — no model is enabled, so the crosshair is always red — and
	/// enters alignment mode with the Find button.
	@MainActor
	private func enterAlignmentMode() {
		launch(LaunchConfig(pageScenario: .localFixture, fixtureName: "uitest_page"))
		XCTAssertTrue(
			waitForCheckpoint(AID.cpCurrentPageFile, equals: "uitest_page.html"),
			"Local fixture did not become the live page"
		)

		let find = app.buttons[AID.findTop]
		XCTAssertTrue(find.waitForExistence(timeout: 10), "Find button missing")
		find.tap()
		XCTAssertTrue(
			element(AID.findingAlignmentCrosshair).waitForExistence(timeout: 10),
			"Find did not show the large alignment crosshair"
		)
	}

	/// Browser chrome composition for the current device idiom, with detection not running
	/// and fullscreen detection disabled (the issue's precondition). Runs meaningfully on
	/// both iPhone and iPad — it asserts the layout for whichever idiom it runs on, so it
	/// never silently skips.
	@MainActor
	func testNavigationBarComposition_matchesDeviceIdiom() {
		launch()

		XCTAssertTrue(app.buttons[AID.cpu].waitForExistence(timeout: 15), "Browser chrome should appear")
		XCTAssertEqual(checkpointValue(AID.cpFullscreen), "false", "Precondition: fullscreen detection is off")

		// Default orientation is portrait (reset in setUp).
		assertNormalModeComposition(isLandscape: false)
	}

	/// The composition is idiom-driven, and on iPhone also orientation-driven for the address
	/// (AIA-0338): in landscape the address returns to the top bar. The capsule stays in both
	/// orientations; iPad keeps everything in the top bar regardless.
	@MainActor
	func testNavigationBarComposition_landscape() {
		launch()
		XCTAssertTrue(app.buttons[AID.cpu].waitForExistence(timeout: 15))

		XCUIDevice.shared.orientation = .landscapeLeft
		XCTAssertTrue(waitForLandscape(), "App should re-lay out in landscape before asserting geometry")
		XCTAssertTrue(app.buttons[AID.cpu].waitForExistence(timeout: 10))

		assertNormalModeComposition(isLandscape: true)
	}

	/// Shared normal-mode (chrome visible) assertion, per device idiom (AIA-0294) and, on
	/// iPhone, per orientation (AIA-0338):
	/// - iPhone portrait: address is at the BOTTOM (not the top bar); Find stays in the top bar.
	/// - iPhone landscape: address is back in the top bar.
	/// - iPad: everything (incl. back/forward/reload and Find) is in the top bar; no capsule.
	/// back/forward/reload live in the floating capsule on iPhone in both orientations.
	@MainActor
	private func assertNormalModeComposition(isLandscape: Bool) {
		if isPhoneIdiom {
			if isLandscape {
				assertButtonsLeftToRight([AID.cpu, AID.address, AID.findTop, AID.play, AID.edit])
			} else {
				// Portrait: the address left the top bar for the bottom (still exists; its
				// bottom placement is asserted by testAdaptiveAddressBar_*).
				assertButtonsLeftToRight([AID.cpu, AID.findTop, AID.play, AID.edit])
				assertExists(AID.address, true)
			}
			assertExists(AID.webBack, false)   // back/forward/reload are not in the top bar
			assertExists(AID.floatBack, true)  // they live in the capsule
			assertExists(AID.floatReload, true)
			assertExists(AID.floatForward, true)
			assertExists(AID.floatFind, false) // Find is in the top bar in normal mode
		} else {
			assertButtonsLeftToRight([
				AID.cpu, AID.webBack, AID.address, AID.webForward, AID.webReload, AID.findTop, AID.play, AID.edit
			])
			assertExists(AID.floatBack, false) // no capsule on iPad in normal mode
		}
	}

	/// AIA-0338: on iPhone the address bar sits at the BOTTOM in portrait — below the floating
	/// nav capsule, not overlapping it — and returns to the TOP bar in landscape. iPad/Mac are
	/// unaffected, so this asserts only on iPhone (it never silently skips: the guard is after a
	/// real chrome wait, and iPad has no bottom placement to assert).
	@MainActor
	func testAdaptiveAddressBar_bottomInPortraitTopInLandscape() {
		launch()
		XCTAssertTrue(app.buttons[AID.cpu].waitForExistence(timeout: 15), "Browser chrome should appear")
		guard isPhoneIdiom else { return } // iPhone-only feature

		let address = app.buttons[AID.address]
		let capsule = element(AID.floatReload) // capsule items are Images carrying .isButton
		XCTAssertTrue(address.waitForExistence(timeout: 10), "Address bar should exist")
		XCTAssertTrue(capsule.waitForExistence(timeout: 10), "Floating capsule should exist on iPhone")

		// Portrait: address is in the bottom half and strictly below the capsule (no overlap).
		let portraitWindow = app.windows.firstMatch.frame
		XCTAssertGreaterThan(
			Double(address.frame.midY), Double(portraitWindow.midY),
			"Portrait: the address bar should be in the bottom half of the screen"
		)
		XCTAssertGreaterThan(
			Double(address.frame.minY), Double(capsule.frame.maxY),
			"Portrait: the address bar should sit below the floating capsule (no overlap)"
		)

		// Landscape: address returns to the top bar.
		XCUIDevice.shared.orientation = .landscapeLeft
		XCTAssertTrue(waitForLandscape(), "App should re-lay out in landscape before asserting geometry")
		XCTAssertTrue(address.waitForExistence(timeout: 10), "Address bar should still exist in landscape")
		let landscapeWindow = app.windows.firstMatch.frame
		XCTAssertLessThan(
			Double(address.frame.midY), Double(landscapeWindow.midY),
			"Landscape: the address bar should be back in the top half (top bar)"
		)
	}

	/// AIA-0294: in fullscreen the top bar is gone, so the capsule stays visible on every
	/// device and carries Find, alongside the floating chrome toggle.
	@MainActor
	func testFullscreenCapsule_visibleAndCarriesFind() {
		launch(LaunchConfig(fullscreenDetection: true))

		let play = app.buttons[AID.play]
		XCTAssertTrue(play.waitForExistence(timeout: 15), "Browser mode should show the play button")
		play.tap()

		// Chrome hides; the floating capsule must remain and now include Find.
		XCTAssertTrue(
			app.descendants(matching: .any)[AID.floatFind].waitForExistence(timeout: 10),
			"Fullscreen capsule should carry Find"
		)
		assertExists(AID.floatBack, true)
		assertExists(AID.floatReload, true)
		assertExists(AID.floatForward, true)
		assertExists(AID.chromeToggle, true) // the floating TOOLS toggle stays
		assertExists(AID.findTop, false)     // top-bar Find is gone with the chrome
	}

	/// With a default page set, the browser decides to load the home page.
	@MainActor
	func testHomePage_loadedWhenDefaultPageSet() {
		launch(LaunchConfig(pageScenario: .home))
		XCTAssertTrue(
			waitForCheckpoint(AID.cpIntendedPageKind, equals: "home"),
			"A set default page should produce a `home` load decision"
		)
	}

	/// With no default page, the browser stays blank.
	@MainActor
	func testBlankPage_whenNoDefaultPage() {
		launch(LaunchConfig(pageScenario: .blank))
		XCTAssertTrue(
			waitForCheckpoint(AID.cpIntendedPageKind, equals: "blank"),
			"No default page should produce a `blank` load decision"
		)
	}

	/// An about:blank default page is treated as the blank-home state — not loaded as a
	/// page (which would search-treat "about:blank" in the load pipeline). AIA-0298.
	@MainActor
	func testAboutBlankDefaultPage_treatedAsBlank() {
		launch(LaunchConfig(defaultPageOverride: "about:blank"))
		XCTAssertTrue(
			waitForCheckpoint(AID.cpIntendedPageKind, equals: "blank"),
			"about:blank should resolve to a blank home page"
		)
	}
}
