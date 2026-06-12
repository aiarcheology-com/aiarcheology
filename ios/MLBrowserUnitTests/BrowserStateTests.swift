//
//  BrowserStateTests.swift
//  AI ArcheologyTests
//
//  Created by Vladimír Cortes Slavík on 11.06.26.
//

import XCTest
import WebKit
import Combine
@testable import ML_Browser

/// Exercises BrowserState against a real WKWebView: the KVO mirrors (including the
/// central AIA-0044 assumption that `\.url` fires for History-API navigations), the
/// navigation intents, and the user-load display gate.
/// Test-only navigation delegate: BrowserState deliberately has no didFinish concept,
/// but the History-API tests must not run JavaScript before the document exists.
private final class NavigationWaiter: NSObject, WKNavigationDelegate {
    var onFinish: (() -> Void)?

    // swiftlint:disable:next implicitly_unwrapped_optional
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onFinish?()
    }
}

@MainActor
final class BrowserStateTests: XCTestCase {

    var settings: Settings!
    var webView: WKWebView!
    var sut: BrowserState!
    private let navigationWaiter = NavigationWaiter()
    private var cancellables: Set<AnyCancellable> = []
    private var originalLastPage: URL?

    private static let baseURL = URL(string: "https://example.com/start")!
    private static let html = "<html><body>test</body></html>"

    override func setUp() async throws {
        try await super.setUp()
        settings = Settings()
        // Settings persists to UserDefaults.standard; keep the suite clean.
        originalLastPage = settings.lastPage
        settings.lastPage = nil
        webView = WKWebView()
        sut = BrowserState(settings: settings)
        sut.attach(webView)
    }

    override func tearDown() async throws {
        settings.lastPage = originalLastPage
        cancellables.removeAll()
        sut = nil
        webView = nil
        settings = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Waits until `currentURL` satisfies the predicate (KVO mirrors are asynchronous).
    private func waitForCurrentURL(timeout: TimeInterval = 10,
                                   _ predicate: @escaping (URL?) -> Bool) async {
        let expectation = expectation(description: "currentURL predicate")
        sut.$currentURL
            .first(where: predicate)
            .sink { _ in expectation.fulfill() }
            .store(in: &cancellables)
        await fulfillment(of: [expectation], timeout: timeout)
    }

    /// Loads the test page and waits until the document finished loading — the KVO
    /// mirror updates at load start, which is too early to evaluate JavaScript.
    private func loadTestPage() async {
        let finished = expectation(description: "didFinish")
        // WebKit may report didFinish more than once for a loadHTMLString navigation.
        finished.assertForOverFulfill = false
        navigationWaiter.onFinish = { finished.fulfill() }
        webView.navigationDelegate = navigationWaiter
        webView.loadHTMLString(Self.html, baseURL: Self.baseURL)
        await fulfillment(of: [finished], timeout: 10)
        await waitForCurrentURL { $0 == Self.baseURL }
    }

    /// Runs JavaScript once the document is ready.
    private func evaluate(_ script: String) async {
        let expectation = expectation(description: "javascript")
        webView.evaluateJavaScript(script) { _, error in
            XCTAssertNil(error, "JavaScript failed: \(String(describing: error))")
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 10)
    }

    // MARK: - KVO mirrors

    func testAttach_MirrorsLoadedURL() async {
        await loadTestPage()

        XCTAssertEqual(sut.currentURL, Self.baseURL)
    }

    func testPushState_UpdatesCurrentURL() async {
        await loadTestPage()

        // The central AIA-0044 assumption: same-document History-API navigations
        // never reach the navigation delegate but do fire KVO on \.url.
        // (canGoBack is NOT asserted here: WKWebView does not register pushState
        // entries in the back-forward list for loadHTMLString documents — real
        // http(s) documents do; covered by manual verification on the map sites.)
        await evaluate("history.pushState({}, '', '/page2')")
        await waitForCurrentURL { $0?.path == "/page2" }

        XCTAssertEqual(sut.currentURL?.path, "/page2")
    }

    func testReplaceState_UpdatesCurrentURL() async {
        await loadTestPage()

        await evaluate("history.replaceState({}, '', '/moved?x=1')")
        await waitForCurrentURL { $0?.path == "/moved" }

        XCTAssertEqual(sut.currentURL?.query, "x=1")
    }

    func testGoBackIntent_WalksBackToThePreviousDocument() async {
        await loadTestPage()
        let secondURL = URL(string: "https://example.com/second")!
        let finished = expectation(description: "second didFinish")
        finished.assertForOverFulfill = false
        navigationWaiter.onFinish = { finished.fulfill() }
        webView.loadHTMLString(Self.html, baseURL: secondURL)
        await fulfillment(of: [finished], timeout: 10)
        await waitForCurrentURL { $0 == secondURL }

        guard webView.canGoBack else {
            // Back-forward list behavior for data-based loads is a WebKit detail this
            // suite must not depend on; the intent itself is a one-line forward.
            return
        }
        XCTAssertTrue(sut.canGoBack, "Mirror must agree with the web view")
        sut.goBackTapped()
        await waitForCurrentURL { $0?.path == "/start" }

        XCTAssertEqual(sut.currentURL?.path, "/start")
    }

    func testReattach_CancelsOldWebViewMirrors() async {
        let otherWebView = WKWebView()
        sut.attach(otherWebView)

        // The originally attached web view must no longer publish into the mirrors.
        // Bounded sleep, NOT an inverted expectation: awaiting fulfillment of an
        // inverted expectation from a @MainActor test stalls the main thread on
        // Xcode Cloud (watchdog kill after the 10-minute allowance); Task.sleep
        // suspends instead. Recording every emission (not just the final value)
        // catches even a transient publish that something later overwrites.
        var sawBaseURL = false
        sut.$currentURL
            .sink { if $0 == Self.baseURL { sawBaseURL = true } }
            .store(in: &cancellables)
        webView.loadHTMLString(Self.html, baseURL: Self.baseURL)
        try? await Task.sleep(for: .seconds(1))

        XCTAssertFalse(sawBaseURL, "Detached web view must not publish into the mirrors")
    }

    func testCancelSubscriptions_IsIdentityGuarded() async {
        let unrelatedWebView = WKWebView()

        // A stale dismantle for a web view that is not attached must be a no-op.
        sut.cancelSubscriptions(if: unrelatedWebView)
        await loadTestPage()

        XCTAssertEqual(sut.currentURL, Self.baseURL)
    }

    // MARK: - lastPage persistence

    func testLastPage_PersistsEligibleURL_AfterSettling() async {
        await loadTestPage()

        // Persistence is debounced (storage-churn protection); poll past the window.
        let deadline = Date().addingTimeInterval(5)
        while settings.lastPage != Self.baseURL && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(settings.lastPage, Self.baseURL)
    }

    func testLastPage_IgnoresAboutBlank() async {
        webView.load(URLRequest(url: URL(string: "about:blank")!))
        await waitForCurrentURL { $0?.absoluteString == "about:blank" }

        // Wait out the persistence debounce before asserting nothing was written.
        try? await Task.sleep(for: .milliseconds(1400))
        XCTAssertNil(settings.lastPage)
    }

    // MARK: - User-load display gate

    func testUserLoadRequested_ShowsRequestedURLImmediately() {
        sut.userLoadRequested("example.org")

        XCTAssertTrue(sut.isUserLoadPending)
        XCTAssertEqual(sut.displayedURL, URL(string: "https://example.org"))
    }

    func testGate_ClearsOnlyForTheLatestNavigation() async {
        await loadTestPage()
        sut.userLoadRequested("https://example.com/picked")
        let stale = webView.loadHTMLString(Self.html, baseURL: URL(string: "https://example.com/old")!)
        let latest = webView.loadHTMLString(Self.html, baseURL: URL(string: "https://example.com/new")!)
        sut.navigationIssued(latest)

        // A superseded navigation's settle (e.g. its cancellation) must not open the gate.
        sut.navigationSettled(stale, error: nil)
        XCTAssertTrue(sut.isUserLoadPending)

        sut.navigationSettled(latest, error: nil)
        XCTAssertFalse(sut.isUserLoadPending)
    }

    func testGate_IgnoresSettleBeforeTokenIsRecorded() async {
        await loadTestPage()
        sut.userLoadRequested("https://example.com/picked")
        let oldNavigation = webView.loadHTMLString(Self.html, baseURL: Self.baseURL)

        // Pre-token window: a settle of an unrecorded (older) navigation is ignored.
        sut.navigationSettled(oldNavigation, error: nil)

        XCTAssertTrue(sut.isUserLoadPending)
    }

    func testNavigationIssued_NilToken_FailsOpen() {
        sut.userLoadRequested("https://example.com/picked")

        sut.navigationIssued(nil)

        XCTAssertFalse(sut.isUserLoadPending, "A nil token must release the gate so it cannot stick")
    }

    func testStopTapped_ReleasesGate() {
        sut.userLoadRequested("https://example.com/picked")

        sut.stopTapped()

        XCTAssertFalse(sut.isUserLoadPending)
    }

    func testGate_BlocksDisplayedURLWhilePending() async {
        sut.userLoadRequested("https://example.com/picked")

        // KVO emissions while the gate is set must not overwrite the display.
        // Bounded sleep, NOT an inverted expectation — see
        // testReattach_CancelsOldWebViewMirrors for the Xcode Cloud stall.
        webView.loadHTMLString(Self.html, baseURL: Self.baseURL)
        await waitForCurrentURL { $0 == Self.baseURL }
        try? await Task.sleep(for: .milliseconds(500))

        XCTAssertEqual(sut.displayedURL, URL(string: "https://example.com/picked"))
    }
}
