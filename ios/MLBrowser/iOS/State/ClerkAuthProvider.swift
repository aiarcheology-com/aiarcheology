//
//  ClerkAuthProvider.swift
//  AI Archeology
//
//  Real (and mock) implementations of `AuthProviding` for AIA-0340.
//

import Foundation
import OSLog
import ClerkKit

/// Production ``AuthProviding`` backed by the Clerk iOS SDK.
///
/// `@MainActor` (not an `actor`) on purpose: `Clerk.shared` is itself a
/// `@MainActor @Observable` singleton, so every call here is already main-actor
/// work. Wrapping it in an `actor` would only add hops. Named `…Provider`
/// rather than `…Service` so the Harmonize "services are not @MainActor" rule
/// does not apply (see `ArchitectureTests.testServicesAreNotMainActor`).
@MainActor
final class ClerkAuthProvider: AuthProviding {

    /// Info.plist key, injected from `CLERK_PUBLISHABLE_KEY` in `Secrets.xcconfig`.
    static let publishableKey: String =
        Bundle.main.object(forInfoDictionaryKey: "ClerkPublishableKey") as? String ?? ""

    /// `publicMetadata` flag that grants access during the v1 allowlist phase.
    private static let accessMetadataKey = "access"

    /// Configure the Clerk SDK. Call once, at app launch, before reading `Clerk.shared`.
    static func configure() {
        guard !publishableKey.isEmpty else {
            LoggingPolicy.error(
                "CLERK_PUBLISHABLE_KEY missing — Clerk not configured. Check Secrets.xcconfig.",
                logger: .configuration
            )
            return
        }
        Clerk.configure(publishableKey: publishableKey)
    }

    var isSignedIn: Bool {
        Clerk.shared.user != nil
    }

    func prepare() async {
        // `Clerk.configure` loads the cached client/session synchronously, so the
        // persisted signed-in state is already available here. `validateSession`
        // performs the authoritative server round-trip.
    }

    func validateSession() async throws {
        do {
            try await Clerk.shared.refreshClient()
        } catch let urlError as URLError {
            // Genuinely offline / server unreachable — fail closed to "needs
            // connection" rather than signing the user out on a transient blip.
            LoggingPolicy.warning(
                "Session validation could not reach Clerk: \(urlError.localizedDescription)",
                logger: .networking
            )
            throw AuthValidationError.offline
        } catch let apiError as ClerkAPIError {
            // Server reachable but rejected the session (banned/revoked/expired).
            // This is NOT an offline condition — route to sign-in, not "retry".
            LoggingPolicy.info(
                "Clerk rejected session refresh (\(apiError.code)) — signing out",
                logger: .state
            )
            throw AuthValidationError.noValidSession
        } catch {
            // Unknown failure — be conservative and treat as offline (retryable)
            // rather than signing the user out spuriously.
            LoggingPolicy.warning(
                "Session validation failed: \(error.localizedDescription)",
                logger: .networking
            )
            throw AuthValidationError.offline
        }

        // Server reachable: require an ACTIVE session. `Clerk.shared.user` can be
        // derived from a non-active session object (expired/revoked/ended/pending),
        // so checking the session status — not just user presence — is what keeps a
        // stale or revoked session from opening the app.
        guard Clerk.shared.session?.status == .active, Clerk.shared.user != nil else {
            throw AuthValidationError.noValidSession
        }
    }

    func hasAccess() -> Bool {
        guard let access = Clerk.shared.user?.publicMetadata?[Self.accessMetadataKey] else {
            return false
        }
        // Accept either documented convention for the allowlist flag:
        // boolean `true`, or the string `"allowed"` / `"true"`. Set this per user
        // in the Clerk Dashboard (Users → Metadata → Public).
        if access.boolValue == true { return true }
        if let str = access.stringValue?.lowercased() {
            return str == "allowed" || str == "true"
        }
        return false
    }

    func signOut() async {
        do {
            try await Clerk.shared.auth.signOut()
        } catch {
            LoggingPolicy.warning("Sign-out failed: \(error.localizedDescription)", logger: .state)
        }
    }

    func deleteAccount() async throws {
        _ = try await Clerk.shared.user?.delete()
    }
}

#if DEBUG
/// In-memory ``AuthProviding`` for UI tests and SwiftUI previews. Compiled out of
/// Release/TestFlight builds (`#if DEBUG`) so the auth bypass cannot ship.
///
/// Selected by `DependencyContainer` under `UI_TESTING`, optionally overridden by
/// the `-mockAuthGate <state>` launch argument.
@MainActor
final class MockAuthProvider: AuthProviding {
    /// Which terminal gate the mock should resolve to.
    enum Outcome: String {
        case ready
        case signedOut
        case locked
        case offline
    }

    private var outcome: Outcome

    init(outcome: Outcome = .ready) {
        self.outcome = outcome
    }

    /// Parse `-mockAuthGate <state>` from the launch arguments, defaulting to `.ready`
    /// so existing UI tests bypass the gate straight into the app.
    static func fromLaunchArguments() -> MockAuthProvider {
        let args = ProcessInfo.processInfo.arguments
        if let idx = args.firstIndex(of: "-mockAuthGate"),
           idx + 1 < args.count,
           let parsed = Outcome(rawValue: args[idx + 1]) {
            return MockAuthProvider(outcome: parsed)
        }
        return MockAuthProvider(outcome: .ready)
    }

    /// Mutate the simulated outcome between refreshes (tests/previews only).
    func setOutcomeForTesting(_ newOutcome: Outcome) {
        outcome = newOutcome
    }

    var isSignedIn: Bool { outcome != .signedOut }

    func prepare() async {}

    func validateSession() async throws {
        switch outcome {
        case .offline: throw AuthValidationError.offline
        case .signedOut: throw AuthValidationError.noValidSession
        case .ready, .locked: return
        }
    }

    func hasAccess() -> Bool { outcome == .ready }

    func signOut() async { outcome = .signedOut }

    func deleteAccount() async throws { outcome = .signedOut }
}
#endif
