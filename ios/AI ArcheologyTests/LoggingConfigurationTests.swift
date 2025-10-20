//
//  LoggingConfigurationTests.swift
//  AI ArcheologyTests
//
//  Tests for logging configuration and timestamp functionality
//

import XCTest
@testable import ML_Browser

final class LoggingConfigurationTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
        // Restore default configuration before each test
        LoggingConfiguration.timestampsEnabled = true
        LoggingConfiguration.timestampFormat = .iso8601WithMilliseconds
    }
    
    func test_timestampEnabled_generatesNonEmptyString() throws {
        // Given
        LoggingConfiguration.timestampsEnabled = true
        
        // When
        let timestamp = Logger.timestamp
        
        // Then
        XCTAssertFalse(timestamp.isEmpty, "Timestamp should not be empty when enabled")
        XCTAssertTrue(timestamp.hasSuffix(" "), "Timestamp should end with a space")
    }
    
    func test_timestampDisabled_generatesEmptyString() throws {
        // Given
        LoggingConfiguration.timestampsEnabled = false
        
        // When
        let timestamp = Logger.timestamp
        
        // Then
        XCTAssertTrue(timestamp.isEmpty, "Timestamp should be empty when disabled")
    }
    
    func test_timestampFormat_matchesISO8601WithMilliseconds() throws {
        // Given
        LoggingConfiguration.timestampsEnabled = true
        LoggingConfiguration.timestampFormat = .iso8601WithMilliseconds
        
        // When
        let timestamp = Logger.timestamp.trimmingCharacters(in: .whitespaces)
        
        // Then
        // Format: 2025-10-20T14:59:59.908Z
        let regex = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#
        let predicate = NSPredicate(format: "SELF MATCHES %@", regex)
        XCTAssertTrue(predicate.evaluate(with: timestamp), 
                     "Timestamp '\(timestamp)' should match ISO 8601 format with milliseconds")
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
    
    func test_multipleTimestampCalls_generateDifferentOrSameTimestamps() throws {
        // Given
        LoggingConfiguration.timestampsEnabled = true
        
        // When
        let timestamp1 = Logger.timestamp
        // Small delay to potentially get different timestamp
        Thread.sleep(forTimeInterval: 0.001)
        let timestamp2 = Logger.timestamp
        
        // Then
        XCTAssertFalse(timestamp1.isEmpty)
        XCTAssertFalse(timestamp2.isEmpty)
        // They might be same or different depending on timing - both are valid
        // Just verify both are well-formed
        XCTAssertTrue(timestamp1.hasSuffix(" "))
        XCTAssertTrue(timestamp2.hasSuffix(" "))
    }
    
    func test_timestampPerformance() throws {
        // Given
        LoggingConfiguration.timestampsEnabled = true
        
        // When/Then
        measure {
            for _ in 0..<1000 {
                _ = Logger.timestamp
            }
        }
        // This test ensures timestamp generation is performant
        // With cached formatter, should be fast
    }
}
