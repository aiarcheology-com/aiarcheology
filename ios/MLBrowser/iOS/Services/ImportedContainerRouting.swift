//
//  ImportedContainerRouting.swift
//  AI Archeology
//
//  Deciding whether a sniffed container is rejected, and saying so (AIA-0654).
//

import Foundation

/// A container the app recognised and will not import.
///
/// It surfaces through the ordinary import failure path — thrown out of the off-main-actor import
/// work, shown in the existing alert, and marking the download `.importFailed` — so it needs no UI
/// of its own. The value it adds over today's failure is that the message names what the file
/// actually is instead of reporting that a model could not be read.
enum ModelContainerImportError: LocalizedError, Equatable {
	/// A PyTorch checkpoint the app could not read — malformed, truncated, ZIP64, an unknown
	/// serialization version, or a pickle that was refused. Still the honest generic message, and
	/// since AIA-0666 it is *only* used when the file genuinely could not be identified.
	case unsupportedCheckpoint
	/// A tar archive. The app has no archive extraction at all, so this one is not "yet".
	case unsupportedArchive
	/// A semantic-segmentation model. **Permanent, not "yet"**: the app detects and classifies objects
	/// in a scene and has no representation for a per-pixel mask anywhere — not in the converter's
	/// task enum, not in the drivers, not in a finding (AIA-0654 scope decision, 2026-08-19).
	case segmentationUnsupported
	/// A readable checkpoint holding a model this app does not know.
	case unrecognizedCheckpoint(tensorCount: Int)

	/// - Note: every message describes what the file **says it is**, never what it is. A checkpoint's
	///   tensor table and training `id` are chosen by whoever wrote the file, so recognition is
	///   self-declaration and the copy must not launder it into a provenance claim. No value from the
	///   checkpoint reaches the alert; diagnostic detail stays in the log instead.
	var errorDescription: String? {
		switch self {
		case .unsupportedCheckpoint:
			return L10n.Import.unsupportedCheckpoint
		case .unsupportedArchive:
			return L10n.Import.unsupportedArchive
		case .segmentationUnsupported:
			return L10n.Import.checkpointSegmentation
		case .unrecognizedCheckpoint:
			// The tensor count is carried on the case for diagnostics and logged by the analyser, but
			// it is deliberately not rendered: "%lld tensors" reads "1 tensors" in English and needs
			// count-dependent forms in Czech, Polish, Russian, Ukrainian and Arabic, and the number
			// tells a person nothing they can act on.
			return L10n.Import.checkpointUnrecognized
		}
	}
}

/// The action the app takes after screening a staged import.
///
/// Only a positively recognised ADAF detector diverts into native conversion. A route is separate
/// from ``ModelContainerImportError`` because conversion is a successful import path, not a refusal
/// phrased differently.
enum ImportedContainerRoute: Equatable {
	case continueImport
	case convertADAFDetector(className: String?)
	case reject(ModelContainerImportError)
}

/// Routes a classified container — pure, so the gating is testable without the view.
enum ImportedContainerRouting {
	/// Decides whether an import continues unchanged, is permanently refused, or becomes an ADAF
	/// conversion (AIA-0696).
	///
	/// **Deliberately not behind a feature flag.** The comparable feature — on-device conversion of
	/// `.onnx` and `.aiagraph`, which likewise parses untrusted downloaded model files — ships
	/// ungated, and every flag this app has gates a *product surface* rather than a file format.
	/// Gating this one would also have shipped it inert, since all it does today is replace a
	/// cryptic import failure with a message that says what the file is. The safety argument is
	/// therefore carried entirely by ``DownloadedContainerFormat/classify(fileAt:)`` answering
	/// `.unrecognized` for everything it does not positively recognise, which is the case that
	/// preserves today's path.
	///
	/// Direct downloads and Files imports both convert a recognised ADAF detector. The successful
	/// conversion creates both the Core Data row and the durable conversion report, so it no longer
	/// has the Files-import orphan cost that made AIA-0654 leave that path untouched. A *real* tar is
	/// different: it can never become a model, so reject it before Files copies it into a configuration
	/// directory and a late validation failure leaves no row or report to clean it up. A Files import
	/// whose checkpoint is *not* an ADAF detector still continues exactly as before; rejecting it
	/// would reintroduce that orphan problem. Catalog installs never read the container here: they
	/// remain on their existing trusted catalog path.
	///
	/// - Parameters:
	///   - format: evaluated only for direct-download and Files imports.
	///   - analyser: evaluated only for a file that content-sniffs as a PyTorch zip checkpoint.
	static func route(
		for format: @autoclosure () -> DownloadedContainerFormat,
		origin: ModelAcquisitionSource,
		analyser: @autoclosure () -> ImportedCheckpointVerdict
	) -> ImportedContainerRoute {
		guard origin != .catalog else { return .continueImport }
		switch format() {
		case .tarArchive:
			return .reject(.unsupportedArchive)
		case .unrecognized:
			return .continueImport
		case .pyTorchZipCheckpoint:
			switch analyser() {
			case .adafDetector(let className):
				return .convertADAFDetector(className: className)
			case .segmentation:
				return origin == .directDownload ? .reject(.segmentationUnsupported) : .continueImport
			case .unrecognizedModel(let tensorCount):
				return origin == .directDownload
					? .reject(.unrecognizedCheckpoint(tensorCount: tensorCount))
					: .continueImport
			case .unreadable:
				return origin == .directDownload ? .reject(.unsupportedCheckpoint) : .continueImport
			}
		}
	}
}

/// Naming a downloaded file after the URL it came from, safely.
enum DownloadedFileNaming {
	/// The URL `storedURL` may be renamed to so it carries the download's original filename, or
	/// `nil` to keep the stored name.
	///
	/// The name comes from a URL the user typed, and `URL.lastPathComponent` percent-decodes, so a
	/// download URL ending `..%2F..%2Fmodel.onnx` produces the single *component* `"../../model.onnx"`
	/// — which still reports a `pathExtension` of `onnx` and would, appended to the configuration
	/// directory, resolve two levels above it. The caller deletes whatever already sits at the
	/// destination before moving onto it, so that is an arbitrary overwrite of another
	/// configuration's model, reachable by pasting one URL (AIA-0654).
	///
	/// Validating the component is what closes it: one component containing no separator, and being
	/// neither `.` nor `..`, cannot escape its parent.
	///
	/// - Important: the containment check that follows is defence in depth, and its standardised
	///   values **must not escape this function**. `standardizedFileURL` strips a leading `/private`
	///   only when the stripped path exists, so it is not a pure function of its input: safe to
	///   compare with, unsafe to return. The returned URL flows on to `URL.relativePath(from:)`,
	///   which is a lexical path-component test against a freshly-fetched Documents URL, so a
	///   `/private` mismatch introduced here would fail every affected import **on device** while
	///   passing in the simulator. That asymmetry is the AIA-0603 hazard
	///   (`CatalogPackageDownloader.destinationURL(for:in:)`), met from the other end.
	static func restoredURL(of storedURL: URL, namedBy downloadURL: URL) -> URL? {
		let candidateName = downloadURL.lastPathComponent
		guard candidateName.isEmpty == false,
			candidateName != ".",
			candidateName != "..",
			candidateName.contains("/") == false,
			candidateName.contains("\0") == false
		else {
			return nil
		}

		let directory = storedURL.deletingLastPathComponent()
		let comparisonRoot = directory.standardizedFileURL
		let comparisonTarget = comparisonRoot.appendingPathComponent(candidateName)
		guard comparisonTarget.pathComponents.count > comparisonRoot.pathComponents.count,
			comparisonTarget.pathComponents.starts(with: comparisonRoot.pathComponents)
		else {
			return nil
		}

		// Derived from the unstandardised directory, deliberately — see the note above.
		let restoredURL = directory.appendingPathComponent(candidateName)
		return restoredURL == storedURL ? nil : restoredURL
	}
}

extension ModelAcquisitionSource {
	/// Where an import came from, derived from the values the import already carries.
	///
	/// Extracted so registration's analytics and the container guard cannot drift into two answers
	/// for one question. `catalogSource` decides before `downloadURL` does: a catalog install has
	/// both, and reading `downloadURL` first would call it a direct download — which is precisely
	/// the misreading that would let the guard start rejecting catalog imports.
	static func resolve(downloadURL: URL?, catalogSource: String?) -> ModelAcquisitionSource {
		if downloadURL == nil { return .fileImport }
		return catalogSource == nil ? .directDownload : .catalog
	}
}
