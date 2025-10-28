//
//  LoggingConfiguration.swift
//  AI Archeology
//
//  Configuration for logging behavior including timestamps
//

import Foundation

/// Configuration for logging behavior across the application
enum LoggingConfiguration {
    /// Whether to include timestamps in log messages
    @MainActor
    static var timestampsEnabled: Bool = true
    
    /// Format for timestamps in log messages
    enum TimestampFormat {
        /// ISO 8601 format with milliseconds: "2025-10-20T13:46:05.233Z"
        case iso8601WithMilliseconds
        
        /// Custom format string (not yet implemented)
        case custom(String)
        
        /// Returns the configured DateFormatter for the format
        var formatter: DateFormatter {
            switch self {
            case .iso8601WithMilliseconds:
                return ISO8601DateFormatter.logFormatter
            case .custom(let format):
                let formatter = DateFormatter()
                formatter.dateFormat = format
                formatter.timeZone = TimeZone(identifier: "UTC")
                return formatter
            }
        }
    }
    
    /// Current timestamp format to use
    @MainActor
    static var timestampFormat: TimestampFormat = .iso8601WithMilliseconds
}

extension ISO8601DateFormatter {
    /// Shared formatter for log timestamps with millisecond precision
    /// Cached to avoid repeated initialization overhead
    static let logFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
