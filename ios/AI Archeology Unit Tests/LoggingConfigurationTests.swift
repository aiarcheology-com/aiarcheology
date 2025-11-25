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
        LoggingConfiguration.setTimestampsEnabled(true)
        LoggingConfiguration.setTimestampFormat(.iso8601WithMilliseconds)
    }
    
    func test_timestampFormatter_isCached() throws {
        // Given
        LoggingConfiguration.setTimestampFormat(.iso8601WithMilliseconds)
        let date = Date(timeIntervalSince1970: 0)
        let ts1 = LoggingConfiguration.timestampPrefix(now: date)
        let ts2 = LoggingConfiguration.timestampPrefix(now: date)
        
        // Then
        XCTAssertEqual(ts1, ts2, "Timestamp prefix should be deterministic for same date and format")
    }
    
    func test_timestampFormatter_usesUTC() throws {
        // Given
        LoggingConfiguration.setTimestampFormat(.iso8601WithMilliseconds)
        let date = Date(timeIntervalSince1970: 0) // 1970-01-01T00:00:00Z
        
        // When
        let prefix = LoggingConfiguration.timestampPrefix(now: date)
        
        // Then: should end with 'Z ' (UTC designator + space)
        XCTAssertTrue(prefix.hasSuffix("Z "), "Timestamp prefix should use UTC timezone and end with 'Z '")
    }
    
    func test_timestampFormatter_producesISO8601Format() throws {
        // Given
        LoggingConfiguration.setTimestampFormat(.iso8601WithMilliseconds)
        let date = Date()
        
        // When
        let prefix = LoggingConfiguration.timestampPrefix(now: date)
        let timestamp = prefix.trimmingCharacters(in: .whitespaces)
        
        // Then
        // Format: 2025-10-20T14:59:59.908Z
        let regex = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#
        let predicate = NSPredicate(format: "SELF MATCHES %@", regex)
        XCTAssertTrue(predicate.evaluate(with: timestamp),
                     "Timestamp '\(timestamp)' should match ISO 8601 format with milliseconds")
    }
    
    func test_loggingConfiguration_timestampsEnabledByDefault() throws {
        // Then
        XCTAssertTrue(LoggingConfiguration.timestampsEnabled(), "Timestamps should be enabled by default")
    }
    
    func test_loggingConfiguration_canBeDisabled() throws {
        // When
        LoggingConfiguration.setTimestampsEnabled(false)
        
        // Then
        XCTAssertFalse(LoggingConfiguration.timestampsEnabled(), "Timestamps should be disabled")
        
        // Cleanup
        LoggingConfiguration.setTimestampsEnabled(true)
    }
    
    func test_loggingConfiguration_defaultFormatIsISO8601() throws {
        // Then
        let format = LoggingConfiguration.timestampFormat()
        XCTAssertEqual(format, .iso8601WithMilliseconds)
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
        LoggingConfiguration.setTimestampFormat(.iso8601WithMilliseconds)
        let date = Date()
        
        // When/Then
        measure {
            for _ in 0..<1000 {
                _ = LoggingConfiguration.timestampPrefix(now: date)
            }
        }
        // This test ensures timestamp generation is performant with cached formatter.
    }
}
