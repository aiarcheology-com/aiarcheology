//
//  NavigationUITests.swift
//  MLBrowserUITests
//
//  AIA-0189: navigation-bar composition (size-class adaptive) and home/blank page.
//

import XCTest

final class NavigationUITests: UITestCase {

	/// Browser chrome composition for the current size class, with detection not running
	/// and fullscreen detection disabled (the issue's precondition). The same test runs on
	/// both iPhone (compact) and iPad (regular) and asserts the layout for whichever class
	/// it is running in — so it never silently skips.
	@MainActor
	func testNavigationBarComposition_matchesSizeClass() {
		launch()

		XCTAssertTrue(app.buttons[AID.cpu].waitForExistence(timeout: 15), "Browser chrome should appear")
		XCTAssertEqual(checkpointValue(AID.cpFullscreen), "false", "Precondition: fullscreen detection is off")

		if isRegularWidth {
			// iPad / regular: browser cluster wraps the address; detection group is trailing.
			assertButtonsLeftToRight([
				AID.cpu, AID.webBack, AID.address, AID.webForward, AID.webReload, AID.findTop, AID.play, AID.edit
			])
			assertExists(AID.floatBack, false) // no floating capsule in regular width
		} else {
			// iPhone / compact: address only in the bar; browser actions in the floating capsule.
			assertButtonsLeftToRight([AID.cpu, AID.address, AID.play, AID.edit])
			assertExists(AID.webBack, false)  // back/forward/reload not in the top bar on compact
			assertExists(AID.findTop, false)  // Find lives in the floating capsule on compact
			assertExists(AID.floatBack, true)
			assertExists(AID.floatForward, true)
			assertExists(AID.floatReload, true)
			assertExists(AID.floatFind, true)
		}
	}

	/// Rotating to landscape keeps the correct composition for the (possibly changed) size
	/// class. iPhones stay compact in landscape; iPads stay regular.
	@MainActor
	func testNavigationBarComposition_landscape() {
		launch()
		XCTAssertTrue(app.buttons[AID.cpu].waitForExistence(timeout: 15))

		XCUIDevice.shared.orientation = .landscapeLeft
		// Let the size class settle after rotation before reading geometry.
		_ = checkpointValue(AID.cpSizeClass)
		XCTAssertTrue(app.buttons[AID.cpu].waitForExistence(timeout: 10))

		if isRegularWidth {
			assertButtonsLeftToRight([
				AID.cpu, AID.webBack, AID.address, AID.webForward, AID.webReload, AID.findTop, AID.play, AID.edit
			])
		} else {
			assertButtonsLeftToRight([AID.cpu, AID.address, AID.play, AID.edit])
		}
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
