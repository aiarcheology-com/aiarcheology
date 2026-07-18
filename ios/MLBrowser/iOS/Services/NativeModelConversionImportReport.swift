//
//  NativeModelConversionImportReport.swift
//  AI Archeology
//
//  Durable app-owned conversion recovery and support report.
//

import Foundation
import NativeModelConverter

/// The app-level lifetime of a native conversion import.
///
/// This is deliberately outside `NativeModelConverter`: the package reports conversion facts,
/// while ML Browser owns sandbox storage, user retention decisions, Core Data registration, and
/// recovery after an app termination.
enum NativeModelConversionImportState: String, Codable, Equatable, Sendable {
	case staged
	case converting
	/// The app was no longer running before a staged or converting report reached a terminal state.
	case interrupted
	case emitted
	case registered
	case cancelled
	case failed

	var isRecoverable: Bool {
		switch self {
		case .staged, .converting, .interrupted, .emitted, .cancelled, .failed:
			true
		case .registered:
			false
		}
	}
}

/// One path-free event in the user-visible conversion report.
struct NativeModelConversionImportLogEntry: Codable, Equatable, Identifiable, Sendable {
	let id: UUID
	let timestamp: Date
	let state: NativeModelConversionImportState
	let progress: NativeModelConversionProgress?
	let diagnostic: NativeModelConversionDiagnostic?

	init(
		state: NativeModelConversionImportState,
		progress: NativeModelConversionProgress? = nil,
		diagnostic: NativeModelConversionDiagnostic? = nil
	) {
		id = UUID()
		timestamp = Date()
		self.state = state
		self.progress = progress
		self.diagnostic = diagnostic
	}
}

/// A durable, path-free report retained beside the converted model or staged source package.
///
/// The report is both a support log and a recovery checkpoint. It persists only relative artifact
/// names, so it can reconstruct URLs inside the known configuration directory without recording a
/// user-selected external path. It is intentionally retained after registration so a client can
/// show conversion evidence after success as well as after an error.
struct NativeModelConversionImportReport: Codable, Equatable, Identifiable, Sendable {
	static let format = "com.aiarcheology.native-conversion-import-report"
	static let formatVersion = 1
	static let filename = "native-conversion-report.json"

	let formatIdentifier: String
	let reportFormatVersion: Int
	let configurationID: UUID
	let sourcePackageFilename: String
	let convertedModelFilename: String
	let retainOriginalPackage: Bool
	let nativeConverterPackageVersion: String
	let nativeConverterConversionRevision: Int
	let wasRemoteImport: Bool
	let createdAt: Date
	var updatedAt: Date
	var state: NativeModelConversionImportState
	var lastProgress: NativeModelConversionProgress?
	var metrics: NativeModelConversionMetrics?
	var diagnostic: NativeModelConversionDiagnostic?
	var entries: [NativeModelConversionImportLogEntry]

	var id: UUID { configurationID }

	init(
		configurationID: UUID,
		sourcePackageFilename: String,
		convertedModelFilename: String = "converted.mlmodel",
		retainOriginalPackage: Bool,
		wasRemoteImport: Bool
	) throws {
		guard Self.isPlainFilename(sourcePackageFilename), Self.isPlainFilename(convertedModelFilename) else {
			throw NativeModelConversionImportReportError.invalidArtifactFilename
		}
		formatIdentifier = Self.format
		reportFormatVersion = Self.formatVersion
		self.configurationID = configurationID
		self.sourcePackageFilename = sourcePackageFilename
		self.convertedModelFilename = convertedModelFilename
		self.retainOriginalPackage = retainOriginalPackage
		nativeConverterPackageVersion = NativeModelConverterVersion.packageVersion
		nativeConverterConversionRevision = NativeModelConverterVersion.conversionRevision
		self.wasRemoteImport = wasRemoteImport
		createdAt = Date()
		updatedAt = createdAt
		state = .staged
		lastProgress = nil
		metrics = nil
		diagnostic = nil
		entries = [NativeModelConversionImportLogEntry(state: .staged)]
	}

	static func reportURL(in configurationDirectory: URL) -> URL {
		configurationDirectory.appendingPathComponent(filename, isDirectory: false)
	}

	func sourcePackageURL(in configurationDirectory: URL) -> URL {
		configurationDirectory.appendingPathComponent(sourcePackageFilename, isDirectory: true)
	}

	func convertedModelURL(in configurationDirectory: URL) -> URL {
		configurationDirectory.appendingPathComponent(convertedModelFilename, isDirectory: false)
	}

	func write(in configurationDirectory: URL) throws {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		try encoder.encode(self).write(to: Self.reportURL(in: configurationDirectory), options: .atomic)
	}

	static func load(in configurationDirectory: URL) throws -> Self {
		let report = try JSONDecoder().decode(Self.self, from: Data(contentsOf: reportURL(in: configurationDirectory)))
		guard report.formatIdentifier == format, report.reportFormatVersion == formatVersion,
			isPlainFilename(report.sourcePackageFilename), isPlainFilename(report.convertedModelFilename)
		else {
			throw NativeModelConversionImportReportError.invalidReport
		}
		return report
	}

	static func recoverableReports(in configurationsDirectory: URL) -> [Self] {
		guard let configurationDirectories = try? FileManager.default.contentsOfDirectory(
			at: configurationsDirectory,
			includingPropertiesForKeys: [.isDirectoryKey],
			options: [.skipsHiddenFiles]
		) else {
			return []
		}
		return configurationDirectories.compactMap { directory in
			guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
				let report = try? load(in: directory), report.state.isRecoverable
			else {
				return nil
			}
			return report
		}.sorted { $0.updatedAt > $1.updatedAt }
	}

	mutating func transition(
		to state: NativeModelConversionImportState,
		progress: NativeModelConversionProgress? = nil,
		diagnostic: NativeModelConversionDiagnostic? = nil
	) {
		self.state = state
		if let progress {
			lastProgress = progress
		}
		if let diagnostic {
			self.diagnostic = diagnostic
		}
		updatedAt = Date()
		entries.append(NativeModelConversionImportLogEntry(state: state, progress: progress, diagnostic: diagnostic))
	}

	mutating func record(progress: NativeModelConversionProgress) {
		guard shouldPersist(progress: progress) else { return }
		lastProgress = progress
		updatedAt = Date()
		entries.append(NativeModelConversionImportLogEntry(state: state, progress: progress))
	}

	mutating func record(metrics: NativeModelConversionMetrics) {
		self.metrics = metrics
		updatedAt = Date()
	}

	/// Records the recovery fact that the app no longer has a live task for an incomplete report.
	///
	/// This does not claim a crash diagnosis. iOS can terminate or suspend an app for several reasons
	/// and the durable journal only proves that its last checkpoint was incomplete. The user can see
	/// the last saved phase and retry from the retained source package.
	@discardableResult
	mutating func markInterruptedIfIncomplete() -> Bool {
		guard state == .staged || state == .converting else { return false }
		let lastPhase = lastProgress?.phase ?? .preparing
		transition(
			to: .interrupted,
			diagnostic: NativeModelConversionDiagnostic(
				code: "app.interruptedBeforeCompletion",
				phase: lastPhase,
				message: "The app was no longer running before conversion completed. The last saved phase was \(lastPhase.rawValue). The exact process-termination cause is not available in this report; resume to retry from the staged source package."
			)
		)
		return true
	}

	static func removeTransientArtifacts(
		for report: Self,
		in configurationDirectory: URL,
		includingSourcePackage: Bool
	) {
		let fileManager = FileManager.default
		try? fileManager.removeItem(at: report.convertedModelURL(in: configurationDirectory))
		try? fileManager.removeItem(at: NativeModelMetadataSidecar.url(for: report.convertedModelURL(in: configurationDirectory)))
		if includingSourcePackage {
			try? fileManager.removeItem(at: report.sourcePackageURL(in: configurationDirectory))
		}
	}

	private static func isPlainFilename(_ filename: String) -> Bool {
		!filename.isEmpty && filename == URL(fileURLWithPath: filename).lastPathComponent && filename != "." && filename != ".."
	}

	private func shouldPersist(progress: NativeModelConversionProgress) -> Bool {
		guard progress.phase == .emittingModel else { return true }
		guard progress.phase != lastProgress?.phase else {
			return progress.completedUnitCount == progress.totalUnitCount || progress.completedUnitCount.isMultiple(of: 10)
		}
		return true
	}
}

/// Serializes report updates from package callbacks without putting app concerns into the package.
actor NativeModelConversionImportReportStore {
	private var report: NativeModelConversionImportReport
	private let configurationDirectory: URL

	init(report: NativeModelConversionImportReport, configurationDirectory: URL) {
		self.report = report
		self.configurationDirectory = configurationDirectory
	}

	func transition(
		to state: NativeModelConversionImportState,
		progress: NativeModelConversionProgress? = nil,
		diagnostic: NativeModelConversionDiagnostic? = nil
	) throws {
		report.transition(to: state, progress: progress, diagnostic: diagnostic)
		try report.write(in: configurationDirectory)
	}

	func record(progress: NativeModelConversionProgress) {
		let previousCount = report.entries.count
		report.record(progress: progress)
		guard report.entries.count != previousCount else { return }
		try? report.write(in: configurationDirectory)
	}

	func record(metrics: NativeModelConversionMetrics) throws {
		report.record(metrics: metrics)
		try report.write(in: configurationDirectory)
	}

	func snapshot() -> NativeModelConversionImportReport {
		report
	}
}

enum NativeModelConversionImportReportError: LocalizedError {
	case invalidArtifactFilename
	case invalidReport

	var errorDescription: String? {
		switch self {
		case .invalidArtifactFilename:
			"A conversion report contains an invalid artifact filename."
		case .invalidReport:
			"The conversion report is not a supported format."
		}
	}
}
