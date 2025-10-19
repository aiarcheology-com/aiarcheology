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
        logger.debug("\(message, privacy: .public)")
    }
    
    /// Use `.info` or `.notice` for:
    /// - App state changes
    /// - User actions
    /// - Non-critical updates
    /// - Lifecycle events
    static func info(_ message: String, logger: Logger = .app) {
        logger.info("\(message, privacy: .public)")
    }
    
    /// Use `.warning` for:
    /// - Degraded behavior
    /// - Retry operations
    /// - Unexpected but recoverable conditions
    static func warning(_ message: String, logger: Logger = .app) {
        logger.warning("\(message, privacy: .public)")
    }
    
    /// Use `.error` for:
    /// - Recoverable operation failures
    /// - Invalid user input
    /// - Network errors
    static func error(_ message: String, error: Error? = nil, logger: Logger = .app) {
        if let error = error {
            logger.error("\(message, privacy: .public): \(error.localizedDescription, privacy: .public)")
        } else {
            logger.error("\(message, privacy: .public)")
        }
    }
    
    /// Use `.fault` for:
    /// - Compromised functionality
    /// - Invariant breaches
    /// - Critical data corruption
    /// - Conditions that will lead to a crash
    static func fault(_ message: String, logger: Logger = .app) {
        logger.fault("\(message, privacy: .public)")
    }
    
    // MARK: - Crash Policy
    
    /// Use for invariant violations and critical errors that compromise app functionality
    /// This will crash in ALL builds (debug and release) to ensure data integrity
    static func criticalFailure(_ message: String, file: String = #file, line: Int = #line) -> Never {
        let fileName = (file as NSString).lastPathComponent
        Logger.app.fault("CRITICAL FAILURE at \(fileName, privacy: .public):\(line): \(message, privacy: .public)")
        preconditionFailure(message, file: file, line: UInt(line))
    }
    
    /// Use for assertion failures during development
    /// Crashes in debug builds but logs as error in release
    static func assertionFailure(_ message: String, file: String = #file, line: Int = #line) {
        let fileName = (file as NSString).lastPathComponent
        #if DEBUG
        Logger.app.fault("ASSERTION FAILURE at \(fileName, privacy: .public):\(line): \(message, privacy: .public)")
        Swift.assertionFailure(message, file: file, line: line)
        #else
        Logger.app.error("Assertion would fail in debug at \(fileName, privacy: .public):\(line): \(message, privacy: .public)")
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
        logger.debug("\(message, privacy: .public)")
        #else
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
