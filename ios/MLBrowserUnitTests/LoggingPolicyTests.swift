//
//  LoggingPolicyTests.swift
//  AI ArcheologyTests
//
//  Tests for LoggingPolicy and LoggingError.
//

import XCTest
@testable import ML_Browser

// MARK: - LoggingError Tests

final class LoggingErrorTests: XCTestCase {
    
    // MARK: - Error Description Tests
    
    func testAssertionFailure_ErrorDescription() {
        let error = LoggingError.assertionFailure("Test message")
        XCTAssertEqual(error.errorDescription, "Assertion failure: Test message")
    }
    
    func testUnexpectedNil_ErrorDescription() {
        let error = LoggingError.unexpectedNil("some context")
        XCTAssertEqual(error.errorDescription, "Unexpected nil value: some context")
    }
    
    func testInvalidState_ErrorDescription() {
        let error = LoggingError.invalidState("state description")
        XCTAssertEqual(error.errorDescription, "Invalid state: state description")
    }
    
    // MARK: - LocalizedError Conformance
    
    func testAssertionFailure_IsLocalizedError() {
        let error: Error = LoggingError.assertionFailure("Test")
        XCTAssertNotNil(error.localizedDescription)
        XCTAssertTrue(error.localizedDescription.contains("Assertion failure"))
    }
    
    func testUnexpectedNil_IsLocalizedError() {
        let error: Error = LoggingError.unexpectedNil("context")
        XCTAssertNotNil(error.localizedDescription)
        XCTAssertTrue(error.localizedDescription.contains("Unexpected nil"))
    }
    
    func testInvalidState_IsLocalizedError() {
        let error: Error = LoggingError.invalidState("description")
        XCTAssertNotNil(error.localizedDescription)
        XCTAssertTrue(error.localizedDescription.contains("Invalid state"))
    }
    
    // MARK: - Empty Message Tests
    
    func testAssertionFailure_EmptyMessage() {
        let error = LoggingError.assertionFailure("")
        XCTAssertEqual(error.errorDescription, "Assertion failure: ")
    }
    
    func testUnexpectedNil_EmptyContext() {
        let error = LoggingError.unexpectedNil("")
        XCTAssertEqual(error.errorDescription, "Unexpected nil value: ")
    }
    
    func testInvalidState_EmptyDescription() {
        let error = LoggingError.invalidState("")
        XCTAssertEqual(error.errorDescription, "Invalid state: ")
    }
    
    // MARK: - Special Characters Tests
    
    func testAssertionFailure_WithSpecialCharacters() {
        let error = LoggingError.assertionFailure("Line 1\nLine 2\tTabbed")
        XCTAssertTrue(error.errorDescription?.contains("Line 1") ?? false)
        XCTAssertTrue(error.errorDescription?.contains("Line 2") ?? false)
    }
    
    func testUnexpectedNil_WithUnicode() {
        let error = LoggingError.unexpectedNil("Variable: 变量 🎉")
        XCTAssertTrue(error.errorDescription?.contains("变量") ?? false)
        XCTAssertTrue(error.errorDescription?.contains("🎉") ?? false)
    }
    
    // MARK: - Equality by Description (since enum cases with associated values)
    
    func testDifferentCases_HaveDifferentDescriptions() {
        let assertion = LoggingError.assertionFailure("test")
        let unexpectedNil = LoggingError.unexpectedNil("test")
        let invalidState = LoggingError.invalidState("test")
        
        XCTAssertNotEqual(assertion.errorDescription, unexpectedNil.errorDescription)
        XCTAssertNotEqual(assertion.errorDescription, invalidState.errorDescription)
        XCTAssertNotEqual(unexpectedNil.errorDescription, invalidState.errorDescription)
    }
}

// MARK: - LoggingPolicy Tests

final class LoggingPolicyTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
        // Ensure Observability is started for tests
        // Using NoOp to avoid actual Sentry calls during tests
        if !Observability.isStarted {
            Observability.start(with: NoOpCrashReportingService())
        }
    }
    
    // Note: These tests verify the methods don't crash.
    // Full integration testing would require mocking Observability.
    
    // MARK: - Basic Logging Tests
    
    func testDebug_DoesNotCrash() {
        LoggingPolicy.debug("Test debug message")
    }
    
    func testDebug_WithCategory_DoesNotCrash() {
        LoggingPolicy.debug("Test debug message", category: "test.category")
    }
    
    func testInfo_DoesNotCrash() {
        LoggingPolicy.info("Test info message")
    }
    
    func testInfo_WithCategory_DoesNotCrash() {
        LoggingPolicy.info("Test info message", category: "navigation")
    }
    
    func testWarning_DoesNotCrash() {
        LoggingPolicy.warning("Test warning message")
    }
    
    func testWarning_WithCategory_DoesNotCrash() {
        LoggingPolicy.warning("Test warning message", category: "network")
    }
    
    func testError_WithoutError_DoesNotCrash() {
        LoggingPolicy.error("Test error message")
    }
    
    func testError_WithError_DoesNotCrash() {
        let testError = NSError(domain: "TestDomain", code: 42, userInfo: nil)
        LoggingPolicy.error("Test error message", error: testError)
    }
    
    func testError_WithCategory_DoesNotCrash() {
        LoggingPolicy.error("Test error message", category: "persistence")
    }
    
    func testFault_DoesNotCrash() {
        LoggingPolicy.fault("Test fault message")
    }
    
    func testFault_WithCategory_DoesNotCrash() {
        LoggingPolicy.fault("Test fault message", category: "critical")
    }
    
    // MARK: - Empty Message Tests
    
    func testDebug_EmptyMessage_DoesNotCrash() {
        LoggingPolicy.debug("")
    }
    
    func testInfo_EmptyMessage_DoesNotCrash() {
        LoggingPolicy.info("")
    }
    
    func testWarning_EmptyMessage_DoesNotCrash() {
        LoggingPolicy.warning("")
    }
    
    func testError_EmptyMessage_DoesNotCrash() {
        LoggingPolicy.error("")
    }
    
    func testFault_EmptyMessage_DoesNotCrash() {
        LoggingPolicy.fault("")
    }
    
    // MARK: - Long Message Tests
    
    func testDebug_LongMessage_DoesNotCrash() {
        let longMessage = String(repeating: "A", count: 10000)
        LoggingPolicy.debug(longMessage)
    }
    
    func testInfo_LongMessage_DoesNotCrash() {
        let longMessage = String(repeating: "B", count: 10000)
        LoggingPolicy.info(longMessage)
    }
    
    func testError_LongMessage_DoesNotCrash() {
        let longMessage = String(repeating: "C", count: 10000)
        LoggingPolicy.error(longMessage)
    }
    
    // MARK: - Unicode Tests
    
    func testInfo_UnicodeMessage_DoesNotCrash() {
        LoggingPolicy.info("Unicode: 你好世界 🌍 مرحبا")
    }
    
    func testError_UnicodeMessage_DoesNotCrash() {
        LoggingPolicy.error("Error with unicode: 错误 ⚠️")
    }
    
    // Note: criticalFailure and assertionFailure are not tested as they terminate/assert
}

final class LogRedactorTests: XCTestCase {
	func testRedactingSensitiveData_RemovesTraceableValues() {
		let url = "https://models.example.com/private/weights.mlmodel?token=secret#fragment"
		let identifier = "123E4567-E89B-12D3-A456-426614174000"
		let path = "/var/mobile/Containers/Data/Application/secret/model.mlmodel"
		let message = "url=\(url) id=\(identifier) path=\(path) accountID=acct-123 token=secret-token email=user@example.com latitude: 48.8566 longitude: 2.3522 location=<+48.8566,+2.3522>"

		let redacted = LogRedactor.redactingSensitiveData(message)

		for sensitiveValue in [url, identifier, path, "acct-123", "secret-token", "user@example.com", "48.8566", "2.3522"] {
			XCTAssertFalse(redacted.contains(sensitiveValue), "Expected \(sensitiveValue) to be redacted")
		}
		XCTAssertTrue(redacted.contains("[redacted URL]"))
		XCTAssertTrue(redacted.contains("[redacted ID]"))
		XCTAssertTrue(redacted.contains("[redacted path]"))
		XCTAssertTrue(redacted.contains("accountID=[redacted]"))
		XCTAssertTrue(redacted.contains("token=[redacted]"))
	}
}

final class ApplicationLogBufferTests: XCTestCase {
	private var directoryURL: URL!

	override func setUpWithError() throws {
		try super.setUpWithError()
		// The static store is now disk-backed, so without this it would write into the test host's
		// real container and accumulate across runs and suites.
		directoryURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("AIA0602-static-\(UUID().uuidString)", isDirectory: true)
		LoggingPolicy.redirectApplicationLogForTesting(to: directoryURL)
	}

	override func tearDownWithError() throws {
		try? FileManager.default.removeItem(at: directoryURL)
		try super.tearDownWithError()
	}

	func testRecentApplicationLogData_UsesTheRawMessageOnlyWhenExplicitlyRequested() {
		let marker = UUID().uuidString
		let sensitiveURL = "https://models.example.com/weights?downloadID=\(marker)"
		let sensitivePath = "/var/mobile/Containers/Data/Application/\(marker)/model.mlmodel"
		let sensitiveLatitude = "48.8566"
		LoggingPolicy.info(
			"Support-log marker: \(sensitiveURL) accountID=\(marker) path=\(sensitivePath) latitude: \(sensitiveLatitude)"
		)

		guard let redactedLog = String(
			bytes: LoggingPolicy.recentApplicationLogData(),
			encoding: .utf8
		), let unredactedLog = String(
			bytes: LoggingPolicy.recentApplicationLogData(sendUnredactedData: true),
			encoding: .utf8
		) else {
			return XCTFail("Expected UTF-8 application logs")
		}

		for sensitiveValue in [marker, sensitiveURL, sensitivePath, sensitiveLatitude] {
			XCTAssertFalse(redactedLog.contains(sensitiveValue), "Expected \(sensitiveValue) to be redacted")
			XCTAssertTrue(unredactedLog.contains(sensitiveValue), "Expected \(sensitiveValue) in the raw attachment")
		}
	}

	// The four tests below previously asserted that a byte-level trim keeps the *partial* first
	// entry (`"st\nsecond\n"`, `"cdef\n"`, …). That was safe only while the buffer held text already
	// redacted at write time. It now holds raw text, so a surviving half-entry can carry a truncated
	// URL or token whose left anchor no longer matches its redaction pattern — and that fragment
	// would ship in the *default*, supposedly-redacted attachment. The rule is now "whole entries
	// only" (AIA-0602).

	func testSnapshotData_KeepsOnlyWholeEntriesWithinTheByteLimit() {
		let buffer = ApplicationLogBuffer(maximumByteCount: 10)
		buffer.append("first")
		buffer.append("second")

		guard let text = String(bytes: buffer.snapshotData(), encoding: .utf8) else {
			return XCTFail("Expected a UTF-8 application log")
		}
		XCTAssertEqual(text, "second\n", "The partial leading entry must be dropped, not truncated")
	}

	func testSnapshotData_DropsAnOversizedOlderEntryRatherThanAFragmentOfIt() {
		let buffer = ApplicationLogBuffer(maximumByteCount: 10)
		buffer.append(String(repeating: "a", count: 12))
		buffer.append("x")

		guard let text = String(bytes: buffer.snapshotData(), encoding: .utf8) else {
			return XCTFail("Expected a UTF-8 application log")
		}
		XCTAssertEqual(text, "x\n")
	}

	/// A budget too small for one whole entry yields nothing. Empty beats a fragment, and this is
	/// unreachable in production: a single entry is clamped far below any store's budget.
	func testSnapshotData_IsEmptyWhenTheBudgetCannotHoldOneWholeEntry() {
		let buffer = ApplicationLogBuffer(maximumByteCount: 5)
		buffer.append("abcdef")

		XCTAssertEqual(buffer.snapshotData().count, 0)
	}

	/// Entry boundaries are always UTF-8 scalar boundaries, so resolving the cut to a whole entry
	/// makes the old "drop stray continuation bytes" pass unnecessary — the result is valid by
	/// construction even when the byte cut lands inside a multi-byte scalar.
	func testSnapshotData_IsValidUTF8WhenTheCutLandsInsideAMultiByteScalar() {
		let buffer = ApplicationLogBuffer(maximumByteCount: 12)
		buffer.append("aa€bbbb")
		buffer.append("ccc")

		guard let text = String(bytes: buffer.snapshotData(), encoding: .utf8) else {
			return XCTFail("Expected a UTF-8 application log")
		}
		XCTAssertEqual(text, "ccc\n")
	}

	/// The defect this rule exists for: the trim must not leave a fragment whose redaction anchor
	/// has been cut off.
	func testSnapshotData_NeverLeavesAFragmentOfASensitiveValue() {
		let buffer = ApplicationLogBuffer(maximumByteCount: 24)
		buffer.append("https://host/p?token=SECRETVALUE")
		buffer.append("later entry")

		guard let text = String(bytes: buffer.snapshotData(), encoding: .utf8) else {
			return XCTFail("Expected a UTF-8 application log")
		}
		XCTAssertFalse(text.contains("SECRET"), "A truncated secret must never survive the trim")
		XCTAssertEqual(text, "later entry\n")
	}
}

final class ApplicationLogRecordTests: XCTestCase {
	func testFrame_CollapsesAMultiLineEntryToOnePhysicalLine() {
		let framed = ApplicationLogRecord.frame("first\nsecond\r\nthird\rfourth")

		guard let text = String(bytes: framed, encoding: .utf8) else {
			return XCTFail("Expected UTF-8")
		}
		XCTAssertEqual(text, "first\\nsecond\\nthird\\nfourth\n")
		XCTAssertEqual(text.filter { $0 == "\n" }.count, 1, "One entry must be exactly one line")
	}

	/// Asserts the reported figure, not merely that a figure is present. The previous version only
	/// checked `contains("truncated")`, so it would have passed with any number — and the number was
	/// in fact wrong by the notice's own length, because the loss was computed against the budget
	/// rather than against the text that actually survived.
	func testFrame_ClampsAnOversizedEntryAndReportsTheRealLoss() throws {
		let originalByteCount = ApplicationLogRecord.maximumEntryByteCount * 2
		let oversized = String(repeating: "a", count: originalByteCount)

		let framed = ApplicationLogRecord.frame(oversized)

		XCTAssertLessThanOrEqual(framed.count, ApplicationLogRecord.maximumEntryByteCount + 1)
		let text = try XCTUnwrap(String(bytes: framed, encoding: .utf8))
		let separator = " …[truncated "
		let parts = text.components(separatedBy: separator)
		XCTAssertEqual(parts.count, 2, "A shortened entry must not read as a complete one")
		let keptByteCount = parts[0].utf8.count
		let reported = try XCTUnwrap(Int(parts[1].components(separatedBy: " bytes]").first ?? ""))

		XCTAssertEqual(
			reported,
			originalByteCount - keptByteCount,
			"The figure has to describe the text that survived, not the budget"
		)
	}

	func testDroppingTornTrailingRecord_RemovesAnUnterminatedTail() {
		let intact = Data("first\nsecond\n".utf8)
		XCTAssertEqual(ApplicationLogRecord.droppingTornTrailingRecord(intact), intact)

		let torn = Data("first\nsecond\nthird-was-cut".utf8)
		XCTAssertEqual(
			ApplicationLogRecord.droppingTornTrailingRecord(torn),
			intact,
			"A record without its terminator is the remains of an interrupted write"
		)
	}

	/// The retention window is set almost entirely by the highest-volume call site, which is
	/// `Detector.detect`'s per-pass summary. At the measured 195 bytes and the default three-second
	/// cadence, five MiB covers ~22 hours of continuous detection with one detector and ~7.5 with
	/// three; at the fastest selectable cadence and three detectors it is still ~2.5 hours. Those
	/// numbers are why the switch ships on by default (AIA-0602).
	///
	/// This guards the assumption rather than the arithmetic: restoring per-region detail would put
	/// 16 of these lines in each pass and collapse the window to minutes, which is the failure the
	/// budget exists to prevent.
	func testDetectionSummaryEntry_StaysWithinTheBudgetTheWindowAssumes() {
		let summary = "Detection over 15 regions completed with 3 objects (7 raw) in 0.5843729972839355s; "
			+ "slowest region 11 at 0.0614290237426758s, 9 empty"
		let entry = "[DEBUG] [app.log] 2026-08-13T14:51:45.123Z Detector.swift:137 " + summary

		let byteCount = ApplicationLogRecord.frame(entry).count

		XCTAssertLessThanOrEqual(
			byteCount,
			256,
			"A per-pass detection entry above this collapses the retention window; re-measure before raising it"
		)
	}

	func testTrim_ReturnsTheInputUnchangedWhenItFits() {
		let data = Data("short\n".utf8)

		XCTAssertEqual(ApplicationLogRecord.trim(data, to: 1_024), data)
	}
}

final class ApplicationLogFileStoreTests: XCTestCase {
	private var directoryURL: URL!

	override func setUpWithError() throws {
		try super.setUpWithError()
		directoryURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("AIA0602-\(UUID().uuidString)", isDirectory: true)
	}

	override func tearDownWithError() throws {
		try? FileManager.default.removeItem(at: directoryURL)
		try super.tearDownWithError()
	}

	private func bytesOnDisk() -> Int {
		let contents = (try? FileManager.default.contentsOfDirectory(
			at: directoryURL,
			includingPropertiesForKeys: [.fileSizeKey]
		)) ?? []
		return contents.reduce(0) { total, url in
			total + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
		}
	}

	/// The headline invariant, at the real budget: far more than the cap goes in, never more than
	/// the cap is on disk. Rotation is checked *before* each write, so this holds by construction
	/// rather than by a counter that could drift.
	func testAppend_NeverExceedsTheByteBudgetOnDisk() {
		let store = ApplicationLogFileStore(directoryURL: directoryURL, maximumByteCount: 64 * 1_024)
		let entry = String(repeating: "x", count: 512)

		for index in 0..<4_000 {
			store.append("\(index) \(entry)")
		}
		store.flush()

		XCTAssertGreaterThan(bytesOnDisk(), 0, "Something must have been written")
		XCTAssertLessThanOrEqual(bytesOnDisk(), 64 * 1_024, "The on-disk cap is not a suggestion")
	}

	func testAppend_KeepsTheNewestEntriesWhenTheBudgetIsExceeded() {
		let store = ApplicationLogFileStore(directoryURL: directoryURL, maximumByteCount: 8 * 1_024)

		for index in 0..<2_000 {
			store.append("entry-\(index)")
		}
		store.flush()

		guard let text = String(bytes: store.snapshotData(), encoding: .utf8) else {
			return XCTFail("Expected a UTF-8 application log")
		}
		XCTAssertTrue(text.contains("entry-1999"), "The newest entry must survive")
		XCTAssertFalse(text.contains("entry-0\n"), "The oldest entries must have rolled off")
	}

	/// The reason the store exists at all: a report must be able to cover the session in which the
	/// problem happened, not the one in which the user got around to reporting it.
	func testSnapshotData_SurvivesAcrossStoreInstances() {
		let first = ApplicationLogFileStore(directoryURL: directoryURL)
		first.append("from the earlier session")
		first.flush()

		let second = ApplicationLogFileStore(directoryURL: directoryURL)

		guard let text = String(bytes: second.snapshotData(), encoding: .utf8) else {
			return XCTFail("Expected a UTF-8 application log")
		}
		XCTAssertTrue(text.contains("from the earlier session"))
	}

	/// Disable must be ordered *behind* outstanding writes. Deleting the files directly would let a
	/// queued block re-create them immediately afterwards, leaving the switch reading off while an
	/// unredacted file sits on disk.
	func testDisable_LeavesNothingOnDiskEvenWithWritesInFlight() {
		let store = ApplicationLogFileStore(directoryURL: directoryURL)
		for index in 0..<500 {
			store.append("entry-\(index)")
		}

		store.disable()
		store.flush()

		XCTAssertEqual(bytesOnDisk(), 0, "A disabled store must leave no raw log behind")
		XCTAssertEqual(store.snapshotData().count, 0)
	}

	func testAppend_IsIgnoredWhileDisabled() {
		let store = ApplicationLogFileStore(directoryURL: directoryURL)
		store.disable()

		store.append("must not be written")
		store.flush()

		XCTAssertEqual(bytesOnDisk(), 0)
	}

	/// Age is keyed on creation date: `current`'s modification date is refreshed by its newest
	/// append, so an mtime-based cap would never expire the file that actually accumulates entries.
	func testPrepare_DiscardsFilesOlderThanTheRetentionLimit() throws {
		let seed = ApplicationLogFileStore(directoryURL: directoryURL)
		seed.append("from long ago")
		seed.flush()

		let stale = Date(timeIntervalSinceNow: -8 * 24 * 60 * 60)
		for url in try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) {
			try FileManager.default.setAttributes([.creationDate: stale], ofItemAtPath: url.path)
		}

		let reopened = ApplicationLogFileStore(
			directoryURL: directoryURL,
			maximumRetainedAge: 7 * 24 * 60 * 60
		)

		XCTAssertEqual(reopened.snapshotData().count, 0, "Expired entries must not survive a launch")
	}

	func testAppend_ClampsAnOversizedEntryRatherThanBlowingTheBudget() {
		let store = ApplicationLogFileStore(directoryURL: directoryURL, maximumByteCount: 1_024 * 1_024)

		store.append(String(repeating: "z", count: ApplicationLogRecord.maximumEntryByteCount * 3))
		store.flush()

		XCTAssertLessThanOrEqual(bytesOnDisk(), ApplicationLogRecord.maximumEntryByteCount + 1)
	}
}

/// The runtime switch that replaced the `#if DEBUG` gate.
///
/// These cannot prove "retained in a release build" — a unit test runs in DEBUG, where the old code
/// retained too. What they prove is the thing that actually changed: retention is now controlled at
/// runtime by the user's switch rather than at compile time, so the release behaviour follows from
/// there being no `#if` left on that path.
final class DetailedLoggingSwitchTests: XCTestCase {
	private var directoryURL: URL!

	override func setUpWithError() throws {
		try super.setUpWithError()
		directoryURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("AIA0602-switch-\(UUID().uuidString)", isDirectory: true)
		LoggingPolicy.redirectApplicationLogForTesting(to: directoryURL, enabled: true)
	}

	override func tearDownWithError() throws {
		LoggingPolicy.redirectApplicationLogForTesting(to: directoryURL, enabled: true)
		try? FileManager.default.removeItem(at: directoryURL)
		try super.tearDownWithError()
	}

	private func currentLog() -> String {
		String(bytes: LoggingPolicy.recentApplicationLogData(sendUnredactedData: true), encoding: .utf8) ?? ""
	}

	private func bytesOnDisk() -> Int {
		let contents = (try? FileManager.default.contentsOfDirectory(
			at: directoryURL,
			includingPropertiesForKeys: [.fileSizeKey]
		)) ?? []
		return contents.reduce(0) { $0 + (((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize)) ?? 0) }
	}

	func testDebugEntriesAreRetainedWhileTheSwitchIsOn() {
		let marker = UUID().uuidString

		LoggingPolicy.debug("detection pass \(marker)")

		XCTAssertTrue(currentLog().contains(marker), "The 87 debug call sites are the point of AIA-0602")
	}

	func testDebugEntriesAreDroppedWhileTheSwitchIsOff() {
		LoggingPolicy.isDetailedLoggingEnabled = false
		let debugMarker = UUID().uuidString
		let infoMarker = UUID().uuidString

		LoggingPolicy.debug("detection pass \(debugMarker)")
		LoggingPolicy.info("lifecycle \(infoMarker)")

		let log = currentLog()
		XCTAssertFalse(log.contains(debugMarker), "Off must be today's behaviour: no debug retention")
		XCTAssertTrue(log.contains(infoMarker), "Off still keeps a session log, so the attachment is never empty")
	}

	/// The switch gates persistence at *every* level, not debug verbosity. Gating only debug would
	/// leave a control a user reads as "log less" while an unredacted on-disk record of URLs kept
	/// growing at info/warning/error.
	func testTurningTheSwitchOffLeavesNothingOnDisk() {
		LoggingPolicy.info("something with a host https://example.com/page")
		LoggingPolicy.flushApplicationLog()
		XCTAssertGreaterThan(bytesOnDisk(), 0, "Precondition: the on state persists")

		LoggingPolicy.isDetailedLoggingEnabled = false
		LoggingPolicy.info("after the switch went off")
		LoggingPolicy.flushApplicationLog()

		XCTAssertEqual(bytesOnDisk(), 0, "Off must erase the record, not just stop adding to it")
	}

	/// Entries are stored raw and redacted at export, so the default attachment must still be clean.
	func testTheDefaultExportIsRedactedEvenThoughTheStoreIsRaw() {
		let marker = UUID().uuidString
		LoggingPolicy.info("visited https://models.example.com/w?downloadID=\(marker)")

		let redacted = String(
			bytes: LoggingPolicy.recentApplicationLogData(),
			encoding: .utf8
		) ?? ""

		XCTAssertFalse(redacted.contains(marker), "Read-time redaction must still strip the URL")
		XCTAssertTrue(redacted.contains("[redacted URL]"))
		XCTAssertTrue(currentLog().contains(marker), "…while the stored record stays complete")
	}

	/// A user who hits a bug and *then* switches detailed logging on to report it must still get the
	/// entries from before the switch — those live in the memory backing, and reading only the
	/// active store would hide exactly the failure they turned it on for.
	func testEnablingMidSessionStillExportsWhatWasLoggedBeforehand() {
		LoggingPolicy.isDetailedLoggingEnabled = false
		let beforeMarker = UUID().uuidString
		LoggingPolicy.info("before the switch \(beforeMarker)")

		LoggingPolicy.isDetailedLoggingEnabled = true
		let afterMarker = UUID().uuidString
		LoggingPolicy.info("after the switch \(afterMarker)")
		LoggingPolicy.flushApplicationLog()

		let log = currentLog()
		XCTAssertTrue(log.contains(beforeMarker), "The pre-toggle session log must survive enabling")
		XCTAssertTrue(log.contains(afterMarker))
	}

	/// A crash part-way through a write leaves the last record unterminated. The failable decode this
	/// used to do turned that into an empty export — the user's whole log replaced by the
	/// "unavailable" placeholder, in precisely the post-crash report the feature exists for.
	func testATornTrailingRecordDoesNotCollapseTheRedactedExport() throws {
		LoggingPolicy.info("a complete entry that must survive")
		LoggingPolicy.flushApplicationLog()

		let currentURL = directoryURL.appendingPathComponent("application-current.log")
		var raw = try Data(contentsOf: currentURL)
		// A multi-byte scalar cut in half: valid bytes, invalid UTF-8 tail.
		raw.append(contentsOf: [0xE2, 0x82])
		try raw.write(to: currentURL, options: .atomic)

		let redacted = String(bytes: LoggingPolicy.recentApplicationLogData(), encoding: .utf8) ?? ""

		XCTAssertTrue(
			redacted.contains("a complete entry that must survive"),
			"One torn tail must not cost the user the entire log"
		)
	}

	/// The remote brake has to stop the behaviour, not just hide the switch. A kill switch that left
	/// the store writing — or that stopped writing but left raw addresses on disk — would be worse
	/// than none, because the UI would say the feature was off.
	func testTheRemoteBrakeStopsPersistenceAndErasesWhatWasStored() {
		LoggingPolicy.info("recorded while the brake was open https://example.com/page")
		LoggingPolicy.flushApplicationLog()
		XCTAssertGreaterThan(bytesOnDisk(), 0, "Precondition: persistence is on")

		// What `Settings.applyDetailedLoggingToLogger` computes when the flag goes false while the
		// user's own preference stays true.
		LoggingPolicy.isDetailedLoggingEnabled = true && false

		XCTAssertEqual(bytesOnDisk(), 0, "Flipping the brake must delete the stored log, not just stop adding")

		LoggingPolicy.info("recorded while the brake was shut")
		LoggingPolicy.flushApplicationLog()
		XCTAssertEqual(bytesOnDisk(), 0, "…and nothing may be written afterwards")

		// Diagnostics are not gone, only session-scoped — the pre-AIA-0602 behaviour.
		XCTAssertTrue(
			currentLog().contains("recorded while the brake was shut"),
			"Off must fall back to a session log, not to no log at all"
		)
	}

	func testPurgeRemovesEverythingRetained() {
		LoggingPolicy.info("to be purged")
		LoggingPolicy.flushApplicationLog()

		LoggingPolicy.purgeApplicationLog()

		XCTAssertEqual(bytesOnDisk(), 0)
		XCTAssertEqual(LoggingPolicy.recentApplicationLogData().count, 0)
	}
}
