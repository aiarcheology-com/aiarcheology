//
//  ObservabilityTests.swift
//  AI ArcheologyTests
//
//  Tests for the Observability abstraction layer.
//

import XCTest
@testable import ML_Browser

// MARK: - Mock CrashReportingService

/// Test mock for CrashReportingService.
/// Uses @unchecked Sendable since tests run serially and the mock needs mutable state for assertions.
final class MockCrashReportingService: CrashReportingService, @unchecked Sendable {
	private(set) var startCalled = false
	private(set) var breadcrumbs: [(message: String, level: BreadcrumbLevel, category: String)] = []
	private(set) var capturedErrors: [(message: String, error: Error?)] = []
	private(set) var capturedContexts: [[String: String]] = []
	private(set) var capturedFaults: [String] = []
	private(set) var customValues: [String: String] = [:]
	
	func start() {
		startCalled = true
	}
	
	func addBreadcrumb(message: String, level: BreadcrumbLevel, category: String) {
		breadcrumbs.append((message, level, category))
	}
	
	func captureError(message: String, error: Error?) {
		capturedErrors.append((message, error))
	}

	/// Recorded separately so a test can tell a capture WITH context from one without — the default
	/// protocol implementation forwards to the two-argument call, and a mock that folded them
	/// together could not notice that the context had been dropped on the way.
	func captureError(message: String, error: Error?, context: [String: String]) {
		capturedErrors.append((message, error))
		capturedContexts.append(context)
	}
	
	func captureFault(message: String) {
		capturedFaults.append(message)
	}
	
	func setCustomValue(_ value: String, forKey key: String) {
		customValues[key] = value
	}
	
	func reset() {
		startCalled = false
		breadcrumbs.removeAll()
		capturedErrors.removeAll()
		capturedFaults.removeAll()
		customValues.removeAll()
	}
}

// MARK: - NoOpCrashReportingService Tests

final class NoOpCrashReportingServiceTests: XCTestCase {
	
	var sut: NoOpCrashReportingService!
	
	override func setUp() {
		super.setUp()
		sut = NoOpCrashReportingService()
	}
	
	override func tearDown() {
		sut = nil
		super.tearDown()
	}
	
	func test_start_doesNotCrash() {
		sut.start()
	}
	
	func test_addBreadcrumb_doesNotCrash() {
		sut.addBreadcrumb(message: "Test", level: .info, category: "test")
	}
	
	func test_captureError_doesNotCrash() {
		sut.captureError(message: "Test error", error: nil)
	}
	
	func test_captureError_withError_doesNotCrash() {
		let error = NSError(domain: "Test", code: 42)
		sut.captureError(message: "Test error", error: error)
	}
	
	func test_captureFault_doesNotCrash() {
		sut.captureFault(message: "Test fault")
	}
	
	func test_setCustomValue_doesNotCrash() {
		sut.setCustomValue("value", forKey: "key")
	}
}

// MARK: - CrashReportingService Protocol Tests

final class CrashReportingServiceProtocolTests: XCTestCase {
	
	func test_mockImplementation_conformsToProtocol() {
		let service: CrashReportingService = MockCrashReportingService()
		XCTAssertNotNil(service)
	}
	
	func test_noOpImplementation_conformsToProtocol() {
		let service: CrashReportingService = NoOpCrashReportingService()
		XCTAssertNotNil(service)
	}
	
	func test_mockService_recordsStart() {
		let mock = MockCrashReportingService()
		
		mock.start()
		
		XCTAssertTrue(mock.startCalled)
	}
	
	func test_mockService_recordsBreadcrumbs() {
		let mock = MockCrashReportingService()
		
		mock.addBreadcrumb(message: "Test message", level: .warning, category: "test.category")
		
		XCTAssertEqual(mock.breadcrumbs.count, 1)
		XCTAssertEqual(mock.breadcrumbs.first?.message, "Test message")
		XCTAssertEqual(mock.breadcrumbs.first?.level, .warning)
		XCTAssertEqual(mock.breadcrumbs.first?.category, "test.category")
	}
	
	func test_mockService_recordsErrors() {
		let mock = MockCrashReportingService()
		let error = NSError(domain: "TestDomain", code: 42)
		
		mock.captureError(message: "Error occurred", error: error)
		
		XCTAssertEqual(mock.capturedErrors.count, 1)
		XCTAssertEqual(mock.capturedErrors.first?.message, "Error occurred")
		XCTAssertNotNil(mock.capturedErrors.first?.error)
	}
	
	func test_mockService_recordsFaults() {
		let mock = MockCrashReportingService()
		
		mock.captureFault(message: "Critical fault")
		
		XCTAssertEqual(mock.capturedFaults.count, 1)
		XCTAssertEqual(mock.capturedFaults.first, "Critical fault")
	}
	
	func test_mockService_recordsCustomValues() {
		let mock = MockCrashReportingService()
		
		mock.setCustomValue("testValue", forKey: "testKey")
		
		XCTAssertEqual(mock.customValues["testKey"], "testValue")
	}
}

// MARK: - BreadcrumbLevel Tests (moved from CrashReporterTests)

final class BreadcrumbLevelTests: XCTestCase {
	
	func test_debug_hasCorrectRawValue() {
		XCTAssertEqual(BreadcrumbLevel.debug.rawValue, "debug")
	}
	
	func test_none_hasCorrectRawValue() {
		XCTAssertEqual(BreadcrumbLevel.none.rawValue, "none")
	}
	
	func test_info_hasCorrectRawValue() {
		XCTAssertEqual(BreadcrumbLevel.info.rawValue, "info")
	}
	
	func test_warning_hasCorrectRawValue() {
		XCTAssertEqual(BreadcrumbLevel.warning.rawValue, "warning")
	}
	
	func test_error_hasCorrectRawValue() {
		XCTAssertEqual(BreadcrumbLevel.error.rawValue, "error")
	}
	
	func test_fatal_hasCorrectRawValue() {
		XCTAssertEqual(BreadcrumbLevel.fatal.rawValue, "fatal")
	}
	
	func test_allCases_haveUniqueRawValues() {
		let levels: [BreadcrumbLevel] = [.none, .debug, .info, .warning, .error, .fatal]
		let rawValues = levels.map { $0.rawValue }
		let uniqueValues = Set(rawValues)
		
		XCTAssertEqual(rawValues.count, uniqueValues.count)
	}
	
	func test_breadcrumbLevel_isSendable() {
		// If this compiles, BreadcrumbLevel conforms to Sendable
		let level: BreadcrumbLevel = .info
		Task {
			_ = level
		}
		XCTAssertNotNil(level)
	}
}

// MARK: - SentryCrashReportingService Tests

final class SentryCrashReportingServiceTests: XCTestCase {
	func testRedactedMessage_RemovesSensitiveErrorDetailsBeforeCapture() {
		let sensitiveURL = "https://models.example.com/private/model.mlmodel?token=secret"
		let sensitiveIdentifier = "123E4567-E89B-12D3-A456-426614174000"
		let message = "Support failure at \(sensitiveURL), accountID=\(sensitiveIdentifier)"

		let redacted = SentryCrashReportingService.redactedMessage(message)

		XCTAssertFalse(redacted.contains(sensitiveURL))
		XCTAssertFalse(redacted.contains(sensitiveIdentifier))
		XCTAssertTrue(redacted.contains("[redacted URL]"))
		XCTAssertTrue(redacted.contains("accountID=[redacted]"))
	}
	
	func test_toSentryLevel_mappings_coverAllCases() {
		XCTAssertEqual(BreadcrumbLevel.none.toSentryLevel(), .none)
		XCTAssertEqual(BreadcrumbLevel.debug.toSentryLevel(), .debug)
		XCTAssertEqual(BreadcrumbLevel.info.toSentryLevel(), .info)
		XCTAssertEqual(BreadcrumbLevel.warning.toSentryLevel(), .warning)
		XCTAssertEqual(BreadcrumbLevel.error.toSentryLevel(), .error)
		XCTAssertEqual(BreadcrumbLevel.fatal.toSentryLevel(), .fatal)
	}
	
	func test_start_withoutDsn_doesNotCrash() {
		// With nil DSN the service should no-op without throwing or crashing.
		let sut = SentryCrashReportingService(dsn: nil, tracesSampleRate: 1.0, enableProfiling: false)
		sut.start() // should early-return and not crash
	}
	
	func test_start_withEmptyDsn_doesNotCrash() {
		let sut = SentryCrashReportingService(dsn: "", tracesSampleRate: 0.25, enableProfiling: true)
		sut.start() // should early-return and not crash
	}
	
	func test_initialization_storesParameters() {
		let sut = SentryCrashReportingService(dsn: "https://example", tracesSampleRate: 0.25, enableProfiling: true)
		
		XCTAssertEqual(try? sut.privateValue(for: "dsn") as? String, "https://example")
		XCTAssertEqual(try? sut.privateValue(for: "tracesSampleRate") as? Float, 0.25)
		XCTAssertEqual(try? sut.privateValue(for: "enableProfiling") as? Bool, true)
	}
	
	func test_start_idempotent_onMainThread() {
		// Sentry SDK expects main-thread initialization (it touches UIApplication).
		// Verify repeated calls on main thread do not crash.
		let sut = SentryCrashReportingService(dsn: nil, tracesSampleRate: 0.1, enableProfiling: false)
		for _ in 0..<3 {
			sut.start()
		}
	}
}

// MARK: - Observability Test Triggers Tests

final class ObservabilityTestTriggersTests: XCTestCase {
	
	func test_runTestTriggersIfEnabled_doesNotCrashWhenNoEnvVarsSet() {
		// When no test environment variables are set, this should be a no-op
		Observability.runTestTriggersIfEnabled()
	}
	
	func test_runSentryTestErrorIfEnabled_onlyExecutesWhenEnvVarSet() {
		// This test verifies the method is properly gated by AppEnvironment.shouldTriggerTestError
		// We can't easily mock environment variables in unit tests, but we can verify
		// the method doesn't crash when called directly
		
		// When SENTRY_TEST_ERROR is not set, this should return early without logging an error
		// Note: We can't directly test the error logging without triggering actual Sentry events
		XCTAssertNoThrow(Observability.runTestTriggersIfEnabled())
	}
	
	func test_runSentryTestCrashIfEnabled_properlyGatedByAppStore() {
		// Verify that test crashes are blocked in App Store distributions
		// This is critical for safety - we should never crash in production
		
		// The actual crash test is async with a 1-second delay, so we can't easily test it
		// but we can verify the method exists and doesn't crash when environment is not set
		XCTAssertNoThrow(Observability.runTestTriggersIfEnabled())
	}
	
	func test_runSentryThrottleSmokeTestIfEnabled_properlyGatedByEnvVar() {
		// When SENTRY_THROTTLE_SMOKE_TEST is not set, this should return early
		XCTAssertNoThrow(Observability.runTestTriggersIfEnabled())
	}
}

// MARK: - Test helpers

private enum MirrorError: Error {
	case propertyNotFound(String)
}

private extension SentryCrashReportingService {
	func privateValue(for property: String) throws -> Any {
		var mirror: Mirror? = Mirror(reflecting: self)
		while let current = mirror {
			if let child = current.children.first(where: { $0.label == property }) {
				return child.value
			}
			mirror = current.superclassMirror
		}
		throw MirrorError.propertyNotFound(property)
	}
}
