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
}
