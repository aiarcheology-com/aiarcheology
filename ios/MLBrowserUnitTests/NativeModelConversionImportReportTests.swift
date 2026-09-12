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

	/// AIA-0889: a kill during `MLModel.load` leaves the report at `emitted` — conversion finished
	/// and the model is on disk, only the load did not. That state was not treated as incomplete, so
	/// the report kept `emitted` with no diagnostic and the user was left a half-finished import
	/// that explained nothing.
	func testReport_emittedButNeverRegistered_recoversAsInterruptedAndNamesTheLoad() async throws {
		let configurationDirectory = try makeTemporaryDirectory()
		defer { try? FileManager.default.removeItem(at: configurationDirectory) }
		let report = try NativeModelConversionImportReport(
			configurationID: UUID(),
			sourcePackageFilename: "source.aiagraph",
			retainOriginalPackage: true,
			wasRemoteImport: false
		)
		try report.write(in: configurationDirectory)
		let store = NativeModelConversionImportReportStore(report: report, configurationDirectory: configurationDirectory)
		try await store.transition(to: .converting)
		try await store.transition(to: .emitted)

		var loaded = try NativeModelConversionImportReport.load(in: configurationDirectory)
		XCTAssertEqual(loaded.state, .emitted, "Precondition: the kill leaves the report here")

		XCTAssertTrue(loaded.markInterruptedIfIncomplete(), "An emitted-but-unregistered report is incomplete")
		try loaded.write(in: configurationDirectory)

		let interrupted = try NativeModelConversionImportReport.load(in: configurationDirectory)
		XCTAssertEqual(interrupted.state, .interrupted)
		XCTAssertEqual(interrupted.diagnostic?.code, "app.interruptedAfterEmission")
		let message = try XCTUnwrap(interrupted.diagnostic?.message)
		XCTAssertTrue(message.contains("memory"), "The user needs the likely cause named: \(message)")
		XCTAssertTrue(message.lowercased().contains("loaded"), "The failing stage must be named: \(message)")
		// It must not overclaim: the report cannot prove why the process died.
		XCTAssertTrue(message.contains("cannot confirm"), "Must not assert a termination cause it cannot prove")
	}

	/// The distinction is the point: a kill during conversion and a kill during the load are
	/// different failures and must not collapse into one message.
	func testReport_interruptedDuringConversion_keepsItsOwnDiagnostic() async throws {
		let configurationDirectory = try makeTemporaryDirectory()
		defer { try? FileManager.default.removeItem(at: configurationDirectory) }
		let report = try NativeModelConversionImportReport(
			configurationID: UUID(),
			sourcePackageFilename: "source.aiagraph",
			retainOriginalPackage: true,
			wasRemoteImport: false
		)
		try report.write(in: configurationDirectory)
		let store = NativeModelConversionImportReportStore(report: report, configurationDirectory: configurationDirectory)
		try await store.transition(to: .converting)

		var loaded = try NativeModelConversionImportReport.load(in: configurationDirectory)
		XCTAssertTrue(loaded.markInterruptedIfIncomplete())
		XCTAssertEqual(loaded.diagnostic?.code, "app.interruptedBeforeCompletion")
	}

	/// A finished import must never be rewritten as interrupted.
	func testReport_registered_isNeverMarkedInterrupted() async throws {
		let configurationDirectory = try makeTemporaryDirectory()
		defer { try? FileManager.default.removeItem(at: configurationDirectory) }
		let report = try NativeModelConversionImportReport(
			configurationID: UUID(),
			sourcePackageFilename: "source.aiagraph",
			retainOriginalPackage: true,
			wasRemoteImport: false
		)
		try report.write(in: configurationDirectory)
		let store = NativeModelConversionImportReportStore(report: report, configurationDirectory: configurationDirectory)
		try await store.transition(to: .converting)
		try await store.transition(to: .emitted)
		try await store.transition(to: .registered)

		var loaded = try NativeModelConversionImportReport.load(in: configurationDirectory)
		XCTAssertFalse(loaded.markInterruptedIfIncomplete())
		XCTAssertEqual(loaded.state, .registered)
	}

	/// AIA-0889: a load refused for memory is the one failure whose artifact is good — the
	/// conversion succeeded and only this device cannot load it. The model is kept so the user can
	/// still export it and use it elsewhere.
	func testReport_memoryRefusal_keepsItsConvertedModelForExport() async throws {
		let configurationDirectory = try makeTemporaryDirectory()
		defer { try? FileManager.default.removeItem(at: configurationDirectory) }
		var report = try NativeModelConversionImportReport(
			configurationID: UUID(),
			sourcePackageFilename: "source.aiagraph",
			retainOriginalPackage: true,
			wasRemoteImport: false
		)
		report.state = .failed
		report.diagnostic = NativeModelConversionDiagnostic(
			code: NativeModelConversionImportReport.AppDiagnosticCode.insufficientMemoryForModelLoad,
			phase: .failed,
			message: "not enough memory"
		)
		XCTAssertTrue(report.keepsConvertedModelForExport)
	}

	/// Every other failure keeps today's behaviour: the artifact is unproven, so it goes.
	func testReport_otherFailures_doNotKeepTheirConvertedModel() async throws {
		let configurationDirectory = try makeTemporaryDirectory()
		defer { try? FileManager.default.removeItem(at: configurationDirectory) }
		var report = try NativeModelConversionImportReport(
			configurationID: UUID(),
			sourcePackageFilename: "source.aiagraph",
			retainOriginalPackage: true,
			wasRemoteImport: false
		)
		let codes = [
			NativeModelConversionImportReport.AppDiagnosticCode.modelCompilationFailed,
			NativeModelConversionImportReport.AppDiagnosticCode.modelLoadFailed,
			NativeModelConversionImportReport.AppDiagnosticCode.modelValidationOrRegistrationFailed
		]
		for code in codes {
			report.state = .failed
			report.diagnostic = NativeModelConversionDiagnostic(code: code, phase: .failed, message: "x")
			XCTAssertFalse(report.keepsConvertedModelForExport, "\(code) must not retain its model")
		}
		// A memory refusal that has not actually failed is not a retention case either.
		report.state = .converting
		report.diagnostic = NativeModelConversionDiagnostic(
			code: NativeModelConversionImportReport.AppDiagnosticCode.insufficientMemoryForModelLoad,
			phase: .failed,
			message: "x"
		)
		XCTAssertFalse(report.keepsConvertedModelForExport)
	}

	/// The retention is only useful if the file actually survives the failure cleanup.
	func testRemoveTransientArtifacts_canKeepTheConvertedModelWhileClearingPartials() throws {
		let configurationDirectory = try makeTemporaryDirectory()
		defer { try? FileManager.default.removeItem(at: configurationDirectory) }
		let report = try NativeModelConversionImportReport(
			configurationID: UUID(),
			sourcePackageFilename: "source.aiagraph",
			retainOriginalPackage: true,
			wasRemoteImport: false
		)
		let modelURL = report.convertedModelURL(in: configurationDirectory)
		try Data("model".utf8).write(to: modelURL)
		let sidecarURL = NativeModelMetadataSidecar.url(for: modelURL)
		try Data("{}".utf8).write(to: sidecarURL)
		let partialURL = configurationDirectory
			.appendingPathComponent(".\(report.convertedModelFilename).partial-abc", isDirectory: false)
		try Data("partial".utf8).write(to: partialURL)

		NativeModelConversionImportReport.removeTransientArtifacts(
			for: report,
			in: configurationDirectory,
			includingSourcePackage: false,
			includingConvertedModel: false
		)

		XCTAssertTrue(FileManager.default.fileExists(atPath: modelURL.path), "The exportable model must survive")
		XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarURL.path), "Its sidecar travels with it")
		XCTAssertFalse(FileManager.default.fileExists(atPath: partialURL.path), "Partials are still debris")

		// And the default still removes it, so no other caller changed behaviour.
		NativeModelConversionImportReport.removeTransientArtifacts(
			for: report,
			in: configurationDirectory,
			includingSourcePackage: false
		)
		XCTAssertFalse(FileManager.default.fileExists(atPath: modelURL.path))
		XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarURL.path))
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

// MARK: - Export availability tracks the artifact, not the failure (AIA-0889)

extension NativeModelConversionImportReportTests {

	/// `keepsConvertedModelForExport` records how the import failed and stays true forever. Offering
	/// an export from it alone means offering one after cleanup has removed the model, which can
	/// only fail — the same widened-in-one-layer mistake as the exporter's own guard.
	func testHasExportableConvertedModel_isFalseOnceTheModelIsGone() throws {
		let configurationDirectory = try makeTemporaryDirectory()
		defer { try? FileManager.default.removeItem(at: configurationDirectory) }
		var report = try NativeModelConversionImportReport(
			configurationID: UUID(),
			sourcePackageFilename: "source.aiagraph",
			retainOriginalPackage: true,
			wasRemoteImport: false
		)
		report.state = .failed
		report.diagnostic = NativeModelConversionDiagnostic(
			code: NativeModelConversionImportReport.AppDiagnosticCode.insufficientMemoryForModelLoad,
			phase: .failed,
			message: "not enough memory"
		)
		let modelURL = report.convertedModelURL(in: configurationDirectory)
		try Data("model".utf8).write(to: modelURL)

		XCTAssertTrue(report.hasExportableConvertedModel(in: configurationDirectory))

		try FileManager.default.removeItem(at: modelURL)

		XCTAssertTrue(report.keepsConvertedModelForExport, "The failure is still what it was")
		XCTAssertFalse(
			report.hasExportableConvertedModel(in: configurationDirectory),
			"But there is nothing left to export, so no surface may offer one"
		)
	}

	func testHasExportableConvertedModel_isFalseForAnUnrelatedFailure() throws {
		let configurationDirectory = try makeTemporaryDirectory()
		defer { try? FileManager.default.removeItem(at: configurationDirectory) }
		var report = try NativeModelConversionImportReport(
			configurationID: UUID(),
			sourcePackageFilename: "source.aiagraph",
			retainOriginalPackage: true,
			wasRemoteImport: false
		)
		report.state = .failed
		report.diagnostic = NativeModelConversionDiagnostic(
			code: NativeModelConversionImportReport.AppDiagnosticCode.modelCompilationFailed,
			phase: .failed,
			message: "compile failed"
		)
		try Data("model".utf8).write(to: report.convertedModelURL(in: configurationDirectory))

		XCTAssertFalse(
			report.hasExportableConvertedModel(in: configurationDirectory),
			"A stray file on disk must not make an unrelated failure exportable"
		)
	}

	/// A termination between the Core Data save and the report's `registered` write leaves a stale
	/// `emitted` beside a live configuration. Treating that as interrupted deleted the model the
	/// configuration points at.
	func testRepairRegisteredStateAfterStaleEmission_promotesEmittedToRegistered() throws {
		let configurationDirectory = try makeTemporaryDirectory()
		defer { try? FileManager.default.removeItem(at: configurationDirectory) }
		var report = try NativeModelConversionImportReport(
			configurationID: UUID(),
			sourcePackageFilename: "source.aiagraph",
			retainOriginalPackage: true,
			wasRemoteImport: false
		)
		report.state = .emitted

		report.repairRegisteredStateAfterStaleEmission()

		XCTAssertEqual(report.state, .registered)
	}

	func testRepairRegisteredStateAfterStaleEmission_leavesEveryOtherStateAlone() throws {
		let configurationDirectory = try makeTemporaryDirectory()
		defer { try? FileManager.default.removeItem(at: configurationDirectory) }
		var report = try NativeModelConversionImportReport(
			configurationID: UUID(),
			sourcePackageFilename: "source.aiagraph",
			retainOriginalPackage: true,
			wasRemoteImport: false
		)
		for state in [NativeModelConversionImportState.staged, .converting, .failed, .cancelled, .interrupted] {
			report.state = state
			report.repairRegisteredStateAfterStaleEmission()
			XCTAssertEqual(report.state, state, "\(state) must not be promoted to registered")
		}
	}
}
