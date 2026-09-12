//
//  WebLoadFailureTests.swift
//  AI ArcheologyTests
//
//  AIA-0509: the allowlist that decides whether a navigation error is worth showing the user
//  an overlay for, and where its "Try Again" should go.
//

import XCTest
@testable import ML_Browser

final class WebLoadFailureTests: XCTestCase {

    /// The reachability family the overlay exists for. Numeric values are spelled out because
    /// the ticket is written in terms of them.
    private static let allowlisted: [(name: String, code: Int)] = [
        ("NSURLErrorNotConnectedToInternet", NSURLErrorNotConnectedToInternet),  // -1009
        ("NSURLErrorTimedOut", NSURLErrorTimedOut),                              // -1001
        ("NSURLErrorNetworkConnectionLost", NSURLErrorNetworkConnectionLost),    // -1005
        ("NSURLErrorCannotFindHost", NSURLErrorCannotFindHost),                  // -1003
        ("NSURLErrorCannotConnectToHost", NSURLErrorCannotConnectToHost)         // -1004
    ]

    private static func urlError(_ code: Int, userInfo: [String: Any]? = nil) -> NSError {
        NSError(domain: NSURLErrorDomain, code: code, userInfo: userInfo)
    }

    // MARK: - Allowlisted -> shown

    func testClassify_ReachabilityCodes_AreShownAsUnreachable() {
        for entry in Self.allowlisted {
            let failure = WebLoadFailure.classify(Self.urlError(entry.code))
            XCTAssertEqual(failure?.kind, .unreachable, "\(entry.name) (\(entry.code)) must surface an overlay")
        }
    }

    // MARK: - Not allowlisted -> silent

    func testClassify_Cancelled_IsNotShown() {
        // -999: a superseded load (navigating away, reloading, a redirect). Nothing failed.
        XCTAssertNil(WebLoadFailure.classify(Self.urlError(NSURLErrorCancelled)))
    }

    func testClassify_UnsupportedURL_IsNotShown() {
        // -1002: `mailto:` / `tel:` / app-scheme links. The page itself is fine.
        XCTAssertNil(WebLoadFailure.classify(Self.urlError(NSURLErrorUnsupportedURL)))
    }

    func testClassify_WebKitFrameLoadInterrupted_IsNotShown() {
        // WebKitErrorDomain 102 ("frame load interrupted") is what WKWebView delivers for a
        // download or a non-renderable MIME type — and `MLWebView` implements neither
        // `decidePolicyFor navigationResponse` nor `WKDownloadDelegate`, so *every* attachment
        // link takes this path. Overlaying it would cover a page that is perfectly fine.
        let error = NSError(domain: "WebKitErrorDomain", code: 102, userInfo: nil)

        XCTAssertNil(WebLoadFailure.classify(error))
    }

    func testClassify_ReachabilityCodeInAnotherDomain_IsNotShown() {
        // The codes only mean "unreachable" inside NSURLErrorDomain.
        let error = NSError(domain: "SomeOtherDomain", code: NSURLErrorNotConnectedToInternet, userInfo: nil)

        XCTAssertNil(WebLoadFailure.classify(error))
    }

    // MARK: - Retry target

    func testClassify_TakesRetryURLFromTheFailingURLKey() {
        let failingURL = URL(string: "https://example.com/wedged")!
        let error = Self.urlError(NSURLErrorTimedOut, userInfo: [NSURLErrorFailingURLErrorKey: failingURL])

        XCTAssertEqual(WebLoadFailure.classify(error)?.retryURL, failingURL)
    }

    func testClassify_WithoutAFailingURL_HasNoRetryURL() {
        // `nil` is meaningful: BrowserState then falls back to `lastRestorableURL`.
        XCTAssertNil(WebLoadFailure.classify(Self.urlError(NSURLErrorTimedOut))?.retryURL)
    }

    // MARK: - Drift guard

    func testEveryShownFailure_IsAlsoReportedToSentry() {
        // `WebLoadFailure.classify` (UI) and `webViewLoadErrorLevel(for:)` (Sentry log level,
        // AIA-0296) are deliberately separate classifiers: one is an allowlist of what deserves
        // an overlay, the other a denylist of what deserves a downgrade. They must not be
        // unified — 102 and -1002 belong in exactly one of them. This guard exists so they
        // cannot drift into a state where the app overlays something Sentry never sees.
        for entry in Self.allowlisted {
            let error = Self.urlError(entry.code)
            XCTAssertNotNil(WebLoadFailure.classify(error), "\(entry.name): precondition")
            XCTAssertEqual(webViewLoadErrorLevel(for: error), .error,
                           "\(entry.name) (\(entry.code)) is shown to the user but would not reach Sentry as an error")
        }
    }
}
