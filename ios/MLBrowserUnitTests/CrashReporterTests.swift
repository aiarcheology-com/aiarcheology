//
//  CrashReporterTests.swift
//  AI ArcheologyTests
//
//

import XCTest
@testable import ML_Browser

// MARK: - DefaultCrashReporter Tests

final class DefaultCrashReporterTests: XCTestCase {
    
    var sut: DefaultCrashReporter!
    
    override func setUp() {
        super.setUp()
        sut = DefaultCrashReporter.shared
        
        // Ensure Observability is started for tests
        // In real tests, this would be done with a mock service
        if !Observability.isStarted {
            Observability.start(with: NoOpCrashReportingService())
        }
    }
    
    override func tearDown() {
        sut = nil
        super.tearDown()
    }
    
    // MARK: - Singleton Tests
    
    func test_shared_returnsSameInstance() {
        let first = DefaultCrashReporter.shared
        let second = DefaultCrashReporter.shared
        
        XCTAssertTrue(first === second)
    }
    
    // MARK: - recordError Tests
    
    func test_recordError_withNilContext_doesNotCrash() {
        let error = NSError(domain: "TestDomain", code: 42)
        
        // Should not crash
        sut.recordError(error, context: nil)
    }
    
    func test_recordError_withContext_doesNotCrash() {
        let error = NSError(domain: "TestDomain", code: 42)
        let context: [String: Any] = [
            "screen": "HomeScreen",
            "userId": "12345",
            "timestamp": Date()
        ]
        
        // Should not crash
        sut.recordError(error, context: context)
    }
    
    func test_recordError_withEmptyContext_doesNotCrash() {
        let error = NSError(domain: "TestDomain", code: 42)
        
        sut.recordError(error, context: [:])
    }
    
    func test_recordError_withCustomError_doesNotCrash() {
        enum TestError: Error {
            case somethingWentWrong
        }
        
        sut.recordError(TestError.somethingWentWrong, context: ["type": "custom"])
    }
    
    // MARK: - recordBreadcrumb Tests
    
    func test_recordBreadcrumb_debugLevel_doesNotCrash() {
        sut.recordBreadcrumb("Debug message", level: .debug)
    }
    
    func test_recordBreadcrumb_infoLevel_doesNotCrash() {
        sut.recordBreadcrumb("Info message", level: .info)
    }
    
    func test_recordBreadcrumb_warningLevel_doesNotCrash() {
        sut.recordBreadcrumb("Warning message", level: .warning)
    }
    
    func test_recordBreadcrumb_errorLevel_doesNotCrash() {
        sut.recordBreadcrumb("Error message", level: .error)
    }
    
    func test_recordBreadcrumb_emptyMessage_doesNotCrash() {
        sut.recordBreadcrumb("", level: .info)
    }
    
    func test_recordBreadcrumb_longMessage_doesNotCrash() {
        let longMessage = String(repeating: "A", count: 10000)
        sut.recordBreadcrumb(longMessage, level: .info)
    }
    
    // MARK: - setCustomValue Tests
    
    func test_setCustomValue_normalKeyValue_doesNotCrash() {
        sut.setCustomValue("testValue", forKey: "testKey")
    }
    
    func test_setCustomValue_emptyKey_doesNotCrash() {
        sut.setCustomValue("value", forKey: "")
    }
    
    func test_setCustomValue_emptyValue_doesNotCrash() {
        sut.setCustomValue("", forKey: "key")
    }
    
    func test_setCustomValue_multipleValues_doesNotCrash() {
        sut.setCustomValue("value1", forKey: "key1")
        sut.setCustomValue("value2", forKey: "key2")
        sut.setCustomValue("value3", forKey: "key3")
    }
    
    func test_setCustomValue_overwriteKey_doesNotCrash() {
        sut.setCustomValue("original", forKey: "key")
        sut.setCustomValue("updated", forKey: "key")
    }
    
    // MARK: - Protocol Conformance Tests
    
    func test_conformsToCrashReporter() {
        let reporter: CrashReporter = DefaultCrashReporter.shared
        
        XCTAssertNotNil(reporter)
    }
    
    func test_isSendable() {
        // DefaultCrashReporter should be Sendable for safe concurrent access
        let reporter = DefaultCrashReporter.shared
        
        Task {
            reporter.recordBreadcrumb("From task", level: .info)
        }
        
        // If this compiles, the Sendable conformance is valid
        XCTAssertNotNil(reporter)
    }
}

// MARK: - CrashReporter Protocol Tests

final class CrashReporterProtocolTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
        // Ensure Observability is started for tests
        if !Observability.isStarted {
            Observability.start(with: NoOpCrashReportingService())
        }
    }
    
    func test_protocolMethods_areCallable() {
        let reporter: CrashReporter = DefaultCrashReporter.shared
        
        // All protocol methods should be callable
        reporter.recordError(NSError(domain: "Test", code: 1), context: nil)
        reporter.recordBreadcrumb("Test", level: .info)
        reporter.setCustomValue("value", forKey: "key")
    }
}
