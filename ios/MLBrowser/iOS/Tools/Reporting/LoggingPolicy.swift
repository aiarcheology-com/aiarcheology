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

/// Shared record framing for every application-log backing.
///
/// One entry becomes exactly one physical line. That single property is what makes byte-level
/// trimming safe: a trim can always be resolved back to whole entries, and no redaction pattern can
/// ever be split across a line boundary.
enum ApplicationLogRecord {
	/// The largest single entry retained. Deliberately far below any store's byte budget — that gap
	/// is what makes `trim(_:to:)`'s empty return unreachable in production (see its note).
	static let maximumEntryByteCount = 64 * 1_024

	/// Escapes embedded newlines, clamps an oversized entry, and terminates the record.
	///
	/// Newlines are escaped rather than preserved because two redaction patterns match across them:
	/// `identifierValuePattern` and `coordinateValuePattern` separate key from value with `\s*`, and
	/// the former's quoted alternative `"[^"]*"` spans line breaks outright. Redacting the export
	/// line by line would therefore miss `token:\n  secret` — and redacting a 5 MiB blob in one
	/// regex subject is not an option. Multi-line entries are real: `error()` interpolates
	/// `localizedDescription`, and `String(describing:)` of a `DecodingError` is several lines.
	static func frame(_ entry: String) -> Data {
		let singleLine = entry
			.replacingOccurrences(of: "\r\n", with: "\\n")
			.replacingOccurrences(of: "\n", with: "\\n")
			.replacingOccurrences(of: "\r", with: "\\n")

		var body = singleLine
		if body.utf8.count > maximumEntryByteCount {
			// Say how much went missing. A silently shortened entry reads as a complete one.
			let droppedByteCount = body.utf8.count - maximumEntryByteCount
			let notice = " …[truncated \(droppedByteCount) bytes]"
			body = clamping(body, toUTF8ByteCount: maximumEntryByteCount - notice.utf8.count) + notice
		}

		var record = Data(body.utf8)
		record.append(0x0A)
		return record
	}

	/// Returns the newest `maximumByteCount` bytes, containing **only complete entries**.
	///
	/// The byte cut lands in raw, unredacted text, so a surviving half-entry is a live leak: a
	/// truncated `https://…`, `token=…`, or UUID loses the left anchor its redaction pattern needs
	/// and would then ship *unredacted in the default attachment*. Dropping through the first
	/// newline costs at most one entry and closes that.
	///
	/// Returns empty when the budget cannot hold one whole entry. Empty beats a fragment, and the
	/// case is unreachable in production — `maximumEntryByteCount` (64 KiB) is far below any store's
	/// budget. Do not "fix" this to return the fragment.
	static func trim(_ data: Data, to maximumByteCount: Int) -> Data {
		guard data.count > maximumByteCount else { return data }
		let window = data.suffix(maximumByteCount)
		guard let firstNewline = window.firstIndex(of: 0x0A) else { return Data() }
		return Data(window[window.index(after: firstNewline)...])
	}

	/// Truncates on a grapheme boundary so the result is always valid UTF-8. Iterating `Character`s
	/// rather than trimming stray continuation bytes keeps combining sequences intact.
	private static func clamping(_ text: String, toUTF8ByteCount budget: Int) -> String {
		guard budget > 0 else { return "" }
		var end = text.startIndex
		var used = 0
		for index in text.indices {
			let width = String(text[index]).utf8.count
			if used + width > budget { break }
			used += width
			end = text.index(after: index)
		}
		return String(text[text.startIndex..<end])
	}
}

/// A bounded tail of application-log entries. Implementations differ only in where the tail lives;
/// both frame and trim through `ApplicationLogRecord`, so the export has identical safety properties
/// whichever one is active.
protocol ApplicationLogStoring: AnyObject, Sendable {
	func append(_ entry: String)
	func snapshotData() -> Data
	/// Blocks until everything already appended is durable. No-op for a memory-backed store.
	func flush()
	/// Discards everything retained, including any on-disk copy.
	func purge()
}

/// A thread-safe, bounded, in-memory tail — the backing used when the user has turned the detailed
/// log off. Session-scoped: it dies with the process, which is the whole point of the off state.
final class ApplicationLogBuffer: ApplicationLogStoring, @unchecked Sendable {
	static let maximumByteCount = 5 * 1_024 * 1_024

	private let lock = NSLock()
	private let maximumByteCount: Int
	private var logTail = Data()

	init(maximumByteCount: Int) {
		self.maximumByteCount = maximumByteCount
	}

	func append(_ entry: String) {
		let record = ApplicationLogRecord.frame(entry)
		lock.lock()
		defer { lock.unlock() }
		logTail.append(record)
		logTail = ApplicationLogRecord.trim(logTail, to: maximumByteCount)
	}

	func snapshotData() -> Data {
		lock.lock()
		defer { lock.unlock() }
		return logTail
	}

	func flush() {}

	func purge() {
		lock.lock()
		defer { lock.unlock() }
		logTail = Data()
	}
}

/// A bounded, crash-durable, on-disk tail — the backing used when the user keeps the detailed log
/// on. Unlike `ApplicationLogBuffer` it survives relaunch, so a report can cover the session in
/// which the problem actually happened.
///
/// **The five-MiB cap is structural, not bookkeeping.** Two files rotate at half the budget each,
/// and the rotation check runs *before* a write rather than after, so neither file can ever exceed
/// its half. With `ApplicationLogRecord.maximumEntryByteCount` bounding a single entry far below
/// that, `current ≤ budget/2` and `previous ≤ budget/2` hold unconditionally — the total is bounded
/// by construction, with no counter to trust and nothing to scan. (Checking *after* the write is the
/// obvious version and is wrong: it permits `previous` to be half-plus-one-entry while `current`
/// fills independently.)
///
/// **The serial queue is the buffer.** There is deliberately no ring of my own in front of it: a
/// bounded queue that evicts to stay bounded would delete entries the disk budget had room for, and
/// preferentially the oldest pending ones — the context immediately before the failure being
/// diagnosed. A truncated head is legible to whoever reads the log; a hole in the middle is not.
final class ApplicationLogFileStore: ApplicationLogStoring, @unchecked Sendable {
	static let maximumByteCount = 5 * 1_024 * 1_024
	static let maximumRetainedAge: TimeInterval = 7 * 24 * 60 * 60

	private static let currentFileName = "application-current.log"
	private static let previousFileName = "application-previous.log"
	/// Outstanding writes tolerated before a caller is throttled. Sized so an ordinary logging burst
	/// never reaches it; see `append(_:isTerminal:)` for why hitting it is not fatal.
	private static let outstandingWriteLimit = 512

	private let directoryURL: URL
	private let maximumByteCount: Int
	private let maximumRetainedAge: TimeInterval
	private let fileManager: FileManager
	private let queue = DispatchQueue(label: "com.aiarcheology.ios.application-log", qos: .utility)
	private let slots: DispatchSemaphore

	// Everything below is read and written ONLY on `queue`.
	private var handle: FileHandle?
	private var currentByteCount = 0
	private var isPrepared = false
	private var isEnabled = true
	private var throttledWriteCount = 0

	private var rotationByteCount: Int { maximumByteCount / 2 }
	private var currentURL: URL { directoryURL.appendingPathComponent(Self.currentFileName) }
	private var previousURL: URL { directoryURL.appendingPathComponent(Self.previousFileName) }

	init(
		directoryURL: URL,
		maximumByteCount: Int = ApplicationLogFileStore.maximumByteCount,
		maximumRetainedAge: TimeInterval = ApplicationLogFileStore.maximumRetainedAge,
		fileManager: FileManager = .default
	) {
		self.directoryURL = directoryURL
		self.maximumByteCount = maximumByteCount
		self.maximumRetainedAge = maximumRetainedAge
		self.fileManager = fileManager
		self.slots = DispatchSemaphore(value: Self.outstandingWriteLimit)
	}

	/// The default location: **not** `Caches`, which the system may purge under disk pressure —
	/// precisely when a user is having the kind of day that ends in a support email.
	static func defaultDirectoryURL(fileManager: FileManager = .default) -> URL? {
		fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
			.first?
			.appendingPathComponent("Diagnostics", isDirectory: true)
	}

	// MARK: - ApplicationLogStoring

	func append(_ entry: String) {
		append(entry, isTerminal: false)
	}

	/// - Parameter isTerminal: set by the paths that are on their way to `preconditionFailure`. Such
	///   an append skips the rotation check and runs past the cap, because `close`+`rename`+`open`
	///   is filesystem surgery to be performing on the way to a deliberate crash. The oversized
	///   `current` it can leave behind is absorbed at the next launch, when the byte counter is
	///   re-derived from the file itself.
	func append(_ entry: String, isTerminal: Bool) {
		let record = ApplicationLogRecord.frame(entry)

		// Backpressure, never a hang. `DispatchSemaphore` does not donate priority, so an unbounded
		// `wait()` on the main thread against a wedged filesystem would be a watchdog kill — the
		// diagnostics subsystem terminating the app it exists to diagnose. On timeout the record is
		// enqueued anyway and the event is counted, so this can only ever cost latency.
		let acquiredSlot = slots.wait(timeout: .now() + .milliseconds(20)) == .success

		queue.async { [weak self] in
			guard let self else { return }
			defer { if acquiredSlot { self.slots.signal() } }
			if acquiredSlot == false { self.throttledWriteCount += 1 }
			self.write(record, allowRotation: isTerminal == false)
		}
	}

	func snapshotData() -> Data {
		queue.sync {
			self.prepareIfNeeded()
			var combined = (try? Data(contentsOf: previousURL)) ?? Data()
			combined.append((try? Data(contentsOf: currentURL)) ?? Data())
			// Second belt. Rotation already bounds the total; this also guarantees the *export* is
			// whole-entry even if a file was truncated underneath us.
			return ApplicationLogRecord.trim(combined, to: maximumByteCount)
		}
	}

	func flush() {
		queue.sync {
			// `synchronize()` is the documented durability operation: a completed `write(2)` outlives
			// the process, but not a panic or power loss.
			try? self.handle?.synchronize()
		}
	}

	func purge() {
		queue.sync {
			self.closeHandle()
			self.removeFiles()
			self.currentByteCount = 0
		}
	}

	/// Stops persistence and erases what was kept, ordered **behind** every outstanding write.
	///
	/// The ordering is the point. Up to `outstandingWriteLimit` records can be queued when the user
	/// turns the switch off on the main actor; deleting the files directly would let one of those
	/// blocks re-create `application-current.log` with raw entries immediately afterwards, leaving
	/// the switch reading off while an unredacted file exists on disk.
	func disable() {
		queue.async {
			self.closeHandle()
			self.isEnabled = false
			self.removeFiles()
			self.currentByteCount = 0
		}
	}

	func enable() {
		queue.async { self.isEnabled = true }
	}

	// MARK: - Queue-confined internals
	//
	// INVARIANT: nothing below calls any `LoggingPolicy` API, or any helper that might — several
	// `FileManager` extensions in this project log. A `LoggingPolicy` call from here would re-enter
	// `queue.sync` from the queue itself, which is an unconditional deadlock, not a smell.

	private func write(_ record: Data, allowRotation: Bool) {
		prepareIfNeeded()
		guard isEnabled else { return }

		if allowRotation, currentByteCount + record.count > rotationByteCount {
			rotate()
		}
		guard let handle = openHandleIfNeeded() else { return }
		// `write(contentsOf:)`, never `write(_:)`: the latter raises `NSFileHandleOperationException`
		// on ENOSPC/EIO, which Swift cannot catch — the diagnostics path would crash the app.
		do {
			try handle.write(contentsOf: record)
			currentByteCount += record.count
		} catch {
			closeHandle()
		}
	}

	private func prepareIfNeeded() {
		guard isPrepared == false else { return }
		isPrepared = true

		try? fileManager.createDirectory(
			at: directoryURL,
			withIntermediateDirectories: true,
			// NOT `.complete`: appends happen while the app is backgrounded and the device is
			// locked, and `.complete` would fail every one of them.
			attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
		)
		var excludedDirectoryURL = directoryURL
		var resourceValues = URLResourceValues()
		resourceValues.isExcludedFromBackup = true
		try? excludedDirectoryURL.setResourceValues(resourceValues)

		purgeAgedFiles()
		currentByteCount = byteCount(of: currentURL)
	}

	/// Age is keyed on **creation** date, not modification date: `current`'s mtime is refreshed by
	/// its newest append so it would never look old, and `previous`'s mtime describes its newest
	/// entry — the wrong end of the window to be measuring.
	///
	/// A long-lived `current` is deleted whole, recent entries included. That is the honest reading
	/// of a retention limit: the file's oldest entries are past it, and there is no per-entry index
	/// to split on.
	private func purgeAgedFiles() {
		for url in [currentURL, previousURL] where hasExpired(url) {
			try? fileManager.removeItem(at: url)
		}
	}

	private func hasExpired(_ url: URL) -> Bool {
		guard let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate else {
			return false
		}
		return Date().timeIntervalSince(created) > maximumRetainedAge
	}

	/// Close → rename → open, in that order. A retained `FileHandle` follows the renamed inode, so
	/// keeping it open across the rename would silently append into `previous` while the byte
	/// counter tracked `current`.
	private func rotate() {
		closeHandle()
		try? fileManager.removeItem(at: previousURL)
		try? fileManager.moveItem(at: currentURL, to: previousURL)
		currentByteCount = 0
	}

	private func openHandleIfNeeded() -> FileHandle? {
		if let handle { return handle }
		if fileManager.fileExists(atPath: currentURL.path) == false {
			// A missing `current` is a normal state, not an error: first launch, post-rotation, or a
			// crash between the rename and the re-open.
			fileManager.createFile(
				atPath: currentURL.path,
				contents: nil,
				attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
			)
		}
		guard let opened = try? FileHandle(forWritingTo: currentURL) else { return nil }
		_ = try? opened.seekToEnd()
		// Re-derive rather than trust the in-memory count; this is what self-heals a crash part-way
		// through a rotation.
		currentByteCount = byteCount(of: currentURL)
		handle = opened
		return opened
	}

	private func closeHandle() {
		try? handle?.close()
		handle = nil
	}

	private func removeFiles() {
		try? fileManager.removeItem(at: currentURL)
		try? fileManager.removeItem(at: previousURL)
	}

	private func byteCount(of url: URL) -> Int {
		(try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
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
