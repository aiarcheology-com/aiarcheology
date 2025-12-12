//
//  LoggingPolicy.swift
//  AI Archeology
//
//  Defines logging conventions and crash policy for the application.
//  Routes logs to both OSLog (local) and Observability (remote).
//

import Foundation
import OSLog

/// Centralized logging policy and crash handling guidelines.
///
/// Each log level routes to:
/// - **OSLog**: Always (for local debugging via Console.app / Xcode)
/// - **Observability Breadcrumbs**: debug, info, warning (FREE - attached to crash reports)
/// - **Observability Capture**: error, fault (QUOTA - counts toward event limit)
///
/// Usage:
/// ```swift
/// LoggingPolicy.info("User logged in", logger: .lifecycle)
/// LoggingPolicy.error("Failed to load model", error: modelError, logger: .drivers)
/// LoggingPolicy.fault("Core Data stack corrupted", logger: .persistence)
/// ```
enum LoggingPolicy {
    
    // MARK: - Logging Levels
    
    /// Use `.debug` for:
    /// - Internal developer details
    /// - Verbose diagnostic information
    /// - Development-only messages
    ///
    /// Remote: Breadcrumb only (FREE)
    static func debug(
        _ message: String,
        logger: Logger = .app,
        category: String = "app.log",
        file: String = #file,
        line: UInt = #line
    ) {
        let prefixedMessage = LoggingConfiguration.logPrefix(file: file, line: line) + message
        
        // 1. Local (Console.app / Xcode)
        logger.logDebug(prefixedMessage)
        
        // 2. Remote breadcrumb (FREE - only uploaded with crash/error events)
        Observability.recordBreadcrumb(prefixedMessage, level: .debug, category: category)
    }
    
    /// Use `.info` or `.notice` for:
    /// - App state changes
    /// - User actions
    /// - Non-critical updates
    /// - Lifecycle events
    ///
    /// Remote: Breadcrumb only (FREE)
    static func info(
        _ message: String,
        logger: Logger = .app,
        category: String = "app.log",
        file: String = #file,
        line: UInt = #line
    ) {
        let prefixedMessage = LoggingConfiguration.logPrefix(file: file, line: line) + message
        
        // 1. Local
        logger.logInfo(prefixedMessage)
        
        // 2. Remote breadcrumb (FREE)
        Observability.recordBreadcrumb(prefixedMessage, level: .info, category: category)
    }
    
    /// Use `.warning` for:
    /// - Degraded behavior
    /// - Retry operations
    /// - Unexpected but recoverable conditions
    ///
    /// Remote: Breadcrumb only (FREE)
    static func warning(
        _ message: String,
        logger: Logger = .app,
        category: String = "app.log",
        file: String = #file,
        line: UInt = #line
    ) {
        let prefixedMessage = LoggingConfiguration.logPrefix(file: file, line: line) + message
        
        // 1. Local
        logger.logWarning(prefixedMessage)
        
        // 2. Remote breadcrumb (FREE)
        Observability.recordBreadcrumb(prefixedMessage, level: .warning, category: category)
    }
    
    /// Use `.error` for:
    /// - Recoverable operation failures
    /// - Invalid user input
    /// - Network errors
    ///
    /// Remote: Captured event (QUOTA - use sparingly)
    static func error(
        _ message: String,
        error: Error? = nil,
        logger: Logger = .app,
        category: String = "app.log",
        file: String = #file,
        line: UInt = #line
    ) {
        let baseMessage: String
        if let error = error {
            baseMessage = "\(message): \(error.localizedDescription)"
        } else {
            baseMessage = message
        }
        let prefixedMessage = LoggingConfiguration.logPrefix(file: file, line: line) + baseMessage
        
        // 1. Local
        logger.logError(prefixedMessage)
        
        // 2. Remote capture (QUOTA - counts toward event limit)
        // Also add as breadcrumb for context in future events
        Observability.recordBreadcrumb(prefixedMessage, level: .error, category: category)
        Observability.captureError(prefixedMessage, error: error)
    }
    
    /// Use `.fault` for:
    /// - Compromised functionality
    /// - Invariant breaches
    /// - Critical data corruption
    /// - Conditions that will lead to a crash
    ///
    /// Remote: Captured event (QUOTA - critical issues only)
    static func fault(
        _ message: String,
        logger: Logger = .app,
        category: String = "app.log",
        file: String = #file,
        line: UInt = #line
    ) {
        let prefixedMessage = LoggingConfiguration.logPrefix(file: file, line: line) + message
        
        // 1. Local
        logger.logFault(prefixedMessage)
        
        // 2. Remote capture (QUOTA - critical issues)
        Observability.recordBreadcrumb(prefixedMessage, level: .error, category: category)
        Observability.captureFault(prefixedMessage)
    }
    
    // MARK: - Crash Policy
    
    /// Crashes in all builds to ensure data integrity.
    /// Use for programming errors that should never happen.
    static func criticalFailure(
        _ message: String,
        file: StaticString = #file,
        filePath: String = #file,
        line: UInt = #line
    ) -> Never {
        let fileName = (filePath as NSString).lastPathComponent
        let fullMessage = "CRITICAL FAILURE at \(fileName):\(line): \(message)"
        
        Logger.app.logFault(fullMessage)
        Observability.captureFault(fullMessage)
        
        preconditionFailure(message, file: file, line: line)
    }
    
    /// Crashes in debug; logs and reports in release.
    /// Use for recoverable issues during development that shouldn't crash in production.
    static func assertionFailure(
        _ message: String,
        file: StaticString = #file,
        filePath: String = #file,
        line: UInt = #line
    ) {
        let fileName = (filePath as NSString).lastPathComponent
        let fullMessage = "ASSERTION FAILURE at \(fileName):\(line): \(message)"
        
#if DEBUG
        Logger.app.logFault(fullMessage)
        Observability.captureFault(fullMessage)
        Swift.assertionFailure(message, file: file, line: line)
#else
        Logger.app.logError("Assertion would fail in debug at \(fileName):\(line): \(message)")
        Observability.captureError(fullMessage, error: LoggingError.assertionFailure(message))
#endif
    }
    
    // MARK: - Privacy Guidelines
    
    /// Log sensitive data only in debug builds.
    /// In production, uses `.private` privacy level.
    static func debugPrivate(
        _ message: String,
        logger: Logger = .app,
        file: String = #file,
        line: UInt = #line
    ) {
        let prefixedMessage = LoggingConfiguration.logPrefix(file: file, line: line) + message
        
#if DEBUG
        logger.logDebug(prefixedMessage)
        // Don't send private data to remote in any build
#else
        // Privacy enforced
        logger.debug("\(prefixedMessage, privacy: .private)")
#endif
    }
}

// MARK: - Logging Errors

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
