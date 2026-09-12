//
//  NativeModelConversionExporter.swift
//  AI Archeology
//
//  Builds a single, explicit user-shareable archive for a converted model.
//

import Foundation
import NativeModelConverter

/// Exports a converted native model as one portable archive.
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
		// Registered, or kept after a memory refusal (AIA-0889). The second case is the whole point
		// of retaining that model: the conversion succeeded and only *this* device cannot load it,
		// so exporting it to a device that can is the one thing still worth doing with it.
		guard report.state == .registered || report.keepsConvertedModelForExport else {
			throw NativeModelConversionExportError.notExportable
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
			"This archive contains a converted Core ML model, its source-metadata sidecar when present, and a path-free conversion report. The model may not have been registered on the exporting device — a device without the memory to load it can still convert and export it. The original source package is not included.\n".utf8
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
	fileprivate static func zip(directory: URL, to destination: URL, fileManager: FileManager) throws {
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

/// Exports a configuration's model file itself, so the user gets something they can drop straight
/// into Xcode or another app — as opposed to ``NativeModelConversionExporter``, which packages a
/// converted model *with* its conversion report for support purposes.
///
/// Co-located with that type because both need the same `NSFileCoordinator` zip step; the project
/// lists source files explicitly, so a shared helper here beats a duplicated one elsewhere.
enum ModelFileExporter {
	private static let exportsDirectoryName = "ModelExports"

	/// Returns a temporary copy of `modelURL` suitable for the share sheet.
	///
	/// A single-file `.mlmodel` is shared as-is — that is exactly the droppable artifact. A bundle
	/// (`.mlpackage`, `.mlmodelc`) is a directory, which does not survive most share destinations,
	/// so it is zipped. The copy keeps the model's own filename: it is the name shown in the
	/// Configuration sheet and the one the user expects to receive.
	static func makeShareableCopy(of modelURL: URL, fileManager: FileManager = .default) throws -> URL {
		var isDirectory: ObjCBool = false
		guard fileManager.fileExists(atPath: modelURL.path, isDirectory: &isDirectory) else {
			throw ModelFileExportError.missingModelFile
		}

		let exportsDirectory = fileManager.temporaryDirectory
			.appendingPathComponent(exportsDirectoryName, isDirectory: true)
		try? fileManager.removeItem(at: exportsDirectory)
		try fileManager.createDirectory(at: exportsDirectory, withIntermediateDirectories: true)

		if isDirectory.boolValue {
			let destination = exportsDirectory
				.appendingPathComponent("\(modelURL.lastPathComponent).zip", isDirectory: false)
			try NativeModelConversionExporter.zip(directory: modelURL, to: destination, fileManager: fileManager)
			return destination
		}
		let destination = exportsDirectory.appendingPathComponent(modelURL.lastPathComponent, isDirectory: false)
		try fileManager.copyItem(at: modelURL, to: destination)
		return destination
	}

	/// Removes an export once the share sheet is done with it, and the containing directory when it
	/// is left empty — the same lifecycle ``NativeModelConversionExporter`` uses.
	static func removeExport(at url: URL) {
		NativeModelConversionExporter.removeExportArchive(at: url)
	}
}

enum ModelFileExportError: LocalizedError, Equatable {
	case missingModelFile

	var errorDescription: String? {
		switch self {
		case .missingModelFile:
			"The model file for this configuration is missing."
		}
	}
}

enum NativeModelConversionExportError: LocalizedError, Equatable {
	case notExportable
	case missingConvertedModel
	case missingConversionReport

	var errorDescription: String? {
		switch self {
		case .notExportable:
			"This conversion has no converted model to export."
		case .missingConvertedModel:
			"The converted model file is missing."
		case .missingConversionReport:
			"The conversion report needed for export is missing."
		}
	}
}
