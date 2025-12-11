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
