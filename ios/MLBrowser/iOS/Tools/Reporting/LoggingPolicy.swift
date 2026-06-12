//
//  LoggingPolicy.swift
//  AI Archeology
//
//  Defines logging conventions and crash policy for the application.
//  Routes logs to both OSLog (local) and Observability (remote).
//

import Foundation
import OSLog

/// Strips sensitive parts from log messages before they reach OSLog (public) or Sentry.
///
/// URLs may carry tokens or signed query parameters (e.g. S3/CloudFront presigned links),
/// so query strings and fragments are removed from any http(s) URL embedded in a message.
/// Use `LoggingPolicy.debugPrivate` when the full URL is needed for local debugging.
enum LogRedactor {
    private static let urlQueryPattern = try? NSRegularExpression(
        pattern: #"(https?://[^\s?#]+)[?#]\S*"#,
        options: [.caseInsensitive]
    )

    static func redactingURLs(_ message: String) -> String {
        guard let regex = urlQueryPattern else { return message }
        let range = NSRange(message.startIndex..., in: message)
        return regex.stringByReplacingMatches(in: message, options: [], range: range, withTemplate: "$1")
    }
}

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
    /// Remote: Breadcrumb in DEBUG builds only — debug-level messages may fire in hot
    /// loops (e.g. per-detection-pass timings) and would flood the production
    /// breadcrumb buffer, crowding out the trail that matters when a crash uploads.
    /// The gate lives here so call sites never need their own `#if DEBUG`.
    static func debug(
        _ message: String,
        logger: Logger = .app,
        category: String = "app.log",
        file: String = #file,
        line: UInt = #line
    ) {
        let prefixedMessage = LoggingConfiguration.logPrefix(file: file, line: line) + LogRedactor.redactingURLs(message)

        // 1. Local (Console.app / Xcode; release builds discard debug-level os.log)
        logger.logDebug(prefixedMessage)

#if DEBUG
        // 2. Remote breadcrumb (only uploaded with crash/error events)
        Observability.recordBreadcrumb(prefixedMessage, level: .debug, category: category)
#endif
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
        let prefixedMessage = LoggingConfiguration.logPrefix(file: file, line: line) + LogRedactor.redactingURLs(message)

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
        let prefixedMessage = LoggingConfiguration.logPrefix(file: file, line: line) + LogRedactor.redactingURLs(message)

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
        let prefixedMessage = LoggingConfiguration.logPrefix(file: file, line: line) + LogRedactor.redactingURLs(message)
        // The error description is appended locally for readability; the remote capture
        // receives the clean message because the crash-reporting service appends the
        // description itself (appending here too produced "msg: desc: desc" in Sentry).
        // System error descriptions often embed the failing URL — redact those too.
        let localMessage: String
        if let error = error {
            localMessage = "\(prefixedMessage): \(LogRedactor.redactingURLs(error.localizedDescription))"
        } else {
            localMessage = prefixedMessage
        }

        // 1. Local
        logger.logError(localMessage)

        // 2. Remote capture (QUOTA - counts toward event limit)
        // Also add as breadcrumb for context in future events
        Observability.recordBreadcrumb(localMessage, level: .error, category: category)
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
        let prefixedMessage = LoggingConfiguration.logPrefix(file: file, line: line) + LogRedactor.redactingURLs(message)

        // 1. Local
        logger.logFault(prefixedMessage)

        // 2. Remote capture (QUOTA - critical issues)
        Observability.recordBreadcrumb(prefixedMessage, level: .fatal, category: category)
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
