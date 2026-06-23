//
//  AuthState.swift
//  AI Archeology
//
//  Authentication & access gating (AIA-0340).
//

import Foundation
import OSLog

/// The launch-gate state machine for authentication (AIA-0340).
///
/// Flow: `checkingSession` resolves into exactly one of the terminal states.
/// - `signedOut`: no valid session (never signed in, signed out, revoked, or banned).
/// - `offline`: validation could not reach the server. v1 fails closed here.
/// - `ready`: signed in — the app proper is shown.
enum AuthGate: Equatable {
    case checkingSession
    case signedOut
    case offline
    case ready
}

/// Failure modes surfaced by an ``AuthProviding`` while validating a session.
enum AuthValidationError: Error {
    /// The validation round-trip failed because the device is offline or the
    /// Clerk endpoint was unreachable. v1 fails closed → "needs connection".
    case offline
    /// The session is no longer valid (signed out elsewhere, revoked, or banned).
    case noValidSession
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

    /// Ensure the backend has finished loading its persisted session/environment.
    func prepare() async

    /// Round-trip to the server to validate the current session — this is what
    /// rejects revoked/banned sessions. Throws ``AuthValidationError`` on failure.
    func validateSession() async throws

    /// Sign the current user out.
    func signOut() async

    /// Permanently delete the current user's account (Apple Guideline 5.1.1(v)).
    func deleteAccount() async throws
}

/// Owns the authentication launch-gate. Drives which root screen the app shows
/// before `ContentView`. Re-evaluated at launch and on every foreground so that
/// a Dashboard ban/de-entitlement takes effect within one refresh.
@MainActor
final class AuthState: ObservableObject {
    /// The current gate. Views branch on this to pick the root screen.
    @Published private(set) var gate: AuthGate = .checkingSession

    private let provider: AuthProviding

    /// Coalesces overlapping refreshes. `refresh()` is triggered from several places
    /// (launch, foreground, sign-in sheet dismissal, Clerk session changes) that can
    /// fire near-simultaneously. While one pass is in flight, further triggers set
    /// `refreshPending` so exactly one more pass runs afterward — avoiding redundant
    /// round-trips without *dropping* a trigger (e.g. an out-of-band sign-out arriving
    /// mid-refresh still gets re-evaluated rather than leaving a stale gate).
    private var isRefreshing = false
    private var refreshPending = false

    init(provider: AuthProviding) {
        self.provider = provider
    }

    /// Called once when the gate first appears: hydrate the persisted session,
    /// then evaluate access.
    func start() async {
        await provider.prepare()
        await refresh()
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
    }

    private func evaluateGate() async {
        guard provider.isSignedIn else {
            setGate(.signedOut)
            return
        }

        do {
            try await provider.validateSession()
        } catch AuthValidationError.offline {
            setGate(.offline)
            return
        } catch {
            // Revoked / banned / signed out elsewhere — fall back to sign-in.
            setGate(.signedOut)
            return
        }

        // Re-check signed-in status: `validateSession()` suspends, and a sign-out can
        // interleave on the main actor during that await. Without this re-check, a
        // mid-refresh sign-out would still land on `.ready` rather than `.signedOut`.
        guard provider.isSignedIn else {
            setGate(.signedOut)
            return
        }

        setGate(.ready)
    }

    /// Sign out and return to the sign-in screen.
    func signOut() async {
        await provider.signOut()
        setGate(.signedOut)
    }

    /// Delete the account and return to the sign-in screen.
    func deleteAccount() async throws {
        try await provider.deleteAccount()
        setGate(.signedOut)
    }

    private func setGate(_ newValue: AuthGate) {
        guard gate != newValue else { return }
        gate = newValue
        LoggingPolicy.info("Auth gate → \(String(describing: newValue))", logger: .state)
    }
}
