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

	// MARK: - Reconnecting (AIA-0757)

	/// A delay long enough that the post-reconnect retry can never fire inside a test. The retry is
	/// real behaviour, but every assertion below is about the *first* attempt.
	private static let neverFires: Duration = .seconds(600)

	/// The reported bug, end to end. A cold launch with no signal leaves `.offline` **and no account
	/// identifier** — which is what empties the back-up section in Settings, since that section is
	/// gated on exactly this value. Before AIA-0757 nothing re-asked while the app stayed foregrounded.
	func testReconnect_AfterColdOfflineLaunch_RecoversTheAccountAndTheGate() async {
		let provider = CountingAuthProvider(outcome: .offline, accountID: Self.accountA)
		let connectivity = FakeConnectivityMonitor()
		let sut = AuthState(provider: provider, connectivity: connectivity, reconnectRetryDelay: Self.neverFires)

		await sut.start()
		XCTAssertEqual(sut.gate, .offline)
		XCTAssertNil(sut.accountIdentifier, "the state that hides the back-up toggle")

		provider.outcome = .ready
		await connectivity.simulateReconnect()

		XCTAssertEqual(sut.gate, .ready)
		XCTAssertEqual(sut.accountIdentifier, Self.accountA)
	}

	/// The guard that stops a flapping connection becoming a request storm: once a pass has landed on
	/// a terminal answer, later reconnections cost nothing.
	func testReconnect_WhenAlreadyReady_MakesNoFurtherRoundTrip() async {
		let provider = CountingAuthProvider(outcome: .ready, accountID: Self.accountA)
		let connectivity = FakeConnectivityMonitor()
		let sut = AuthState(provider: provider, connectivity: connectivity, reconnectRetryDelay: Self.neverFires)

		await sut.start()
		XCTAssertEqual(sut.gate, .ready)
		let afterStart = provider.validationCount

		await connectivity.simulateReconnect()
		await connectivity.simulateReconnect()

		XCTAssertEqual(provider.validationCount, afterStart, "a reconnect re-validated an already-ready gate")
	}

	/// `.signedOut` is a decision, not an outage: `ClerkAuthProvider` routes a *rejected* session
	/// there. Re-validating it because the network came back would second-guess a revocation.
	func testReconnect_WhenSignedOut_DoesNothing() async {
		let provider = CountingAuthProvider(outcome: .signedOut, accountID: nil)
		let connectivity = FakeConnectivityMonitor()
		let sut = AuthState(provider: provider, connectivity: connectivity, reconnectRetryDelay: Self.neverFires)

		await sut.start()
		XCTAssertEqual(sut.gate, .signedOut)
		let afterStart = provider.validationCount

		await connectivity.simulateReconnect()

		XCTAssertEqual(sut.gate, .signedOut)
		XCTAssertEqual(provider.validationCount, afterStart)
	}

	/// The blocker both pre-PR reviews found, pinned.
	///
	/// A path can become satisfied while the cold-launch pass is still in flight. `refreshIfOffline`
	/// correctly does nothing then — the gate is `.checkingSession`, not `.offline` — and because the
	/// path is now satisfied, no later unsatisfied-to-satisfied edge is coming. If the retry were
	/// armed only by the reconnect handler, that pass landing `.offline` would strand the gate
	/// exactly as AIA-0757 describes. The retry is armed by the *outcome* instead, so it is armed
	/// here, and firing it recovers.
	func testColdOfflineLaunch_ArmsARetryEvenWhenTheReconnectArrivedTooEarly() async {
		let provider = CountingAuthProvider(outcome: .offline, accountID: Self.accountA)
		let connectivity = FakeConnectivityMonitor()
		// Short enough to actually fire inside the test — this one is about the retry, not about
		// keeping it out of the way.
		let sut = AuthState(provider: provider, connectivity: connectivity, reconnectRetryDelay: .milliseconds(20))

		// The reconnect lands while the gate is still `.checkingSession`, and is correctly ignored.
		await connectivity.simulateReconnect()
		await sut.start()
		XCTAssertEqual(sut.gate, .offline)
		XCTAssertNil(sut.accountIdentifier)

		// The network is genuinely back by the time the armed retry runs.
		provider.outcome = .ready
		try? await Task.sleep(for: .milliseconds(300))

		XCTAssertEqual(sut.gate, .ready, "the retry armed by the offline outcome never recovered the gate")
		XCTAssertEqual(sut.accountIdentifier, Self.accountA)
	}

	/// The retry is spent once per offline spell, so a device with no signal is not re-validated
	/// every few seconds for as long as it stays that way.
	func testOfflineRetry_IsSpentOncePerOfflineSpell() async {
		let provider = CountingAuthProvider(outcome: .offline, accountID: Self.accountA)
		let sut = AuthState(provider: provider, reconnectRetryDelay: .milliseconds(20))

		await sut.start()
		try? await Task.sleep(for: .milliseconds(300))

		// One from `start()`, one from its single armed retry. Anything more is a poll.
		XCTAssertEqual(provider.validationCount, 2)
	}

	/// A real path change earns a fresh attempt even after the spell's automatic one was spent.
	func testReconnect_AfterTheAutomaticRetryWasSpent_StillRefreshes() async {
		let provider = CountingAuthProvider(outcome: .offline, accountID: Self.accountA)
		let connectivity = FakeConnectivityMonitor()
		let sut = AuthState(provider: provider, connectivity: connectivity, reconnectRetryDelay: .milliseconds(20))

		await sut.start()
		try? await Task.sleep(for: .milliseconds(300))
		let afterRetry = provider.validationCount

		provider.outcome = .ready
		await connectivity.simulateReconnect()

		XCTAssertGreaterThan(provider.validationCount, afterRetry)
		XCTAssertEqual(sut.gate, .ready)
	}

	/// Before `start()` resolves anything the gate is `.checkingSession`, and a reconnect must not
	/// race a pass that is already on its way.
	func testRefreshIfOffline_WhileCheckingSession_DoesNothing() async {
		let provider = CountingAuthProvider(outcome: .ready, accountID: Self.accountA)
		let sut = AuthState(provider: provider)
		XCTAssertEqual(sut.gate, .checkingSession)

		await sut.refreshIfOffline()

		XCTAssertEqual(sut.gate, .checkingSession)
		XCTAssertEqual(provider.validationCount, 0)
	}

	/// An interface coming up is not the server answering. One failed reconnect must cost exactly one
	/// round-trip and leave the gate where it was — not spin.
	func testReconnect_WhileStillUnreachable_CostsOneRoundTripAndStaysOffline() async {
		let provider = CountingAuthProvider(outcome: .offline, accountID: Self.accountA)
		let connectivity = FakeConnectivityMonitor()
		let sut = AuthState(provider: provider, connectivity: connectivity, reconnectRetryDelay: Self.neverFires)

		await sut.start()
		let afterStart = provider.validationCount

		await connectivity.simulateReconnect()

		XCTAssertEqual(sut.gate, .offline)
		XCTAssertEqual(provider.validationCount, afterStart + 1)
	}

	/// `.task { start() }` mounts once per **scene**, not once per app, and iPad can run several over
	/// one `AppState`. `NWPathMonitor.start(queue:)` traps on a monitor that is already running, so
	/// the claim has to be made before `start()`'s first suspension.
	func testStart_CalledTwice_StartsTheMonitorOnce() async {
		let connectivity = FakeConnectivityMonitor()
		let sut = AuthState(
			provider: CountingAuthProvider(outcome: .ready, accountID: Self.accountA),
			connectivity: connectivity,
			reconnectRetryDelay: Self.neverFires
		)

		async let first: Void = sut.start()
		async let second: Void = sut.start()
		_ = await (first, second)

		XCTAssertEqual(connectivity.startCount, 1)
	}

	// MARK: - Edge detection (AIA-0757)

	/// The first report describes the state the app launched in. Calling it a reconnection would fire
	/// a redundant refresh on every cold launch that already had signal.
	func testEdgeDetector_FirstSatisfiedReport_IsNotAReconnection() {
		var detector = ConnectivityEdgeDetector()
		XCTAssertFalse(detector.isReconnection(isSatisfied: true))
	}

	func testEdgeDetector_RepeatedSatisfiedReports_AreNotReconnections() {
		var detector = ConnectivityEdgeDetector()
		_ = detector.isReconnection(isSatisfied: true)
		XCTAssertFalse(detector.isReconnection(isSatisfied: true))
		XCTAssertFalse(detector.isReconnection(isSatisfied: true))
	}

	func testEdgeDetector_UnsatisfiedThenSatisfied_IsAReconnection() {
		var detector = ConnectivityEdgeDetector()
		_ = detector.isReconnection(isSatisfied: true)
		XCTAssertFalse(detector.isReconnection(isSatisfied: false))
		XCTAssertTrue(detector.isReconnection(isSatisfied: true))
	}

	/// A cold launch in airplane mode: the first report is unsatisfied, and the first satisfied one
	/// after it is the reconnection this whole ticket is about.
	func testEdgeDetector_ColdOfflineLaunchThenSignal_IsAReconnection() {
		var detector = ConnectivityEdgeDetector()
		XCTAssertFalse(detector.isReconnection(isSatisfied: false))
		XCTAssertTrue(detector.isReconnection(isSatisfied: true))
	}

	// MARK: - Programmatic sign-in (AIA-0974)

	func testSignIn_ThenRefresh_LandsReadyWithTheAccount() async throws {
		let provider = CountingAuthProvider(outcome: .signedOut, accountID: Self.accountA)
		let sut = AuthState(provider: provider)
		await sut.start()
		XCTAssertEqual(sut.gate, .signedOut)

		try await sut.signIn(emailAddress: "a+clerk_test@example.com", code: "424242")

		XCTAssertEqual(provider.signInCount, 1)
		XCTAssertEqual(sut.gate, .ready)
		XCTAssertEqual(sut.accountIdentifier, Self.accountA)
		XCTAssertEqual(sut.effectiveContext, .validated(Self.accountA))
		XCTAssertTrue(sut.isProviderSignedIn)
	}

	func testSignIn_ProviderFailure_RethrowsAndStaysSignedOut() async {
		let provider = CountingAuthProvider(outcome: .signedOut, accountID: Self.accountA)
		provider.signInError = ProgrammaticSignInError.incomplete
		let sut = AuthState(provider: provider)
		await sut.start()

		do {
			try await sut.signIn(emailAddress: "a+clerk_test@example.com", code: "000000")
			XCTFail("a failed sign-in must throw")
		} catch {
			XCTAssertEqual(error as? ProgrammaticSignInError, .incomplete)
		}
		XCTAssertEqual(sut.gate, .signedOut)
		XCTAssertNil(sut.accountIdentifier)
		XCTAssertFalse(sut.isProviderSignedIn)
	}

	func testSignIn_TheMock_RefusesRatherThanPretending() async {
		let sut = AuthState(provider: MockAuthProvider(outcome: .signedOut))
		await sut.start()

		do {
			try await sut.signIn(emailAddress: "a+clerk_test@example.com", code: "424242")
			XCTFail("the mock must not sign in")
		} catch {
			XCTAssertEqual(error as? ProgrammaticSignInError, .unsupported)
		}
		XCTAssertEqual(sut.gate, .signedOut)
	}

	/// A plain address is refused before Clerk is touched. Clerk is never configured in a unit-test
	/// host, and reaching `Clerk.shared` there traps — so this test finishing at all is the proof that
	/// the check runs before any network call, not just before a successful one.
	func testClerkSignIn_PlainAddress_IsRefusedBeforeAnyClerkCall() async {
		let provider = ClerkAuthProvider()
		for address in ["jane@example.com", "jane+clerk_test_x@example.com", "jane+clerk_test@gmail.com"] {
			do {
				try await provider.signIn(emailAddress: address, code: "424242")
				XCTFail("\(address) must be refused")
			} catch {
				XCTAssertEqual(error as? ProgrammaticSignInError, .notATestAddress, address)
			}
		}
	}

	func testClerkTestAddress_AcceptsOnlyTheDocumentedSubaddress() {
		for valid in ["jane+clerk_test@example.com", "aia-headless+clerk_test@example.com", "a.b+clerk_test@example.com"] {
			XCTAssertTrue(ClerkTestAddress.isValid(valid), valid)
		}
		for invalid in [
			"jane@example.com",
			"jane+clerk_test_extra@example.com",
			"jane+clerk_testx@example.com",
			"+clerk_test@example.com",
			"jane+clerk_test@example",
			"jane+clerk_test@example.",
			"jane+clerk_test@.com",
			// Real domains: with test mode off, a real inbox would receive the code.
			"jane+clerk_test@gmail.com",
			"jane+clerk_test@sub.example.com",
			"jane+clerk_test@example.com.evil.com",
			"jane+clerk_test@EXAMPLE.COM",
			"jane+clerk_test@@example.com",
			"jane+clerk_test@example.com@evil.com",
			"jane +clerk_test@example.com",
			"jane+CLERK_TEST@example.com",
			""
		] {
			XCTAssertFalse(ClerkTestAddress.isValid(invalid), invalid)
		}
	}
}

/// A ``ConnectivityMonitoring`` the test drives by hand. The production monitor cannot be asked for
/// "the network came back", which is the whole reason the boundary exists.
@MainActor
private final class FakeConnectivityMonitor: ConnectivityMonitoring {
	private(set) var startCount = 0
	private var onReconnect: (@MainActor () async -> Void)?

	func start(onReconnect: @escaping @MainActor () async -> Void) {
		startCount += 1
		self.onReconnect = onReconnect
	}

	/// Fires the reconnection and awaits the work it starts, so assertions never race it.
	func simulateReconnect() async {
		await onReconnect?()
	}
}

/// `MockAuthProvider` with a round-trip counter and a settable outcome, so a test can assert that a
/// reconnect cost exactly the validations it should have.
@MainActor
private final class CountingAuthProvider: AuthProviding {
	enum Outcome { case ready, signedOut, offline }

	var outcome: Outcome
	private let accountID: String?
	private(set) var validationCount = 0

	init(outcome: Outcome, accountID: String?) {
		self.outcome = outcome
		self.accountID = accountID
	}

	var isSignedIn: Bool { outcome != .signedOut }
	var accountIdentifier: String? { outcome == .signedOut ? nil : accountID }
	var displayName: String? { outcome == .signedOut ? nil : "Counting Finder" }

	func prepare() async {}

	func validateSession() async throws {
		validationCount += 1
		switch outcome {
		case .ready: return
		case .offline: throw AuthValidationError.offline
		case .signedOut: throw AuthValidationError.noValidSession
		}
	}

	func sessionToken() async throws -> String? { isSignedIn ? "counting.session.token" : nil }
	func signOut() async { outcome = .signedOut }
	func deleteAccount() async throws { outcome = .signedOut }

	/// Set to make the next `signIn` fail the way a rejected code does.
	var signInError: Error?
	private(set) var signInCount = 0

	func signIn(emailAddress: String, code: String) async throws {
		signInCount += 1
		if let signInError { throw signInError }
		outcome = .ready
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

	func sessionToken() async throws -> String? { isSignedIn ? "suspendable.session.token" : nil }

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
	func signIn(emailAddress: String, code: String) async throws {
		throw ProgrammaticSignInError.unsupported
	}
}

/// Collects published contexts from a Combine sink. A reference box rather than a captured local
/// `var`: `sink` is not actor-isolated, so Swift 6 concurrency checking rejects mutating a local
/// from inside it.
private final class ContextLog: @unchecked Sendable {
	var values: [EffectiveAuthContext] = []
}
