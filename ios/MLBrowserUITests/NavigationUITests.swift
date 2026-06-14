//
//  NavigationUITests.swift
//  MLBrowserUITests
//
//  Navigation-bar composition (device-idiom adaptive), fullscreen capsule, and
//  home/blank page. (AIA-0189 foundation; chrome matrix updated for AIA-0294.)
//

import XCTest

final class NavigationUITests: UITestCase {

	/// Browser chrome composition for the current device idiom, with detection not running
	/// and fullscreen detection disabled (the issue's precondition). Runs meaningfully on
	/// both iPhone and iPad — it asserts the layout for whichever idiom it runs on, so it
	/// never silently skips.
	@MainActor
	func testNavigationBarComposition_matchesDeviceIdiom() {
		launch()

		XCTAssertTrue(app.buttons[AID.cpu].waitForExistence(timeout: 15), "Browser chrome should appear")
		XCTAssertEqual(checkpointValue(AID.cpFullscreen), "false", "Precondition: fullscreen detection is off")

		assertNormalModeComposition()
	}

	/// The composition is idiom-driven, so it must hold in landscape too: iPhone keeps the
	/// capsule in both orientations, iPad keeps everything in the top bar.
	@MainActor
	func testNavigationBarComposition_landscape() {
		launch()
		XCTAssertTrue(app.buttons[AID.cpu].waitForExistence(timeout: 15))

		XCUIDevice.shared.orientation = .landscapeLeft
		_ = checkpointValue(AID.cpDeviceIdiom) // let layout settle after rotation
		XCTAssertTrue(app.buttons[AID.cpu].waitForExistence(timeout: 10))

		assertNormalModeComposition()
	}

	/// Shared normal-mode (chrome visible) assertion, per device idiom (AIA-0294):
	/// - iPhone: Find is in the top bar; back/forward/reload live in the floating capsule.
	/// - iPad:   everything (incl. back/forward/reload and Find) is in the top bar; no capsule.
	@MainActor
	private func assertNormalModeComposition() {
		if isPhoneIdiom {
			assertButtonsLeftToRight([AID.cpu, AID.address, AID.findTop, AID.play, AID.edit])
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
}
