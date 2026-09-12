//
//  ImportedModelStaging.swift
//  AI Archeology
//
//  Staging a model into app-owned storage: copy, name, and screen it (AIA-0654).
//

import Foundation

/// A checkpoint conversion identified while the staged file was screened.
enum ImportedCheckpointConversion: Equatable, Sendable {
	case adafDetector(className: String?)
}

/// The file now owned by the app and any conversion route discovered while staging it.
struct ImportedModelStagingResult: Equatable {
	let storedURL: URL
	let checkpointConversion: ImportedCheckpointConversion?
}

/// Everything that happens to an imported file between "the user chose it" and "the app owns it":
/// it is placed in the configuration directory, named after the download it came from, and screened
/// for containers the app recognises, including an ADAF detector conversion when supported.
///
/// This exists as a service rather than as private methods on the import view for one reason: the
/// view's copy could not be tested. Its pieces were individually covered while the **order** they
/// run in — stage, then name, then screen, with the screen's verdict actually thrown — was not, so
/// deleting the rejection call, or passing every import off as a direct download, left the whole
/// suite green. That gap is what `ImportedModelStagingTests` closes.
enum ImportedModelStaging {
	/// Source extensions the app converts to Core ML on-device before the normal loader runs: the
	/// auditable native package (`.aiagraph`) and self-contained ONNX (`.onnx`). Both share the same
	/// conversion report machinery (progress, cancellation, log sheet, export).
	static let nativeConvertibleExtensions: Set<String> = ["aiagraph", "onnx"]
	/// ADAF distributes PyTorch zip checkpoints with a `.tar` name. Restoring that filename preserves
	/// the model's meaningful source name in its conversion report and configuration title; the
	/// content sniffer, not this extension list, decides whether it is actually convertible.
	private static let filenameRestorableExtensions = nativeConvertibleExtensions.union(["tar"])

	/// Places `sourceURL` under the configuration directory, restores the download's filename where
	/// that matters, then either identifies a supported checkpoint conversion or rejects a container
	/// the app recognises but cannot import.
	///
	/// The screening happens **here**, at the first moment the bytes are app-owned and *before* the
	/// caller creates a conversion report, so a rejected container never leaves a report or an
	/// intermediate to clean up. It is also deliberately *early*, before the converter or Core ML
	/// sees the file: the containers this recognises are 518 MB and 862 MB, and the alternative —
	/// letting the normal path fail first and explaining afterwards — would compile half a gigabyte
	/// of non-model before saying so. The cost of that ordering is recorded on
	/// ``DownloadedContainerFormat``: a file crafted to look like both a supported model and a
	/// recognised container is rejected rather than imported.
	///
	/// - Returns: the app-owned source URL and any checkpoint conversion the caller must perform.
	/// - Throws: ``ModelContainerImportError`` for a recognised-but-unsupported container, or any
	///   file-system error from staging.
	/// - Parameter analyser: reads a recognised checkpoint to decide which model it describes.
	///   Injectable so a test can assert **how often** it runs — the guarantee that matters is that a
	///   catalog install, a Files import, a tar, or any format the app handles normally never triggers
	///   it at all, and that is a claim about call counts rather than about outcomes.
	static func stage(
		sourceURL: URL,
		configurationID: UUID,
		downloadURL: URL?,
		origin: ModelAcquisitionSource,
		analyser: (URL) -> ImportedCheckpointVerdict = ImportedCheckpointAnalyser.verdict
	) throws -> ImportedModelStagingResult {
		let stored = try FileManager.storeModelInDocuments(from: sourceURL, configurationId: configurationID)
		let named = restoringKnownSourceFilename(of: stored, from: downloadURL)
		switch ImportedContainerRouting.route(
			for: DownloadedContainerFormat.classify(fileAt: named),
			origin: origin,
			analyser: analyser(named)
		) {
		case .continueImport:
			return ImportedModelStagingResult(storedURL: named, checkpointConversion: nil)
		case .convertADAFDetector(let className):
			return ImportedModelStagingResult(
				storedURL: named,
				checkpointConversion: .adafDetector(className: className)
			)
		case .reject(let error):
			throw error
		}
	}

	/// A model downloaded from a URL is stored under the URLSession temporary name, which drops the
	/// original extension. Restore the URL's name for a native graph, ONNX model, or an ADAF-named
	/// `.tar` checkpoint so the conversion report and imported configuration remain meaningful. The
	/// content route still decides whether a `.tar` is a PyTorch checkpoint or a real archive; this is
	/// naming only. Core ML files and Files/catalog imports are returned untouched.
	static func restoringKnownSourceFilename(of storedURL: URL, from downloadURL: URL?) -> URL {
		let storedExtension = storedURL.pathExtension.lowercased()
		guard !filenameRestorableExtensions.contains(storedExtension),
			let downloadURL,
			filenameRestorableExtensions.contains(downloadURL.pathExtension.lowercased())
		else {
			return storedURL
		}
		// The filename comes from a URL the user typed, so it is validated before it becomes a path.
		// `DownloadedFileNaming` answers nil for anything that must keep the stored name (AIA-0654).
		guard let restoredURL = DownloadedFileNaming.restoredURL(of: storedURL, namedBy: downloadURL) else {
			return storedURL
		}
		do {
			if FileManager.default.fileExists(atPath: restoredURL.path) {
				try FileManager.default.removeItem(at: restoredURL)
			}
			try FileManager.default.moveItem(at: storedURL, to: restoredURL)
			return restoredURL
		} catch {
			LoggingPolicy.warning("Could not restore native model extension for downloaded file", logger: .storage)
			return storedURL
		}
	}
}
