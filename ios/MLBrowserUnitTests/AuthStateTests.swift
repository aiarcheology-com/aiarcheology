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

	// MARK: - A refresh that joins a pass in flight (AIA-0987)

	/// A signed-out app whose provider has just signed in to A, the moment Clerk's sheet completes a
	/// sign-in: the gate still says `.signedOut`, and only a new pass can change that.
	private func signedOutAppThatJustSignedIn() async -> (SuspendableAuthProvider, AuthState) {
		let provider = SuspendableAuthProvider(accountIdentifier: nil)
		provider.isSignedIn = false
		let sut = AuthState(provider: provider)
		await sut.refresh()
		XCTAssertEqual(sut.gate, .signedOut)
		provider.isSignedIn = true
		provider.accountIdentifier = Self.accountA
		return (provider, sut)
	}

	/// Starts the refresh that owns the loop (the Clerk session watcher's, in the reported bug) and
	/// returns once its first validation is suspended.
	private func startSuspendedPass(
		_ sut: AuthState,
		_ provider: SuspendableAuthProvider
	) async -> (Task<Void, Never>, XCTestExpectation) {
		let suspended = expectation(description: "the owning pass is validating")
		provider.suspendNextValidation = suspended
		let finished = expectation(description: "the owning refresh returned")
		let task = Task {
			await sut.refresh()
			finished.fulfill()
		}
		await fulfillment(of: [suspended], timeout: 2)
		return (task, finished)
	}

	/// Starts a refresh the way `SignInSheet`'s `onDismiss` does, records the gate it reads once the
	/// call returns, and returns only once the call has joined the pass in flight. The waiter count
	/// is the handshake: scheduler order alone would not prove the caller joined before the test
	/// moves the pass on. Code that returns without waiting never registers, so this fails there.
	private func startJoiner(
		_ sut: AuthState,
		_ label: String
	) async -> (Task<Void, Never>, XCTestExpectation, RefreshOutcome) {
		let outcome = RefreshOutcome()
		let returned = expectation(description: "\(label) returned")
		let waitersBefore = sut.refreshWaiterCount
		let task = Task {
			await sut.refresh()
			outcome.gate = sut.gate
			returned.fulfill()
		}
		for _ in 0..<100 where sut.refreshWaiterCount == waitersBefore {
			await Task.yield()
		}
		XCTAssertEqual(sut.refreshWaiterCount, waitersBefore + 1, "\(label) did not wait for the pass in flight")
		return (task, returned, outcome)
	}

	/// Suspends the next validation, lets the current one finish (or throw), and returns once the
	/// next one is suspended.
	private func advanceToNextSuspendedPass(_ provider: SuspendableAuthProvider, _ label: String) async {
		let next = expectation(description: label)
		provider.suspendNextValidation = next
		provider.resumeValidation()
		await fulfillment(of: [next], timeout: 2)
	}

	/// Ends a test without ever hanging on a stranded continuation: waits for the given
	/// completions with a timeout and cancels every task. A failed wait fails the test instead of
	/// blocking it.
	private func finish(_ tasks: [Task<Void, Never>], waitingFor completions: [XCTestExpectation]) async {
		await fulfillment(of: completions, timeout: 2)
		tasks.forEach { $0.cancel() }
	}

	/// The reported bug (#987). The Clerk session watcher's refresh is validating when Clerk's sheet
	/// closes; the sign-in sheet's own refresh used to return at once, read `.signedOut`, and leave
	/// the sheet open over a completed sign-in. It must return only after a pass of its own.
	func testRefresh_CalledWhileAPassIsInFlight_ReturnsOnlyAfterAPassThatStartedAfterIt() async {
		let (provider, sut) = await signedOutAppThatJustSignedIn()
		let (watcher, watcherFinished) = await startSuspendedPass(sut, provider)
		let (sheet, sheetReturned, outcome) = await startJoiner(sut, "the sheet's refresh")

		await advanceToNextSuspendedPass(provider, "the pass the sheet asked for is validating")
		XCTAssertEqual(sut.gate, .ready, "the watcher's pass settled the gate")
		XCTAssertNil(outcome.gate, "the sheet's refresh returned before the pass it asked for finished")

		provider.resumeValidation()
		await finish([watcher, sheet], waitingFor: [sheetReturned, watcherFinished])
		XCTAssertEqual(outcome.gate, .ready)
		XCTAssertEqual(provider.validationCount, 2)
	}

	/// Triggers that keep arriving keep the loop running, and must not postpone a caller whose own
	/// pass has finished: it returns after exactly one more pass, while the loop runs on.
	func testRefresh_TriggersKeepArriving_AnEarlyCallerReturnsAfterItsOwnPass() async {
		let (provider, sut) = await signedOutAppThatJustSignedIn()
		let (owner, ownerFinished) = await startSuspendedPass(sut, provider)
		let (early, earlyReturned, earlyOutcome) = await startJoiner(sut, "the early caller")
		await advanceToNextSuspendedPass(provider, "pass 2, the early caller's, is validating")

		// Another trigger arrives while pass 2 runs, so the loop has to run a third pass.
		let (later, laterReturned, _) = await startJoiner(sut, "the later caller")
		await advanceToNextSuspendedPass(provider, "pass 3 is validating")
		await fulfillment(of: [earlyReturned], timeout: 2)
		XCTAssertEqual(earlyOutcome.gate, .ready)
		XCTAssertEqual(sut.refreshWaiterCount, 1, "only the later caller is still waiting")

		provider.resumeValidation()
		await finish([owner, early, later], waitingFor: [laterReturned, ownerFinished])
		XCTAssertEqual(provider.validationCount, 3)
	}

	/// A pass that validated one account while another signed in publishes nothing and queues a
	/// pass for the new account. It answers nobody: a caller released by it would read the gate the
	/// switch left behind, not the new account's.
	func testRefresh_AccountSwitchesDuringTheCallersPass_WaitsForThePassThatValidatesTheNewAccount() async {
		let (provider, sut) = await signedOutAppThatJustSignedIn()
		let (owner, ownerFinished) = await startSuspendedPass(sut, provider)
		let (caller, callerReturned, outcome) = await startJoiner(sut, "the caller")
		await advanceToNextSuspendedPass(provider, "pass 2, the caller's, is validating A")

		// B signs in while pass 2 validates A: pass 2 settles nothing and queues pass 3 for B.
		provider.accountIdentifier = Self.accountB
		await advanceToNextSuspendedPass(provider, "pass 3 is validating B")
		XCTAssertNil(outcome.gate, "the caller was released by a pass that published nothing")
		XCTAssertEqual(sut.refreshWaiterCount, 1)

		provider.resumeValidation()
		await finish([owner, caller], waitingFor: [callerReturned, ownerFinished])
		XCTAssertEqual(outcome.gate, .ready)
		XCTAssertEqual(sut.accountIdentifier, Self.accountB)
	}

	/// A caller waiting on a pass must never be stranded — a stranded caller is a sign-in sheet that
	/// never closes. Cancelling the waiting task releases it at once, while the pass runs on.
	func testRefresh_WaitingCallerIsCancelled_ReturnsWithoutWaitingForThePass() async {
		let (provider, sut) = await signedOutAppThatJustSignedIn()
		let (owner, ownerFinished) = await startSuspendedPass(sut, provider)
		let (waiter, waiterReturned, outcome) = await startJoiner(sut, "the cancelled caller")

		waiter.cancel()
		await fulfillment(of: [waiterReturned], timeout: 2)
		XCTAssertEqual(outcome.gate, .signedOut, "released while the pass was still validating")
		XCTAssertEqual(sut.refreshWaiterCount, 0)

		// The trigger it left behind still runs.
		provider.resumeValidation()
		await finish([owner], waitingFor: [ownerFinished])
		XCTAssertEqual(sut.gate, .ready)
		XCTAssertEqual(provider.validationCount, 2)
	}

	/// The pass a caller waits on can fail. Every failure ends the pass, so the caller is released
	/// and reads what the pass published.
	func testRefresh_ThePassACallerWaitsOnFails_ReleasesTheCaller() async {
		let failures: [(Error, AuthGate)] = [
			(AuthValidationError.offline, .offline),
			(AuthValidationError.noValidSession, .signedOut)
		]
		for (error, expectedGate) in failures {
			let (provider, sut) = await signedOutAppThatJustSignedIn()
			let (owner, ownerFinished) = await startSuspendedPass(sut, provider)
			let (waiter, waiterReturned, outcome) = await startJoiner(sut, "the caller (\(error))")
			await advanceToNextSuspendedPass(provider, "the caller's pass is validating (\(error))")
			XCTAssertEqual(sut.gate, .ready, "the first pass settled; only the caller's pass fails")

			provider.resumeValidation(throwing: error)
			await finish([owner, waiter], waitingFor: [waiterReturned, ownerFinished])
			XCTAssertEqual(outcome.gate, expectedGate, "after \(error)")
		}
	}

	/// The sign-in sheet's cancel path, with a pass in flight: the account signs out mid-validation,
	/// and the caller returns `.signedOut` rather than hanging. Starts from a validated account, so
	/// `.signedOut` can only come from a pass that ran after the sign-out.
	func testRefresh_SignOutDuringThePassACallerJoined_ReturnsSignedOut() async {
		let provider = SuspendableAuthProvider(accountIdentifier: Self.accountA)
		let sut = AuthState(provider: provider)
		await sut.start()
		XCTAssertEqual(sut.gate, .ready)

		let (owner, ownerFinished) = await startSuspendedPass(sut, provider)
		let (waiter, waiterReturned, outcome) = await startJoiner(sut, "the caller")
		await advanceToNextSuspendedPass(provider, "the caller's pass is validating")
		XCTAssertNil(outcome.gate)

		await provider.signOut()
		provider.resumeValidation()
		await finish([owner, waiter], waitingFor: [waiterReturned, ownerFinished])
		XCTAssertEqual(outcome.gate, .signedOut)
	}

	// MARK: - A cancelled pass (AIA-0987)

	/// A cancelled pass has no result, and "no result" is not "signed out": the gate and the
	/// account stay as they were. Both ways a cancelled round trip surfaces are covered — the raw
	/// cancellation, and `.offline`, which is how `ClerkAuthProvider` reports one.
	func testRefresh_ThePassIsCancelled_LeavesTheGateAndTheAccountUnchanged() async {
		let cancellations: [Error] = [CancellationError(), AuthValidationError.offline]
		for thrown in cancellations {
			let provider = SuspendableAuthProvider(accountIdentifier: Self.accountA)
			let sut = AuthState(provider: provider)
			await sut.start()
			XCTAssertEqual(sut.gate, .ready)

			let (owner, ownerFinished) = await startSuspendedPass(sut, provider)
			owner.cancel()
			provider.resumeValidation(throwing: thrown)
			await finish([owner], waitingFor: [ownerFinished])

			XCTAssertEqual(sut.gate, .ready, "a cancelled pass that threw \(thrown) changed the gate")
			XCTAssertEqual(sut.accountIdentifier, Self.accountA, "after \(thrown)")
			XCTAssertEqual(sut.effectiveContext, .validated(Self.accountA), "after \(thrown)")
		}
	}

	/// The fix must not work by never signing out: Clerk answering "no session" is a real
	/// sign-out, whether or not the pass's task was cancelled while the answer came back.
	func testRefresh_NoSessionAnswer_SignsOutWhetherOrNotThePassWasCancelled() async {
		for cancelsThePass in [false, true] {
			let provider = SuspendableAuthProvider(accountIdentifier: Self.accountA)
			let sut = AuthState(provider: provider)
			await sut.start()
			XCTAssertEqual(sut.gate, .ready)

			let (owner, ownerFinished) = await startSuspendedPass(sut, provider)
			if cancelsThePass { owner.cancel() }
			provider.resumeValidation(throwing: AuthValidationError.noValidSession)
			await finish([owner], waitingFor: [ownerFinished])

			XCTAssertEqual(sut.gate, .signedOut, "cancelled: \(cancelsThePass)")
			XCTAssertNil(sut.accountIdentifier, "cancelled: \(cancelsThePass)")
		}
	}

	/// A caller waiting on the loop of a cancelled task is not stranded, and not answered by the
	/// cancelled pass either: a fresh task runs the pass it asked for, and it reads that result.
	func testRefresh_CancelledPassWithACallerWaiting_AFreshPassAnswersTheCaller() async {
		let (provider, sut) = await signedOutAppThatJustSignedIn()
		let (owner, ownerFinished) = await startSuspendedPass(sut, provider)
		let (caller, callerReturned, outcome) = await startJoiner(sut, "the caller")

		owner.cancel()
		let handedOff = expectation(description: "the caller's pass runs in a fresh task")
		provider.suspendNextValidation = handedOff
		provider.resumeValidation(throwing: CancellationError())
		await fulfillment(of: [handedOff, ownerFinished], timeout: 2)
		XCTAssertNil(outcome.gate, "the caller was answered by the cancelled pass")
		XCTAssertEqual(sut.gate, .signedOut, "the cancelled pass changed nothing")

		provider.resumeValidation()
		await finish([caller], waitingFor: [callerReturned])
		XCTAssertEqual(outcome.gate, .ready)
		XCTAssertEqual(provider.validationCount, 2)
	}

	/// A pass validating a new account stops publishing the outgoing one before it suspends. If it
	/// is then cancelled, the outgoing account must not come back (it is no longer signed in), and
	/// the incoming one is still owed a validation: a fresh task runs it, with nobody asking.
	func testRefresh_CancelledPassThatStoppedPublishingAnAccount_AFreshPassValidatesTheNewOne() async {
		let provider = SuspendableAuthProvider(accountIdentifier: Self.accountA)
		let sut = AuthState(provider: provider)
		await sut.start()
		XCTAssertEqual(sut.accountIdentifier, Self.accountA)

		provider.accountIdentifier = Self.accountB
		let (owner, ownerFinished) = await startSuspendedPass(sut, provider)
		XCTAssertNil(sut.accountIdentifier, "A stops being published before B's validation")

		owner.cancel()
		let handedOff = expectation(description: "B's validation runs in a fresh task")
		provider.suspendNextValidation = handedOff
		provider.resumeValidation(throwing: CancellationError())
		await fulfillment(of: [handedOff, ownerFinished], timeout: 2)
		XCTAssertNil(sut.accountIdentifier, "the cancelled pass restored an account that signed out")

		// The fresh task has no handle to await; its published result is the signal.
		let accountB = Self.accountB
		let publishedB = expectation(description: "B is published")
		let observation = sut.$accountIdentifier.sink { if $0 == accountB { publishedB.fulfill() } }
		provider.resumeValidation()
		await fulfillment(of: [publishedB], timeout: 2)
		observation.cancel()
		XCTAssertEqual(sut.gate, .ready)
	}

	/// A `CancellationError` from a pass whose task nobody cancelled is a failure, not a
	/// cancellation. Treated as a cancellation it would be handed to a fresh task that fails the
	/// same way, for ever; the refresh must end after that one pass.
	func testRefresh_CancellationErrorFromAnUncancelledPass_IsNotHandedOn() async {
		let (provider, sut) = await signedOutAppThatJustSignedIn()
		let (owner, ownerFinished) = await startSuspendedPass(sut, provider)
		provider.resumeValidation(throwing: CancellationError())
		await finish([owner], waitingFor: [ownerFinished])
		for _ in 0..<20 { await Task.yield() }
		XCTAssertEqual(provider.validationCount, 1, "the failed pass was handed to another task")
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

	private var suspended: CheckedContinuation<Void, Error>?

	init(accountIdentifier: String?) {
		self.accountIdentifier = accountIdentifier
	}

	func prepare() async {}

	func validateSession() async throws {
		validationCount += 1
		guard let armed = suspendNextValidation else { return }
		suspendNextValidation = nil
		try await withCheckedThrowingContinuation { continuation in
			suspended = continuation
			armed.fulfill()
		}
	}

	func sessionToken() async throws -> String? { isSignedIn ? "suspendable.session.token" : nil }

	/// Let the currently suspended `validateSession()` return successfully, or throw `error`.
	func resumeValidation(throwing error: Error? = nil) {
		let continuation = suspended
		suspended = nil
		if let error {
			continuation?.resume(throwing: error)
		} else {
			continuation?.resume()
		}
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

/// What a refresh caller read once its call returned. A `@MainActor` reference box rather than a
/// captured local `var`, which Swift 6 concurrency checking rejects inside a `Task`.
@MainActor
private final class RefreshOutcome {
	var gate: AuthGate?
}
