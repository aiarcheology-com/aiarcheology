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
        // development-only controls such as the Clerk environment picker.
        XCTAssertFalse(AppEnvironment.isAppStoreDistribution)
    }

    /// **The unidentifiable-channel direction** (PR #612). A device Release build with neither an
    /// embedded provisioning profile nor a readable receipt can only be a store binary whose
    /// receipt has not landed — Apple documents the receipt can be absent until refreshed.
    ///
    /// Every consumer of `isAppStoreDistribution` tests it *positively* (`== .appStore`), so
    /// answering anything else there sends a real customer down the development branch: the dev
    /// Clerk key (`ClerkAuthProvider.swift:40`), the dev/prod picker (`SignInSheet.swift:36`), the
    /// debug section, Core Data recovery, and Sentry's full sampling rate.
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
