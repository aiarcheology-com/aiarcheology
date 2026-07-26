//
//  MessageSurfaceResolverTests.swift
//  AI ArcheologyTests
//
//  Truth table for the app-message surface resolver, mirroring the gate nesting in
//  MLBrowser.swift (AIA-0115).
//

import XCTest
@testable import ML_Browser

final class MessageSurfaceResolverTests: XCTestCase {

	/// Resolves with a "ready, signed-in, subscribed, no analytics prompt" baseline, so each test
	/// varies only the axis it is about.
	private func resolve(
		isReady: Bool = true,
		gate: AuthGate = .ready,
		paymentsSurfaceEnabled: Bool = false,
		isSubscribed: Bool = true,
		analyticsChoicePending: Bool = false
	) -> MessageSurface? {
		MessageSurfaceResolver.surface(
			isReady: isReady,
			gate: gate,
			paymentsSurfaceEnabled: paymentsSurfaceEnabled,
			isSubscribed: isSubscribed,
			analyticsChoicePending: analyticsChoicePending
		)
	}

	func testNotReady_yieldsNoSurface() {
		XCTAssertNil(resolve(isReady: false, gate: .ready))
	}

	func testNotReady_overridesSignedOut() {
		// `isReady` is the outermost gate; nothing inside the auth switch applies before it flips.
		XCTAssertNil(resolve(isReady: false, gate: .signedOut))
	}

	func testCheckingSession_yieldsNoSurface() {
		XCTAssertNil(resolve(gate: .checkingSession))
	}

	func testOffline_yieldsNoSurface() {
		XCTAssertNil(resolve(gate: .offline))
	}

	func testSignedOut_yieldsLogin() {
		XCTAssertEqual(resolve(gate: .signedOut), .login)
	}

	func testSignedOut_ignoresInnerGates() {
		// `.login` is the outermost terminal gate: the subscription/analytics inputs are irrelevant.
		XCTAssertEqual(
			resolve(gate: .signedOut, paymentsSurfaceEnabled: true, isSubscribed: false, analyticsChoicePending: true),
			.login
		)
	}

	func testReady_paymentsOnNotSubscribed_yieldsPaywall() {
		XCTAssertEqual(resolve(gate: .ready, paymentsSurfaceEnabled: true, isSubscribed: false), .paywall)
	}

	func testReady_paymentsOnSubscribed_yieldsInApp() {
		XCTAssertEqual(resolve(gate: .ready, paymentsSurfaceEnabled: true, isSubscribed: true), .inApp)
	}

	func testReady_paymentsOffNotSubscribed_yieldsInApp() {
		// Payments flag off ⇒ the subscription gate is bypassed regardless of entitlement.
		XCTAssertEqual(resolve(gate: .ready, paymentsSurfaceEnabled: false, isSubscribed: false), .inApp)
	}

	func testReady_analyticsChoicePending_yieldsNoSurface() {
		XCTAssertNil(resolve(gate: .ready, analyticsChoicePending: true))
	}

	func testReady_paywallOutranksAnalyticsChoice() {
		// Subscription gate is outside the analytics gate: paywall wins even with a choice pending.
		XCTAssertEqual(
			resolve(gate: .ready, paymentsSurfaceEnabled: true, isSubscribed: false, analyticsChoicePending: true),
			.paywall
		)
	}

	func testReady_default_yieldsInApp() {
		XCTAssertEqual(resolve(), .inApp)
	}
}
