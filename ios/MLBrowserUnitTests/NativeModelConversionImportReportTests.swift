//
//  NativeModelConversionImportReportTests.swift
//  MLBrowserUnitTests
//

import Foundation
import NativeModelConverter
import XCTest
@testable import MLBrowser

final class NativeModelConversionImportReportTests: XCTestCase {
	func testReport_persistsRecoveryStateAndConverterIdentityWithoutPaths() async throws {
		let rootDirectory = try makeTemporaryDirectory()
		defer { try? FileManager.default.removeItem(at: rootDirectory) }
		let configurationID = UUID()
		let configurationDirectory = rootDirectory.appendingPathComponent(configurationID.uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: configurationDirectory, withIntermediateDirectories: true)

		let report = try NativeModelConversionImportReport(
			configurationID: configurationID,
			sourcePackageFilename: "source.aiagraph",
			retainOriginalPackage: true,
			wasRemoteImport: true
		)
		try report.write(in: configurationDirectory)
		let store = NativeModelConversionImportReportStore(report: report, configurationDirectory: configurationDirectory)
		try await store.transition(to: .converting)
		await store.record(progress: NativeModelConversionProgress(phase: .emittingModel, completedUnitCount: 10, totalUnitCount: 20))

		var loaded = try NativeModelConversionImportReport.load(in: configurationDirectory)
		XCTAssertEqual(loaded.state, .converting)
		XCTAssertEqual(loaded.configurationID, configurationID)
		XCTAssertEqual(loaded.nativeConverterPackageVersion, NativeModelConverterVersion.packageVersion)
		XCTAssertEqual(loaded.nativeConverterConversionRevision, NativeModelConverterVersion.conversionRevision)
		XCTAssertEqual(loaded.lastProgress?.completedUnitCount, 10)
		XCTAssertEqual(loaded.sourcePackageFilename, "source.aiagraph")
		let serializedData = try Data(
			contentsOf: NativeModelConversionImportReport.reportURL(in: configurationDirectory)
		)
		let serialized = try XCTUnwrap(String(bytes: serializedData, encoding: .utf8))
		XCTAssertFalse(serialized.contains(configurationDirectory.path))

		let recovered = NativeModelConversionImportReport.recoverableReports(in: rootDirectory)
		XCTAssertEqual(recovered.map(\.configurationID), [configurationID])

		XCTAssertTrue(loaded.markInterruptedIfIncomplete())
		XCTAssertEqual(loaded.state, .interrupted)
		XCTAssertEqual(loaded.diagnostic?.code, "app.interruptedBeforeCompletion")
		XCTAssertEqual(loaded.diagnostic?.phase, .emittingModel)
		XCTAssertFalse(loaded.markInterruptedIfIncomplete(), "An already recovered report must not duplicate an interruption event.")
	}

	func testRemoveTransientArtifacts_preservesSourceUntilExplicitDiscard() throws {
		let configurationDirectory = try makeTemporaryDirectory()
		defer { try? FileManager.default.removeItem(at: configurationDirectory) }
		let report = try NativeModelConversionImportReport(
			configurationID: UUID(),
			sourcePackageFilename: "source.aiagraph",
			retainOriginalPackage: false,
			wasRemoteImport: false
		)
		let sourceURL = report.sourcePackageURL(in: configurationDirectory)
		let modelURL = report.convertedModelURL(in: configurationDirectory)
		try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
		try Data("model".utf8).write(to: modelURL)
		try Data("metadata".utf8).write(to: NativeModelMetadataSidecar.url(for: modelURL))

		NativeModelConversionImportReport.removeTransientArtifacts(
			for: report,
			in: configurationDirectory,
			includingSourcePackage: false
		)
		XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
		XCTAssertFalse(FileManager.default.fileExists(atPath: modelURL.path))
		XCTAssertFalse(FileManager.default.fileExists(atPath: NativeModelMetadataSidecar.url(for: modelURL).path))

		NativeModelConversionImportReport.removeTransientArtifacts(
			for: report,
			in: configurationDirectory,
			includingSourcePackage: true
		)
		XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
	}

	private func makeTemporaryDirectory() throws -> URL {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		return directory
	}
}
