//
//  ClerkAuthProvider.swift
//  AI Archeology
//
//  Real (and mock) implementations of `AuthProviding` for AIA-0340.
//

import Foundation
import OSLog
import ClerkKit

/// Which Clerk instance non-App-Store builds talk to. App Store builds always use
/// `.production` and ignore any stored override. Lets testers/QA validate the
/// production instance from a TestFlight build before the public release.
enum ClerkEnvironment: String, CaseIterable {
    case development
    case production
}

/// Production ``AuthProviding`` backed by the Clerk iOS SDK.
///
/// `@MainActor` (not an `actor`) on purpose: `Clerk.shared` is itself a
/// `@MainActor @Observable` singleton, so every call here is already main-actor
/// work. Wrapping it in an `actor` would only add hops. Named `…Provider`
/// rather than `…Service` so the Harmonize "services are not @MainActor" rule
/// does not apply (see `ArchitectureTests.testServicesAreNotMainActor`).
@MainActor
final class ClerkAuthProvider: AuthProviding {

    /// The Clerk publishable key for the current distribution channel: the
    /// production (`pk_live_`) instance for App Store builds, the dev/test
    /// (`pk_test_`) instance everywhere else (TestFlight, AdHoc, dev, simulator).
    /// Per the v1 model, testers run on the dev instance and production users on
    /// the production instance — both keys are public, so both ship in the binary
    /// and are selected by the receipt type.
    static var publishableKey: String {
        // App Store is always production and ignores the override. Non-App-Store
        // builds (TestFlight/AdHoc/dev) honor the selected environment so QA can
        // validate production before release.
        if AppEnvironment.isAppStoreDistribution { return liveKey }
        return selectedEnvironment == .production ? liveKey : testKey
    }

    /// Dev/test instance key, injected from `CLERK_PUBLISHABLE_KEY` in `Secrets.xcconfig`.
    private static let testKey =
        Bundle.main.object(forInfoDictionaryKey: "ClerkPublishableKey") as? String ?? ""

    /// Production instance key, injected from `CLERK_PUBLISHABLE_KEY_LIVE`.
    private static let liveKey =
        Bundle.main.object(forInfoDictionaryKey: "ClerkPublishableKeyLive") as? String ?? ""

    private static let environmentDefaultsKey = "clerk.selectedEnvironment"

    /// The Clerk instance selected for non-App-Store builds (persisted). Defaults to
    /// `.development` so testers stay on the dev instance unless they opt into prod.
    static var selectedEnvironment: ClerkEnvironment {
        get {
            let raw = UserDefaults.standard.string(forKey: environmentDefaultsKey)
            return raw.flatMap(ClerkEnvironment.init(rawValue:)) ?? .development
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: environmentDefaultsKey) }
    }

    /// Switch the active Clerk instance at runtime (non-App-Store only). Reconfigures
    /// the SDK with the new instance's key, which clears the current session; the gate's
    /// `ClerkSessionWatcher` then routes the user to sign in on the new instance.
    static func switchEnvironment(to environment: ClerkEnvironment) async {
        guard AppEnvironment.isAppStoreDistribution == false else { return }
        let targetKey = environment == .production ? liveKey : testKey
        // Only switch if the target instance's key is actually present (e.g. a local
        // build without CLERK_PUBLISHABLE_KEY_LIVE can't switch to production). Persist
        // only on success so we don't leave the app pointed at an unconfigured instance.
        guard targetKey.hasPrefix("pk_") else {
            LoggingPolicy.warning(
                "No \(environment.rawValue) Clerk key available — cannot switch environment.",
                logger: .configuration
            )
            return
        }
        do {
            try await Clerk.reconfigure(publishableKey: targetKey)
            // Persist only after a successful reconfigure, so a failed switch never leaves
            // the app pointed at an environment Clerk isn't actually configured for.
            selectedEnvironment = environment
        } catch {
            LoggingPolicy.error("Clerk reconfigure failed: \(error.localizedDescription)", logger: .configuration)
        }
    }

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
    /// Not reachable from UI tests: this provider is configured purely from launch arguments, and
    /// no `-mockDisplayName` flag is parsed. Add one only when a UI test actually needs it.
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

    func signOut() async { outcome = .signedOut }

    func deleteAccount() async throws { outcome = .signedOut }
}
#endif
