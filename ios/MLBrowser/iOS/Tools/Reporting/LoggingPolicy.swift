//
//  LoggingPolicy.swift
//  AI Archeology
//
//  Defines logging conventions and crash policy for the application.
//  Routes logs to both OSLog (local) and Observability (remote).
//

import Foundation
import OSLog

/// Strips traceable data from log messages.
///
/// Applied at two different moments, deliberately. OSLog and Sentry receive text redacted at the
/// point of logging. The support attachment is redacted at the point of **export** instead, because
/// the application log is stored raw: it is the complete record of what the app did, and a consumer
/// that needs less applies its own filter rather than deleting entries from the record. The
/// unredacted attachment is the exception the user opts into explicitly in the mail form.
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
	/// The user-facing switch, as persisted by `Settings`.
	///
	/// `LoggingPolicy` reads this itself rather than waiting to be told. `DependencyContainer`
	/// builds `Settings` lazily, and a background-download relaunch never builds it at all — so a
	/// push-only design would ignore a persisted opt-out on exactly the launches the user cannot
	/// see. `Settings` still pushes on change, as a fast path.
	static let detailedLoggingDefaultsKey = "detailedLoggingEnabled"

	private static let detailedLogging = DetailedLoggingSwitch(defaultsKey: detailedLoggingDefaultsKey)

	/// The off backing: session-scoped and memory-only, which is today's behaviour.
	private static let sessionLogBuffer = ApplicationLogBuffer(
		maximumByteCount: ApplicationLogBuffer.maximumByteCount
	)

	/// The on backing. `nil` only if the container has no Application Support directory, in which
	/// case the session buffer carries the log and nothing is persisted.
	/// `nonisolated(unsafe)` matching `Observability._service` (`Observability.swift:65`): written
	/// once at init, and thereafter only by the DEBUG-only test seam below, which runs before the
	/// suite under test logs anything.
	private nonisolated(unsafe) static var persistentLogStore: ApplicationLogFileStore? = ApplicationLogFileStore
		.defaultDirectoryURL()
		.map { ApplicationLogFileStore(directoryURL: $0) }

#if DEBUG
	/// Test seam. Without it, unit tests exercising the static store would write to the test host's
	/// real Application Support directory and accumulate across runs and suites — the file would
	/// outlive the process that created it, which is the entire point of the store and exactly what
	/// makes it unusable as shared test state.
	static func redirectApplicationLogForTesting(to directoryURL: URL, enabled: Bool = true) {
		persistentLogStore?.purge()
		sessionLogBuffer.purge()
		persistentLogStore = ApplicationLogFileStore(directoryURL: directoryURL)
		_ = detailedLogging.setEnabled(enabled)
	}
#endif

	/// Whether entries are persisted across launches — and, with it, whether `.debug` is retained.
	///
	/// The switch deliberately gates **persistence at every level**, not `.debug` verbosity. Gating
	/// only `.debug` would leave a control a user reads as "log less" while an unredacted on-disk
	/// record of URLs and identifiers kept growing at info/warning/error/fault.
	static var isDetailedLoggingEnabled: Bool {
		get { detailedLogging.isEnabled }
		set {
			guard detailedLogging.setEnabled(newValue) else { return }
			if newValue {
				persistentLogStore?.enable()
			} else {
				// Erases what was kept, ordered behind any writes already queued.
				persistentLogStore?.disable()
				sessionLogBuffer.purge()
			}
		}
	}

	private static var activeStore: ApplicationLogStoring {
		guard isDetailedLoggingEnabled, let persistentLogStore else {
			_ = disabledStoreReconciliation
			return sessionLogBuffer
		}
		return persistentLogStore
	}

	/// Deletes files left behind by a session that was switched off and then killed before the
	/// deletion ran.
	///
	/// Without this, that app comes back reading "off", takes the memory backing, and never looks at
	/// the old files again — so a user who turned the log off keeps a raw record of their browsing on
	/// disk indefinitely, with the UI insisting otherwise. `disable()` being synchronous makes the
	/// window small; this closes it.
	///
	/// A `static let` rather than a checked flag: this is reached from `activeStore`, which logging
	/// calls on every thread and actor in the app, so a plain `var` guard would be a data race — two
	/// threads could both read it unset. Swift initialises a static exactly once and does it
	/// thread-safely, which is precisely the one-time token wanted here.
	private static let disabledStoreReconciliation: Void = {
		persistentLogStore?.disable()
	}()

	/// Returns the latest five MiB of application-log entries for a user-selected support-email
	/// attachment. The default is redacted. When the user expressly enables unredacted data, the
	/// raw message text — including URLs, identifiers, and location data — is returned instead.
	///
	/// Entries are stored **raw** and redacted here, at the point of export. The log is the complete
	/// record of what the app did; a consumer that needs less applies its own filter, rather than
	/// the consumer's constraint reaching back and removing entries from the record itself.
	///
	/// Redaction runs per line because `ApplicationLogRecord` guarantees one entry is one line —
	/// applying seven regexes to a single five-MiB subject is not a workable alternative. Call this
	/// off the main thread: a full log costs on the order of a second.
	static func recentApplicationLogData(sendUnredactedData: Bool = false) -> Data {
		// Both backings, oldest first. A session that started with the switch off keeps those entries
		// in memory and everything after in the file; reading only the active one would hide exactly
		// the failure a user turned the switch on in order to report.
		var combined = sessionLogBuffer.snapshotData()
		if let persistentLogStore { combined.append(persistentLogStore.snapshotData()) }
		// A crash part-way through a write can leave the final record unterminated. Dropping it costs
		// one entry and prevents two different failures: a fragment whose redaction anchor was cut
		// off shipping unredacted, and — since the cut can land inside a multi-byte scalar — the
		// whole export failing to decode and collapsing to nothing.
		let raw = ApplicationLogRecord.trim(
			ApplicationLogRecord.droppingTornTrailingRecord(combined),
			to: ApplicationLogBuffer.maximumByteCount
		)
		guard sendUnredactedData == false else { return raw }
		// Lossy rather than failable, deliberately against `optional_data_string_conversion`: the
		// failable initializer returns nil for the whole snapshot when any byte is bad, which turned
		// one torn trailing record — the ordinary result of a crash mid-write — into an empty export
		// and replaced the user's entire log with the "unavailable" placeholder. That is the exact
		// report the feature exists to produce, so a replacement character in one entry is the
		// cheaper failure by a wide margin.
		// swiftlint:disable:next optional_data_string_conversion
		let text = String(decoding: raw, as: UTF8.self)
		let redacted = text
			.split(separator: "\n", omittingEmptySubsequences: false)
			.map { LogRedactor.redactingSensitiveData(String($0)) }
			.joined(separator: "\n")
		return Data(redacted.utf8)
	}

	/// Makes everything appended so far durable, **blocking the caller**. Only for the paths that may
	/// be the last thing this process does.
	///
	/// Not used by `error`/`fault`: `flush()` waits for the whole write queue and then an `fsync`,
	/// and there are over a hundred `error` call sites, many on the main actor. Making each of them
	/// wait on a possibly-wedged filesystem is the same unbounded main-thread wait that `append`'s
	/// 20 ms timeout exists to avoid.
	static func flushApplicationLog() {
		activeStore.flush()
	}

	/// Schedules the same durability work without waiting for it. Used by `error`/`fault`, where the
	/// point is that the entry reaches the file soon, not that the caller stops until it has.
	static func scheduleApplicationLogFlush() {
		persistentLogStore?.flushAsynchronously()
	}

	/// Deletes every retained entry, on disk and in memory.
	///
	/// One production caller: Clear Browsing History, whose whole purpose is erasing the hosts and
	/// addresses this log also holds. Restore Defaults deliberately does **not** call it — it resets
	/// preference values and nothing else, consistent with the rest of `Settings.reset()`, which does
	/// not delete findings, screenshots or history either.
	static func purgeApplicationLog() {
		persistentLogStore?.purge()
		sessionLogBuffer.purge()
	}

	/// - Parameter isTerminal: set by the paths on their way to `preconditionFailure`, so the store
	///   appends past its cap instead of performing `close`/`rename`/`open` on a thread that is
	///   about to crash deliberately.
	private static func retain(
		_ rawMessage: String,
		level: String,
		category: String,
		isTerminal: Bool = false
	) {
		let entry = "[\(level)] [\(category)] \(rawMessage)"
		if isTerminal, isDetailedLoggingEnabled, let persistentLogStore {
			persistentLogStore.append(entry, isTerminal: true)
		} else {
			activeStore.append(entry)
		}
	}
    
    // MARK: - Logging Levels
    
    /// Use `.debug` for:
    /// - Internal developer details
    /// - Verbose diagnostic information
    /// - Development-only messages
    ///
    /// Support log: retained in **every** build configuration, subject to the user's detailed-log
    /// switch (`isDetailedLoggingEnabled`).
    ///
    /// Remote: Breadcrumb in DEBUG builds only — debug-level messages may fire in hot
    /// loops (e.g. per-detection-pass timings) and would flood the production
    /// breadcrumb buffer, crowding out the trail that matters when a crash uploads.
    /// The gate lives here so call sites never need their own `#if DEBUG`. That quota
    /// rule applies to breadcrumbs and to nothing else: applying it to the support
    /// attachment as well is what removed 87 debug call sites from every customer
    /// report (AIA-0602).
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

        // 2. Support log — every build configuration, but only while the user keeps the detailed
        // log on. Capture is decoupled from consumption; the remaining gate is the user's, not the
        // compiler's. Off is today's behaviour exactly: no debug entries retained anywhere.
        if isDetailedLoggingEnabled {
            retain(unredactedPrefixedMessage, level: "DEBUG", category: category)
        }

#if DEBUG
        // 3. Remote breadcrumb (only uploaded with crash/error events). This gate stays where the
        // quota actually is, so production breadcrumb volume is unchanged by AIA-0602.
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
		retain(unredactedPrefixedMessage, level: "INFO", category: category)

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
		retain(unredactedPrefixedMessage, level: "WARNING", category: category)

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
		retain(unredactedLocalMessage, level: "ERROR", category: category)
		// An error is usually what a support report is about, so its durability is scheduled ahead of
		// ordinary entries — but not waited on. Blocking here would put an fsync on the caller's
		// thread at every one of the hundred-plus error sites, many of them the main actor.
		scheduleApplicationLogFlush()

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
		retain(unredactedPrefixedMessage, level: "FAULT", category: category)
		scheduleApplicationLogFlush()

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
		retain(fullMessage, level: "FAULT", category: "app.log", isTerminal: true)
		flushApplicationLog()

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
		retain(fullMessage, level: "FAULT", category: "app.log", isTerminal: true)
		flushApplicationLog()

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
    //
    // `debugPrivate` lived here: a level written only to the unredacted buffer, so that genuinely
    // sensitive diagnostics could reach a support attachment only when the user opted in. It had
    // zero production call sites — its only caller in the repository was its own unit test — and it
    // was the sole reason the store would have needed a per-line marker distinguishing entries that
    // must be *dropped* from the redacted export rather than redacted. Removed with AIA-0602; the
    // store keeps raw text and redacts uniformly on read.
}

/// Thread-safe holder for the runtime logging switch, resolved from `UserDefaults` on first read.
///
/// Resolution is lazy rather than eager so that reading the flag cannot depend on when — or
/// whether — `Settings` is constructed. Logging happens from every thread and actor in the app, so
/// the value is lock-guarded rather than assumed to be main-actor.
final class DetailedLoggingSwitch: @unchecked Sendable {
	private let lock = NSLock()
	private let defaults: UserDefaults
	private let defaultsKey: String
	private var resolvedValue: Bool?

	init(defaultsKey: String, defaults: UserDefaults = .standard) {
		self.defaultsKey = defaultsKey
		self.defaults = defaults
	}

	var isEnabled: Bool {
		lock.lock()
		defer { lock.unlock() }
		if let resolvedValue { return resolvedValue }
		// Absent key means a fresh install that has not reached `Settings` yet. Default on: the
		// point of the feature is that a problem is already recorded by the time it is reported.
		let value = defaults.object(forKey: defaultsKey) as? Bool ?? true
		resolvedValue = value
		return value
	}

	/// - Returns: `true` when the value actually changed, so callers can skip the erase work on a
	///   redundant write (`Settings` pushes on every `didSet`, including no-op restores).
	func setEnabled(_ newValue: Bool) -> Bool {
		lock.lock()
		defer { lock.unlock() }
		guard resolvedValue != newValue else { return false }
		resolvedValue = newValue
		return true
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
			// Say how much went missing, and say it accurately: the count is taken against the text
			// actually kept, not against the budget, because the notice itself occupies part of the
			// budget. Computing it the obvious way understates the loss by the notice's own length.
			let originalByteCount = body.utf8.count
			// Reserve room using the widest the notice could be — its number can never exceed the
			// original size — then report the loss against the text that actually survived. The
			// entry can come out a few bytes under budget; the figure being true matters more.
			let reservedNoticeByteCount = " …[truncated \(originalByteCount) bytes]".utf8.count
			let kept = clamping(body, toUTF8ByteCount: maximumEntryByteCount - reservedNoticeByteCount)
			body = kept + " …[truncated \(originalByteCount - kept.utf8.count) bytes]"
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

	/// Drops an unterminated final record.
	///
	/// Every framed record ends in a newline, so trailing bytes without one are the remains of a
	/// write interrupted by a crash or power loss. Keeping them causes two distinct failures, and the
	/// second is the quiet one: a fragment whose redaction anchor was cut off ships unredacted in the
	/// *default* export, and — because the cut can land inside a multi-byte scalar — a failable UTF-8
	/// decode of the whole snapshot returns nil, replacing the user's entire log with a placeholder.
	static func droppingTornTrailingRecord(_ data: Data) -> Data {
		guard data.isEmpty == false, data.last != 0x0A else { return data }
		guard let lastNewline = data.lastIndex(of: 0x0A) else { return Data() }
		return Data(data[...lastNewline])
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
/// and the rotation check runs *before* a write rather than after, so neither file exceeds its half.
/// (Checking *after* the write is the obvious version and is wrong: it permits `previous` to be
/// half-plus-one-entry while `current` fills independently.)
///
/// Two honest qualifications, because "unconditional" would be an overclaim:
/// - it assumes a single framed record fits in half the budget — true by a wide margin in production
///   (64 KiB against 2.5 MiB), but not for the deliberately tiny budgets some tests use;
/// - a **terminal** append runs past the cap on purpose, since rotating on the way to
///   `preconditionFailure` is filesystem surgery at the worst possible moment. That overage lasts
///   until the next launch, which rotates an oversized `current` before writing.
///
/// What holds without qualification is the *delivered* bound: `LoggingPolicy.recentApplicationLogData`
/// trims to the budget, so no export exceeds it whatever the files did.
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

		// A throttle, not a bound — and the distinction matters, so it is stated rather than implied.
		// Once the slots are taken the record is enqueued anyway, so a wedged filesystem still lets
		// closures accumulate; what this buys is 20 ms of slack per caller for the queue to catch up.
		// It deliberately does not wait longer: `DispatchSemaphore` does not donate priority, and an
		// unbounded wait on the main thread against a stuck disk would be a watchdog kill — the
		// diagnostics subsystem terminating the app it exists to diagnose. Dropping instead of
		// enqueuing was the alternative, and it is worse: it would punch a hole in the middle of the
		// log with nothing marking it.
		let acquiredSlot = slots.wait(timeout: .now() + .milliseconds(20)) == .success

		queue.async { [weak self] in
			guard let self else { return }
			defer { if acquiredSlot { self.slots.signal() } }
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

	/// The same work, ordered behind the queued writes but not waited on. For callers that want the
	/// entry on disk soon without stopping until it is — see `LoggingPolicy.scheduleApplicationLogFlush`.
	func flushAsynchronously() {
		queue.async { try? self.handle?.synchronize() }
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
		// `sync`, not `async`. Ordering behind the outstanding writes is necessary but not
		// sufficient: with `async`, the switch is persisted as off the moment the setter returns
		// while deletion is merely queued, so an app suspended or killed in between comes back with
		// the toggle reading off and the raw files still on disk — permanently, because the next
		// launch uses the memory backing and never revisits them. Blocking a settings tap for a file
		// delete is the cheaper side of that trade.
		queue.sync {
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
		truncateTornTrailingRecord()
		// A terminal append deliberately runs past the cap (rotating on the way to
		// `preconditionFailure` is filesystem surgery at the worst moment), so a crashed session can
		// leave an oversized `current`. Rotating here bounds the overage to that one launch.
		if currentByteCount > rotationByteCount {
			rotate()
		}
	}

	/// Removes an unterminated final record left by an interrupted write, so the fragment cannot
	/// fuse with the next append into one bogus line.
	private func truncateTornTrailingRecord() {
		guard currentByteCount > 0,
			  let data = try? Data(contentsOf: currentURL, options: .mappedIfSafe),
			  data.last != 0x0A else { return }
		let repaired = ApplicationLogRecord.droppingTornTrailingRecord(Data(data))
		guard (try? repaired.write(to: currentURL, options: .atomic)) != nil else { return }
		currentByteCount = repaired.count
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
		purgeAgedFiles()
		do {
			if fileManager.fileExists(atPath: previousURL.path) {
				try fileManager.removeItem(at: previousURL)
			}
			try fileManager.moveItem(at: currentURL, to: previousURL)
			currentByteCount = 0
		} catch {
			// Swallowing this and resetting the counter anyway is how the cap stops holding: if
			// `previous` cannot be removed the move fails, `current` survives, and a zeroed counter
			// lets it grow without bound. Re-derive from the file instead, so the next write sees the
			// real size and tries to rotate again.
			currentByteCount = byteCount(of: currentURL)
		}
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
