//
//  SubscriptionGateDisplayTests.swift
//  AI ArcheologyTests
//
//  The root gate's precedence rule: payments surface, then entitlement, then the free window
//  (AIA-0556).
//

import XCTest
@testable import ML_Browser

final class SubscriptionGateDisplayTests: XCTestCase {

	private func resolve(
		paymentsSurface: Bool = true,
		subscribed: Bool = false,
		freeAccess: FreeAccessAvailability,
		hasEverShownContent: Bool = false
	) -> RootGateDisplay {
		RootGateDisplay.resolve(
			isPaymentsSurfaceEnabled: paymentsSurface,
			isSubscribed: subscribed,
			freeAccess: freeAccess,
			hasEverShownContent: hasEverShownContent
		)
	}

	// MARK: - Entitlement precedence

	/// **The one that costs a paying customer.** A user who taps Subscribe on day 13 starts Apple's
	/// trial and is `isSubscribed`; on day 14 their app-managed window runs out. Walling them there
	/// bills someone for a paywall. Entitlement outranks an expired window, always.
	func testTrialStartedOnDayThirteen_isNotWalledWhenTheFreeWindowExpiresOnDayFourteen() {
		XCTAssertEqual(resolve(subscribed: true, freeAccess: .closed), .content)

		// And not by being rescued mid-session either: it must hold on a cold launch, where nothing
		// has been shown yet and the wall would be the arrival screen.
		XCTAssertEqual(
			resolve(subscribed: true, freeAccess: .closed, hasEverShownContent: false),
			.content
		)
	}

	func testSubscribed_withNoWindowEverGranted_showsContent() {
		XCTAssertEqual(resolve(subscribed: true, freeAccess: .closed), .content)
	}

	// MARK: - The three ways in

	func testPaymentsSurfaceDisabled_showsContentRegardlessOfEverythingElse() {
		for freeAccess: FreeAccessAvailability in [.undetermined, .open, .closed] {
			for shown in [true, false] {
				XCTAssertEqual(
					resolve(
						paymentsSurface: false,
						subscribed: false,
						freeAccess: freeAccess,
						hasEverShownContent: shown
					),
					.content,
					"A flag-off build is fully open (freeAccess: \(freeAccess), shown: \(shown))."
				)
			}
		}
	}

	func testNotEntitled_withAnOpenWindow_showsContent() {
		XCTAssertEqual(resolve(freeAccess: .open), .content)
	}

	func testNotEntitled_withAnExpiredWindow_showsTheWall() {
		XCTAssertEqual(resolve(freeAccess: .closed), .wall)
	}

	/// `develop`'s behaviour, preserved: with the free-access flag off nothing is ever granted, so
	/// availability settles `.closed` and a non-subscriber meets the paywall exactly as before.
	func testNotEntitled_withNoWindowEverGranted_showsTheWall() {
		XCTAssertEqual(resolve(freeAccess: .closed), .wall)
	}

	// MARK: - Reconciliation must not read as a refusal

	/// `FreeAccessWindow` reports "not granted" while its two stores are being read. Treating that
	/// as a wall would flash the paywall at a valid mid-window user on every single launch.
	func testFreeAccessUndetermined_holdsRatherThanWalling() {
		XCTAssertEqual(resolve(freeAccess: .undetermined), .hold)
		XCTAssertNotEqual(resolve(freeAccess: .undetermined), .wall)
	}

	/// Once the user is in the app, an unsettled anchor is not a reason to throw them out of it —
	/// nor to cover their page with a wall that may turn out to be wrong.
	func testFreeAccessUndetermined_afterContentWasShown_keepsContentUncovered() {
		XCTAssertEqual(resolve(freeAccess: .undetermined, hasEverShownContent: true), .content)
	}

	// MARK: - Expiry must not tear down the root

	/// The window running out mid-session covers the app; it does not replace it. Swapping the root
	/// destroys the `WKWebView` and with it the page, the scroll position and the history.
	func testWindowExpiringAfterContentWasShown_laysTheWallOverRetainedContent() {
		XCTAssertEqual(resolve(freeAccess: .closed, hasEverShownContent: true), .wallOverContent)
	}

	/// The same refusal is a full screen on the way *in*, where there is no session to protect and
	/// rendering the app behind the wall would load pages nobody is entitled to see.
	func testWindowClosedBeforeContentWasShown_makesTheWallTheArrivalScreen() {
		XCTAssertEqual(resolve(freeAccess: .closed, hasEverShownContent: false), .wall)
	}
}
