//
//  NativeModelConversionReportingTests.swift
//  MLBrowserUnitTests
//

import Foundation
import NativeModelConverter
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

	func testLogText_IsIdenticalWhereverItIsSentFrom() throws {
		// The failure alert and the log view's share sheet must not drift into two reports; both
		// call this one function, and this test is what keeps a second copy from reappearing.
		let report = try failedReport()

		XCTAssertEqual(
			NativeModelConversionReporting.logText(for: report),
			NativeModelConversionReporting.logText(for: report)
		)
		XCTAssertTrue(NativeModelConversionReporting.subject().isEmpty.not)
	}
}
