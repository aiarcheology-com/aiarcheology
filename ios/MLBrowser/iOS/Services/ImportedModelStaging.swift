//
//  ImportedModelStaging.swift
//  AI Archeology
//
//  Staging a model into app-owned storage: copy, name, and screen it (AIA-0654).
//

import Foundation

/// Everything that happens to an imported file between "the user chose it" and "the app owns it":
/// it is placed in the configuration directory, named after the download it came from, and screened
/// for containers the app recognises but cannot import.
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

	/// Places `sourceURL` under the configuration directory, restores the download's filename where
	/// that matters, and rejects a container the app recognises but cannot import.
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
	/// - Returns: the URL the model now lives at, which the caller treats as the stored source.
	/// - Throws: ``ModelContainerImportError`` for a recognised-but-unsupported container, or any
	///   file-system error from staging.
	static func stage(
		sourceURL: URL,
		configurationID: UUID,
		downloadURL: URL?,
		origin: ModelAcquisitionSource
	) throws -> URL {
		let stored = try FileManager.storeModelInDocuments(from: sourceURL, configurationId: configurationID)
		let named = restoringNativeConvertibleExtension(of: stored, from: downloadURL)
		if let rejection = ImportedContainerRouting.rejection(
			for: DownloadedContainerFormat.classify(fileAt: named),
			origin: origin
		) {
			throw rejection
		}
		return named
	}

	/// A model downloaded from a URL is stored under the URLSession temporary name, which drops the
	/// original extension. When the download URL names a native-convertible format but the stored
	/// file no longer carries that extension, restore the original filename so the on-device
	/// converter is selected. Core ML files (`.mlmodel`/`.mlpackage`) and files that already carry a
	/// convertible extension (Files/catalog imports) are returned untouched.
	static func restoringNativeConvertibleExtension(of storedURL: URL, from downloadURL: URL?) -> URL {
		let storedExtension = storedURL.pathExtension.lowercased()
		guard !nativeConvertibleExtensions.contains(storedExtension),
			let downloadURL,
			nativeConvertibleExtensions.contains(downloadURL.pathExtension.lowercased())
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
