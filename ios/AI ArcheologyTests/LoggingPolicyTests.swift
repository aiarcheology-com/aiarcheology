//
//  LoggingPolicyTests.swift
//  AI ArcheologyTests
//
//  Created by AI Assistant on 25.11.25.
//

import XCTest
@testable import ML_Browser

// MARK: - LoggingError Tests

final class LoggingErrorTests: XCTestCase {
    
    // MARK: - Error Description Tests
    
    func testAssertionFailure_ErrorDescription() {
        let error = LoggingError.assertionFailure("Test message")
        XCTAssertEqual(error.errorDescription, "Assertion failure: Test message")
    }
    
    func testUnexpectedNil_ErrorDescription() {
        let error = LoggingError.unexpectedNil("some context")
        XCTAssertEqual(error.errorDescription, "Unexpected nil value: some context")
    }
    
    func testInvalidState_ErrorDescription() {
        let error = LoggingError.invalidState("state description")
        XCTAssertEqual(error.errorDescription, "Invalid state: state description")
    }
    
    // MARK: - LocalizedError Conformance
    
    func testAssertionFailure_IsLocalizedError() {
        let error: Error = LoggingError.assertionFailure("Test")
        XCTAssertNotNil(error.localizedDescription)
        XCTAssertTrue(error.localizedDescription.contains("Assertion failure"))
    }
    
    func testUnexpectedNil_IsLocalizedError() {
        let error: Error = LoggingError.unexpectedNil("context")
        XCTAssertNotNil(error.localizedDescription)
        XCTAssertTrue(error.localizedDescription.contains("Unexpected nil"))
    }
    
    func testInvalidState_IsLocalizedError() {
        let error: Error = LoggingError.invalidState("description")
        XCTAssertNotNil(error.localizedDescription)
        XCTAssertTrue(error.localizedDescription.contains("Invalid state"))
    }
    
    // MARK: - Empty Message Tests
    
    func testAssertionFailure_EmptyMessage() {
        let error = LoggingError.assertionFailure("")
        XCTAssertEqual(error.errorDescription, "Assertion failure: ")
    }
    
    func testUnexpectedNil_EmptyContext() {
        let error = LoggingError.unexpectedNil("")
        XCTAssertEqual(error.errorDescription, "Unexpected nil value: ")
    }
    
    func testInvalidState_EmptyDescription() {
        let error = LoggingError.invalidState("")
        XCTAssertEqual(error.errorDescription, "Invalid state: ")
    }
    
    // MARK: - Special Characters Tests
    
    func testAssertionFailure_WithSpecialCharacters() {
        let error = LoggingError.assertionFailure("Line 1\nLine 2\tTabbed")
        XCTAssertTrue(error.errorDescription?.contains("Line 1") ?? false)
        XCTAssertTrue(error.errorDescription?.contains("Line 2") ?? false)
    }
    
    func testUnexpectedNil_WithUnicode() {
        let error = LoggingError.unexpectedNil("Variable: 变量 🎉")
        XCTAssertTrue(error.errorDescription?.contains("变量") ?? false)
        XCTAssertTrue(error.errorDescription?.contains("🎉") ?? false)
    }
    
    // MARK: - Equality by Description (since enum cases with associated values)
    
    func testDifferentCases_HaveDifferentDescriptions() {
        let assertion = LoggingError.assertionFailure("test")
        let unexpectedNil = LoggingError.unexpectedNil("test")
        let invalidState = LoggingError.invalidState("test")
        
        XCTAssertNotEqual(assertion.errorDescription, unexpectedNil.errorDescription)
        XCTAssertNotEqual(assertion.errorDescription, invalidState.errorDescription)
        XCTAssertNotEqual(unexpectedNil.errorDescription, invalidState.errorDescription)
    }
}

// MARK: - LoggingPolicy Tests

final class LoggingPolicyTests: XCTestCase {
    
    // Note: Most LoggingPolicy methods call Logger methods which we can't easily verify
    // without mocking. These tests verify the methods don't crash.
    
    func testDebug_DoesNotCrash() {
        // Should not throw or crash
        LoggingPolicy.debug("Test debug message")
    }
    
    func testInfo_DoesNotCrash() {
        LoggingPolicy.info("Test info message")
    }
    
    func testWarning_DoesNotCrash() {
        LoggingPolicy.warning("Test warning message")
    }
    
    func testError_WithoutError_DoesNotCrash() {
        LoggingPolicy.error("Test error message")
    }
    
    func testError_WithError_DoesNotCrash() {
        let testError = NSError(domain: "TestDomain", code: 42, userInfo: nil)
        LoggingPolicy.error("Test error message", error: testError)
    }
    
    func testFault_DoesNotCrash() {
        LoggingPolicy.fault("Test fault message")
    }
    
    func testDebugPrivate_DoesNotCrash() {
        LoggingPolicy.debugPrivate("Test private message")
    }
    
    // Note: criticalFailure and assertionFailure are not tested as they terminate/assert
}

