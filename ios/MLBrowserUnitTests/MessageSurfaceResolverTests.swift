//
//  MessageSurfaceResolverTests.swift
//  AI ArcheologyTests
//
//  Truth table for the app-message surface resolver, mirroring the gate nesting in
//  MLBrowser.swift (AIA-0115, re-keyed for the paywall-first cut-over in AIA-0536).
//

import XCTest
@testable import ML_Browser

final class MessageSurfaceResolverTests: XCTestCase {

	/// Resolves with a "ready, subscribed, no free window, no analytics prompt" baseline, so each
	/// test varies only the axis it is about.
	private func resolve(
		isReady: Bool = true,
		paymentsSurfaceEnabled: Bool = false,
		isSubscribed: Bool = true,
		freeAccess: FreeAccessAvailability = .closed,
		analyticsChoicePending: Bool = false
	) -> MessageSurface? {
		MessageSurfaceResolver.surface(
			isReady: isReady,
			paymentsSurfaceEnabled: paymentsSurfaceEnabled,
			isSubscribed: isSubscribed,
			freeAccess: freeAccess,
			analyticsChoicePending: analyticsChoicePending
		)
	}

	func testNotReady_yieldsNoSurface() {
		XCTAssertNil(resolve(isReady: false))
	}

	func testNotReady_overridesEverythingInside() {
		// `isReady` is the outermost gate; nothing below it applies before it flips.
		XCTAssertNil(resolve(isReady: false, paymentsSurfaceEnabled: true, isSubscribed: false))
	}

	func testPaymentsOnNotSubscribed_yieldsPaywall() {
		XCTAssertEqual(resolve(paymentsSurfaceEnabled: true, isSubscribed: false), .paywall)
	}

	func testPaymentsOnSubscribed_yieldsInApp() {
		XCTAssertEqual(resolve(paymentsSurfaceEnabled: true, isSubscribed: true), .inApp)
	}

	func testPaymentsOffNotSubscribed_yieldsInApp() {
		// Payments flag off ⇒ the subscription gate is bypassed regardless of entitlement.
		XCTAssertEqual(resolve(paymentsSurfaceEnabled: false, isSubscribed: false), .inApp)
	}

	// MARK: - The app-managed free-access window (AIA-0556)

	/// The mis-targeting this parameter exists to stop. A free-window user matches
	/// `paymentsSurfaceEnabled && !isSubscribed` exactly, but is sitting in `ContentView` — so
	/// answering `.paywall` would fire "Subscribe now, 40% off" as a banner over the working app and
	/// withhold every `.inApp` message for the length of the window.
	func testFreeWindowOpen_yieldsInApp_notPaywall() {
		XCTAssertEqual(
			resolve(paymentsSurfaceEnabled: true, isSubscribed: false, freeAccess: .open),
			.inApp
		)
	}

	func testFreeWindowClosed_yieldsPaywall() {
		// Never granted or expired: the paywall is what the user is looking at, whether it arrived as
		// the root or as the overlay over content they already had.
		XCTAssertEqual(
			resolve(paymentsSurfaceEnabled: true, isSubscribed: false, freeAccess: .closed),
			.paywall
		)
	}

	func testFreeWindowUndetermined_yieldsNoSurface() {
		// The gate is holding on a spinner while the anchor stores are read. Nothing to sit on.
		XCTAssertNil(resolve(paymentsSurfaceEnabled: true, isSubscribed: false, freeAccess: .undetermined))
	}

	/// The window is consulted **only** when the two gates above it have not already opened — the
	/// same order `RootGateDisplay.resolve` uses. An expired app window must never subtract from an
	/// entitlement Apple is charging for, nor wall a build with payments switched off.
	func testEntitlementAndPaymentsOffOutrankTheWindow() {
		for availability: FreeAccessAvailability in [.open, .closed, .undetermined] {
			XCTAssertEqual(
				resolve(paymentsSurfaceEnabled: true, isSubscribed: true, freeAccess: availability),
				.inApp,
				"a subscriber's surface must not depend on the app window (\(availability))"
			)
			XCTAssertEqual(
				resolve(paymentsSurfaceEnabled: false, isSubscribed: false, freeAccess: availability),
				.inApp,
				"payments off bypasses the gate entirely (\(availability))"
			)
		}
	}

	/// The window opens the gate; it does not open the one nested inside it.
	func testFreeWindowOpen_stillYieldsToAPendingAnalyticsChoice() {
		XCTAssertNil(
			resolve(
				paymentsSurfaceEnabled: true,
				isSubscribed: false,
				freeAccess: .open,
				analyticsChoicePending: true
			)
		)
	}

	func testAnalyticsChoicePending_yieldsNoSurface() {
		XCTAssertNil(resolve(analyticsChoicePending: true))
	}

	func testPaywallOutranksAnalyticsChoice() {
		// Subscription gate is outside the analytics gate: paywall wins even with a choice pending.
		XCTAssertEqual(
			resolve(paymentsSurfaceEnabled: true, isSubscribed: false, analyticsChoicePending: true),
			.paywall
		)
	}

	func testDefault_yieldsInApp() {
		XCTAssertEqual(resolve(), .inApp)
	}

	/// **Auth is deliberately not an input any more (AIA-0536).**
	///
	/// Before the cut-over, `.signedOut` was a whole root screen and therefore a mounted surface a
	/// banner could sit on, so the resolver returned `.login`. Sign-in is now a transient sheet
	/// reachable from four places: a signed-out user is looking at the paywall or at the app, and
	/// that is what they are targetable as.
	///
	/// This pins the consequence rather than leaving it implicit — `.login`-targeted messages are
	/// undeliverable and must be retargeted. The enum case survives only so existing payloads decode.
	func testLoginIsNeverResolved_becauseItIsNoLongerAMountedSurface() {
		let everyCombination: [MessageSurface?] = [
			resolve(isReady: false),
			resolve(paymentsSurfaceEnabled: true, isSubscribed: false),
			resolve(paymentsSurfaceEnabled: true, isSubscribed: true),
			resolve(paymentsSurfaceEnabled: false, isSubscribed: false),
			resolve(paymentsSurfaceEnabled: false, isSubscribed: true),
			resolve(analyticsChoicePending: true),
			resolve(paymentsSurfaceEnabled: true, isSubscribed: false, analyticsChoicePending: true),
			resolve(paymentsSurfaceEnabled: true, isSubscribed: false, freeAccess: .open),
			resolve(paymentsSurfaceEnabled: true, isSubscribed: false, freeAccess: .undetermined)
		]
		XCTAssertFalse(everyCombination.contains(.login))
	}
}
