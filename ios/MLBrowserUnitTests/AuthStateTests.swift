//
//  AuthStateTests.swift
//  MLBrowserUnitTests
//
//  AIA-0340: authentication launch-gate state machine coverage.
//

import XCTest
@testable import ML_Browser

@MainActor
final class AuthStateTests: XCTestCase {

	// MARK: - Initial state

	func testInitialGate_BeforeStart_IsCheckingSession() {
		let sut = AuthState(provider: MockAuthProvider(outcome: .ready))
		XCTAssertEqual(sut.gate, .checkingSession)
	}

	// MARK: - refresh() resolves each terminal state

	func testStart_SignedOutProvider_ResolvesToSignedOut() async {
		let sut = AuthState(provider: MockAuthProvider(outcome: .signedOut))
		await sut.start()
		XCTAssertEqual(sut.gate, .signedOut)
	}

	func testStart_SignedInWithAccess_ResolvesToReady() async {
		let sut = AuthState(provider: MockAuthProvider(outcome: .ready))
		await sut.start()
		XCTAssertEqual(sut.gate, .ready)
	}

	func testStart_ValidationOffline_ResolvesToOffline() async {
		let sut = AuthState(provider: MockAuthProvider(outcome: .offline))
		await sut.start()
		XCTAssertEqual(sut.gate, .offline)
	}

	// MARK: - Transitions

	func testSignOut_FromReady_ResolvesToSignedOut() async {
		let sut = AuthState(provider: MockAuthProvider(outcome: .ready))
		await sut.start()
		XCTAssertEqual(sut.gate, .ready)

		await sut.signOut()
		XCTAssertEqual(sut.gate, .signedOut)
	}

	func testDeleteAccount_FromReady_ResolvesToSignedOut() async throws {
		let sut = AuthState(provider: MockAuthProvider(outcome: .ready))
		await sut.start()
		XCTAssertEqual(sut.gate, .ready)

		try await sut.deleteAccount()
		XCTAssertEqual(sut.gate, .signedOut)
	}

	func testRefresh_AfterSignIn_FlipsSignedOutToReady() async {
		// A signed-out user who signs in becomes ready on the next refresh
		// (mirrors the sign-in-sheet dismissal / Clerk session-change re-validation).
		let provider = MockAuthProvider(outcome: .signedOut)
		let sut = AuthState(provider: provider)
		await sut.start()
		XCTAssertEqual(sut.gate, .signedOut)

		provider.setOutcomeForTesting(.ready)
		await sut.refresh()
		XCTAssertEqual(sut.gate, .ready)
	}
}
