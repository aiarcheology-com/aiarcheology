//
//  LoggingPolicy.swift
//  AI Archeology
//
//  Defines logging conventions and crash policy for the application
//

import Foundation
import OSLog

/// Centralized logging policy and crash handling guidelines
/// 
/// This enum serves as documentation and provides helper methods for consistent
/// error handling across the application.
enum LoggingPolicy {
    
    // MARK: - Logging Levels
    
    /// Use `.debug` for:
    /// - Internal developer details
    /// - Verbose diagnostic information
    /// - Development-only messages
    static func debug(_ message: String, logger: Logger = .app) {
        logger.logDebug(message)
    }
    
    /// Use `.info` or `.notice` for:
    /// - App state changes
    /// - User actions
    /// - Non-critical updates
    /// - Lifecycle events
    static func info(_ message: String, logger: Logger = .app) {
        logger.logInfo(message)
    }
    
    /// Use `.warning` for:
    /// - Degraded behavior
    /// - Retry operations
    /// - Unexpected but recoverable conditions
    static func warning(_ message: String, logger: Logger = .app) {
        logger.logWarning(message)
    }
    
    /// Use `.error` for:
    /// - Recoverable operation failures
    /// - Invalid user input
    /// - Network errors
    static func error(_ message: String, error: Error? = nil, logger: Logger = .app) {
        if let error = error {
            logger.logError("\(message): \(error.localizedDescription)")
        } else {
            logger.logError(message)
        }
    }
    
    /// Use `.fault` for:
    /// - Compromised functionality
    /// - Invariant breaches
    /// - Critical data corruption
    /// - Conditions that will lead to a crash
    static func fault(_ message: String, logger: Logger = .app) {
        logger.logFault(message)
    }
    
    // MARK: - Crash Policy
    
    /// Crashes in all builds to ensure data integrity
    static func criticalFailure(
        _ message: String,
        file: StaticString = #file,
        filePath: String = #file,
        line: UInt = #line
    ) -> Never {
        let fileName = (filePath as NSString).lastPathComponent
        Logger.app.logFault("CRITICAL FAILURE at \(fileName):\(line): \(message)")
        preconditionFailure(message, file: file, line: line)
    }
    
    /// Crashes in debug; logs and reports in release
    static func assertionFailure( _ message: String, file: StaticString = #file, filePath: String = #file, line: UInt = #line) {
        let fileName = (filePath as NSString).lastPathComponent
#if DEBUG
        Logger.app.logFault("ASSERTION FAILURE at \(fileName):\(line): \(message)")
        Swift.assertionFailure(message, file: file, line: line)
#else
        Logger.app.logError("Assertion would fail in debug at \(fileName):\(line): \(message)")
        DefaultCrashReporter.shared.recordError(
            LoggingError.assertionFailure(message),
            context: ["file": fileName, "line": "\(line)"]
        )
#endif
    }
    
    // MARK: - Privacy Guidelines
    
    /// Log sensitive data only in debug builds
    static func debugPrivate(_ message: String, logger: Logger = .app) {
        #if DEBUG
        logger.logDebug(message)
        #else
        // In production, use the original debug method with .private privacy
        // Privacy enforced; timestamp display is controlled by LoggingConfiguration.timestampsEnabled
        logger.debug("\(message, privacy: .private)")
        #endif
    }
}

/// Custom errors for logging infrastructure
enum LoggingError: LocalizedError {
    case assertionFailure(String)
    case unexpectedNil(String)
    case invalidState(String)
    
    var errorDescription: String? {
        switch self {
        case .assertionFailure(let message):
            return "Assertion failure: \(message)"
        case .unexpectedNil(let context):
            return "Unexpected nil value: \(context)"
        case .invalidState(let description):
            return "Invalid state: \(description)"
        }
    }
}
