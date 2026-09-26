//
//  AuthState.swift
//  AI Archeology
//
//  Authentication & access gating (AIA-0340).
//

import Foundation
import OSLog

/// Who is signed in, as a state machine (AIA-0340).
///
/// It was the launch gate until AIA-0536 — every state below used to decide which root screen the
/// app rendered, and `AuthGateView` was the view that did it. **None of them gate anything now**:
/// entitlement and the free-access window decide access, and this only tells the rest of the app
/// who it is talking to (analytics consent scope, purchase tagging, which account controls to
/// offer). Read a state here as a fact, never as a permission.
///
/// Flow: `checkingSession` resolves into exactly one of the terminal states.
/// - `signedOut`: no valid session (never signed in, signed out, revoked, or banned).
/// - `offline`: validation could not reach the server. It no longer fails closed — an entitled
///   user in airplane mode reaches the app, which is the lockout AIA-0536 exists to have fixed.
///   Not terminal since AIA-0757: it is re-evaluated when a network path comes back, because the
///   gate is read as fact (`SettingsView`'s back-up section is gated on the identifier `.offline`
///   leaves unset on a cold offline launch) and a stale one takes a working control away.
/// - `ready`: signed in.
enum AuthGate: Equatable {
    case checkingSession
    case signedOut
    case offline
    case ready
}

/// Failure modes surfaced by an ``AuthProviding`` while validating a session.
enum AuthValidationError: Error {
    /// The validation round-trip failed because the device is offline or the
    /// Clerk endpoint was unreachable. Since AIA-0536 this costs the user nothing:
    /// it blocks no screen, it only leaves the session unverifiable.
    case offline
    /// The session is no longer valid (signed out elsewhere, revoked, or banned).
    case noValidSession
}

/// Which half of ``AuthState/deleteAccount()`` failed.
///
/// The two halves leave the cloud copy in different states, and the copy shown to the person who
/// pressed the button differs accordingly (AIA-0816). A single "it failed" cannot be phrased
/// truthfully for both: after ``purge`` the erase is *incomplete*, while after ``accountDeletion``
/// it finished and only the account itself survives.
enum AccountDeletionFailure: Error {
    /// The cloud purge did not complete, and the account still exists -- the caller deliberately
    /// does not delete it, because the session token is the only credential that can reach whatever
    /// is left.
    ///
    /// **How much was erased is unknown**, which is why `auth.account.delete.failedPurge` says a
    /// back-up "may already have been removed" rather than claiming nothing happened. Two very
    /// different situations arrive here: the pre-flight refusal in ``AuthState/deleteAccount()``,
    /// where no request was made at all, and a purge that deleted some objects and then threw. The
    /// caller cannot tell them apart, so the copy must hold for both -- and the hedge is the only
    /// sentence that does. This doc read "Nothing was erased" until AIA-0891; two call sites had
    /// copied that claim into comments, while the shipped string had said otherwise since #818.
    case purge(Error)
    /// The purge succeeded and deleting the account itself did not. The account survives.
    ///
    /// `cloudDataErased` is false when there was nothing to erase -- a build with no sync wired --
    /// so the copy shown never claims a back-up was removed when none was.
    case accountDeletion(Error, cloudDataErased: Bool)

    /// What actually threw, for a caller that wants to inspect or re-report it.
    var underlying: Error {
        switch self {
        case let .purge(error), let .accountDeletion(error, _): error
        }
    }
}

/// Abstraction over the authentication backend so ``AuthState`` can be unit-tested
/// and UI-tested without the real Clerk SDK or any network access.
///
/// All members are `@MainActor` because the production implementation
/// (``ClerkAuthProvider``) wraps `Clerk.shared`, which is itself `@MainActor`-
/// isolated. That is also why the production adapter is a `@MainActor` type rather
/// than an `actor`: wrapping a main-actor singleton in an actor would only add
/// pointless hops. The Harmonize "services are actors" rule is satisfied by *not*
/// naming the adapter `*Service`.
@MainActor
protocol AuthProviding {
    /// True once a persisted session has been hydrated and a user is signed in.
    var isSignedIn: Bool { get }

    /// The stable, server-assigned identifier of the signed-in account, or `nil` when signed out.
    ///
    /// Stable **across devices** for the same account — that property is the whole basis of the
    /// cross-device analytics identity (AIA-0437). It is the account id, never the session id,
    /// which is per-device. Treat the value as sensitive: it may be hashed by the analytics
    /// transport, but it must never be logged or sent as an event parameter.
    var accountIdentifier: String? { get }

    /// A human-readable name for the signed-in account, or `nil` when there is none to offer.
    ///
    /// Used to prefill the author of a finding (AIA-0651) — a credit that ends up on a shared
    /// graphic. **It must never fall back to the account's email address**: an address is not a
    /// byline, and putting one on an image the user posts publicly would leak it to everyone who
    /// sees the post. An account with no usable name returns `nil`, and the field is simply left
    /// empty for the user to fill in.
    ///
    /// Not required to be stable: it reflects whatever the account is called *right now*. Callers
    /// that persist it must snapshot it, never re-read it (see ``AuthState/accountDisplayName``).
    var displayName: String? { get }

    /// Ensure the backend has finished loading its persisted session/environment.
    func prepare() async

    /// Round-trip to the server to validate the current session — this is what
    /// rejects revoked/banned sessions. Throws ``AuthValidationError`` on failure.
    func validateSession() async throws

    /// A short-lived bearer token proving who this is to our own backend, or `nil` when signed out
    /// (AIA-727).
    ///
    /// Ask for one per request rather than holding it: these expire in about a minute, and the SDK
    /// caches and refreshes behind this call, so re-asking is cheap and holding one is a bug that
    /// only shows up on a slow upload.
    ///
    /// **Never log it and never persist it.** It is a credential to every finding the account owns,
    /// which is to say to the coordinates of every site the user has recorded.
    func sessionToken() async throws -> String?

    /// Sign the current user out.
    func signOut() async

    /// Permanently delete the current user's account (Apple Guideline 5.1.1(v)).
    func deleteAccount() async throws

    #if DEBUG
    /// Sign in with an email verification code through the backend's own API, without its UI
    /// (AIA-0974). The headless build has no Clerk `AuthView` to present, so this is how it signs in.
    ///
    /// Debug-only, so the shipping auth surface is unchanged. Returns only once the provider reports
    /// a signed-in user; the caller then re-evaluates the gate exactly as `SignInSheet` does.
    /// Deliberately no default implementation: a conformer whose signature drifted would otherwise
    /// fall back to it silently.
    func signIn(emailAddress: String, code: String) async throws
    #endif
}

/// Owns ``AuthGate``. Re-evaluated at launch, on every foreground, and — since AIA-0757 — when the
/// network comes back, so that a Dashboard ban/revocation takes effect within one refresh and a
/// `.offline` gate cannot outlive the outage that caused it.
///
/// Drives no root screen since AIA-0536 — see ``AuthGate``. It is still evaluated at launch
/// because the answer is needed the moment the app has to attribute a purchase or pick a consent
/// scope, not because anything is waiting on it to render.
@MainActor
final class AuthState: ObservableObject {
    /// The current gate. Nothing branches on this to pick a root screen any more (AIA-0536) —
    /// views read it to decide which *account controls* to offer, and analytics to pick a scope.
    @Published private(set) var gate: AuthGate = .checkingSession

    /// The signed-in account, or `nil` when signed out (AIA-0437).
    ///
    /// Published separately from ``gate`` because ``setGate(_:)`` suppresses equal values: an
    /// in-place account switch (A signs out and B signs in without the gate leaving `.ready`)
    /// publishes nothing on `gate`, so an observer watching only the gate would keep attributing
    /// events to A forever.
    ///
    /// Written at exactly the points that write the gate, and only there. `.ready` implies a
    /// validated account; `.signedOut` implies `nil`. `.offline` and `.checkingSession` leave it
    /// untouched — a transient loss of connectivity is not a change of account.
    @Published private(set) var accountIdentifier: String? {
        didSet {
            guard oldValue != accountIdentifier else { return }
            // On the property rather than at each write site: the identity is written from several
            // places, and a trigger that has to be remembered at each of them is a trigger that
            // gets forgotten at one of them.
            accountDidChange?(accountIdentifier)
        }
    }

    /// Called when the signed-in account changes, including signing in and signing out.
    ///
    /// Cloud sync needs it (AIA-727): signing in is not the app coming to the front, not the
    /// network reconnecting, and not a save, so without this a user signs in and *nothing happens*
    /// until some unrelated event fires. Wired by `DependencyContainer`.
    var accountDidChange: ((String?) -> Void)?

    /// The consent/attribution identity derived from ``gate`` and ``accountIdentifier`` (AIA-0536).
    ///
    /// A total function over that *pair*, not over either alone — `.ready` with a `nil` identifier
    /// is a real, reachable state (see ``evaluateGate()``) and is **not** anonymity.
    ///
    /// Written at exactly the points that write those two properties and nowhere else. That gives
    /// observers an invariant they can rely on: the set of context transitions equals the set of
    /// writes to ``accountIdentifier``, with ``EffectiveAuthContext/suspended(_:)`` as the one
    /// context corresponding to *no* write — which is why it must be ignored rather than acted on.
    @Published private(set) var effectiveContext: EffectiveAuthContext = .indeterminate

    /// A name to offer as the default author of a new finding (AIA-0651), or `nil` when the app
    /// has concluded that nobody is signed in.
    ///
    /// Deliberately **computed and not `@Published`**. It is read once, when the save sheet
    /// appears, to seed an editable text field — it is not state anything renders continuously, and
    /// publishing it would add a second write site to the identity invariant documented on
    /// ``accountIdentifier`` ("written at exactly the points that write the gate, and only there").
    ///
    /// The predicate is `.signedOut`, not `.ready`, and both halves of that matter:
    /// - Excluding `.signedOut` is what makes "signed out ⇒ empty" true. ``setSignedOut()`` is the
    ///   only way into that state and runs on a revoked or banned session *before* the backend's
    ///   cached user necessarily clears — so asking the provider directly could otherwise offer the
    ///   name of a user this app has already stopped trusting.
    /// - Requiring `.ready` would have been wrong: ``AuthGate/offline`` is terminal for the session
    ///   and is the state AIA-0536 exists to have fixed. A signed-in user in the field with no
    ///   signal sits there, and would get no prefill for the whole session — the single scenario
    ///   this feature most needs to work. `.checkingSession` is the same story on a cold launch,
    ///   which is precisely when the persisted account is already hydrated.
    ///
    /// Before the backend configures, the provider reports `nil` anyway and the field starts empty.
    var accountDisplayName: String? {
        gate == .signedOut ? nil : provider.displayName
    }

    private let provider: AuthProviding

    /// Coalesces overlapping refreshes. `refresh()` is triggered from several places
    /// (launch, foreground, sign-in sheet dismissal, Clerk session changes) that can
    /// fire near-simultaneously. While one pass is in flight, further triggers set
    /// `refreshPending` so exactly one more pass runs afterward — avoiding redundant
    /// round-trips without *dropping* a trigger (e.g. an out-of-band sign-out arriving
    /// mid-refresh still gets re-evaluated rather than leaving a stale gate).
    private var isRefreshing = false
    private var refreshPending = false

    /// Watches for the network coming back (AIA-0757). Optional and **defaulted to `nil`**: the
    /// production monitor is constructed at the composition boundary (`AccountSession`) and nowhere
    /// else, so the unit suite's many `AuthState(provider:)` constructions cannot start real network
    /// monitoring underneath tests that assert exact validation counts.
    private let connectivity: ConnectivityMonitoring?

    /// Claimed **synchronously**, before `start()`'s first suspension. `.task { start() }` mounts once
    /// per *scene*, not once per app, and this app can run several iPad scenes over one `AppState`
    /// (the same hazard `FreeAccessState` records). Two scenes racing into `start()` would otherwise
    /// both reach `NWPathMonitor.start(queue:)`, which traps on an already-started monitor.
    private var didStartConnectivityMonitor = false

    /// The single outstanding "try again shortly" after a refresh that landed `.offline`.
    /// Held so a later one replaces it rather than stacking another.
    private var reconnectRetry: Task<Void, Never>?

    /// Whether the current offline spell has already spent its automatic retry.
    ///
    /// This is what keeps "an offline outcome arms a retry" from becoming a refresh every few
    /// seconds for as long as the device has no signal. Cleared by a settled gate and by a genuine
    /// path change — a real network event has earned a fresh attempt.
    private var didAutoRetryWhileOffline = false

    /// How long to wait before the one retry that follows a failed reconnect refresh.
    ///
    /// A satisfied path means an interface is up, not that Clerk answers: after a captive-portal
    /// login or on a cold DNS cache the first attempt can fail while a second, moments later,
    /// succeeds. Injectable so a test can pick a delay long enough never to fire during it.
    private let reconnectRetryDelay: Duration

    init(
        provider: AuthProviding,
        connectivity: ConnectivityMonitoring? = nil,
        reconnectRetryDelay: Duration = .seconds(3)
    ) {
        self.provider = provider
        self.connectivity = connectivity
        self.reconnectRetryDelay = reconnectRetryDelay
    }

    /// Called once when the gate first appears: hydrate the persisted session,
    /// then evaluate access.
    func start() async {
        startConnectivityMonitorIfNeeded()
        await provider.prepare()
        await refresh()
    }

    private func startConnectivityMonitorIfNeeded() {
        guard didStartConnectivityMonitor == false, let connectivity else { return }
        didStartConnectivityMonitor = true
        connectivity.start { [weak self] in
            await self?.handleReconnect()
        }
    }

    /// Re-evaluate a gate that is stuck only for want of a network (AIA-0757).
    ///
    /// The `.offline` guard is what keeps a flapping connection from becoming a request storm: the
    /// first successful pass leaves the gate `.ready` or `.signedOut`, and every later reconnect is
    /// then a no-op. It is also the honest scope of this trigger — `.signedOut` is terminal by
    /// decision (`ClerkAuthProvider` routes a *rejected* session there, not an unreachable one), and
    /// re-validating it on a network blip would second-guess a revocation.
    func refreshIfOffline() async {
        guard gate == .offline else { return }
        await refresh()
    }

    /// A real path change: spend a fresh retry allowance, then re-evaluate.
    ///
    /// The allowance is cleared *before* awaiting, so a reconnect always earns an attempt even if
    /// the previous offline spell had already spent one. Arming the retry itself is left to
    /// ``settleOfflineRetry()``, which every refresh runs — so two reconnects racing cannot leave
    /// two live retry tasks behind, only the one that function keeps.
    private func handleReconnect() async {
        didAutoRetryWhileOffline = false
        await refreshIfOffline()
    }

    /// Re-evaluate the gate. Safe to call on launch and on every foreground.
    func refresh() async {
        if isRefreshing {
            // A pass is already running — request one more afterward instead of
            // running concurrently or dropping this trigger.
            refreshPending = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            refreshPending = false
            await evaluateGate()
        } while refreshPending
        settleOfflineRetry()
    }

    /// One rule, applied to the *outcome* of every refresh: if it ended `.offline`, try once more
    /// shortly; otherwise stand down (AIA-0757).
    ///
    /// Anchoring on the outcome rather than on the connectivity event is what makes this cover the
    /// cases a reconnect handler alone cannot see, each of which reproduced the very bug this
    /// ticket fixes:
    /// - a path becoming satisfied while the gate is still `.checkingSession`, where
    ///   ``refreshIfOffline()`` correctly does nothing and the in-flight pass then lands `.offline`
    ///   with no later edge coming, because the path is already satisfied;
    /// - the foreground refresh firing before networking has settled after a resume;
    /// - a captive portal or cold DNS answering the first attempt and not the second.
    private func settleOfflineRetry() {
        guard gate == .offline else {
            // A terminal answer: nothing left to retry, and the next offline spell starts fresh.
            reconnectRetry?.cancel()
            reconnectRetry = nil
            didAutoRetryWhileOffline = false
            return
        }
        guard didAutoRetryWhileOffline == false else { return }
        didAutoRetryWhileOffline = true
        scheduleOfflineRetry()
    }

    private func scheduleOfflineRetry() {
        reconnectRetry?.cancel()
        let delay = reconnectRetryDelay
        reconnectRetry = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard Task.isCancelled == false else { return }
            await self?.refreshIfOffline()
        }
    }

    private func evaluateGate() async {
        guard provider.isSignedIn else {
            setSignedOut()
            return
        }

        // Bind this validation to a specific account. `validateSession()` suspends, and a sign-out
        // followed by a *different* sign-in can complete inside that window — in which case the
        // round-trip that returns successfully validated the OLD account. Checking `isSignedIn`
        // alone cannot tell the two apart, because it is true for either one (AIA-0437).
        let accountUnderValidation = provider.accountIdentifier

        // Stop publishing the OUTGOING account before suspending. Clerk can switch accounts
        // out-of-band (the embedded profile UI), and the watcher only kicks off a refresh — so
        // without this the previous account stays published for the whole validation round-trip
        // and anything tracked in that window is attributed to a user who is no longer signed in.
        // The post-`await` guard below protects the incoming account; this protects the outgoing one.
        if accountUnderValidation != accountIdentifier {
            accountIdentifier = nil
            // Not `.anonymous`: nobody signed out. This is the `(.ready, nil)` window, and calling it
            // anonymity would hand the anonymous consent scope a slice of time in the middle of a
            // sign-in — long enough to select a bucket and ask a question of the wrong person.
            effectiveContext = .indeterminate
        }

        do {
            try await provider.validateSession()
        } catch AuthValidationError.offline {
            // Identity deliberately left as-is: losing connectivity is not a change of account.
            // On a cold offline launch that identity is still `nil` — this line is the reason
            // `.suspended(nil)` is the common shape rather than the exotic one.
            effectiveContext = .suspended(accountIdentifier)
            setGate(.offline)
            return
        } catch {
            // Revoked / banned / signed out elsewhere — fall back to sign-in.
            setSignedOut()
            return
        }

        // Re-check signed-in status: `validateSession()` suspends, and a sign-out can
        // interleave on the main actor during that await. Without this re-check, a
        // mid-refresh sign-out would still land on `.ready` rather than `.signedOut`.
        guard provider.isSignedIn else {
            setSignedOut()
            return
        }

        // A different account arrived while we were validating. Publishing now would mark the new
        // account ready — and hand its identity to analytics — on the strength of a validation
        // that was never about it. Queue another pass instead; the loop in `refresh()` runs it.
        guard provider.accountIdentifier == accountUnderValidation else {
            refreshPending = true
            return
        }

        // Read fresh rather than reusing the pre-`await` local, so the published value can only
        // ever be the one this pass actually validated.
        let validatedAccount = provider.accountIdentifier
        accountIdentifier = validatedAccount
        // Total over the pair: a provider reporting "signed in" with no identifier is not an
        // anonymous user, it is an unusable one. Fail to `.indeterminate` rather than select a scope.
        effectiveContext = validatedAccount.map(EffectiveAuthContext.validated) ?? .indeterminate
        setGate(.ready)
    }

    /// Sign out and return to the sign-in screen.
    func signOut() async {
        await provider.signOut()
        setSignedOut()
    }

    #if DEBUG
    /// Sign in without the Clerk UI, then re-evaluate the gate — the `authState.refresh()` that
    /// `SignInSheet` runs when Clerk's sheet closes (AIA-0974). Only the headless build calls it.
    ///
    /// Throws what the provider throws and leaves the gate to the refresh: a failed sign-in changes
    /// nothing here, so a signed-out app stays signed out.
    func signIn(emailAddress: String, code: String) async throws {
        try await provider.signIn(emailAddress: emailAddress, code: code)
        await refresh()
    }

    /// Whether the backend itself still holds a signed-in user, as opposed to what ``gate`` says.
    ///
    /// The two differ after a sign-out whose server call failed: ``signOut()`` publishes
    /// `.signedOut` regardless, because a user who asked to leave must not be kept in. Headless
    /// scenarios read this to prove the session really ended (AIA-0974).
    var isProviderSignedIn: Bool {
        provider.isSignedIn
    }
    #endif

    /// Erase the account's cloud data, then delete the account, then return to the sign-in screen.
    ///
    /// **The order is the whole point (AIA-728).** Deleting the Clerk user first destroys the
    /// session token, and that token is the only credential that can reach the user's stored
    /// findings -- they would sit in the bucket for ever with nothing able to name them. A purge
    /// that throws leaves the account intact so the user can try again, rather than leaving them
    /// deleted and their data behind.
    func deleteAccount() async throws {
        // Correlates the lines below with each other, with the Worker's request log, and with the
        // Sentry event the failure path raises (AIA-0816). Deliberately not a UUID: `LogRedactor`
        // strips anything UUID-shaped, and this value exists to survive into the redacted copy.
        let operation = String(UUID().uuidString.prefix(8))
        var cloudDataErased = false
        // The account is named by ``FindingsSyncLedgerStore/fingerprint(of:)``, and only where it
        // is actually known -- inside the purge. Writing the raw id here would achieve nothing: an
        // `account id:` prefix is redacted at export as well as at the call site, so it would reach
        // neither the support attachment nor us.
        LoggingPolicy.info("Account deletion \(operation) requested", logger: .state)

        // Sync is wired but nobody is signed in: the purge would erase nothing, and deleting the
        // account anyway is the one outcome this ordering exists to prevent -- the session token is
        // the only credential that can reach whatever is stored. Refuse instead (review of #818).
        // `provider.accountIdentifier`, not the published one: this type's copy is filled in by
        // `evaluateGate()` and is nil until a refresh has run, so guarding on it would refuse
        // deletions for a signed-in user who simply had not been re-validated yet.
        if purgeCloudData != nil, provider.accountIdentifier == nil {
            LoggingPolicy.error(
                "Account deletion \(operation) refused: no account is signed in, so the cloud copy "
                    + "cannot be reached, let alone erased.",
                logger: .state
            )
            throw AccountDeletionFailure.purge(AuthValidationError.noValidSession)
        }

        do {
            // What the purge *reports*, never what it was asked to do: a wired purge still returns
            // false when there was no account or no endpoint to erase from, and copy promising that
            // a back-up was removed would be false there (review of #818).
            cloudDataErased = try await purgeCloudData?(operation) ?? false
        } catch {
            // "did not complete", not "nothing was erased" (AIA-0891). The purge throws on an
            // incomplete result *after* deleting some objects, so the older wording was false
            // exactly when this line matters most: it is the one that reaches the support
            // attachment and the Sentry event, where somebody is trying to work out what is left.
            LoggingPolicy.error(
                "Account deletion \(operation) stopped: the cloud purge did not complete, so the "
                    + "account was kept; an unknown amount may already have been erased. "
                    + "\(error.localizedDescription)",
                logger: .state
            )
            throw AccountDeletionFailure.purge(error)
        }

        do {
            try await provider.deleteAccount()
        } catch {
            LoggingPolicy.error(
                "Account deletion \(operation) stopped: the cloud data was erased but the account "
                    + "itself was not deleted. \(error.localizedDescription)",
                logger: .state
            )
            throw AccountDeletionFailure.accountDeletion(error, cloudDataErased: cloudDataErased)
        }

        LoggingPolicy.info("Account deletion \(operation) completed: account deleted", logger: .state)
        setSignedOut()
    }

    /// Erases the signed-in account's cloud findings, or throws. Wired by `DependencyContainer`;
    /// `nil` in a build with no sync, where there is nothing stored to erase.
    var purgeCloudData: ((_ operation: String) async throws -> Bool)?

    /// The only way to reach `.signedOut`. Clears the identity *before* the gate so nothing can
    /// observe "signed out" while a stale account is still published. `signOut()` and
    /// `deleteAccount()` reach this directly without passing through ``evaluateGate()``, which is
    /// why the identity cannot be maintained there alone.
    private func setSignedOut() {
        accountIdentifier = nil
        // The one place anonymity is declared. Every other `nil` identifier means "unknown", not
        // "nobody" — only an actual sign-out, revocation, or a provider reporting no session
        // produces a scope that may be asked for consent in its own right.
        effectiveContext = .anonymous
        setGate(.signedOut)
    }

    private func setGate(_ newValue: AuthGate) {
        guard gate != newValue else { return }
        gate = newValue
        LoggingPolicy.info("Auth gate → \(String(describing: newValue))", logger: .state)
    }
}
