//
//  CrashReporter.swift
//  AI Archeology
//
//  Created for logging and crash reporting infrastructure
//

import Foundation
import OSLog

/// Protocol for crash reporting services integration (e.g., Crashlytics, Sentry)
/// This provides a clean abstraction layer for future crash reporting integration
protocol CrashReporter {
    /// Records a non-fatal error for later analysis
    /// - Parameters:
    ///   - error: The error to record
    ///   - context: Additional context about where/when the error occurred
    func recordError(_ error: Error, context: [String: Any]?)
    
    /// Records a custom message as a breadcrumb for debugging
    /// - Parameters:
    ///   - message: The message to record
    ///   - level: The severity level (debug, info, warning, error)
    func recordBreadcrumb(_ message: String, level: BreadcrumbLevel)
    
    /// Sets custom user attributes for crash reports
    /// - Parameters:
    ///   - key: The attribute key
    ///   - value: The attribute value (must be privacy-safe)
    func setCustomValue(_ value: String, forKey key: String)
}

/// Severity levels for breadcrumbs
enum BreadcrumbLevel: String {
    case debug
    case info
    case warning
    case error
}

/// Default implementation that logs to OSLog
/// Replace with actual crash reporting service implementation when needed
final class DefaultCrashReporter: CrashReporter {
    static let shared = DefaultCrashReporter()
    
    private init() {}
    
    func recordError(_ error: Error, context: [String: Any]?) {
        var contextString = ""
        if let context = context {
            contextString = context.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        }
        Logger.app.error("\(Logger.timestamp)Non-fatal error recorded: \(error.localizedDescription, privacy: .public) context: \(contextString, privacy: .public)")
    }
    
    func recordBreadcrumb(_ message: String, level: BreadcrumbLevel) {
        switch level {
        case .debug:
            Logger.app.debug("\(Logger.timestamp)Breadcrumb: \(message, privacy: .public)")
        case .info:
            Logger.app.info("\(Logger.timestamp)Breadcrumb: \(message, privacy: .public)")
        case .warning:
            Logger.app.warning("\(Logger.timestamp)Breadcrumb: \(message, privacy: .public)")
        case .error:
            Logger.app.error("\(Logger.timestamp)Breadcrumb: \(message, privacy: .public)")
        }
    }
    
    func setCustomValue(_ value: String, forKey key: String) {
        Logger.app.debug("\(Logger.timestamp)Custom attribute set: \(key, privacy: .public)=\(value, privacy: .public)")
    }
}
