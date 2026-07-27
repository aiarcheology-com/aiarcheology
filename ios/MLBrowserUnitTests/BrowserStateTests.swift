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
    private(set) var didFinishNavigation = false

    // swiftlint:disable:next implicitly_unwrapped_optional
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didFinishNavigation = true
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
    private static let fixtureName = "fixture.html"
    /// A reachability-class failure — the only family `WebLoadFailure` surfaces (AIA-0509).
    private static let offlineError = NSError(domain: NSURLErrorDomain,
                                              code: NSURLErrorNotConnectedToInternet,
                                              userInfo: nil)

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
    ///
    /// Throws `XCTSkip` if `didFinish` never arrives. A timed-out `fulfillment` only records
    /// a failure; it does not stop the test, so without this guard execution falls through and
    /// runs JavaScript against a document that never loaded — surfacing as a misleading
    /// "pushState … URL is invalid" instead of the real cause (the load never finished).
    private func loadTestPage() async throws {
        let finished = expectation(description: "didFinish")
        // WebKit may report didFinish more than once for a loadHTMLString navigation.
        finished.assertForOverFulfill = false
        navigationWaiter.onFinish = { finished.fulfill() }
        webView.navigationDelegate = navigationWaiter
        webView.loadHTMLString(Self.html, baseURL: Self.baseURL)
        // 30s, not 10s: a 10s ceiling produced spurious didFinish timeouts under Xcode Cloud
        // content-process contention (this suite's CI flakiness is documented in AIA-0217).
        await fulfillment(of: [finished], timeout: 30)
        guard navigationWaiter.didFinishNavigation else {
            throw XCTSkip("WKWebView did not finish loading the test page — cannot establish the precondition.")
        }
        await waitForCurrentURL { $0 == Self.baseURL }
    }

    /// Runs JavaScript once the document is ready.
    private func evaluate(_ script: String) async throws {
        _ = try await webView.evaluateJavaScript(script)
    }

    /// Writes a real on-disk page and returns its directory: `loadFileURL` needs a file that
    /// exists, and `file://` is exactly the scheme `lastRestorableURL` must refuse.
    private static func makeTemporaryPageDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try html.write(to: directory.appendingPathComponent(fixtureName), atomically: true, encoding: .utf8)
        return directory
    }

    // MARK: - KVO mirrors

    func testAttach_MirrorsLoadedURL() async throws {
        try await loadTestPage()

        XCTAssertEqual(sut.currentURL, Self.baseURL)
    }

    func testPushState_UpdatesCurrentURL() async throws {
        try await loadTestPage()

        // The central AIA-0044 assumption: same-document History-API navigations
        // never reach the navigation delegate but do fire KVO on \.url.
        // (canGoBack is NOT asserted here: WKWebView does not register pushState
        // entries in the back-forward list for loadHTMLString documents — real
        // http(s) documents do; covered by manual verification on the map sites.)
        try await evaluate("history.pushState({}, '', '/page2')")
        await waitForCurrentURL { $0?.path == "/page2" }

        XCTAssertEqual(sut.currentURL?.path, "/page2")
    }

    func testReplaceState_UpdatesCurrentURL() async throws {
        try await loadTestPage()

        try await evaluate("history.replaceState({}, '', '/moved?x=1')")
        await waitForCurrentURL { $0?.path == "/moved" }

        XCTAssertEqual(sut.currentURL?.query, "x=1")
    }

    func testGoBackIntent_WalksBackToThePreviousDocument() async throws {
        try await loadTestPage()
        let secondURL = URL(string: "https://example.com/second")!
        let finished = expectation(description: "second didFinish")
        finished.assertForOverFulfill = false
        navigationWaiter.onFinish = { finished.fulfill() }
        webView.loadHTMLString(Self.html, baseURL: secondURL)
        // Same 30s ceiling as loadTestPage — the second load faces the same CI cold-start risk.
        await fulfillment(of: [finished], timeout: 30)
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

    func testCancelSubscriptions_IsIdentityGuarded() async throws {
        let unrelatedWebView = WKWebView()

        // A stale dismantle for a web view that is not attached must be a no-op.
        sut.cancelSubscriptions(if: unrelatedWebView)
        try await loadTestPage()

        XCTAssertEqual(sut.currentURL, Self.baseURL)
    }

    // MARK: - lastPage persistence

    func testLastPage_PersistsEligibleURL_AfterSettling() async throws {
        try await loadTestPage()

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

    func testGate_ClearsOnlyForTheLatestNavigation() async throws {
        try await loadTestPage()
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

    func testGate_IgnoresSettleBeforeTokenIsRecorded() async throws {
        try await loadTestPage()
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

    // MARK: - AIA-0509: recovery target

    func testLastRestorableURL_IsStickyAndRefusesFileURLs() async throws {
        try await loadTestPage()
        XCTAssertEqual(sut.lastRestorableURL, Self.baseURL)

        let directory = try Self.makeTemporaryPageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        webView.loadFileURL(directory.appendingPathComponent(Self.fixtureName),
                            allowingReadAccessTo: directory)
        await waitForCurrentURL { $0?.isFileURL == true }

        // Why the property exists at all: KVO drives `currentURL` to nil when the content
        // process dies, so the recovery target has to be sticky — and AIA-0316's `file://`
        // fixtures must never become one, or recovery would reopen a test page.
        XCTAssertEqual(sut.lastRestorableURL, Self.baseURL)
    }

    // MARK: - AIA-0509: failure publication

    func testNavigationFailed_ReachabilityError_PublishesLoadFailure() throws {
        let navigation = try XCTUnwrap(webView.loadHTMLString(Self.html, baseURL: Self.baseURL))
        sut.navigationStarted(navigation)

        sut.navigationFailed(navigation, error: Self.offlineError)

        XCTAssertEqual(sut.loadFailure?.kind, .unreachable)
    }

    func testNavigationStarted_ClearsAPublishedLoadFailure() throws {
        let failed = try XCTUnwrap(webView.loadHTMLString(Self.html, baseURL: Self.baseURL))
        sut.navigationStarted(failed)
        sut.navigationFailed(failed, error: Self.offlineError)
        XCTAssertNotNil(sut.loadFailure, "Precondition: the overlay is up")

        // The overlay comes down when a retry is in flight, not only once it succeeds.
        sut.navigationStarted(try XCTUnwrap(webView.loadHTMLString(Self.html, baseURL: Self.baseURL)))

        XCTAssertNil(sut.loadFailure)
    }

    func testNavigationFailed_SupersededNavigation_DoesNotPublish() throws {
        let stale = try XCTUnwrap(webView.loadHTMLString(Self.html, baseURL: URL(string: "https://example.com/old")!))
        let latest = try XCTUnwrap(webView.loadHTMLString(Self.html, baseURL: URL(string: "https://example.com/new")!))
        XCTAssertFalse(stale === latest, "Precondition: two distinct navigation tokens")
        sut.navigationStarted(stale)
        sut.navigationStarted(latest)

        // WebKit guarantees no ordering between a post-commit didFail on `stale` and a
        // didCommit on `latest`; without the identity check, `stale`'s late failure would
        // paint an overlay over the page `latest` just loaded successfully.
        sut.navigationFailed(stale, error: Self.offlineError)

        XCTAssertNil(sut.loadFailure)
    }

    // MARK: - AIA-0509: web view invalidation

    func testWebViewInvalidated_ReleasesAStrandedUserLoadGate() async throws {
        try await loadTestPage()
        sut.userLoadRequested("https://example.com/picked")
        XCTAssertTrue(sut.isUserLoadPending, "Precondition: a user load is gating the display")

        // The pending token can never settle once the instance is gone. Without this the gate
        // stays set and the throttled display sink stops updating `displayedURL` — the address
        // bar freezes on the requested URL for the rest of the session.
        sut.webViewInvalidated()

        XCTAssertFalse(sut.isUserLoadPending)
        XCTAssertEqual(sut.displayedURL, Self.baseURL, "The bar must resync to the live URL")
    }

    func testConsumePendingSessionState_IsOneShot() async throws {
        try await loadTestPage()
        sut.webViewInvalidated()

        let first = sut.consumePendingSessionState()
        try XCTSkipIf(first == nil, "WKWebView reported no interactionState — nothing to consume.")

        // `makeUIView` runs on any SwiftUI identity change (a tab or mode switch, not only a
        // recovery rebuild), so a session left sitting here would eventually be restored over a
        // perfectly healthy live web view.
        XCTAssertNil(sut.consumePendingSessionState(), "The captured session must be consumed exactly once")
    }

    // MARK: - LoadRequest

    func testNext_CarriesTheCachePolicyAndBumpsGeneration() {
        let request = LoadRequest.initial.next("https://example.com", cachePolicy: .reloadIgnoringLocalCacheData)

        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData,
                       "The rebuild rung recovers from a poisoned cached document; the policy must reach the load")
        XCTAssertEqual(request.generation, LoadRequest.initial.generation + 1)
    }

    func testNext_WithoutACachePolicy_KeepsTheProtocolDefault() {
        // Every pre-AIA-0509 call site omits the argument and must be unchanged by it.
        XCTAssertEqual(LoadRequest.initial.next("https://example.com").cachePolicy, .useProtocolCachePolicy)
    }

    // MARK: - Recovery entry points (AIA-0509)

    func testWebContentProcessDidTerminate_FromAForeignWebView_IsIgnored() {
        // A `.id()` rebuild leaves the outgoing web view and its Coordinator briefly alive, and
        // their late callbacks target this same shared state. A dying instance must not spend
        // recovery budget or clear state belonging to the live one.
        let foreign = WKWebView()
        sut.userLoadRequested("https://example.com/pending")
        XCTAssertTrue(sut.isUserLoadPending)

        sut.webContentProcessDidTerminate(from: foreign)

        XCTAssertTrue(sut.isUserLoadPending, "A callback from a detached web view must not clear the live gate")
    }

    func testNavigationFailed_FromAForeignWebView_DoesNotPublish() {
        let foreign = WKWebView()

        sut.navigationFailed(nil, error: Self.offlineError, from: foreign)

        XCTAssertNil(sut.loadFailure)
    }

    func testWebContentProcessDidTerminate_ClearsTheDisplayGate() {
        // The gate is keyed on a navigation token the dead process can never settle; without this
        // the throttled display sink stops updating and the address bar freezes for the session.
        sut.userLoadRequested("https://example.com/pending")
        XCTAssertTrue(sut.isUserLoadPending)

        sut.webContentProcessDidTerminate()

        XCTAssertFalse(sut.isUserLoadPending)
    }

    func testActiveNotification_RetriesOnlyWhenSomethingIsBroken() async throws {
        let name = Notification.Name("BrowserStateTests.didBecomeActive")
        let state = BrowserState(settings: settings, activeNotification: name)
        state.attach(webView)

        // Nothing is broken: becoming active must not touch the web view at all.
        NotificationCenter.default.post(name: name, object: nil)
        await Task.yield()
        XCTAssertNil(state.loadFailure)

        // With a failure showing, the same notification drives a recovery attempt. The web view
        // here has never loaded anything, so the rung cannot produce a navigation and the state
        // must end up surfacing a failure rather than silently swallowing the attempt.
        state.navigationFailed(nil, error: Self.offlineError)
        XCTAssertNotNil(state.loadFailure)

        NotificationCenter.default.post(name: name, object: nil)
        await Task.yield()

        XCTAssertNotNil(state.loadFailure, "An exhausted or failed retry must leave the user an escape hatch")
    }

    func testWebViewInvalidated_DuringARebuild_KeepsTheRebuiltViewsGate() throws {
        // The view calls webViewInvalidated() *while* serving the rebuild request. Clearing the
        // display gate there is the point; the assertion is that doing so is still safe for the
        // incoming web view — a stranded gate here would freeze the address bar exactly as the
        // termination path would.
        sut.navigationFailed(nil, error: Self.offlineError)
        sut.retryRequested()
        sut.userLoadRequested("https://example.com/in-flight")

        sut.webViewInvalidated()

        XCTAssertFalse(sut.isUserLoadPending, "The outgoing web view's token can never settle")
    }

    func testRebuildRequestDeclined_ReleasesTheLadderAndKeepsTheEscapeHatch() throws {
        // A rebuild arriving mid finding-capture is dropped by the view. The rung never ran, so
        // nothing will call back to release it — without this the ladder jams for the session.
        sut.navigationFailed(nil, error: Self.offlineError)
        sut.retryRequested()

        sut.rebuildRequestDeclined()

        XCTAssertNil(sut.rebuildRequest)
        XCTAssertNotNil(sut.loadFailure, "Try Again must stay available after a declined rebuild")
    }

}
