//
//  BrowserRevampUITests.swift
//  AI ArcheologyUITests
//
//  Created by Vladimír Slavík on 11.06.26.
//

import XCTest

/// End-to-end coverage for the browser revamp:
/// fullscreen detection mode (#11), toolbar modes (#196), settings in the
/// drawer (#249) and the top-right button spacing verification (#183).
final class BrowserRevampUITests: XCTestCase {

	private enum Identifier {
		static let play = "_AIA:Button.GlobalToolbarPlayDetection"
		static let pause = "_AIA:Button.GlobalToolbarPauseDetection"
		static let adjustments = "_AIA:Button.GlobalToolbarAdjustments"
		static let sideMenu = "_AIA:Button.GlobalToolbarSideMenu"
		static let floatingToggle = "_AIA:Button.FloatingChromeToggle"
		static let drawerSettings = "_AIA:Button.DrawerSettings"
		static let settingsDismiss = "_AIA:Button.SettingsDismiss"
	}

	override func setUpWithError() throws {
		continueAfterFailure = false
	}

	@MainActor
	private func launchApp() -> XCUIApplication {
		let app = XCUIApplication()
		app.launchEnvironment["UI_TESTING"] = "1"
		// This flow exercises fullscreen detection, which is off by default. Opt in
		// deterministically through the shared launch config rather than relying on
		// whatever value happens to be persisted on the simulator (AIA-0189).
		if let data = try? JSONEncoder().encode(LaunchConfig(fullscreenDetection: true)) {
			app.launchEnvironment["UI_TEST_CONFIG"] = String(data: data, encoding: .utf8)
		}
		app.launch()
		// The onboarding tour does not auto-start under UI tests (it is opt-in via
		// `startOnboardingTour`), so the chrome is reachable immediately.
		return app
	}

	@MainActor
	func testFullscreenDetectionFlow_TogglesChromeAndRestoresBrowserMode() throws {
		let app = launchApp()

		// Browser mode: play button plus the always-available adjustment control.
		let play = app.buttons[Identifier.play]
		XCTAssertTrue(play.waitForExistence(timeout: 10), "Browser mode should show the play button")
		XCTAssertTrue(app.buttons[Identifier.adjustments].exists, "Adjustment is available in browser mode too")
		XCTAssertFalse(app.buttons[Identifier.floatingToggle].exists, "Floating button is detection-only")

		// Start detection: chrome hides, floating button appears.
		play.tap()
		let floating = app.buttons[Identifier.floatingToggle]
		XCTAssertTrue(floating.waitForExistence(timeout: 5), "Fullscreen must show the floating chrome toggle")
		// The floating button and the chrome hide animate independently, so
		// wait for the bar to finish hiding instead of asserting immediately.
		XCTAssertTrue(
			waitForDisappearance(of: app.buttons[Identifier.play], timeout: 5),
			"Navigation bar should be hidden in fullscreen"
		)

		// Reveal chrome mid-detection: pause + adjustment are back, detection keeps running.
		floating.tap()
		let pause = app.buttons[Identifier.pause]
		let adjustments = app.buttons[Identifier.adjustments]
		XCTAssertTrue(pause.waitForExistence(timeout: 5), "Revealed chrome shows the pause button")
		XCTAssertTrue(adjustments.waitForExistence(timeout: 2), "Revealed chrome shows the adjustment button")
		XCTAssertTrue(floating.exists, "Floating button stays while detection runs")

		// AIA-0183: measure the trailing buttons' frames and their gap.
		let pauseFrame = pause.frame
		let adjustmentsFrame = adjustments.frame
		let gap = adjustmentsFrame.minX - pauseFrame.maxX
		print("AIA-0183 measurement: pause=\(pauseFrame) adjustments=\(adjustmentsFrame) gap=\(gap)pt")
		XCTAssertFalse(pauseFrame.intersects(adjustmentsFrame), "Buttons must not overlap")
		XCTAssertGreaterThanOrEqual(gap, 8, "Tappable frames need at least 8pt between them")
		XCTAssertGreaterThanOrEqual(pauseFrame.width, 44, "Pause button needs a 44pt hit target")
		XCTAssertGreaterThanOrEqual(adjustmentsFrame.width, 44, "Adjustment button needs a 44pt hit target")
		XCTAssertTrue(pause.isHittable)
		XCTAssertTrue(adjustments.isHittable)

		// Hide chrome again from the floating button.
		floating.tap()
		XCTAssertTrue(waitForDisappearance(of: pause, timeout: 5), "Chrome hides again on second tap")

		// Drag the floating button towards the screen center and confirm it moved and still works.
		let before = floating.frame
		floating.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
			forDuration: 0.2,
			thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
		)
		XCTAssertTrue(floating.isHittable, "Floating button must stay usable after dragging")
		XCTAssertNotEqual(before.origin, floating.frame.origin, "Floating button should be movable")

		// A plain swipe (no long press) must also drag the button.
		let beforeSwipe = floating.frame
		floating.swipeLeft()
		XCTAssertNotEqual(beforeSwipe.origin, floating.frame.origin, "A plain swipe must drag the button")
		XCTAssertTrue(floating.isHittable)

		// Stop detection: browser mode restores, floating button leaves.
		floating.tap()
		XCTAssertTrue(pause.waitForExistence(timeout: 5))
		pause.tap()
		XCTAssertTrue(play.waitForExistence(timeout: 5), "Stopping detection restores browser mode")
		XCTAssertTrue(waitForDisappearance(of: floating, timeout: 5), "Floating button leaves with detection")
		XCTAssertTrue(app.buttons[Identifier.adjustments].exists, "Adjustment stays available in browser mode")
	}

	@MainActor
	func testSettingsOpensFromDrawer() throws {
		let app = launchApp()

		let sideMenu = app.buttons[Identifier.sideMenu]
		XCTAssertTrue(sideMenu.waitForExistence(timeout: 10))
		sideMenu.tap()

		let drawerSettings = app.buttons[Identifier.drawerSettings]
		if !drawerSettings.waitForExistence(timeout: 5) {
			// List rows are created lazily; in landscape the Settings section
			// sits below the fold until the drawer list is scrolled.
			app.cells.firstMatch.swipeUp()
		}
		XCTAssertTrue(drawerSettings.waitForExistence(timeout: 5), "Drawer must contain the Settings entry")
		drawerSettings.tap()

		let settingsDismiss = app.buttons[Identifier.settingsDismiss]
		XCTAssertTrue(settingsDismiss.waitForExistence(timeout: 5), "Settings sheet should present from the drawer")
		settingsDismiss.tap()
		XCTAssertTrue(waitForDisappearance(of: settingsDismiss, timeout: 5))
	}

	@MainActor
	private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) -> Bool {
		let predicate = NSPredicate(format: "exists == false OR isHittable == false")
		let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
		return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
	}
}
