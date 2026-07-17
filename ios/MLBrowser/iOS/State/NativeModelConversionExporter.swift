//
//  NativeModelConversionExporter.swift
//  AI Archeology
//
//  Builds a single, explicit user-shareable archive for a registered conversion.
//

import Foundation
import NativeModelConverter

/// Exports a registered native conversion as one portable archive.
///
/// The archive contains the generated `.mlmodel`, its lossless metadata sidecar when present, and
/// the path-free conversion report. The original `.aiagraph` package is intentionally excluded:
/// retaining it is a separate user choice and sharing it can disclose a large or private source
/// artifact. Temporary staging and finished archives are cleaned after the share sheet finishes.
enum NativeModelConversionExporter {
	private static let exportsDirectoryName = "NativeModelConversionExports"
	private static let archiveDirectoryName = "ConvertedModel"

	static func makeZip(
		report: NativeModelConversionImportReport,
		configurationDirectory: URL,
		date: Date = .now
	) throws -> URL {
		guard report.state == .registered else {
			throw NativeModelConversionExportError.notRegistered
		}

		let fileManager = FileManager.default
		let modelURL = report.convertedModelURL(in: configurationDirectory)
		guard fileManager.fileExists(atPath: modelURL.path) else {
			throw NativeModelConversionExportError.missingConvertedModel
		}
		let reportURL = NativeModelConversionImportReport.reportURL(in: configurationDirectory)
		guard fileManager.fileExists(atPath: reportURL.path) else {
			throw NativeModelConversionExportError.missingConversionReport
		}

		let exportsDirectory = fileManager.temporaryDirectory
			.appendingPathComponent(exportsDirectoryName, isDirectory: true)
		try? fileManager.removeItem(at: exportsDirectory)
		try fileManager.createDirectory(at: exportsDirectory, withIntermediateDirectories: true)
		var keepCompletedArchive = false
		defer {
			if !keepCompletedArchive {
				try? fileManager.removeItem(at: exportsDirectory)
			}
		}

		let stagingRoot = fileManager.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let archiveDirectory = stagingRoot.appendingPathComponent(archiveDirectoryName, isDirectory: true)
		try fileManager.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
		defer { try? fileManager.removeItem(at: stagingRoot) }

		try fileManager.copyItem(at: modelURL, to: archiveDirectory.appendingPathComponent(report.convertedModelFilename))
		let sidecarURL = NativeModelMetadataSidecar.url(for: modelURL)
		if fileManager.fileExists(atPath: sidecarURL.path) {
			try fileManager.copyItem(at: sidecarURL, to: archiveDirectory.appendingPathComponent(sidecarURL.lastPathComponent))
		}
		try fileManager.copyItem(at: reportURL, to: archiveDirectory.appendingPathComponent(reportURL.lastPathComponent))
		try Data(
			"This archive contains a registered Core ML model, its source-metadata sidecar when present, and a path-free conversion report. The original source package is not included.\n".utf8
		).write(to: archiveDirectory.appendingPathComponent("README.txt"), options: .atomic)

		let archiveName = "ConvertedModel-\(timestamp(date)).zip"
		let archiveURL = exportsDirectory.appendingPathComponent(archiveName, isDirectory: false)
		try zip(directory: archiveDirectory, to: archiveURL, fileManager: fileManager)
		keepCompletedArchive = true
		return archiveURL
	}

	static func removeExportArchive(at archiveURL: URL) {
		try? FileManager.default.removeItem(at: archiveURL)
		let exportsDirectory = archiveURL.deletingLastPathComponent()
		if (try? FileManager.default.contentsOfDirectory(atPath: exportsDirectory.path).isEmpty) == true {
			try? FileManager.default.removeItem(at: exportsDirectory)
		}
	}

	private static func timestamp(_ date: Date) -> String {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.dateFormat = "yyyy-MM-dd-HHmmss"
		return formatter.string(from: date)
	}

	/// `NSFileCoordinator`'s `.forUploading` output exists only during its accessor, so the copy
	/// into the temporary export directory must happen inside this closure.
	private static func zip(directory: URL, to destination: URL, fileManager: FileManager) throws {
		var coordinatorError: NSError?
		var copyError: Error?
		NSFileCoordinator().coordinate(readingItemAt: directory, options: .forUploading, error: &coordinatorError) { zippedURL in
			do {
				if fileManager.fileExists(atPath: destination.path) {
					try fileManager.removeItem(at: destination)
				}
				try fileManager.copyItem(at: zippedURL, to: destination)
			} catch {
				copyError = error
			}
		}
		if let coordinatorError { throw coordinatorError }
		if let copyError { throw copyError }
	}
}

enum NativeModelConversionExportError: LocalizedError, Equatable {
	case notRegistered
	case missingConvertedModel
	case missingConversionReport

	var errorDescription: String? {
		switch self {
		case .notRegistered:
			"Only a registered converted model can be exported."
		case .missingConvertedModel:
			"The registered converted model file is missing."
		case .missingConversionReport:
			"The conversion report needed for export is missing."
		}
	}
}
