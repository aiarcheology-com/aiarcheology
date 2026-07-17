//
//  LoggingPolicyTests.swift
//  AI ArcheologyTests
//
//  Tests for LoggingPolicy and LoggingError.
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
    
    override func setUp() {
        super.setUp()
        // Ensure Observability is started for tests
        // Using NoOp to avoid actual Sentry calls during tests
        if !Observability.isStarted {
            Observability.start(with: NoOpCrashReportingService())
        }
    }
    
    // Note: These tests verify the methods don't crash.
    // Full integration testing would require mocking Observability.
    
    // MARK: - Basic Logging Tests
    
    func testDebug_DoesNotCrash() {
        LoggingPolicy.debug("Test debug message")
    }
    
    func testDebug_WithCategory_DoesNotCrash() {
        LoggingPolicy.debug("Test debug message", category: "test.category")
    }
    
    func testInfo_DoesNotCrash() {
        LoggingPolicy.info("Test info message")
    }
    
    func testInfo_WithCategory_DoesNotCrash() {
        LoggingPolicy.info("Test info message", category: "navigation")
    }
    
    func testWarning_DoesNotCrash() {
        LoggingPolicy.warning("Test warning message")
    }
    
    func testWarning_WithCategory_DoesNotCrash() {
        LoggingPolicy.warning("Test warning message", category: "network")
    }
    
    func testError_WithoutError_DoesNotCrash() {
        LoggingPolicy.error("Test error message")
    }
    
    func testError_WithError_DoesNotCrash() {
        let testError = NSError(domain: "TestDomain", code: 42, userInfo: nil)
        LoggingPolicy.error("Test error message", error: testError)
    }
    
    func testError_WithCategory_DoesNotCrash() {
        LoggingPolicy.error("Test error message", category: "persistence")
    }
    
    func testFault_DoesNotCrash() {
        LoggingPolicy.fault("Test fault message")
    }
    
    func testFault_WithCategory_DoesNotCrash() {
        LoggingPolicy.fault("Test fault message", category: "critical")
    }
    
    func testDebugPrivate_DoesNotCrash() {
        LoggingPolicy.debugPrivate("Test private message")
    }
    
    // MARK: - Empty Message Tests
    
    func testDebug_EmptyMessage_DoesNotCrash() {
        LoggingPolicy.debug("")
    }
    
    func testInfo_EmptyMessage_DoesNotCrash() {
        LoggingPolicy.info("")
    }
    
    func testWarning_EmptyMessage_DoesNotCrash() {
        LoggingPolicy.warning("")
    }
    
    func testError_EmptyMessage_DoesNotCrash() {
        LoggingPolicy.error("")
    }
    
    func testFault_EmptyMessage_DoesNotCrash() {
        LoggingPolicy.fault("")
    }
    
    // MARK: - Long Message Tests
    
    func testDebug_LongMessage_DoesNotCrash() {
        let longMessage = String(repeating: "A", count: 10000)
        LoggingPolicy.debug(longMessage)
    }
    
    func testInfo_LongMessage_DoesNotCrash() {
        let longMessage = String(repeating: "B", count: 10000)
        LoggingPolicy.info(longMessage)
    }
    
    func testError_LongMessage_DoesNotCrash() {
        let longMessage = String(repeating: "C", count: 10000)
        LoggingPolicy.error(longMessage)
    }
    
    // MARK: - Unicode Tests
    
    func testInfo_UnicodeMessage_DoesNotCrash() {
        LoggingPolicy.info("Unicode: 你好世界 🌍 مرحبا")
    }
    
    func testError_UnicodeMessage_DoesNotCrash() {
        LoggingPolicy.error("Error with unicode: 错误 ⚠️")
    }
    
    // Note: criticalFailure and assertionFailure are not tested as they terminate/assert
}

final class LogRedactorTests: XCTestCase {
	func testRedactingSensitiveData_RemovesTraceableValues() {
		let url = "https://models.example.com/private/weights.mlmodel?token=secret#fragment"
		let identifier = "123E4567-E89B-12D3-A456-426614174000"
		let path = "/var/mobile/Containers/Data/Application/secret/model.mlmodel"
		let message = "url=\(url) id=\(identifier) path=\(path) accountID=acct-123 token=secret-token email=user@example.com latitude: 48.8566 longitude: 2.3522 location=<+48.8566,+2.3522>"

		let redacted = LogRedactor.redactingSensitiveData(message)

		for sensitiveValue in [url, identifier, path, "acct-123", "secret-token", "user@example.com", "48.8566", "2.3522"] {
			XCTAssertFalse(redacted.contains(sensitiveValue), "Expected \(sensitiveValue) to be redacted")
		}
		XCTAssertTrue(redacted.contains("[redacted URL]"))
		XCTAssertTrue(redacted.contains("[redacted ID]"))
		XCTAssertTrue(redacted.contains("[redacted path]"))
		XCTAssertTrue(redacted.contains("accountID=[redacted]"))
		XCTAssertTrue(redacted.contains("token=[redacted]"))
	}
}

final class ApplicationLogBufferTests: XCTestCase {
	func testRecentApplicationLogData_UsesTheRawMessageOnlyWhenExplicitlyRequested() {
		let marker = UUID().uuidString
		let sensitiveURL = "https://models.example.com/weights?downloadID=\(marker)"
		let sensitivePath = "/var/mobile/Containers/Data/Application/\(marker)/model.mlmodel"
		let sensitiveLatitude = "48.8566"
		LoggingPolicy.info(
			"Support-log marker: \(sensitiveURL) accountID=\(marker) path=\(sensitivePath) latitude: \(sensitiveLatitude)"
		)

		guard let redactedLog = String(
			bytes: LoggingPolicy.recentApplicationLogData(),
			encoding: .utf8
		), let unredactedLog = String(
			bytes: LoggingPolicy.recentApplicationLogData(sendUnredactedData: true),
			encoding: .utf8
		) else {
			return XCTFail("Expected UTF-8 application logs")
		}

		for sensitiveValue in [marker, sensitiveURL, sensitivePath, sensitiveLatitude] {
			XCTAssertFalse(redactedLog.contains(sensitiveValue), "Expected \(sensitiveValue) to be redacted")
			XCTAssertTrue(unredactedLog.contains(sensitiveValue), "Expected \(sensitiveValue) in the raw attachment")
		}
	}

	func testSnapshotData_KeepsTheNewestBytesWithinTheByteLimit() {
		let buffer = ApplicationLogBuffer(maximumByteCount: 10)
		buffer.append("first")
		buffer.append("second")

		guard let text = String(bytes: buffer.snapshotData(), encoding: .utf8) else {
			return XCTFail("Expected a UTF-8 application log")
		}
		XCTAssertEqual(text, "st\nsecond\n")
	}

	func testSnapshotData_TruncatesAnOversizedNewestEntryToTheByteLimit() {
		let buffer = ApplicationLogBuffer(maximumByteCount: 5)
		buffer.append("abcdef")

		XCTAssertEqual(buffer.snapshotData().count, 5)
		guard let text = String(bytes: buffer.snapshotData(), encoding: .utf8) else {
			return XCTFail("Expected a UTF-8 application log")
		}
		XCTAssertEqual(text, "cdef\n")
	}

	func testSnapshotData_KeepsTheNewestTailWhenAnOversizedEntryHasLaterEntries() {
		let buffer = ApplicationLogBuffer(maximumByteCount: 10)
		buffer.append(String(repeating: "a", count: 12))
		buffer.append("x")

		guard let text = String(bytes: buffer.snapshotData(), encoding: .utf8) else {
			return XCTFail("Expected a UTF-8 application log")
		}
		XCTAssertEqual(text, "aaaaaaa\nx\n")
	}

	func testSnapshotData_TrimsAUnicodeCutoffToValidUTF8() {
		let buffer = ApplicationLogBuffer(maximumByteCount: 8)
		buffer.append("aa€bbbbbb")

		guard let text = String(bytes: buffer.snapshotData(), encoding: .utf8) else {
			return XCTFail("Expected a UTF-8 application log")
		}
		XCTAssertEqual(text, "bbbbbb\n")
	}
}
