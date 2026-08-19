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
	/// A PyTorch training checkpoint. Support is the rest of AIA-0654; this is the honest interim.
	case unsupportedCheckpoint
	/// A tar archive. The app has no archive extraction at all, so this one is not "yet".
	case unsupportedArchive

	var errorDescription: String? {
		switch self {
		case .unsupportedCheckpoint: return L10n.Import.unsupportedCheckpoint
		case .unsupportedArchive: return L10n.Import.unsupportedArchive
		}
	}
}

/// Whether a classified container is rejected — pure, so the gating is testable without the view.
enum ImportedContainerRouting {
	/// The rejection for `format`, or `nil` to mean "carry on exactly as before AIA-0654".
	///
	/// Two conditions narrow this to the one case it exists for, and both are load-bearing:
	///
	/// - `isCheckpointRoutingEnabled` is the feature flag. Off, this function is inert.
	/// - `origin` must be `.directDownload`. Not because other origins cannot produce these
	///   containers — a checkpoint renamed to `.onnx` is selectable in the Files picker, since the
	///   allowed types are matched by extension — but because of what a rejection *costs* on each
	///   path. A direct download is already stored under the configuration directory, so
	///   `storeModelInDocuments` short-circuits and rejecting it leaves only the download the user
	///   made and can see. A Files import is copied in first, and at this point in the import there
	///   is no Core Data row and no conversion report, so nothing would ever clean that copy up:
	///   rejecting there would trade a cryptic error for a silently orphaned file. The renamed-file
	///   case therefore keeps its current behaviour, deliberately.
	/// - Parameter format: evaluated **only** when the two conditions above already hold, so an
	///   import this guard cannot touch does not even pay for the sniff's file read. Autoclosed
	///   rather than gated at the call site, which would put the same decision in two places.
	static func rejection(
		for format: @autoclosure () -> DownloadedContainerFormat,
		origin: ModelAcquisitionSource,
		isCheckpointRoutingEnabled: Bool
	) -> ModelContainerImportError? {
		guard isCheckpointRoutingEnabled, origin == .directDownload else { return nil }
		switch format() {
		case .pyTorchZipCheckpoint: return .unsupportedCheckpoint
		case .tarArchive: return .unsupportedArchive
		case .unrecognized: return nil
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
