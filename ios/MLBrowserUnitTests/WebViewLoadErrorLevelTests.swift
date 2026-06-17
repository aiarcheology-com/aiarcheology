//
//  WebViewLoadErrorLevelTests.swift
//  AI ArcheologyTests
//
//  Tests for webViewLoadErrorLevel(for:) — the decision that downgrades benign
//  WebView load cancellations (NSURLErrorCancelled, -999) to .debug so they stop
//  being captured as Sentry errors, while genuine load failures keep logging at
//  .error (AIA-0296).
//

import XCTest
@testable import ML_Browser

final class WebViewLoadErrorLevelTests: XCTestCase {

    // MARK: - Benign cancellation -> .debug

    func testCancelled_IsDowngradedToDebug() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, userInfo: nil)
        XCTAssertEqual(webViewLoadErrorLevel(for: error), .debug)
    }

    func testURLErrorCancelled_BridgesToDebug() {
        // URLError(.cancelled) bridges to NSURLErrorDomain/-999.
        let error = URLError(.cancelled)
        XCTAssertEqual(webViewLoadErrorLevel(for: error), .debug)
    }

    // MARK: - Genuine failures -> .error

    func testNotConnectedToInternet_StaysError() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: nil)
        XCTAssertEqual(webViewLoadErrorLevel(for: error), .error)
    }

    func testTimedOut_StaysError() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: nil)
        XCTAssertEqual(webViewLoadErrorLevel(for: error), .error)
    }

    func testCannotFindHost_StaysError() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost, userInfo: nil)
        XCTAssertEqual(webViewLoadErrorLevel(for: error), .error)
    }

    // MARK: - Domain guard

    func testCancelledCodeInOtherDomain_StaysError() {
        // -999 only counts in NSURLErrorDomain; the same code elsewhere is a real error.
        let error = NSError(domain: "SomeOtherDomain", code: NSURLErrorCancelled, userInfo: nil)
        XCTAssertEqual(webViewLoadErrorLevel(for: error), .error)
    }
}
