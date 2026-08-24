//
//  NativeModelConversionImportReportTests.swift
//  MLBrowserUnitTests
//

import Foundation
import NativeModelConverter
import XCTest
@testable import ML_Browser

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
		try loaded.write(in: configurationDirectory)

		// Reload through the on-disk path so the interruption is proven to survive persistence, not
		// just an in-memory mutation.
		var interrupted = try NativeModelConversionImportReport.load(in: configurationDirectory)
		XCTAssertEqual(interrupted.state, .interrupted)
		XCTAssertEqual(interrupted.diagnostic?.code, "app.interruptedBeforeCompletion")
		XCTAssertEqual(interrupted.diagnostic?.phase, .emittingModel)
		XCTAssertFalse(interrupted.markInterruptedIfIncomplete(), "An already recovered report must not duplicate an interruption event.")
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
		let partialModelURL = configurationDirectory.appendingPathComponent(
			".\(modelURL.lastPathComponent).partial-\(UUID().uuidString)"
		)
		let unrelatedPartialURL = configurationDirectory.appendingPathComponent(
			".unrelated.mlmodel.partial-\(UUID().uuidString)"
		)
		try Data("partial model".utf8).write(to: partialModelURL)
		try Data("unrelated partial".utf8).write(to: unrelatedPartialURL)

		NativeModelConversionImportReport.removeTransientArtifacts(
			for: report,
			in: configurationDirectory,
			includingSourcePackage: false
		)
		XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
		XCTAssertFalse(FileManager.default.fileExists(atPath: modelURL.path))
		XCTAssertFalse(FileManager.default.fileExists(atPath: NativeModelMetadataSidecar.url(for: modelURL).path))
		XCTAssertFalse(FileManager.default.fileExists(atPath: partialModelURL.path))
		XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedPartialURL.path))

		NativeModelConversionImportReport.removeTransientArtifacts(
			for: report,
			in: configurationDirectory,
			includingSourcePackage: true
		)
		XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
	}

	func testSourceCleanupFailure_doesNotOverwriteSuccessfulImportDiagnosticOrAppendDuplicateEntries() throws {
		var report = try NativeModelConversionImportReport(
			configurationID: UUID(),
			sourcePackageFilename: "detector.tar",
			retainOriginalPackage: false,
			wasRemoteImport: false
		)
		let cleanupDiagnostic = NativeModelConversionDiagnostic(
			code: "app.sourceCleanupFailed",
			phase: .completed,
			message: "The original package could not yet be removed."
		)
		// A report written by the earlier implementation could already contain this conversion-level
		// diagnostic. The first reconciliation must clear it as well as avoiding new ones.
		report.transition(to: .registered, diagnostic: cleanupDiagnostic)
		let entryCountBeforeFailure = report.entries.count

		report.recordSourceCleanup(.failed, diagnostic: cleanupDiagnostic)
		XCTAssertEqual(report.state, .registered)
		XCTAssertNil(report.diagnostic)
		XCTAssertEqual(report.entries.count, entryCountBeforeFailure + 1)
		XCTAssertEqual(report.entries.last?.diagnostic, cleanupDiagnostic)

		report.recordSourceCleanup(.failed, diagnostic: cleanupDiagnostic)
		XCTAssertEqual(report.entries.count, entryCountBeforeFailure + 1)

		report.recordSourceCleanup(.removed)
		XCTAssertEqual(report.effectiveSourceCleanupState, .removed)
		XCTAssertEqual(report.entries.count, entryCountBeforeFailure + 2)
	}

	func testSourceCleanup_removesOnlyRegisteredNonRetainedSourceAndRecordsCompletion() async throws {
		let rootDirectory = try makeTemporaryDirectory()
		defer { try? FileManager.default.removeItem(at: rootDirectory) }
		let configurationDirectory = rootDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: configurationDirectory, withIntermediateDirectories: true)

		let report = try NativeModelConversionImportReport(
			configurationID: UUID(),
			sourcePackageFilename: "detector.tar",
			retainOriginalPackage: false,
			wasRemoteImport: false
		)
		try Data("checkpoint".utf8).write(to: report.sourcePackageURL(in: configurationDirectory))
		try Data("coreml".utf8).write(to: report.convertedModelURL(in: configurationDirectory))
		try report.write(in: configurationDirectory)
		let store = NativeModelConversionImportReportStore(report: report, configurationDirectory: configurationDirectory)
		let service = NativeModelSourceCleanupService()

		// The recovery source is still required before the Core Data configuration commits.
		_ = await service.reconcile(reportStore: store, in: configurationDirectory)
		XCTAssertTrue(FileManager.default.fileExists(atPath: report.sourcePackageURL(in: configurationDirectory).path))
		let pending = await store.snapshot()
		XCTAssertEqual(pending.effectiveSourceCleanupState, .pending)

		try await store.transition(to: .registered)
		let cleaned = await service.reconcile(reportStore: store, in: configurationDirectory)
		XCTAssertEqual(cleaned.state, .registered)
		XCTAssertEqual(cleaned.effectiveSourceCleanupState, .removed)
		XCTAssertFalse(FileManager.default.fileExists(atPath: report.sourcePackageURL(in: configurationDirectory).path))
		XCTAssertTrue(FileManager.default.fileExists(atPath: report.convertedModelURL(in: configurationDirectory).path))

		let loaded = try NativeModelConversionImportReport.load(in: configurationDirectory)
		XCTAssertEqual(loaded.effectiveSourceCleanupState, .removed)
	}

	func testSourceCleanup_launchRecoveryLeavesRecoveryAndRetainedSourcesUntouched() async throws {
		let rootDirectory = try makeTemporaryDirectory()
		defer { try? FileManager.default.removeItem(at: rootDirectory) }

		let incompleteDirectory = rootDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let retainedDirectory = rootDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: incompleteDirectory, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: retainedDirectory, withIntermediateDirectories: true)
		let incomplete = try NativeModelConversionImportReport(
			configurationID: UUID(), sourcePackageFilename: "retry.onnx", retainOriginalPackage: false, wasRemoteImport: false
		)
		let retained = try NativeModelConversionImportReport(
			configurationID: UUID(), sourcePackageFilename: "keep.aiagraph", retainOriginalPackage: true, wasRemoteImport: false
		)
		try Data("retry".utf8).write(to: incomplete.sourcePackageURL(in: incompleteDirectory))
		try Data("keep".utf8).write(to: retained.sourcePackageURL(in: retainedDirectory))
		try incomplete.write(in: incompleteDirectory)
		try retained.write(in: retainedDirectory)
		let retainedStore = NativeModelConversionImportReportStore(report: retained, configurationDirectory: retainedDirectory)
		try await retainedStore.transition(to: .registered)

		await NativeModelSourceCleanupService().reconcileAll(in: rootDirectory)

		XCTAssertTrue(FileManager.default.fileExists(atPath: incomplete.sourcePackageURL(in: incompleteDirectory).path))
		XCTAssertTrue(FileManager.default.fileExists(atPath: retained.sourcePackageURL(in: retainedDirectory).path))
		XCTAssertEqual(
			try NativeModelConversionImportReport.load(in: retainedDirectory).effectiveSourceCleanupState,
			.notRequested
		)
	}

	private func makeTemporaryDirectory() throws -> URL {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		return directory
	}
}
