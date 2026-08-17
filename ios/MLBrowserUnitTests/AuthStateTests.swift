//
//  AuthStateTests.swift
//  MLBrowserUnitTests
//
//  AIA-0340: authentication launch-gate state machine coverage.
//

import Combine
import XCTest
@testable import ML_Browser

@MainActor
final class AuthStateTests: XCTestCase {

	// MARK: - Initial state

	func testInitialGate_BeforeStart_IsCheckingSession() {
		let sut = AuthState(provider: MockAuthProvider(outcome: .ready))
		XCTAssertEqual(sut.gate, .checkingSession)
	}

	// MARK: - EffectiveAuthContext (AIA-0536)

	func testEffectiveContext_BeforeStart_IsIndeterminate() {
		let sut = AuthState(provider: MockAuthProvider(outcome: .ready))
		XCTAssertEqual(sut.effectiveContext, .indeterminate)
	}

	func testEffectiveContext_SignedOutProvider_IsAnonymous() async {
		let sut = AuthState(provider: MockAuthProvider(outcome: .signedOut))
		await sut.start()
		XCTAssertEqual(sut.effectiveContext, .anonymous)
	}

	func testEffectiveContext_SignedInAndValidated_CarriesTheAccount() async {
		let sut = AuthState(provider: MockAuthProvider(outcome: .ready, accountID: Self.accountA))
		await sut.start()
		XCTAssertEqual(sut.effectiveContext, .validated(Self.accountA))
	}

	/// The **common** offline shape, not the exotic one: at launch nothing has been published yet, so
	/// the identifier the offline catch preserves is `nil`. UI that assumes a payload here would be
	/// wrong for most offline users.
	func testEffectiveContext_ColdOfflineLaunch_IsSuspendedWithNoAccount() async {
		let sut = AuthState(provider: MockAuthProvider(outcome: .offline, accountID: Self.accountA))
		await sut.start()
		XCTAssertEqual(sut.effectiveContext, .suspended(nil))
	}

	/// Losing connectivity *after* a successful validation is the only case that retains the account.
	func testEffectiveContext_OfflineAfterReady_RetainsTheValidatedAccount() async {
		let provider = MockAuthProvider(outcome: .ready, accountID: Self.accountA)
		let sut = AuthState(provider: provider)
		await sut.start()
		XCTAssertEqual(sut.effectiveContext, .validated(Self.accountA))

		provider.setOutcomeForTesting(.offline)
		await sut.refresh()

		XCTAssertEqual(sut.effectiveContext, .suspended(Self.accountA))
	}

	func testEffectiveContext_SignOut_IsAnonymous() async {
		let sut = AuthState(provider: MockAuthProvider(outcome: .ready, accountID: Self.accountA))
		await sut.start()
		await sut.signOut()
		XCTAssertEqual(sut.effectiveContext, .anonymous)
	}

	/// The regression lock for the `(.ready, nil)` window. ``AuthState`` clears the outgoing account
	/// before it suspends, so anything deriving the context from the identifier alone would read
	/// `.anonymous` mid-switch — handing the anonymous consent scope a slice of time that belongs to
	/// neither account, long enough to select a bucket and ask a question of the wrong person.
	func testEffectiveContext_InPlaceSwitchAToB_PassesThroughIndeterminateAndNeverAnonymous() async {
		let provider = MockAuthProvider(outcome: .ready, accountID: Self.accountA)
		let sut = AuthState(provider: provider)
		await sut.start()

		let log = ContextLog()
		let observation = sut.$effectiveContext.sink { log.values.append($0) }
		defer { observation.cancel() }

		provider.setAccountIDForTesting(Self.accountB)
		await sut.refresh()

		XCTAssertFalse(log.values.contains(.anonymous), "the switch window must never look like a sign-out")
		XCTAssertTrue(log.values.contains(.indeterminate), "the outgoing account must stop being published")
		XCTAssertEqual(log.values.last, .validated(Self.accountB))
	}

	/// Purchase tagging and analytics attribution share this, and both need a session we could not
	/// verify to read as *no account* — a stale Clerk session must never tag a purchase (AIA-0536).
	func testValidatedAccount_IsNilForEverythingButAFreshValidation() {
		XCTAssertEqual(EffectiveAuthContext.validated(Self.accountA).validatedAccount, Self.accountA)
		XCTAssertNil(EffectiveAuthContext.anonymous.validatedAccount)
		XCTAssertNil(EffectiveAuthContext.indeterminate.validatedAccount)
		// The one that is easy to get wrong: `.suspended` *carries* an identifier, and returning it
		// would tag a purchase with an account this device could not prove was still signed in.
		XCTAssertNil(EffectiveAuthContext.suspended(Self.accountA).validatedAccount)
		XCTAssertNil(EffectiveAuthContext.suspended(nil).validatedAccount)
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

	// MARK: - Account display name (AIA-0651)

	/// The prefill source for a finding's author field: the signed-in account's name while there is
	/// an account, nothing once there isn't — a signed-out user must never be credited.
	func testAccountDisplayName_ReadyThenSignedOut_ReturnsTheNameThenNil() async {
		let provider = MockAuthProvider(outcome: .ready)
		provider.mockDisplayName = "Jane Archeologist"
		let sut = AuthState(provider: provider)
		await sut.start()
		XCTAssertEqual(sut.gate, .ready)

		XCTAssertEqual(sut.accountDisplayName, "Jane Archeologist")

		await sut.signOut()
		XCTAssertEqual(sut.gate, .signedOut)
		XCTAssertNil(sut.accountDisplayName)
	}

	/// The field case this is actually for: an archeologist standing in a trench with no signal.
	/// They are still signed in, so the capture editor must still prefill their name — which is why
	/// the predicate is `.signedOut` and not `.ready`. Gating on `.ready` would blank the credit for
	/// exactly the users most likely to be recording a finding.
	func testAccountDisplayName_OfflineGate_StillReturnsTheName() async {
		let provider = MockAuthProvider(outcome: .ready)
		provider.mockDisplayName = "Jane Archeologist"
		let sut = AuthState(provider: provider)
		await sut.start()

		provider.setOutcomeForTesting(.offline)
		await sut.refresh()

		XCTAssertEqual(sut.gate, .offline)
		XCTAssertEqual(sut.accountDisplayName, "Jane Archeologist")
	}

	// MARK: - No address may become a byline (AIA-0651)

	/// Declining to read `primaryEmailAddress` is not what keeps an address off a share card:
	/// `firstName`, `lastName` and `username` are free text, and an OAuth provider may fill them
	/// from the account's email. Anything holding an `@` is refused, so the field is left empty for
	/// the user rather than publishing their address on an image.
	func testNameUnlessItIsAnAddress_EmailShapedCandidates_AreRefused() {
		XCTAssertNil(ClerkAuthProvider.nameUnlessItIsAnAddress("alice@example.com"))
		XCTAssertNil(ClerkAuthProvider.nameUnlessItIsAnAddress("Alice Smith <alice@example.com>"))
		XCTAssertNil(ClerkAuthProvider.nameUnlessItIsAnAddress("@alice"))
	}

	/// The other half: an ordinary name must survive, including non-ASCII and internal punctuation.
	/// A rule that refused these would silently leave every author field empty.
	func testNameUnlessItIsAnAddress_OrdinaryNames_SurviveTrimmed() {
		XCTAssertEqual(ClerkAuthProvider.nameUnlessItIsAnAddress("  Jane Archeologist  "), "Jane Archeologist")
		XCTAssertEqual(ClerkAuthProvider.nameUnlessItIsAnAddress("Karol Nálezca"), "Karol Nálezca")
		XCTAssertEqual(ClerkAuthProvider.nameUnlessItIsAnAddress("O'Brien-Smith"), "O'Brien-Smith")
	}

	/// Blank and whitespace-only are absent, not an empty byline.
	func testNameUnlessItIsAnAddress_BlankCandidates_AreNil() {
		XCTAssertNil(ClerkAuthProvider.nameUnlessItIsAnAddress(nil))
		XCTAssertNil(ClerkAuthProvider.nameUnlessItIsAnAddress(""))
		XCTAssertNil(ClerkAuthProvider.nameUnlessItIsAnAddress("   \n "))
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
	var displayName: String?

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

/// Collects published contexts from a Combine sink. A reference box rather than a captured local
/// `var`: `sink` is not actor-isolated, so Swift 6 concurrency checking rejects mutating a local
/// from inside it.
private final class ContextLog: @unchecked Sendable {
	var values: [EffectiveAuthContext] = []
}
