//
//  WizardUITests.swift
//  MLBrowserUITests
//
//  AIA-0189: welcome wizard (slideshow) coverage.
//

import XCTest

final class WizardUITests: UITestCase {

	/// The welcome wizard presents on launch and can be dismissed by dragging it down,
	/// revealing the browser chrome.
	@MainActor
	func testWizard_dismiss() {
		launch(LaunchConfig(presentWizard: true))

		let firstSlide = app.descendants(matching: .any)[AID.slide(0)]
		XCTAssertTrue(firstSlide.waitForExistence(timeout: 15), "Wizard should present on launch")

		// The sheet has no navigation bar, so dismiss it the way a user does — drag down.
		app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).press(
			forDuration: 0.1,
			thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
		)

		XCTAssertTrue(waitForDisappearance(of: firstSlide), "Wizard should dismiss")
		XCTAssertTrue(app.buttons[AID.cpu].waitForExistence(timeout: 10), "Browser chrome should be reachable after dismiss")
	}

	/// Every slide in the wizard is reachable by swiping through it. (The on-slide arrow
	/// glyphs are decorative; navigation is by swipe.)
	@MainActor
	func testWizard_scrollThroughAllSlides() {
		launch(LaunchConfig(presentWizard: true))

		let slideCount = 10 // SlideshowView defines 10 slides.
		XCTAssertTrue(app.descendants(matching: .any)[AID.slide(0)].waitForExistence(timeout: 15), "Wizard should present")

		for index in 1..<slideCount {
			app.swipeLeft()
			let slide = app.descendants(matching: .any)[AID.slide(index)]
			XCTAssertTrue(slide.waitForExistence(timeout: 5), "Slide \(index) should be reachable by swiping")
		}

		// Paging unloads distant pages, so the first slide is no longer in the tree — this
		// confirms we genuinely scrolled through rather than the pages being all preloaded.
		XCTAssertFalse(
			app.descendants(matching: .any)[AID.slide(0)].exists,
			"Should have scrolled past the first slide"
		)
	}
}
