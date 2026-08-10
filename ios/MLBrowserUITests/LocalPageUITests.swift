//
//  LocalPageUITests.swift
//  MLBrowserUITests
//
//  AIA-0316: smoke test for the local-HTML file:// loader harness. Launching with the
//  `.localFixture` scenario must load a bundled HTML page via WKWebView.loadFileURL — fully
//  offline, no network — and that file must become the live page. Both assertions read in-app
//  checkpoints (web content is not reliably exposed to XCUITest).
//

import XCTest

final class LocalPageUITests: UITestCase {

    func testLocalFixture_loadsOfflineAndBecomesLivePage() {
        launch(LaunchConfig(pageScenario: .localFixture, fixtureName: "uitest_page"))

        // 1) The app decided to load the local fixture (not a network home page).
        XCTAssertTrue(
            waitForCheckpoint(AID.cpIntendedPageKind, equals: "localFixture"),
            "App did not choose the local-fixture scenario"
        )
        // 2) The bundled file actually became the live web-view page (render proof; the \\.url KVO
        //    path fires for host-less file:// URLs).
        XCTAssertTrue(
            waitForCheckpoint(AID.cpCurrentPageFile, equals: "uitest_page.html"),
            "Local fixture did not become the live page"
        )
    }

	func testNavigationFromPageInteraction_DetectionAdmitsSnapshotWithoutFurtherGesture() {
		launch(LaunchConfig(
			pageScenario: .localFixture,
			fullscreenDetection: true,
			fixtureName: "uitest_page"
		))

		XCTAssertTrue(
			waitForCheckpoint(AID.cpCurrentPageFile, equals: "uitest_page.html"),
			"Local fixture did not become the live page"
		)

		// The injected interaction script publishes `interacting` on touch-start. The link then
		// replaces the document before that script's delayed idle callback can execute.
		let navigationLink = app.links["AIA NAVIGATE"]
		XCTAssertTrue(navigationLink.waitForExistence(timeout: 10), "Navigation fixture link missing")
		navigationLink.tap()
		XCTAssertTrue(
			waitForDisappearance(of: navigationLink, timeout: 10),
			"Fixture link did not replace its document"
		)

		let play = app.buttons[AID.play]
		XCTAssertTrue(play.waitForExistence(timeout: 10), "Play button missing")
		play.tap()

		let deliveryCheckpoint = app.staticTexts[AID.cpSnapshotDeliveryCount]
		let positiveDelivery = NSPredicate { object, _ in
			guard let element = object as? XCUIElement, element.exists else { return false }
			let value = (element.value as? String) ?? element.label
			return (Int(value) ?? 0) > 0
		}
		let expectation = XCTNSPredicateExpectation(predicate: positiveDelivery, object: deliveryCheckpoint)
		XCTAssertEqual(
			XCTWaiter().wait(for: [expectation], timeout: 15),
			.completed,
			"Detection should admit a snapshot after navigation without requiring scroll or zoom"
		)
	}
}
