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
    
    // MARK: - Protocol Conformance Tests

    func test_conformsToCrashReporter() {
        let reporter: CrashReporter = DefaultCrashReporter.shared

        XCTAssertNotNil(reporter)
    }

    func test_isSendable() {
        // DefaultCrashReporter should be Sendable for safe concurrent access
        let reporter = DefaultCrashReporter.shared

        Task {
            reporter.recordError(NSError(domain: "Test", code: 1), context: nil)
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
    }
}
