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
    
    // MARK: - Environment Variable Detection Tests
    
    func test_XCTestConfigurationFilePath_isSetInTestEnvironment() {
        let env = ProcessInfo.processInfo.environment
        let hasTestConfig = env["XCTestConfigurationFilePath"] != nil
        
        XCTAssertTrue(hasTestConfig, "XCTestConfigurationFilePath should be set when running tests")
    }
}
