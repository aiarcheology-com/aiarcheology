//
//  NativeModelConversionReportingTests.swift
//  MLBrowserUnitTests
//

import Foundation
import NativeModelConverter
import UniformTypeIdentifiers
import XCTest
@testable import ML_Browser

/// The report text is the whole deliverable of AIA-0778: a failed conversion is the only signal the
/// app gets about which models it does not yet support, and that signal is only worth anything if
/// the text names the model and carries the diagnostic.
final class NativeModelConversionReportingTests: XCTestCase {
	private func failedReport(
		filename: String = "yolov8n.aiagraph",
		wasRemoteImport: Bool = false
	) throws -> NativeModelConversionImportReport {
		var report = try NativeModelConversionImportReport(
			configurationID: UUID(),
			sourcePackageFilename: filename,
			retainOriginalPackage: true,
			wasRemoteImport: wasRemoteImport
		)
		report.transition(
			to: .failed,
			diagnostic: NativeModelConversionDiagnostic(
				code: "unsupported-operation",
				phase: .failed,
				message: "Operation 'GridSample' has no Core ML equivalent."
			)
		)
		return report
	}

	func testLogText_NamesTheModelThatFailed() throws {
		let text = NativeModelConversionReporting.logText(for: try failedReport())

		// The point of the ticket. Without this the recipient learns which *phase* failed and
		// nothing about *what* failed.
		XCTAssertTrue(text.contains("yolov8n.aiagraph"), text)
	}

	func testLogText_CarriesTheDiagnosticCodeAndMessage() throws {
		let text = NativeModelConversionReporting.logText(for: try failedReport())

		XCTAssertTrue(text.contains("unsupported-operation"), text)
		XCTAssertTrue(text.contains("Operation 'GridSample' has no Core ML equivalent."), text)
		XCTAssertTrue(text.contains(NativeModelConversionImportState.failed.rawValue), text)
	}

	func testLogText_DistinguishesRemoteFromLocalAcquisition() throws {
		let remote = NativeModelConversionReporting.logText(for: try failedReport(wasRemoteImport: true))
		let local = NativeModelConversionReporting.logText(for: try failedReport(wasRemoteImport: false))

		XCTAssertTrue(remote.contains("remote link"), remote)
		XCTAssertTrue(local.contains("local file"), local)
		XCTAssertNotEqual(remote, local)
	}

	/// The report is deliberately free of user document locations. A filename identifies the model;
	/// a path would say where that user keeps their files, and the report has never recorded one.
	///
	/// Deliberately **not** "contains no `/`": a progress line renders `completed/total`, so that
	/// assertion would pass here only because this fixture records no progress, and would fail on a
	/// real report — a guard that holds by accident and breaks on the data it exists to protect.
	func testLogText_RecordsNoDocumentLocation() throws {
		var report = try failedReport(filename: "model.aiagraph")
		report.record(progress: NativeModelConversionProgress(
			phase: .emittingModel,
			completedUnitCount: 3,
			totalUnitCount: 10
		))
		let text = NativeModelConversionReporting.logText(for: report)

		XCTAssertTrue(text.contains("3/10"), "the fixture must exercise the progress path: \(text)")
		XCTAssertFalse(text.contains("file://"), text)
		XCTAssertFalse(text.contains("/Users/"), text)
		XCTAssertFalse(text.contains(FileManager.default.temporaryDirectory.path), text)
		// The configuration directory is named for this id, so leaking it leaks the location.
		XCTAssertFalse(text.contains(report.configurationID.uuidString), text)
	}

	/// The ticket's definition of a failing conversion, pinned: one that produced no Core ML model
	/// for a technical reason. Getting this wrong in either direction ruins the signal — a
	/// registered model reported as a failure is noise, a real failure with no button is a loss.
	func testReportableFailure_ExcludesSuccessAndUserCancellation() {
		XCTAssertFalse(NativeModelConversionImportState.registered.isReportableConversionFailure)
		XCTAssertFalse(NativeModelConversionImportState.cancelled.isReportableConversionFailure)

		for state: NativeModelConversionImportState in [.staged, .converting, .interrupted, .emitted, .failed] {
			XCTAssertTrue(state.isReportableConversionFailure, state.rawValue)
		}
	}

	/// The subject has to survive being read in a mail client's list: it names the app's support
	/// channel and the log, and nothing about it is derived from the report.
	func testSubject_NamesTheConversionLog() {
		XCTAssertTrue(NativeModelConversionReporting.subject().contains(L10n.Import.conversionLog))
	}

	// MARK: - The shared file

	/// The crash this guards: `ShareLink(item: someString)` gives the share sheet no filename, and
	/// macOS's Save-to-Files service then calls `-[NSSavePanel setNameFieldStringValue:]` with
	/// `nil` and raises `NSInternalInconsistencyException` from inside ShareKit. A non-empty name
	/// is the whole fix, so every test below is about the name being real.
	/// Every case here is one `NativeModelConversionImportReport.init` actually accepts — it rejects
	/// empty, `.`, `..` and anything with a separator, so those cannot reach this code and testing
	/// them would only be testing the fixture. What it does *not* reject is a name that is entirely
	/// whitespace, dots or dashes, and each of those sanitises away to nothing.
	func testExportFilename_IsNeverEmptyAndAlwaysEndsInTxt() throws {
		for filename in ["yolov8n.aiagraph", "...", "   ", "---", ".hidden", "模型.aiagraph"] {
			let name = NativeModelConversionReporting.exportFilename(
				for: try failedReport(filename: filename)
			)
			XCTAssertTrue(name.hasSuffix(".txt"), "'\(filename)' produced '\(name)'")
			XCTAssertFalse(
				name.hasPrefix("."),
				"'\(filename)' produced the dotfile '\(name)' — invisible in a save panel"
			)
			XCTAssertFalse(
				name == ".txt" || name.isEmpty,
				"'\(filename)' produced a nameless '\(name)', which is the shape that crashes the save panel"
			)
		}
	}

	func testExportFilename_NamesTheModel() throws {
		let name = NativeModelConversionReporting.exportFilename(for: try failedReport())

		// The recipient gets several of these; the model is what tells them apart.
		XCTAssertTrue(name.contains("yolov8n"), "got '\(name)'")
	}

	/// The outer guard the export relies on, asserted where it lives rather than assumed.
	///
	/// `sourcePackageFilename` names a file the *user* chose, and a separator in it would place the
	/// export outside its directory. `exportFilename(for:)` never sees one — but only because the
	/// report refuses to exist with such a name, and that refusal is the thing worth pinning: if it
	/// were ever relaxed, the sanitising below becomes the only guard rather than the second one.
	func testReport_CannotBeConstructedWithATraversingFilename() {
		for hostile in ["../../etc/passwd", "a/b/c.aiagraph", "/absolute.aiagraph", "", ".", ".."] {
			XCTAssertThrowsError(
				try failedReport(filename: hostile),
				"'\(hostile)' was accepted as a plain filename"
			)
		}
	}

	/// …and what does reach it still never grows a separator.
	func testExportFilename_HasNoPathSeparators() throws {
		for filename in ["yolov8n.aiagraph", "...", "   ", ".hidden", "模型.aiagraph"] {
			let name = NativeModelConversionReporting.exportFilename(
				for: try failedReport(filename: filename)
			)
			XCTAssertFalse(name.contains("/"), "'\(filename)' produced '\(name)'")
			XCTAssertFalse(name.contains(".."), "'\(filename)' produced '\(name)'")
		}
	}

	// MARK: - The size of the model that failed

	/// The gap this closes: `record(metrics:)` runs only after a *successful* conversion, so a
	/// failed report — the one a user is asked to send — carried no size at all.
	func testLogText_CarriesTheSourceSizeOnAFailedConversion() throws {
		var report = try failedReport()
		XCTAssertNil(report.metrics, "a failed conversion has no metrics; that is the premise here")

		report.record(sourceByteCount: 4_923_611)
		let text = NativeModelConversionReporting.logText(for: report)

		XCTAssertTrue(
			text.contains("4923611"),
			"a failed report must still say how big the model was; got:\n\(text)"
		)
	}

	/// Absent rather than zero when it could not be read — a zero would read as a real measurement.
	func testLogText_OmitsTheSourceSizeWhenItWasNeverRecorded() throws {
		let text = NativeModelConversionReporting.logText(for: try failedReport())

		XCTAssertFalse(text.contains("Source bytes"), "got:\n\(text)")
	}

	/// Both forms: the exact count is what gets compared against a limit, the readable one is what
	/// a human reacts to. 101390463 bytes is the size that prompted this — "101,390,463" alone
	/// does not tell a reader it is ~100 MB.
	func testLogText_PrintsTheSourceSizeExactlyAndReadably() throws {
		var report = try failedReport()
		report.record(sourceByteCount: 101_390_463)
		let text = NativeModelConversionReporting.logText(for: report)

		XCTAssertTrue(text.contains("101390463"), "got:\n\(text)")
		XCTAssertTrue(text.contains("MB"), "no human-readable size; got:\n\(text)")
	}

	/// A remote import's download address is a public link and the most useful field for
	/// reproducing the failure, so it is recorded — unlike a local path, which never is.
	func testLogText_CarriesTheDownloadURLOfARemoteImport() throws {
		var report = try failedReport(wasRemoteImport: true)
		report.record(sourceByteCount: nil, sourceURL: "https://example.com/models/license-plate.onnx")
		let text = NativeModelConversionReporting.logText(for: report)

		XCTAssertTrue(text.contains("https://example.com/models/license-plate.onnx"), "got:\n\(text)")
	}

	/// The host supplies no URL for a local file, so nothing can leak even by accident — asserted
	/// here so a future change that starts passing one has to argue with a test.
	func testLogText_HasNoSourceURLForALocalImport() throws {
		let text = NativeModelConversionReporting.logText(for: try failedReport())

		XCTAssertFalse(text.contains("Source URL"), "got:\n\(text)")
	}

	/// The download row's URL is free text the user can edit after downloading
	/// (`DownloadDetailView.swift:197`), and import checks only that it is non-empty — so a local
	/// path really can reach the recorder. Rejecting it is the last line, and it is asserted by
	/// *recording* the hostile value, not by assuming it never arrives.
	func testRecordedSourceURL_RejectsAnythingThatIsNotAWebAddress() throws {
		for hostile in [
			"file:///Users/alice/private-models/secret.onnx",
			"/Users/alice/private-models/secret.onnx",
			"~/Documents/secret.onnx",
			"ftp://example.com/model.onnx",
			"https:///no-host.onnx"
		] {
			var report = try failedReport(wasRemoteImport: true)
			report.record(sourceByteCount: nil, sourceURL: hostile)

			XCTAssertNil(report.sourceURL, "'\(hostile)' was recorded")
			let text = NativeModelConversionReporting.logText(for: report)
			XCTAssertFalse(text.contains("alice"), "got:\n\(text)")
			XCTAssertFalse(text.contains("Source URL"), "got:\n\(text)")
		}
	}

	/// `Downloader.swift:733` states the rule: full URLs may carry signed query parameters. A
	/// presigned link in a support attachment hands over working credentials.
	func testRecordedSourceURL_DropsQueryTokensAndCredentials() throws {
		var report = try failedReport(wasRemoteImport: true)
		report.record(
			sourceByteCount: nil,
			sourceURL: "https://user:hunter2@cdn.example.com/models/plate.onnx?X-Amz-Signature=deadbeef&token=abc#frag"
		)

		let recorded = try XCTUnwrap(report.sourceURL)
		XCTAssertEqual(recorded, "https://cdn.example.com/models/plate.onnx")
		XCTAssertFalse(recorded.contains("deadbeef"))
		XCTAssertFalse(recorded.contains("hunter2"))
		XCTAssertFalse(recorded.contains("token"))
		XCTAssertFalse(recorded.contains("frag"))
	}

	/// Two conversions of the same model must not share one export file: the second write would
	/// replace one the first report's share may still be loading.
	func testExportFilename_IsUniquePerReportEvenForTheSameModel() throws {
		let first = NativeModelConversionReporting.exportFilename(for: try failedReport())
		let second = NativeModelConversionReporting.exportFilename(for: try failedReport())

		XCTAssertNotEqual(first, second, "same model, different reports, one filename: \(first)")
		XCTAssertTrue(first.contains("yolov8n"), "the model must still be recognisable: \(first)")
	}

	func testExportedLogFile_WritesTheSameTextTheMailPathSends() throws {
		let report = try failedReport()
		let url = try XCTUnwrap(NativeModelConversionReporting.exportedLogFile(for: report))
		defer { try? FileManager.default.removeItem(at: url) }

		XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
		XCTAssertEqual(
			try String(contentsOf: url, encoding: .utf8),
			NativeModelConversionReporting.logText(for: report),
			"the file and the mail body must be the same report, or support gets two different stories"
		)
		XCTAssertEqual(url.lastPathComponent, NativeModelConversionReporting.exportFilename(for: report))
	}

	/// The regression that crashed macOS's Save-to-Files with *"Save: timed out loading URL"*.
	///
	/// This view is instantiated more than once, so the export runs repeatedly. An earlier version
	/// deleted and recreated its directory each time, which removed the file while the share sheet
	/// was still loading it. Repeated calls must therefore leave a readable file at a stable URL.
	func testExportedLogFile_SurvivesRepeatedCallsForTheSameReport() throws {
		let report = try failedReport()
		let first = try XCTUnwrap(NativeModelConversionReporting.exportedLogFile(for: report))
		let second = try XCTUnwrap(NativeModelConversionReporting.exportedLogFile(for: report))
		defer { try? FileManager.default.removeItem(at: first) }

		XCTAssertEqual(first, second, "the share sheet is holding this URL; it must not move")
		XCTAssertTrue(
			FileManager.default.fileExists(atPath: first.path),
			"a second export removed the file the first one handed to the share sheet"
		)
		XCTAssertEqual(
			try String(contentsOf: first, encoding: .utf8),
			NativeModelConversionReporting.logText(for: report)
		)
	}

	/// A different report must not overwrite the file an in-flight share is reading, so each one
	/// gets its own name.
	func testExportedLogFile_GivesDifferentReportsDifferentFiles() throws {
		let first = try XCTUnwrap(
			NativeModelConversionReporting.exportedLogFile(for: try failedReport(filename: "first-model.aiagraph"))
		)
		let second = try XCTUnwrap(
			NativeModelConversionReporting.exportedLogFile(for: try failedReport(filename: "second-model.aiagraph"))
		)
		defer {
			try? FileManager.default.removeItem(at: first)
			try? FileManager.default.removeItem(at: second)
		}

		XCTAssertNotEqual(first, second)
		XCTAssertTrue(try String(contentsOf: first, encoding: .utf8).contains("first-model"))
		XCTAssertTrue(try String(contentsOf: second, encoding: .utf8).contains("second-model"))
	}
}
