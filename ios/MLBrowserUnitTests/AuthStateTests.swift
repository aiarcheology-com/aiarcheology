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

	// MARK: - Published account identity (AIA-0437)

	/// Stable stand-ins for Clerk account ids (`user_…`).
	private static let accountA = "user_2aaaaaaaaaaaaaaaaaaaaaaaaa"
	private static let accountB = "user_2bbbbbbbbbbbbbbbbbbbbbbbbb"

	/// `signOut()` reaches `setSignedOut()` directly, bypassing `evaluateGate()` entirely — which is
	/// why maintaining the identity in the gate evaluation alone would silently regress this.
	func testSignOut_FromReady_ClearsAccountIdentifier() async {
		let sut = AuthState(provider: MockAuthProvider(outcome: .ready))
		await sut.start()
		XCTAssertEqual(sut.accountIdentifier, MockAuthProvider.defaultMockAccountID)

		await sut.signOut()

		XCTAssertNil(sut.accountIdentifier)
	}

	/// Account deletion takes the same bypassing path as sign-out.
	func testDeleteAccount_FromReady_ClearsAccountIdentifier() async throws {
		let sut = AuthState(provider: MockAuthProvider(outcome: .ready))
		await sut.start()
		XCTAssertEqual(sut.accountIdentifier, MockAuthProvider.defaultMockAccountID)

		try await sut.deleteAccount()

		XCTAssertNil(sut.accountIdentifier)
	}

	/// Losing connectivity is not a change of account: the `.offline` gate must leave the published
	/// identity exactly as it was, so analytics keeps attributing to the same person.
	func testRefresh_ValidationOffline_LeavesAccountIdentifierUnchanged() async {
		let provider = MockAuthProvider(outcome: .ready)
		let sut = AuthState(provider: provider)
		await sut.start()
		XCTAssertEqual(sut.accountIdentifier, MockAuthProvider.defaultMockAccountID)

		provider.setOutcomeForTesting(.offline)
		await sut.refresh()

		XCTAssertEqual(sut.gate, .offline)
		XCTAssertEqual(sut.accountIdentifier, MockAuthProvider.defaultMockAccountID)
	}

	/// The interleaving AIA-0437 guards against: `validateSession()` suspends, and a sign-out
	/// followed by a *different* sign-in can complete inside that window. The round-trip that
	/// returns successfully validated the OLD account, so publishing the new one on the strength of
	/// it would mark B ready — and hand B's identity to analytics — with B never validated.
	func testRefresh_AccountSwitchesDuringValidation_DoesNotPublishTheNewAccountOnTheOldValidation() async {
		let provider = SuspendableAuthProvider(accountIdentifier: Self.accountA)
		let sut = AuthState(provider: provider)

		let firstSuspended = expectation(description: "A's validation suspended")
		provider.suspendNextValidation = firstSuspended
		let refresh = Task { await sut.refresh() }
		await fulfillment(of: [firstSuspended], timeout: 2)

		// B takes over mid-flight, and only then does A's validation succeed.
		provider.accountIdentifier = Self.accountB
		let secondSuspended = expectation(description: "B's own validation suspended")
		provider.suspendNextValidation = secondSuspended
		provider.resumeValidation()
		await fulfillment(of: [secondSuspended], timeout: 2)

		// A's validation returned successfully, yet nothing was published: B is being validated in
		// its own pass rather than riding A's result.
		XCTAssertNil(sut.accountIdentifier)
		XCTAssertEqual(sut.gate, .checkingSession)

		provider.resumeValidation()
		await refresh.value

		XCTAssertEqual(sut.accountIdentifier, Self.accountB)
		XCTAssertEqual(sut.gate, .ready)
		XCTAssertEqual(provider.validationCount, 2)
	}

	/// The other half of the interleaving above, and the one that actually leaks.
	///
	/// The test before this starts from no published account, so it would pass even if a
	/// previously validated account stayed published throughout B's validation. Here A is
	/// established first: once Clerk has moved to B, A must stop being published *before* the
	/// round-trip, because anything tracked during that window would otherwise be attributed to a
	/// user who is no longer signed in (AIA-0437).
	func testRefresh_AccountChangesWhileValidating_StopsPublishingTheOutgoingAccountImmediately() async {
		let provider = SuspendableAuthProvider(accountIdentifier: Self.accountA)
		let sut = AuthState(provider: provider)

		// A is signed in and validated.
		await sut.start()
		XCTAssertEqual(sut.accountIdentifier, Self.accountA)
		XCTAssertEqual(sut.gate, .ready)

		// Clerk switches to B out-of-band; the watcher kicks off a refresh that suspends mid-flight.
		let suspended = expectation(description: "validation suspended for B")
		provider.suspendNextValidation = suspended
		provider.accountIdentifier = Self.accountB
		let refresh = Task { await sut.refresh() }
		await fulfillment(of: [suspended], timeout: 2)

		// The window that matters: B's validation has not returned, so B must not be published —
		// but A must already be gone.
		XCTAssertNil(sut.accountIdentifier, "the outgoing account is still published during validation")

		provider.resumeValidation()
		await refresh.value
		XCTAssertEqual(sut.accountIdentifier, Self.accountB)
	}
}

/// An ``AuthProviding`` whose `validateSession()` can be suspended and resumed by the test, so the
/// signed-in account can be switched *inside* the validation window. `MockAuthProvider` cannot
/// express this: its `validateSession()` never suspends.
@MainActor
private final class SuspendableAuthProvider: AuthProviding {
	var isSignedIn = true
	var accountIdentifier: String?

	/// Arm before a call and the next `validateSession()` suspends and fulfils this instead of
	/// returning. Consumed on use, so a validation with nothing armed completes immediately.
	var suspendNextValidation: XCTestExpectation?

	/// How many round-trips were actually made — the evidence that B was validated for itself.
	private(set) var validationCount = 0

	private var suspended: CheckedContinuation<Void, Never>?

	init(accountIdentifier: String?) {
		self.accountIdentifier = accountIdentifier
	}

	func prepare() async {}

	func validateSession() async throws {
		validationCount += 1
		guard let armed = suspendNextValidation else { return }
		suspendNextValidation = nil
		await withCheckedContinuation { continuation in
			suspended = continuation
			armed.fulfill()
		}
	}

	/// Let the currently suspended `validateSession()` return successfully.
	func resumeValidation() {
		let continuation = suspended
		suspended = nil
		continuation?.resume()
	}

	func signOut() async {
		isSignedIn = false
		accountIdentifier = nil
	}

	func deleteAccount() async throws {
		isSignedIn = false
		accountIdentifier = nil
	}
}
