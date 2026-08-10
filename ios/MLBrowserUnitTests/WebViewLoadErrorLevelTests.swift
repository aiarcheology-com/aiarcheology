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
import UIKit
import WebKit
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

@MainActor
final class WebViewInteractionLifecycleTests: XCTestCase {

	func testNavigationStart_InteractionWasActive_PublishesIdle() {
		var interactionChanges: [Bool] = []
		let renderer = WebSnapshotRenderer(adjustment: SnapAdjustment())
		let view = MLWebView(
			.initial,
			renderer: renderer,
			interactionStateChanged: { interactionChanges.append($0.isInteracting) }
		)
		let coordinator = view.makeCoordinator()

		coordinator.scrollViewWillBeginDragging(UIScrollView())
		XCTAssertEqual(interactionChanges, [true])

		coordinator.webView(WKWebView(), didStartProvisionalNavigation: nil)

		XCTAssertEqual(interactionChanges, [true, false])
	}

	func testNavigationStart_InteractionWasIdle_DoesNotPublishDuplicateIdle() {
		var interactionChanges: [Bool] = []
		let renderer = WebSnapshotRenderer(adjustment: SnapAdjustment())
		let view = MLWebView(
			.initial,
			renderer: renderer,
			interactionStateChanged: { interactionChanges.append($0.isInteracting) }
		)
		let coordinator = view.makeCoordinator()

		coordinator.webView(WKWebView(), didStartProvisionalNavigation: nil)

		XCTAssertTrue(interactionChanges.isEmpty)
	}
}
