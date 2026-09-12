//
//  BackendEnvironment.swift
//  AI Archeology
//
//  Which backend a build talks to, decided once at build time (AIA-0791).
//

import Foundation
#if DEBUG
// `switch(to:)` reconfigures Clerk, so the DEBUG half of this file needs the SDK. The rest of the
// type is pure Foundation — the import is scoped so a Release build never pulls it in for nothing.
import ClerkKit
#endif

/// The backend a build talks to: a **pair** of a Clerk instance and a findings Worker.
///
/// The pair is the whole point. Each Worker pins exactly one Clerk issuer, so a build that signs
/// in against one instance and uploads to the other is refused on every request. That is what
/// shipped in 1.0.8 build 1005: the Clerk key was chosen from the distribution channel and the
/// Worker from a `UserDefaults` value that App-Store-classified builds could never write, so they
/// disagreed permanently and cloud sync was dead.
///
/// Fixed at **build time** from `AIA_BACKEND_ENVIRONMENT`, never inferred at runtime.
/// `AppEnvironment.distributionChannel` is not reliable enough to carry a decision about where a
/// user's data lives: an iOS-app-on-Mac install has no receipt at that path at all, and an iPhone
/// restored from backup has none until `SKReceiptRefreshRequest` completes.
///
/// It stays in use elsewhere, and not all of that is cosmetic — besides Settings' debug section,
/// Sentry sampling and StoreKit sandbox detection, `DataController` uses it to choose Core Data
/// mapping-model inference and to gate destructive store-destruction recovery. Those are
/// pre-existing and out of scope here; this type neither fixes nor worsens them. What it does fix
/// is that no decision about *which backend holds user data* goes through that inference any more.
enum BackendEnvironment: String, CaseIterable, Sendable {
    case development
    case production
}

extension BackendEnvironment {

    /// The `Info.plist` key carrying `$(AIA_BACKEND_ENVIRONMENT)`.
    ///
    /// Diagnostics and artifact assertions only — `deliver.sh` and `ci_post_xcodebuild.sh` read it
    /// from a built `.app` where no Swift runs. It is never the source of truth in the app; that
    /// is `configured` below. Both are expansions of the same build setting, so they cannot drift.
    static let infoDictionaryKey = "BackendEnvironment"

    /// What the binary was built for.
    ///
    /// Non-optional by construction: an unset, misspelled or non-identifier value defines neither
    /// compilation condition and the `#else` below fails the build. There is deliberately no
    /// runtime fallback — falling back to `development` is the defect this replaces, and falling
    /// back to `production` would put test findings in real users' bucket.
    ///
    /// The compilation condition cannot catch *every* bad value on its own:
    /// `SWIFT_ACTIVE_COMPILATION_CONDITIONS` is a whitespace-separated list, so
    /// `AIA_BACKEND_ENVIRONMENT="development production"` still defines
    /// `AIA_BACKEND_ENV_development` and compiles clean. The "Validate backend environment" run
    /// script phase on the MLBrowser target does the exact-string comparison that catches that.
    #if AIA_BACKEND_ENV_production
    static let configured: BackendEnvironment = .production
    #elseif AIA_BACKEND_ENV_development
    static let configured: BackendEnvironment = .development
    #else
    #error("AIA_BACKEND_ENVIRONMENT must be set to exactly 'development' or 'production'. See AUTH-SUBSCRIPTION.md, 'Which backend a build talks to'.")
    #endif

    #if DEBUG
    /// Points a Debug build at the other backend without rebuilding, for validating production
    /// from a simulator. `#if DEBUG`, so it cannot exist in TestFlight or App Store builds — the
    /// switcher this replaces was live in Release, which is how the pair came apart.
    ///
    /// `private(set)`: an open setter would let a caller move the Worker while Clerk stayed
    /// configured for the other instance — the exact mismatched pair this ticket removes. The
    /// only way to change it is `switch(to:)`, which reconfigures Clerk first.
    @MainActor private(set) static var override: BackendEnvironment?

    /// Moves both halves of the pair, or neither.
    ///
    /// Returns `false` (and changes nothing) when the target instance's key is missing or the
    /// reconfigure fails. `Clerk.configure` traps on a malformed key in DEBUG
    /// (`ClerkAuthProvider.configure()`), and a local build may legitimately lack the live key.
    /// Serialises `switch(to:)`. `Clerk.reconfigure` rejects a concurrent reconfigure, and a fast
    /// double-tap on the segmented picker can start a second switch while the first is still
    /// awaiting — which would leave the picker and the active backend disagreeing.
    @MainActor private static var isSwitching = false

    @MainActor
    static func `switch`(to environment: BackendEnvironment) async -> Bool {
        // The re-entrancy guard comes FIRST, before the already-there check. The other order has
        // a race: with a switch to production in flight, `current` still reads development, so a
        // second tap back to development would take the already-there path and report success —
        // and then the first switch lands on production under a control that says development.
        // Refuse rather than queue; the caller resynchronises from `current` afterwards.
        guard isSwitching == false else { return false }
        // Already there: report success so the caller does not resynchronise the control away
        // from a value that is in fact correct.
        guard environment != current else { return true }
        isSwitching = true
        defer { isSwitching = false }

        let key = ClerkAuthProvider.publishableKey(for: environment)
        guard key.hasPrefix("pk_") else {
            LoggingPolicy.warning(
                "No \(environment.rawValue) Clerk key available — cannot switch backend.",
                logger: .configuration
            )
            return false
        }
        do {
            // Clears the current session, which is required: a session from the other instance is
            // exactly what the other Worker rejects.
            try await Clerk.reconfigure(publishableKey: key)
            override = environment
            // The launch line would otherwise go stale and the support log would contradict the
            // running app — and that log is the only textual record of the environment.
            LoggingPolicy.info("Backend environment: \(environment.rawValue) (switched)", logger: .configuration)
            ProductionBannerWindow.update()
            return true
        } catch {
            LoggingPolicy.error("Clerk reconfigure failed: \(error.localizedDescription)", logger: .configuration)
            return false
        }
    }
    #endif

    /// The environment in force.
    @MainActor static var current: BackendEnvironment {
        #if DEBUG
        if let override { return override }
        #endif
        return configured
    }
}
