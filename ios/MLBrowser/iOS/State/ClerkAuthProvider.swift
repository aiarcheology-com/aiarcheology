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

    /// `publicMetadata` boolean flag that grants access during the v1 allowlist
    /// phase. Set per user in the Clerk Dashboard (Users → Metadata → Public) as
    /// `{ "hasAccess": true }`.
    private static let accessMetadataKey = "hasAccess"

    /// Configure the Clerk SDK. Call once, at app launch, before reading `Clerk.shared`.
    static func configure() {
        // Real Clerk publishable keys are `pk_test_…` / `pk_live_…`. Reject anything else
        // (empty, or an unexpanded `$(CLERK_PUBLISHABLE_KEY)` placeholder) so we never hand
        // Clerk an invalid key — `Clerk.configure` traps on a malformed key in DEBUG.
        guard publishableKey.hasPrefix("pk_") else {
            LoggingPolicy.error(
                "CLERK_PUBLISHABLE_KEY missing or invalid — Clerk not configured. Check Secrets.xcconfig / CI env.",
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
        Clerk.shared.user?.publicMetadata?[Self.accessMetadataKey]?.boolValue == true
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
