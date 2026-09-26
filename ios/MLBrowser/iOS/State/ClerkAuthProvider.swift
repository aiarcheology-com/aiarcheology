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

    /// The Clerk publishable key for an environment. Pure and injectable, so the pairing with the
    /// findings Worker is testable without a bundle — non-archive CI builds ship no Clerk keys.
    ///
    /// Both keys are public and both ship in the binary; which one is *used* is fixed at build
    /// time by `AIA_BACKEND_ENVIRONMENT`, never inferred from the receipt. Receipt inference is
    /// what broke this: it fails closed to `.appStore` for an iOS-app-on-Mac install and for an
    /// iPhone restored from backup, and the findings Worker was chosen from a different value
    /// entirely, so the two disagreed permanently (AIA-0791).
    nonisolated static func publishableKey(
        for environment: BackendEnvironment,
        testKey: String = ClerkAuthProvider.testKey,
        liveKey: String = ClerkAuthProvider.liveKey
    ) -> String {
        switch environment {
        case .development: return testKey
        case .production: return liveKey
        }
    }

    /// The key for the environment in force. Non-optional: `BackendEnvironment` cannot be
    /// unresolved, because an invalid `AIA_BACKEND_ENVIRONMENT` fails the build (AIA-0791).
    static var publishableKey: String {
        publishableKey(for: BackendEnvironment.current)
    }

    /// Dev/test instance key, injected from `CLERK_PUBLISHABLE_KEY` in `Secrets.xcconfig`.
    ///
    /// `nonisolated` so the pure seam above can default to it and so tests can skip themselves
    /// when this build ships no keys.
    nonisolated static let testKey =
        Bundle.main.object(forInfoDictionaryKey: "ClerkPublishableKey") as? String ?? ""

    /// Production instance key, injected from `CLERK_PUBLISHABLE_KEY_LIVE`.
    nonisolated static let liveKey =
        Bundle.main.object(forInfoDictionaryKey: "ClerkPublishableKeyLive") as? String ?? ""

    /// Configure the Clerk SDK. Call once, at app launch, before reading `Clerk.shared`.
    static func configure() {
        // Real Clerk publishable keys are `pk_test_…` / `pk_live_…`. Reject anything else
        // (empty, or an unexpanded `$(CLERK_PUBLISHABLE_KEY)` placeholder) so we never hand
        // Clerk an invalid key — `Clerk.configure` traps on a malformed key in DEBUG.
        guard publishableKey.hasPrefix("pk_") else {
            LoggingPolicy.error(
                "No valid Clerk publishable key (CLERK_PUBLISHABLE_KEY / CLERK_PUBLISHABLE_KEY_LIVE) — Clerk not configured. Check Secrets.xcconfig / CI env.",
                logger: .configuration
            )
            return
        }
        Clerk.configure(publishableKey: publishableKey)
    }

    var isSignedIn: Bool {
        Clerk.shared.user != nil
    }

    /// The Clerk **user** id (`user_…`), which is server-assigned and identical for the same
    /// account on every device. Deliberately not `Clerk.shared.session?.id` (`sess_…`), which is
    /// per-device and would defeat the cross-device attribution it is used for (AIA-0437).
    var accountIdentifier: String? {
        Clerk.shared.user?.id
    }

    /// The account's name, preferring "First Last" and falling back to the username.
    ///
    /// Clerk populates these inconsistently depending on how the account was created — an OAuth
    /// sign-up usually has both names, an email/password one may have neither, and `username` is
    /// optional on the instance — so every field here can be absent. When they all are, this
    /// returns `nil` rather than reaching for `primaryEmailAddress`: see ``AuthProviding/displayName``
    /// for why an email address must never become a byline on a shared image.
    var displayName: String? {
        guard let user = Clerk.shared.user else { return nil }
        let fullName = [user.firstName, user.lastName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty.not }
            .joined(separator: " ")
        return Self.nameUnlessItIsAnAddress(fullName)
            ?? Self.nameUnlessItIsAnAddress(user.username)
    }

    /// The candidate, or `nil` if it is blank **or looks like an email address**.
    ///
    /// Not reading `primaryEmailAddress` is not enough to keep an address off a share card.
    /// `firstName`, `lastName` and `username` are free text: the user can type anything, and an
    /// OAuth provider may populate them from the account's email when it has nothing better. A
    /// profile with `firstName = "alice@example.com"` would otherwise be prefilled, saved, and
    /// rendered onto an image the user posts publicly — the exact outcome the no-email rule exists
    /// to prevent.
    ///
    /// The test is simply "contains an `@`", which is deliberately blunt: no human name contains
    /// one, so the false-positive cost is an empty field the user can type into, while the
    /// false-negative cost is a leaked address on a public graphic. Those are not comparable.
    static func nameUnlessItIsAnAddress(_ candidate: String?) -> String? {
        guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty.not,
              trimmed.contains("@").not
        else { return nil }
        return trimmed
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
                "Clerk rejected session refresh (\(apiError.code)) — treating session as invalid",
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

    func sessionToken() async throws -> String? {
        // `getToken()` serves a cached token and refreshes it when it is close to expiring, so
        // calling this per request is the intended usage rather than a wasteful one.
        guard let session = Clerk.shared.session else { return nil }
        return try await session.getToken()
    }

    func signOut() async {
        do {
            try await Clerk.shared.auth.signOut()
        } catch {
            LoggingPolicy.warning("Sign-out failed: \(error.localizedDescription)", logger: .state)
        }
    }

    func deleteAccount() async throws {
        // Fail explicitly rather than silently "succeeding" on a nil user — otherwise a
        // missing/revoked session would look like a completed deletion to the caller.
        guard let user = Clerk.shared.user else {
            throw AuthValidationError.noValidSession
        }
        _ = try await user.delete()
    }
}

#if DEBUG
/// A Clerk **test** email address: one whose local part ends in `+clerk_test` (AIA-0974).
///
/// Clerk's test mode sends no email to such an address and accepts the fixed code `424242` for it
/// (https://clerk.com/docs/guides/development/testing/test-emails-and-phones). Programmatic sign-in
/// accepts nothing else, so an automation run can never send a code to a real person's inbox or
/// sign in to a real account. Strict on purpose: `jane+clerk_test_x@…` is not a test address.
enum ClerkTestAddress {
    static func isValid(_ address: String) -> Bool {
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let local = parts[0]
        let domain = parts[1]
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        return local.hasSuffix("+clerk_test")
            && local.count > "+clerk_test".count
            && labels.count >= 2
            && labels.allSatisfy { $0.isEmpty.not }
            && address.contains(where: \.isWhitespace).not
    }
}

/// Why a programmatic sign-in did not produce a session. Carries no email address and no code.
enum ProgrammaticSignInError: LocalizedError, Equatable {
    /// The address is not a Clerk test address; nothing was sent.
    case notATestAddress
    /// This provider cannot sign in without a UI (the in-memory mock).
    case unsupported
    /// Clerk accepted the attempt but did not complete it.
    case incomplete
    /// Clerk completed the attempt, yet no signed-in user appeared.
    case noSession

    var errorDescription: String? {
        switch self {
        case .notATestAddress: "not a Clerk test address (the local part must end in +clerk_test)"
        case .unsupported: "this auth provider cannot sign in programmatically"
        case .incomplete: "Clerk did not complete the sign-in"
        case .noSession: "Clerk completed the sign-in but reports no signed-in user"
        }
    }
}

extension ClerkAuthProvider {
    /// Signs in to a Clerk test account with its email code, creating the account first if it does
    /// not exist — the same two paths Clerk's `AuthView` takes for an address it does or does not
    /// know (AIA-0974).
    ///
    /// The address is checked **before** anything touches Clerk. The sign-up branch fills the fields
    /// the development instance requires: fixed names, and a random password that is never stored,
    /// logged, or used again — every later sign-in uses the email code.
    func signIn(emailAddress: String, code: String) async throws {
        guard ClerkTestAddress.isValid(emailAddress) else {
            throw ProgrammaticSignInError.notATestAddress
        }
        do {
            let attempt = try await Clerk.shared.auth.signInWithEmailCode(emailAddress: emailAddress)
            guard try await attempt.verifyCode(code).status == .complete else {
                throw ProgrammaticSignInError.incomplete
            }
        } catch let error as ClerkAPIError where error.code == "form_identifier_not_found" {
            let signUp = try await Clerk.shared.auth.signUp(
                emailAddress: emailAddress,
                password: Self.throwawayPassword(),
                firstName: "Headless",
                lastName: "Automation"
            )
            let prepared = try await signUp.sendEmailCode()
            guard try await prepared.verifyEmailCode(code).status == .complete else {
                throw ProgrammaticSignInError.incomplete
            }
        }
        // The client that comes back with a completed attempt carries the new session. Should it
        // not have been applied, ask once; the gate refresh that follows would otherwise read
        // "signed out" and settle there.
        if Clerk.shared.user == nil {
            _ = try await Clerk.shared.refreshClient()
        }
        guard Clerk.shared.user != nil else {
            throw ProgrammaticSignInError.noSession
        }
    }

    /// 32 random bytes, base64-encoded. `SystemRandomNumberGenerator` is cryptographically secure on
    /// Apple platforms; the value exists only to satisfy the instance's sign-up requirement.
    private static func throwawayPassword() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
    }
}

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
        case offline
    }

    private var outcome: Outcome
    private var accountID: String?

    init(outcome: Outcome = .ready, accountID: String? = MockAuthProvider.defaultMockAccountID) {
        self.outcome = outcome
        self.accountID = accountID
    }

    /// Parse `-mockAuthGate <state>` from the launch arguments, defaulting to `.ready`
    /// so existing UI tests bypass the gate straight into the app. `-mockAccountID <id>` sets the
    /// simulated account; `UITestCase.launch(mockAccountID:)` passes it, which is how the
    /// account-scoped analytics choice is driven across a switch (AIA-0437).
    static func fromLaunchArguments() -> MockAuthProvider {
        let args = ProcessInfo.processInfo.arguments
        var accountID = defaultMockAccountID
        if let idx = args.firstIndex(of: "-mockAccountID"), idx + 1 < args.count {
            accountID = args[idx + 1]
        }
        if let idx = args.firstIndex(of: "-mockAuthGate"),
           idx + 1 < args.count,
           let parsed = Outcome(rawValue: args[idx + 1]) {
            return MockAuthProvider(outcome: parsed, accountID: accountID)
        }
        return MockAuthProvider(outcome: .ready, accountID: accountID)
    }

    /// Mutate the simulated outcome between refreshes (tests/previews only).
    func setOutcomeForTesting(_ newOutcome: Outcome) {
        outcome = newOutcome
    }

    /// Simulate an account switch without leaving the `.ready` outcome (tests/previews only) —
    /// the in-place A-to-B transition that publishes nothing on the gate.
    func setAccountIDForTesting(_ newAccountID: String?) {
        accountID = newAccountID
    }

    var isSignedIn: Bool { outcome != .signedOut }

    /// Shaped like a real Clerk id so anything that pattern-matches on it behaves the same.
    static let defaultMockAccountID = "user_mock0000000000000000000"

    /// `nil` while signed out, mirroring the real provider: there is no account to identify.
    var accountIdentifier: String? { outcome == .signedOut ? nil : accountID }

    /// A fixed stand-in name, `nil` while signed out — same shape as the real provider.
    /// Settable so a unit test can drive the "signed in but no usable name" case, which is a real
    /// Clerk state (see ``ClerkAuthProvider/displayName``) and the one where the author field must
    /// end up empty rather than showing something derived from the email address.
    ///
    /// **UI tests do see this value**, they just cannot choose it: `fromLaunchArguments()` defaults
    /// to `.ready`, so any UI test that opens the save sheet finds the Author field prefilled with
    /// the default below and saves a finding carrying that credit. A UI test asserting an *empty*
    /// author must therefore arrange `-mockAuthGate signedOut`, not assume nothing filled it in.
    /// Making the name itself selectable would need a `-mockDisplayName` flag, which no test needs yet.
    var displayName: String? { outcome == .signedOut ? nil : mockDisplayName }

    /// Overridable stand-in for the account's name (tests/previews only).
    var mockDisplayName: String? = "Mock Finder"

    func prepare() async {}

    func validateSession() async throws {
        switch outcome {
        case .offline: throw AuthValidationError.offline
        case .signedOut: throw AuthValidationError.noValidSession
        case .ready: return
        }
    }

    /// A syntactically plausible stand-in. Nothing in the app parses it; the Worker would reject
    /// it, which is correct — a UI test must never reach real storage.
    func sessionToken() async throws -> String? {
        switch outcome {
        case .signedOut: return nil
        case .offline: throw AuthValidationError.offline
        case .ready: return "mock.session.token"
        }
    }

    func signOut() async { outcome = .signedOut }

    func deleteAccount() async throws { outcome = .signedOut }

    /// Refuses rather than pretending (AIA-0974): a mock that "signed in" would let a headless run
    /// built without Clerk keys pass a sign-in scenario without ever reaching Clerk.
    func signIn(emailAddress: String, code: String) async throws {
        throw ProgrammaticSignInError.unsupported
    }
}
#endif
