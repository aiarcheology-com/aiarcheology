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
	/// The pinned ADAF object-detection table, with the class name when the checkpoint carried one.
	/// Conversion is AIA-0654 M3.
	case adafDetectorNotConvertible(className: String?)
	/// A semantic-segmentation model. **Permanent, not "yet"**: the app detects and classifies objects
	/// in a scene and has no representation for a per-pixel mask anywhere — not in the converter's
	/// task enum, not in the drivers, not in a finding (AIA-0654 scope decision, 2026-08-19).
	case segmentationUnsupported
	/// A readable checkpoint holding a model this app does not know.
	case unrecognizedCheckpoint(tensorCount: Int)

	/// - Note: every message describes what the file **says it is**, never what it is. A checkpoint's
	///   tensor table and training `id` are chosen by whoever wrote the file, so recognition is
	///   self-declaration and the copy must not launder it into a provenance claim. The only values
	///   interpolated here are a class name from a closed four-case enum and a tensor count; nothing
	///   attacker-authored reaches the alert, and the detail goes to the log instead.
	var errorDescription: String? {
		switch self {
		case .unsupportedCheckpoint:
			return L10n.Import.unsupportedCheckpoint
		case .unsupportedArchive:
			return L10n.Import.unsupportedArchive
		case .adafDetectorNotConvertible(let className):
			guard let className else { return L10n.Import.checkpointDetectorUnlabelled }
			return L10n.Import.checkpointDetector(className)
		case .segmentationUnsupported:
			return L10n.Import.checkpointSegmentation
		case .unrecognizedCheckpoint(let tensorCount):
			return L10n.Import.checkpointUnrecognized(tensorCount)
		}
	}
}

/// Whether a classified container is rejected — pure, so the gating is testable without the view.
enum ImportedContainerRouting {
	/// The rejection for `format`, or `nil` to mean "carry on exactly as before AIA-0654".
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
	/// `origin` must be `.directDownload`. Not because other origins cannot produce these containers
	/// — a checkpoint renamed to `.onnx` is selectable in the Files picker, since the allowed types
	/// are matched by extension — but because of what a rejection *costs* on each path. A direct
	/// download is already stored under the configuration directory, so `storeModelInDocuments`
	/// short-circuits and rejecting it leaves only the download the user made and can see. A Files
	/// import is copied in first, and at this point in the import there is no Core Data row and no
	/// conversion report, so nothing would ever clean that copy up: rejecting there would trade a
	/// cryptic error for a silently orphaned file. The renamed-file case therefore keeps its
	/// current behaviour, deliberately.
	///
	/// - Parameter format: evaluated **only** when `origin` already qualifies, so an import this
	///   guard cannot touch does not even pay for the sniff's file read. Autoclosed rather than
	///   gated at the call site, which would put the same decision in two places.
	static func rejection(
		for format: @autoclosure () -> DownloadedContainerFormat,
		origin: ModelAcquisitionSource
	) -> ModelContainerImportError? {
		guard origin == .directDownload else { return nil }
		switch format() {
		case .pyTorchZipCheckpoint: return .unsupportedCheckpoint
		case .tarArchive: return .unsupportedArchive
		case .unrecognized: return nil
		}
	}

	/// Upgrades a generic checkpoint rejection to one that names the model, once the file has been
	/// read (AIA-0666).
	///
	/// Kept separate from ``rejection(for:origin:)`` so that function stays pure and its tests stay
	/// exactly as they were: the decision about *whether* to reject is unchanged by this milestone,
	/// and only the wording of one of its two verdicts gets sharper.
	///
	/// - Parameter verdict: autoclosed, so a tar rejection — or any rejection that is not a
	///   checkpoint — never pays for reading and decoding one.
	static func refined(
		_ rejection: ModelContainerImportError,
		by verdict: @autoclosure () -> ImportedCheckpointVerdict
	) -> ModelContainerImportError {
		guard rejection == .unsupportedCheckpoint else { return rejection }
		switch verdict() {
		case .adafDetector(let className): return .adafDetectorNotConvertible(className: className)
		case .segmentation: return .segmentationUnsupported
		case .unrecognisedModel(let tensorCount): return .unrecognizedCheckpoint(tensorCount: tensorCount)
		case .unreadable: return rejection
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
	///   which is a raw `hasPrefix` string test against a freshly-fetched Documents URL, so a
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
