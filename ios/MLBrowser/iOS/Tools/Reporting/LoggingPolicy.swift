//
//  LoggingPolicy.swift
//  AI Archeology
//
//  Defines logging conventions and crash policy for the application.
//  Routes logs to both OSLog (local) and Observability (remote).
//

import Foundation
import OSLog

/// Strips traceable data from log messages before they reach OSLog, Sentry, or the default
/// support-email attachment. The unredacted support attachment is the only deliberate exception
/// and requires the user's explicit choice in the mail form.
enum LogRedactor {
    private static let urlPattern = try? NSRegularExpression(
        pattern: #"\b(?:https?|file)://[^\s<>\"']+"#,
        options: [.caseInsensitive]
    )
    private static let emailPattern = try? NSRegularExpression(
        pattern: #"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#,
        options: [.caseInsensitive]
    )
    private static let uuidPattern = try? NSRegularExpression(
        pattern: #"\b[0-9A-F]{8}-(?:[0-9A-F]{4}-){3}[0-9A-F]{12}\b"#,
        options: [.caseInsensitive]
    )
    private static let absolutePathPattern = try? NSRegularExpression(
        pattern: #"/(?:[^\s/]+/)+[^\s/:;,\)\]\}]+"#
    )
    private static let identifierValuePattern = try? NSRegularExpression(
        pattern: #"\b((?:(?:account|user|session|device|installation|client|entity|download|transaction)[ _-]?(?:id|identifier)?|(?:auth|access|refresh|api)[ _-]?(?:token|key)?|token|identifier)\s*[:=])\s*(?:\"[^\"]*\"|[^,\s;\}\]]+)"#,
        options: [.caseInsensitive]
    )
    private static let coordinateValuePattern = try? NSRegularExpression(
        pattern: #"\b((?:latitude|lat|longitude|lon|lng|altitude|alt)\s*[:=])\s*-?\d+(?:\.\d+)?"#,
        options: [.caseInsensitive]
    )
    private static let coordinatePairPattern = try? NSRegularExpression(
        pattern: #"<[-+]?\d{1,2}\.\d+,\s*[-+]?\d{1,3}\.\d+>"#
    )
    private static let redactionPatterns: [(NSRegularExpression?, String)] = [
        (urlPattern, "[redacted URL]"),
        (emailPattern, "[redacted email]"),
        (identifierValuePattern, "$1[redacted]"),
        (uuidPattern, "[redacted ID]"),
        (absolutePathPattern, "[redacted path]"),
        (coordinateValuePattern, "$1 [redacted]"),
        (coordinatePairPattern, "[redacted location]")
    ]

    static func redactingSensitiveData(_ message: String) -> String {
        redactionPatterns.reduce(message) { partialMessage, pattern in
            guard let regex = pattern.0 else { return partialMessage }
            let range = NSRange(partialMessage.startIndex..., in: partialMessage)
            return regex.stringByReplacingMatches(
                in: partialMessage,
                options: [],
                range: range,
                withTemplate: pattern.1
            )
        }
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
        let prefixedMessage = LogRedactor.redactingSensitiveData(unredactedPrefixedMessage)

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
        let prefixedMessage = LogRedactor.redactingSensitiveData(unredactedPrefixedMessage)

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
        let prefixedMessage = LogRedactor.redactingSensitiveData(unredactedPrefixedMessage)

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
        let prefixedMessage = LogRedactor.redactingSensitiveData(unredactedPrefixedMessage)
        // The error description is appended locally for readability; the remote capture
        // receives the clean message because the crash-reporting service appends the
        // description itself (appending here too produced "msg: desc: desc" in Sentry).
        // System error descriptions often embed the failing URL — redact those too.
        let localMessage: String
        let unredactedLocalMessage: String
        if let error = error {
            localMessage = "\(prefixedMessage): \(LogRedactor.redactingSensitiveData(error.localizedDescription))"
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
        let prefixedMessage = LogRedactor.redactingSensitiveData(unredactedPrefixedMessage)

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
		let redactedMessage = LogRedactor.redactingSensitiveData(fullMessage)
		retainForSupportEmail(
			redactedMessage: redactedMessage,
			unredactedMessage: fullMessage,
			level: "FAULT",
			category: "app.log"
		)
        
        Logger.app.logFault(redactedMessage)
        Observability.captureFault(redactedMessage)
        
        preconditionFailure(redactedMessage, file: file, line: line)
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
		let redactedMessage = LogRedactor.redactingSensitiveData(fullMessage)
		retainForSupportEmail(
			redactedMessage: redactedMessage,
			unredactedMessage: fullMessage,
			level: "FAULT",
			category: "app.log"
		)
        
#if DEBUG
        Logger.app.logFault(redactedMessage)
        Observability.captureFault(redactedMessage)
        Swift.assertionFailure(redactedMessage, file: file, line: line)
#else
        Logger.app.logError("Assertion would fail in debug: \(redactedMessage)")
        Observability.captureError(redactedMessage, error: LoggingError.assertionFailure(redactedMessage))
#endif
    }
    
    // MARK: - Privacy Guidelines
    
    /// Logs sensitive diagnostic data locally. Release builds mark it private in OSLog and it is
    /// never sent remotely. It remains in the in-memory raw support-log tail only, which can leave
    /// the device solely when the user explicitly chooses the unredacted support attachment.
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

/// A thread-safe, bounded tail of text log entries. Keeping a tail rather than a count means a
/// burst of verbose events cannot make a support email exceed the five-MiB limit.
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
		logTail.removeSubrange(logTail.startIndex..<firstRetainedIndex)
		// The byte cutoff can land inside a multi-byte UTF-8 scalar. Drop only its remaining
		// continuation bytes so the attachment stays valid text, rather than sacrificing the next
		// whole entry. This retains the newest usable tail, minus at most three leading bytes.
		while let firstByte = logTail.first, firstByte & 0b1100_0000 == 0b1000_0000 {
			logTail.removeFirst()
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
