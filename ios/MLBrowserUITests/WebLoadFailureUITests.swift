//
//  WebLoadFailureUITests.swift
//  MLBrowserUITests
//
//  AIA-0552: the load-failure overlay must never replace a page the user already has — offline,
//  on-device detection still works on loaded content. It remains the honest state when nothing is
//  committed (cold launch against an unreachable home page, AIA-0509).
//

import XCTest

final class WebLoadFailureUITests: UITestCase {

	/// Raw identifier from `WebLoadFailureOverlay` (AIA-0509 predates the `Testability` enum here).
	private static let retryID = "web.load.retry"

	/// An instantly-refused loopback URL. Two properties are load-bearing:
	/// - The port must NOT be on WebKit's blocked "bad ports" list (1, 7, 25, …): a blocked port
	///   fails with a WebKit restricted-port error that is outside `WebLoadFailure.classify`'s
	///   reachability allowlist, so the overlay never fires and both tests break — learned
	///   empirically; 52099 is in the dynamic range with nothing bound, so the TCP connect is
	///   refused in ~1ms as NSURLErrorCannotConnectToHost (-1004), squarely in the allowlist.
	/// - `https`, not `http`, purely to avoid any ATS ambiguity; the refusal happens before TLS
	///   ever engages, so the scheme does not change the error.
	private static let unreachableURL = "https://127.0.0.1:52099"

	/// The companion cold-launch test below proves this exact URL raises the overlay when nothing
	/// is committed, so this pair cannot pass vacuously: the failure mechanism demonstrably fires
	/// in this environment, and here it is the committed fixture page that keeps it quiet.
	///
	/// Deliberately asserts only the overlay, which is the ticket's literal ask ("the offline
	/// message replacing the web content must be removed"). That the committed page also *renders*
	/// through the failure is not assertable at this level — WKWebView exposes none of the page's
	/// text to the accessibility tree here (verified against a failure-run hierarchy dump), and
	/// `Checkpoint.CurrentPageFile` mirrors `webView.url`, which keeps reporting the *failed*
	/// target after a provisional failure. Rendering preservation is WebKit's committed-document
	/// semantics, and the suppression state machine is pinned by `BrowserStateTests`.
	func testOfflineNavigation_KeepsTheLoadedPage() {
		launch(LaunchConfig(pageScenario: .localFixture, fixtureName: "uitest_page"))
		XCTAssertTrue(
			waitForCheckpoint(AID.cpCurrentPageFile, equals: "uitest_page.html"),
			"Local fixture did not become the live page"
		)

		let addressBar = app.buttons[AID.address]
		XCTAssertTrue(addressBar.waitForExistence(timeout: 10), "Address bar missing")
		addressBar.tap()
		let input = app.textFields[AID.locationInput]
		XCTAssertTrue(input.waitForExistence(timeout: 10), "Location composer did not open")
		input.tap()
		// The trailing return submits (`.onSubmit` in LocationSheetView).
		input.typeText(Self.unreachableURL + "\n")

		// Bounded inverted wait: the refusal settles in milliseconds, so 4 seconds is generous
		// headroom for the provisional failure to have been delivered — and suppressed.
		XCTAssertFalse(
			app.buttons[Self.retryID].waitForExistence(timeout: 4),
			"An offline navigation over live content must not raise the overlay (AIA-0552)"
		)
	}

	func testColdLaunchUnreachableHome_ShowsTheFailureOverlay() {
		launch(LaunchConfig(pageScenario: .home, defaultPageOverride: Self.unreachableURL))

		// Nothing is committed, so the overlay is the only honest state — and the AIA-0536
		// manual-test scenario ("Page didn't load / Try Again") stays valid exactly here.
		XCTAssertTrue(
			app.buttons[Self.retryID].waitForExistence(timeout: 10),
			"With nothing committed the failure overlay must surface (AIA-0509/0552)"
		)
	}
}
