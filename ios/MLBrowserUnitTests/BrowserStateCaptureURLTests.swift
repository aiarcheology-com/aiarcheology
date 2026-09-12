//
//  BrowserStateCaptureURLTests.swift
//  MLBrowserUnitTests
//
//  AIA-0817: which URL a finding records.
//
//  Both existing URLs are wrong for this. `displayedURL` is throttled and shows the *requested*
//  address during a user load, while the old page is still on screen. `currentURL` is raw KVO,
//  which can already hold a provisional URL for a document that does not exist yet. A finding must
//  record the page whose pixels were captured.
//

import WebKit
import XCTest
@testable import ML_Browser

@MainActor
final class BrowserStateCaptureURLTests: XCTestCase {

	private var settings: Settings!
	private var state: BrowserState!
	private var webView: WKWebView!
	private var originalLastPage: URL?

	override func setUp() async throws {
		try await super.setUp()
		settings = Settings()
		// Settings persists to UserDefaults.standard; keep the suite clean for everyone else.
		originalLastPage = settings.lastPage
		settings.lastPage = nil
		webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
		state = BrowserState(settings: settings)
		state.attach(webView)
	}

	override func tearDown() async throws {
		settings.lastPage = originalLastPage
		state = nil
		webView = nil
		settings = nil
		try await super.tearDown()
	}

	/// Loads a document, waits for the KVO sink, and simulates the commit the app would deliver.
	///
	/// The commit is not optional decoration. In the app `MLWebView`'s coordinator forwards
	/// `didCommit` to `BrowserState`, which is what stamps `committedURL`; this test owns a bare
	/// `WKWebView` with no delegate, so without this the state under test never reaches the shape it
	/// always has in production, and the tests would be describing a situation that cannot occur.
	private func load(_ html: String, at url: URL) async {
		webView.loadHTMLString(html, baseURL: url)
		let deadline = Date().addingTimeInterval(15)
		while Date() < deadline {
			try? await Task.sleep(for: .milliseconds(50))
			if webView.isLoading == false, webView.url != nil { break }
		}
		await settle()
		state.navigationCommitted(nil, from: webView)
		await settle()
	}

	private func settle() async {
		try? await Task.sleep(for: .milliseconds(150))
	}

	// MARK: - The committed page, not the requested one

	/// The failure this prevents: the user types an address, then taps a detection on the page
	/// still rendered underneath. The finding must record what was on screen, not the destination.
	func testDuringAUserLoad_CaptureURLIsTheRenderedPage_NotTheRequestedOne() async {
		await load("<p>rendered</p>", at: URL(string: "https://example.org/rendered")!)
		let rendered = state.captureURL
		XCTAssertNotNil(rendered)

		state.userLoadRequested("https://example.org/requested")
		await settle()

		XCTAssertEqual(state.displayedURL?.absoluteString, "https://example.org/requested",
		               "the address bar shows where we are going")
		XCTAssertEqual(state.captureURL, rendered,
		               "a finding must not claim the page that is only being fetched")
	}

	// MARK: - Same-document navigation: the map pan

	/// The case this ticket exists for. `pushState`/`replaceState` never commit, and
	/// `WKNavigationDelegate` has no public same-document callback, so the KVO stream is the only
	/// signal available — `captureURL` has to follow it or a pan is never recorded.
	func testReplaceState_AdvancesCaptureURL() async {
		await load("<p>map</p>", at: URL(string: "https://example.org/map")!)

		_ = try? await webView.evaluateJavaScript(
			"history.replaceState(null, '', '/map#map=15/47.941230/18.709545'); true"
		)
		await settle()

		XCTAssertEqual(state.captureURL?.fragment, "map=15/47.941230/18.709545")
	}

	func testPushState_FeedsTheResolver() async {
		await load("<p>map</p>", at: URL(string: "https://example.org/map")!)

		_ = try? await webView.evaluateJavaScript(
			"history.pushState(null, '', '/map#map=15/47.941230/18.709545'); true"
		)
		await settle()

		let location = MapLocationResolver.resolve(url: state.captureURL)
		XCTAssertEqual(location.reading?.coordinate.latitude ?? 0, 47.941230, accuracy: 0.0000001)
		XCTAssertEqual(location.reading?.coordinate.longitude ?? 0, 18.709545, accuracy: 0.0000001)
	}

	/// Rapid same-document updates: the newest one wins, and the capture path notices they were
	/// same-document at all.
	///
	/// **Named for what it proves.** It was called `…IsNotSubjectToTheAddressBarThrottle`, and it did
	/// not show that: it waits past the 100 ms window, by which point the throttled address bar has
	/// caught up too, so both values agree and neither path is distinguished (raised in review). The
	/// contrast is genuinely time-dependent — the throttle is a wall-clock timer with no injected
	/// clock — so asserting it would mean asserting that a 100 ms deadline was not met on a loaded CI
	/// machine, which is a flake rather than a proof. What *is* deterministic is latest-wins over five
	/// updates, and that the same-document marker was raised: no navigation committed here, so a
	/// `captureURL` that moved at all moved through the KVO path this feature added.
	func testCaptureURL_TracksRapidSameDocumentUpdates_LatestWins() async {
		await load("<p>map</p>", at: URL(string: "https://example.org/map")!)

		for index in 1...5 {
			_ = try? await webView.evaluateJavaScript(
				"history.replaceState(null, '', '/map#step\(index)'); true"
			)
		}
		await settle()

		XCTAssertEqual(state.captureURL?.fragment, "step5", "the newest pan must be the one recorded")
		XCTAssertTrue(
			state.hasObservedSameDocumentURLChange,
			"the URL moved without a commit, so the same-document path is what moved it"
		)
	}

	// MARK: - The in-flight marker must always clear

	/// The regression this pins: `navigationFailed` returns early for an unclassified error and for
	/// a provisional failure over committed content. Clearing the marker after those guards would
	/// freeze `captureURL` for the rest of the session, and no later pan would ever be recorded.
	func testUnclassifiedFailure_DoesNotFreezeCaptureURL() async {
		await load("<p>map</p>", at: URL(string: "https://example.org/map")!)

		state.navigationStarted(nil, from: webView)
		state.navigationFailed(
			nil,
			error: NSError(domain: "TestDomain", code: -1, userInfo: nil),
			provisional: true,
			from: webView
		)

		_ = try? await webView.evaluateJavaScript("history.replaceState(null, '', '/map#after'); true")
		await settle()

		XCTAssertEqual(state.captureURL?.fragment, "after", "the in-flight marker stuck")
	}

	/// While a different document is genuinely being fetched, a KVO update must not be mistaken for
	/// the page on screen.
	func testWhileANavigationIsInFlight_CaptureURLHolds() async {
		await load("<p>map</p>", at: URL(string: "https://example.org/map")!)
		let beforeNavigation = state.captureURL

		state.navigationStarted(nil, from: webView)
		_ = try? await webView.evaluateJavaScript("history.replaceState(null, '', '/map#during'); true")
		await settle()

		XCTAssertEqual(state.captureURL, beforeNavigation, "a page being fetched is not the page on screen")

		state.navigationCommitted(nil, from: webView)
		_ = try? await webView.evaluateJavaScript("history.replaceState(null, '', '/map#settled'); true")
		await settle()

		XCTAssertEqual(state.captureURL?.fragment, "settled", "tracking must resume after the commit")
	}

	// MARK: - Fallback

	/// Attaching to an already-loaded web view produces no commit callback, yet a page is on
	/// screen. The fallback is what keeps the ticket's floor — always some URL — intact.
	///
	/// Arranged **without** `load`, which synthesizes the commit the app's coordinator would deliver
	/// — so the previous version of this test exercised the committed path and could not have failed
	/// if the fallback were deleted (raised in review). Here the document is loaded first and a fresh
	/// `BrowserState` attaches to it afterwards, which is the real situation: a mode switch rebuilds
	/// the state around a web view that is already showing a page.
	func testWithNoObservedCommit_StillReportsAURL() async {
		let url = URL(string: "https://example.org/already-here")!
		webView.loadHTMLString("<p>here</p>", baseURL: url)
		let deadline = Date().addingTimeInterval(15)
		while Date() < deadline {
			try? await Task.sleep(for: .milliseconds(50))
			if webView.isLoading == false, webView.url != nil { break }
		}

		let attaching = BrowserState(settings: settings)
		attaching.attach(webView)
		await settle()

		XCTAssertNotNil(
			attaching.captureURL,
			"a state that never saw a commit must still report the page that is on screen"
		)
	}
}
