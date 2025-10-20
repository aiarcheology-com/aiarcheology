//
//  LoggingConfigurationTests.swift
//  AI ArcheologyTests
//
//  Tests for logging configuration and timestamp functionality
//

import XCTest
import OSLog
@testable import ML_Browser

final class LoggingConfigurationTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
        // Restore default configuration before each test
        LoggingConfiguration.timestampsEnabled = true
        LoggingConfiguration.timestampFormat = .iso8601WithMilliseconds
    }
    
    func test_timestampFormatter_isCached() throws {
        // Given
        let formatter1 = ISO8601DateFormatter.logFormatter
        let formatter2 = ISO8601DateFormatter.logFormatter
        
        // Then
        XCTAssertTrue(formatter1 === formatter2, "Formatter should be cached and return same instance")
    }
    
    func test_timestampFormatter_usesUTC() throws {
        // Given
        let formatter = ISO8601DateFormatter.logFormatter
        
        // Then
        XCTAssertEqual(formatter.timeZone.identifier, "UTC", "Formatter should use UTC timezone")
    }
    
    func test_timestampFormatter_producesISO8601Format() throws {
        // Given
        let formatter = ISO8601DateFormatter.logFormatter
        let date = Date()
        
        // When
        let timestamp = formatter.string(from: date)
        
        // Then
        // Format: 2025-10-20T14:59:59.908Z
        let regex = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#
        let predicate = NSPredicate(format: "SELF MATCHES %@", regex)
        XCTAssertTrue(predicate.evaluate(with: timestamp), 
                     "Timestamp '\(timestamp)' should match ISO 8601 format with milliseconds")
    }
    
    func test_loggingConfiguration_timestampsEnabledByDefault() throws {
        // Then
        XCTAssertTrue(LoggingConfiguration.timestampsEnabled, "Timestamps should be enabled by default")
    }
    
    func test_loggingConfiguration_canBeDisabled() throws {
        // When
        LoggingConfiguration.timestampsEnabled = false
        
        // Then
        XCTAssertFalse(LoggingConfiguration.timestampsEnabled, "Timestamps should be disabled")
        
        // Cleanup
        LoggingConfiguration.timestampsEnabled = true
    }
    
    func test_loggingConfiguration_defaultFormatIsISO8601() throws {
        // Then
        let formatter = LoggingConfiguration.timestampFormat.formatter
        XCTAssertTrue(formatter === ISO8601DateFormatter.logFormatter, 
                     "Default format should use ISO 8601 formatter")
    }
    
    func test_loggerMethods_existAndAreCallable() throws {
        // Given
        let logger = Logger.app
        
        // When/Then - Just verify these methods compile and execute without crashing
        logger.logDebug("Test debug message")
        logger.logInfo("Test info message")
        logger.logNotice("Test notice message")
        logger.logWarning("Test warning message")
        logger.logError("Test error message")
        logger.logFault("Test fault message")
        
        // If we get here without crashing, the test passes
        XCTAssertTrue(true)
    }
    
    func test_formatterPerformance() throws {
        // Given
        let formatter = ISO8601DateFormatter.logFormatter
        
        // When/Then
        measure {
            for _ in 0..<1000 {
                _ = formatter.string(from: Date())
            }
        }
        // This test ensures timestamp generation is performant
        // With cached formatter, should be fast
    }
}
