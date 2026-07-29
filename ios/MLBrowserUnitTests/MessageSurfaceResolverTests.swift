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

	/// Resolves with a "ready, subscribed, no analytics prompt" baseline, so each test varies only
	/// the axis it is about.
	private func resolve(
		isReady: Bool = true,
		paymentsSurfaceEnabled: Bool = false,
		isSubscribed: Bool = true,
		analyticsChoicePending: Bool = false
	) -> MessageSurface? {
		MessageSurfaceResolver.surface(
			isReady: isReady,
			paymentsSurfaceEnabled: paymentsSurfaceEnabled,
			isSubscribed: isSubscribed,
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
			resolve(paymentsSurfaceEnabled: true, isSubscribed: false, analyticsChoicePending: true)
		]
		XCTAssertFalse(everyCombination.contains(.login))
	}
}
