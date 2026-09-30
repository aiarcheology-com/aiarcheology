//
//  AppEnvironmentTests.swift
//  AI ArcheologyTests
//
//  Created by AI Assistant on 05.12.25.
//

import XCTest
@testable import ML_Browser

// MARK: - AppEnvironment Tests

final class AppEnvironmentTests: XCTestCase {
    
    // MARK: - Compile-time Configuration Tests
    
    func test_isDebugConfiguration_returnsBool() {
        // In test environment, DEBUG is typically defined
        let isDebug = AppEnvironment.isDebugConfiguration
        
        // Just verify it returns a Bool without crashing
        XCTAssertTrue(isDebug || !isDebug)
        
        #if DEBUG
        XCTAssertTrue(isDebug)
        #else
        XCTAssertFalse(isDebug)
        #endif
    }
    
    func test_isDebugConfiguration_isConstant() {
        let first = AppEnvironment.isDebugConfiguration
        let second = AppEnvironment.isDebugConfiguration
        
        XCTAssertEqual(first, second)
    }
    
    // MARK: - Runtime Detection Tests
    
    func test_isRunningUnderAnyTests_returnsTrueInTestEnvironment() {
        // When running unit tests, XCTestConfigurationFilePath should be set
        let isRunningTests = AppEnvironment.isRunningUnderAnyTests
        
        XCTAssertTrue(isRunningTests, "Should detect that we're running under XCTest")
    }
    
    func test_isRunningUITests_returnsFalseInUnitTestEnvironment() {
        // Unit tests should not have UI_TESTING environment variable
        let isRunningUITests = AppEnvironment.isRunningUITests
        
        XCTAssertFalse(isRunningUITests, "Unit tests should not be detected as UI tests")
    }
    
    func test_isRunningUnitTests_returnsTrueInUnitTestEnvironment() {
        // We're running unit tests, so this should be true
        let isRunningUnitTests = AppEnvironment.isRunningUnitTests
        
        XCTAssertTrue(isRunningUnitTests, "Should detect unit test environment")
    }
    
    func test_isRunningUITests_and_isRunningUnitTests_areMutuallyExclusive() {
        let isUI = AppEnvironment.isRunningUITests
        let isUnit = AppEnvironment.isRunningUnitTests
        
        // When running tests, exactly one should be true (or neither if not in test)
        if AppEnvironment.isRunningUnderAnyTests {
            XCTAssertNotEqual(isUI, isUnit, "UI and Unit test flags should be mutually exclusive")
        }
    }

    // MARK: - Distribution Detection

    func test_simulatorIsNeverTreatedAsAppStoreDistribution() throws {
        try XCTSkipUnless(AppEnvironment.isSimulator, "Requires an iOS Simulator runtime")

        // StoreKit's local testing configuration can create a receipt called `receipt`,
        // identical to an App Store receipt by filename. A Simulator must still retain
        // development-only behaviour: Settings' debug section, full Sentry sampling and
        // StoreKit sandbox detection. (The Clerk environment picker used to be on this
        // list; it is now `#if DEBUG` and reads `BackendEnvironment` — AIA-0791.)
        XCTAssertFalse(AppEnvironment.isAppStoreDistribution)
    }

    /// **The unidentifiable-channel direction** (PR #612). A device Release build with neither an
    /// embedded provisioning profile nor a readable receipt can only be a store binary whose
    /// receipt has not landed — Apple documents the receipt can be absent until refreshed.
    ///
    /// Every consumer of `isAppStoreDistribution` tests it *positively* (`== .appStore`), so
    /// answering anything else there sends a real customer down the development branch: the debug
    /// section, `DataController`'s mapping-model choice and recovery paths, and Sentry's full
    /// sampling rate. Auth used to be on that list; AIA-0791 moved it to `BackendEnvironment`,
    /// because this inference answers `.appStore` for an iOS-app-on-Mac install and for a phone
    /// restored from backup — right for a cosmetic decision, wrong for where a user's data lives.
    ///
    /// `.unknown` must therefore mean **only** "simulator" — which is what its own doc comment
    /// claims. This asserts that claim rather than trusting it, and fails if the fallback is ever
    /// restored to `.unknown`.
    func test_unknownChannel_meansSimulatorOnly() {
        // On the simulator the early return is the *only* producer of `.unknown`. Off it, no
        // reachable path yields `.unknown` at all — the fallback now answers `.appStore`.
        if AppEnvironment.isSimulator {
            XCTAssertEqual(AppEnvironment.distributionChannel, .unknown)
        } else {
            XCTAssertNotEqual(
                AppEnvironment.distributionChannel, .unknown,
                "A device build must never report .unknown — it would take every production gate "
                    + "down its development branch."
            )
        }
    }

    /// The badge and the production gates read the same unidentifiable state in *opposite*
    /// directions, and both are safe. Pinned together so a later edit cannot quietly align them.
    func test_unidentifiableChannel_isProductionForGates_andUndecoratedForTheBadge() {
        XCTAssertFalse(AppEnvironment.decoratesControls(on: .unknown), "never decorate what we cannot identify")
        XCTAssertFalse(AppEnvironment.decoratesControls(on: .appStore), "never decorate production")
    }

    // MARK: - Environment Variable Detection Tests
    
    func test_XCTestConfigurationFilePath_isSetInTestEnvironment() {
        let env = ProcessInfo.processInfo.environment
        let hasTestConfig = env["XCTestConfigurationFilePath"] != nil
        
        XCTAssertTrue(hasTestConfig, "XCTestConfigurationFilePath should be set when running tests")
    }
}

// MARK: - Interface (AIA-0991)

/// `-interface`: which interface a launch of the Debug app asks for, and when that request stops it.
/// `#if DEBUG` only, like `AppInterface` itself: the unit suite always builds against development, so
/// the non-development rule is covered through `resolve`'s `backend` parameter.
#if DEBUG
final class AppInterfaceTests: XCTestCase {

    private let executable = "/path/to/ML Browser"
    private let noMarkers: [String: String] = [:]

    private func resolve(_ arguments: [String], environment: [String: String] = [:], backend: BackendEnvironment = .development) -> Result<AppInterface, AppInterface.Refusal> {
        AppInterface.resolve(arguments: [executable] + arguments, environment: environment, backend: backend)
    }

    private func assertRefused(_ result: Result<AppInterface, AppInterface.Refusal>, file: StaticString = #filePath, line: UInt = #line) {
        if case .success(let interface) = result {
            XCTFail("expected a refusal, got \(interface)", file: file, line: line)
        }
    }

    func test_noInterfaceArgument_isTheUI() {
        XCTAssertEqual(resolve([]), .success(.ui))
    }

    /// A normal UI launch is untouched, even under the UI tests' marker and with stale headless
    /// options on the command line: nothing asks for headless, so nothing is refused.
    func test_uiLaunchWithStaleHeadlessOptionsUnderTestMarkers_isTheUI() {
        let stale = ["-headlessFlag", "bogus", "-headlessStagedImage", "../x", "-mockSubscription", "nonsense"]
        XCTAssertEqual(resolve(stale, environment: ["UI_TESTING": "1"]), .success(.ui))
        XCTAssertEqual(resolve(stale, environment: ["XCTestConfigurationFilePath": "/tmp/x"]), .success(.ui))
        XCTAssertEqual(resolve(stale), .success(.ui))
    }

    func test_interfaceHeadless_isHeadless() {
        XCTAssertEqual(resolve(["-interface", "headless"]), .success(.headless))
    }

    func test_interfaceUI_isTheUI() {
        XCTAssertEqual(resolve(["-interface", "ui"]), .success(.ui))
    }

    func test_lastInterfaceArgumentWins() {
        XCTAssertEqual(resolve(["-interface", "headless", "-interface", "ui"]), .success(.ui))
        XCTAssertEqual(resolve(["-interface", "ui", "-interface", "headless"]), .success(.headless))
    }

    func test_interfaceWithoutAValue_isRefused() {
        assertRefused(resolve(["-interface"]))
    }

    func test_interfaceFollowedByAnotherOption_isRefused() {
        assertRefused(resolve(["-interface", "-headlessFlag", "isPaymentsEnabled=true"]))
    }

    func test_unknownInterface_isRefused() {
        assertRefused(resolve(["-interface", "Headless"]))
        assertRefused(resolve(["-interface", "cli"]))
    }

    /// The scheme hands its launch arguments to the test hosts, so a left-on `-interface headless`
    /// must stop a test run rather than run the host as a server or wipe data headlessly.
    func test_headlessInATestHost_isRefused() {
        assertRefused(resolve(["-interface", "headless"], environment: ["XCTestConfigurationFilePath": "/tmp/x"]))
        assertRefused(resolve(["-interface", "headless"], environment: ["UI_TESTING": "1"]))
    }

    /// AIA-1007: the kit's `HeadlessLaunch` reads `-headlessAppMoves` in headless mode, so a malformed
    /// one stops a headless launch at the same point as a malformed `-interface`; a UI launch never
    /// reads it, and a production build reads neither.
    func test_malformedAppMoves_stopsOnlyAHeadlessLaunch() {
        assertRefused(resolve(["-interface", "headless", "-headlessAppMoves", "sometimes"]))
        XCTAssertEqual(resolve(["-interface", "headless", "-headlessAppMoves", "off"]), .success(.headless))
        XCTAssertEqual(resolve(["-headlessAppMoves", "sometimes"]), .success(.ui))
        XCTAssertEqual(resolve(["-interface", "headless", "-headlessAppMoves", "sometimes"], backend: .production), .success(.ui))
    }

    /// A Debug build against production has no headless mode: `-interface` is ignored unread, so
    /// even a value that a development build refuses cannot stop it.
    func test_nonDevelopmentBackend_ignoresInterfaceUnread() {
        XCTAssertEqual(resolve(["-interface", "headless"], backend: .production), .success(.ui))
        XCTAssertEqual(resolve(["-interface", "nonsense"], backend: .production), .success(.ui))
        XCTAssertEqual(resolve(["-interface"], backend: .production), .success(.ui))
        XCTAssertEqual(resolve(["-interface", "headless"], environment: ["UI_TESTING": "1"], backend: .production), .success(.ui))
    }

    /// This process is the unit-test host, launched without `-interface`.
    func test_theUnitTestHostIsNotInHeadlessMode() {
        XCTAssertFalse(AppEnvironment.isHeadlessMode)
    }
}
#endif
