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
	/// The newest log entries, retained only while the app is running. The user can explicitly
	/// choose either redacted or unredacted data for a support-email attachment; neither is sent
	/// automatically.
	private static let redactedApplicationLogBuffer = ApplicationLogBuffer(
		maximumByteCount: ApplicationLogBuffer.maximumByteCount
	)
	private static let unredactedApplicationLogBuffer = ApplicationLogBuffer(
		maximumByteCount: ApplicationLogBuffer.maximumByteCount
	)

	/// Returns the latest five MiB of application-log entries for a user-selected support-email
	/// attachment. The default is redacted. When the user expressly enables unredacted data, the
	/// raw message text — including URLs, identifiers, and location data — is returned instead.
	static func recentApplicationLogData(sendUnredactedData: Bool = false) -> Data {
		(sendUnredactedData ? unredactedApplicationLogBuffer : redactedApplicationLogBuffer).snapshotData()
	}

	private static func retainForSupportEmail(
		redactedMessage: String,
		unredactedMessage: String,
		level: String,
		category: String
	) {
		redactedApplicationLogBuffer.append("[\(level)] [\(category)] \(redactedMessage)")
		unredactedApplicationLogBuffer.append("[\(level)] [\(category)] \(unredactedMessage)")
	}

	private static func retainUnredactedForSupportEmail(_ message: String, level: String, category: String) {
		unredactedApplicationLogBuffer.append("[\(level)] [\(category)] \(message)")
	}
    
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
        let unredactedPrefixedMessage = LoggingConfiguration.logPrefix(file: file, line: line) + message
        let prefixedMessage = LogRedactor.redactingURLs(unredactedPrefixedMessage)

        // 1. Local (Console.app / Xcode; release builds discard debug-level os.log)
        logger.logDebug(prefixedMessage)

#if DEBUG
		retainForSupportEmail(
			redactedMessage: prefixedMessage,
			unredactedMessage: unredactedPrefixedMessage,
			level: "DEBUG",
			category: category
		)
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
        let unredactedPrefixedMessage = LoggingConfiguration.logPrefix(file: file, line: line) + message
        let prefixedMessage = LogRedactor.redactingURLs(unredactedPrefixedMessage)

        // 1. Local
        logger.logInfo(prefixedMessage)
		retainForSupportEmail(
			redactedMessage: prefixedMessage,
			unredactedMessage: unredactedPrefixedMessage,
			level: "INFO",
			category: category
		)

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
        let unredactedPrefixedMessage = LoggingConfiguration.logPrefix(file: file, line: line) + message
        let prefixedMessage = LogRedactor.redactingURLs(unredactedPrefixedMessage)

        // 1. Local
        logger.logWarning(prefixedMessage)
		retainForSupportEmail(
			redactedMessage: prefixedMessage,
			unredactedMessage: unredactedPrefixedMessage,
			level: "WARNING",
			category: category
		)

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
        let unredactedPrefixedMessage = LoggingConfiguration.logPrefix(file: file, line: line) + message
        let prefixedMessage = LogRedactor.redactingURLs(unredactedPrefixedMessage)
        // The error description is appended locally for readability; the remote capture
        // receives the clean message because the crash-reporting service appends the
        // description itself (appending here too produced "msg: desc: desc" in Sentry).
        // System error descriptions often embed the failing URL — redact those too.
        let localMessage: String
        let unredactedLocalMessage: String
        if let error = error {
            localMessage = "\(prefixedMessage): \(LogRedactor.redactingURLs(error.localizedDescription))"
			unredactedLocalMessage = "\(unredactedPrefixedMessage): \(error.localizedDescription)"
        } else {
            localMessage = prefixedMessage
			unredactedLocalMessage = unredactedPrefixedMessage
        }

        // 1. Local
        logger.logError(localMessage)
		retainForSupportEmail(
			redactedMessage: localMessage,
			unredactedMessage: unredactedLocalMessage,
			level: "ERROR",
			category: category
		)

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
        let unredactedPrefixedMessage = LoggingConfiguration.logPrefix(file: file, line: line) + message
        let prefixedMessage = LogRedactor.redactingURLs(unredactedPrefixedMessage)

        // 1. Local
        logger.logFault(prefixedMessage)
		retainForSupportEmail(
			redactedMessage: prefixedMessage,
			unredactedMessage: unredactedPrefixedMessage,
			level: "FAULT",
			category: category
		)

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
		retainForSupportEmail(
			redactedMessage: LogRedactor.redactingURLs(fullMessage),
			unredactedMessage: fullMessage,
			level: "FAULT",
			category: "app.log"
		)
        
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
		retainForSupportEmail(
			redactedMessage: LogRedactor.redactingURLs(fullMessage),
			unredactedMessage: fullMessage,
			level: "FAULT",
			category: "app.log"
		)
        
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
		// This is excluded from the redacted support attachment. It is retained only in the
		// separate raw tail for a user who explicitly chooses to send unredacted diagnostic data.
		retainUnredactedForSupportEmail(prefixedMessage, level: "PRIVATE DEBUG", category: "app.log")
        
#if DEBUG
        logger.logDebug(prefixedMessage)
        // Don't send private data to remote in any build
#else
        // Privacy enforced
        logger.debug("\(prefixedMessage, privacy: .private)")
#endif
    }
}

/// A thread-safe, bounded tail of redacted text log entries. Keeping a tail rather than a count
/// means a burst of verbose events cannot make a support email exceed the five-MiB limit.
final class ApplicationLogBuffer: @unchecked Sendable {
	static let maximumByteCount = 5 * 1_024 * 1_024

	private let lock = NSLock()
	private let maximumByteCount: Int
	private var logTail = Data()

	init(maximumByteCount: Int) {
		self.maximumByteCount = maximumByteCount
	}

	func append(_ entry: String) {
		let entryData = Data((entry + "\n").utf8)
		lock.lock()
		defer { lock.unlock() }
		logTail.append(entryData)
		trimToLatestEntries()
	}

	func snapshotData() -> Data {
		lock.lock()
		defer { lock.unlock() }
		return logTail
	}

	private func trimToLatestEntries() {
		guard logTail.count > maximumByteCount else { return }
		let firstRetainedIndex = logTail.index(logTail.endIndex, offsetBy: -maximumByteCount)
		let retainedTail = logTail[firstRetainedIndex...]
		// Prefer starting at a whole entry. If one oversized entry occupies the whole tail, keep
		// its newest bytes instead; dropping it would lose the very event the report is about.
		if let newlineIndex = retainedTail.firstIndex(of: 0x0A),
		   newlineIndex < logTail.index(before: logTail.endIndex) {
			logTail.removeSubrange(...newlineIndex)
		} else {
			logTail.removeSubrange(logTail.startIndex..<firstRetainedIndex)
		}
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
