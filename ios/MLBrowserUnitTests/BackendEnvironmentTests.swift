//
//  BackendEnvironmentTests.swift
//  MLBrowserUnitTests
//
//  The one value that picks the Clerk instance and the findings Worker (AIA-0791).
//

import XCTest
@testable import ML_Browser

final class BackendEnvironmentTests: XCTestCase {

    /// The unit suite compiles against the app module in Debug. If this fails, a target-level
    /// `SWIFT_ACTIVE_COMPILATION_CONDITIONS` was written without `$(inherited)` and `DEBUG` has
    /// been dropped from the app module — which also removes `MockAuthProvider` and silently
    /// flips `DataController` and StoreKit sandbox detection, while compiling clean.
    func test_debugFlagSurvivesTheCompilationConditionChange() {
        XCTAssertTrue(AppEnvironment.isDebugConfiguration)
    }

    /// Environment-**neutral** on purpose. Asserting `configured == .development` would only ever
    /// exercise the Debug branch, because tests run in Debug — so a `#if AIA_BACKEND_ENV_production`
    /// branch that mistakenly said `.development` would pass here *and* pass both archive
    /// assertions, which read the independently expanded plist string rather than the compiled
    /// value. This compares the two expansions of the one setting against each other, so it is
    /// meaningful under either.
    /// A missing key is a **failure**, not a skip. Unlike the Clerk keys, `BackendEnvironment` is
    /// not a secret and is never withheld from a build — it is `$(AIA_BACKEND_ENVIRONMENT)` in
    /// `MLBrowser-Info.plist`, present on every path. Its absence would mean the plist entry was
    /// dropped or the setting failed to expand, which is precisely the integration defect this
    /// test exists to catch; skipping on it would make the test vacuous.
    func test_compiledValueMatchesTheInfoPlistValue() throws {
        let raw = try XCTUnwrap(
            Bundle(for: ClerkAuthProvider.self)
                .object(forInfoDictionaryKey: BackendEnvironment.infoDictionaryKey) as? String,
            "The app bundle carries no \(BackendEnvironment.infoDictionaryKey) key — the Info.plist entry or the build setting is missing."
        )
        XCTAssertEqual(
            raw.trimmingCharacters(in: .whitespacesAndNewlines),
            BackendEnvironment.configured.rawValue,
            "The compilation condition and the Info.plist disagree — they expand from one setting, so one consumer was edited by hand."
        )
    }
}

// MARK: - The pairing invariant

/// Each findings Worker pins exactly one Clerk issuer, so the Clerk key and the Worker URL must
/// move together. These fail if anyone reintroduces a second source of truth.
extension BackendEnvironmentTests {

    // The mapping, tested hermetically. Non-archive CI builds deliberately ship no Clerk keys
    // (ci_pre_xcodebuild.sh, "keeps the test workflows hermetic"), so the assertion that
    // matters must not depend on them.
    private static var testFixture: String { "pk_test_FIXTURE" }
    private static var liveFixture: String { "pk_live_FIXTURE" }

    func test_development_mapsToTheTestInstance() {
        XCTAssertEqual(
            ClerkAuthProvider.publishableKey(for: .development, testKey: Self.testFixture, liveKey: Self.liveFixture),
            Self.testFixture
        )
    }

    func test_production_mapsToTheLiveInstance() {
        XCTAssertEqual(
            ClerkAuthProvider.publishableKey(for: .production, testKey: Self.testFixture, liveKey: Self.liveFixture),
            Self.liveFixture
        )
    }

    func test_everyEnvironmentMapsToADistinctInstance() {
        // Catches the "both cases return the same thing" mutation, which the two above survive.
        let keys = BackendEnvironment.allCases.map {
            ClerkAuthProvider.publishableKey(for: $0, testKey: Self.testFixture, liveKey: Self.liveFixture)
        }
        XCTAssertEqual(Set(keys).count, BackendEnvironment.allCases.count)
    }

    func test_development_usesTheStagingWorker() {
        XCTAssertEqual(
            FindingsCloudEndpoint.baseURL(for: .development)?.host(),
            "aia-findings-staging.vladimir-slavik.workers.dev"
        )
    }

    func test_production_usesTheProductionWorker() {
        XCTAssertEqual(
            FindingsCloudEndpoint.baseURL(for: .production)?.host(),
            "aia-findings-production.vladimir-slavik.workers.dev"
        )
    }

    func test_everyEnvironmentUsesADistinctWorker() {
        let hosts = BackendEnvironment.allCases.compactMap { FindingsCloudEndpoint.baseURL(for: $0)?.host() }
        XCTAssertEqual(Set(hosts).count, BackendEnvironment.allCases.count)
    }

    /// The real keys, when this build has them. Skipped rather than failed on hermetic CI builds.
    ///
    /// The prefix alone is not enough: a `pk_live_` key for the *wrong* Clerk instance has the
    /// right prefix and still produces a 401 against the Worker, which pins an exact issuer.
    /// A Clerk publishable key is `pk_(test|live)_` + base64 of the frontend API host with a
    /// trailing `$`, so the key can be checked against the issuer the Worker actually pins,
    /// which is the property that matters.
    func test_realKeysBelongToTheInstanceTheWorkerPins() throws {
        try XCTSkipIf(
            ClerkAuthProvider.testKey.isEmpty || ClerkAuthProvider.liveKey.isEmpty,
            "This build ships no Clerk keys (non-archive CI action)."
        )
        XCTAssertEqual(Self.clerkHost(of: ClerkAuthProvider.testKey), "advanced-tetra-5.clerk.accounts.dev")
        XCTAssertEqual(Self.clerkHost(of: ClerkAuthProvider.liveKey), "clerk.aiarcheology.com")
    }

    /// Decodes the frontend API host a publishable key points at. Never log the key itself.
    private static func clerkHost(of key: String) -> String? {
        let body = key
            .replacingOccurrences(of: "pk_test_", with: "")
            .replacingOccurrences(of: "pk_live_", with: "")
        // Clerk omits base64 padding; Foundation requires it.
        let padded = body.padding(
            toLength: body.count + (4 - body.count % 4) % 4,
            withPad: "=",
            startingAt: 0
        )
        guard let data = Data(base64Encoded: padded), let decoded = String(data: data, encoding: .utf8)
        else { return nil }
        return decoded.hasSuffix("$") ? String(decoded.dropLast()) : decoded
    }
}

// MARK: - Headless mode (AIA-0970, AIA-0991)

#if DEBUG
extension BackendEnvironmentTests {

    /// Headless mode never moves the backend: the switch refuses before doing anything, even to the
    /// backend already in force, which it would otherwise report as success without touching Clerk.
    /// That first call is what makes the guard observable safely; the switch to production after it
    /// runs only once the guard is proven, so a broken guard cannot reconfigure Clerk here.
    @MainActor
    func test_switch_refusesInHeadlessMode() async {
        continueAfterFailure = false
        let before = BackendEnvironment.current

        let toCurrent = await BackendEnvironment.switch(to: before, isHeadlessMode: true)
        XCTAssertFalse(toCurrent, "headless mode must refuse even a switch to the backend in force")

        let toProduction = await BackendEnvironment.switch(to: .production, isHeadlessMode: true)
        XCTAssertFalse(toProduction)
        XCTAssertEqual(BackendEnvironment.current, before)
    }

    /// The control: outside headless mode, a switch to the backend in force succeeds without a
    /// reconfigure, so the refusal above is the guard and not some other early return.
    @MainActor
    func test_switch_toTheBackendInForce_succeedsOutsideHeadlessMode() async {
        let before = BackendEnvironment.current
        let result = await BackendEnvironment.switch(to: before, isHeadlessMode: false)
        XCTAssertTrue(result)
        XCTAssertEqual(BackendEnvironment.current, before)
    }
}
#endif
