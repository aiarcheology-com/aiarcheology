//
//  ImportedCheckpointAnalyser.swift
//  AI Archeology
//
//  Asking a downloaded PyTorch checkpoint what it says it is (AIA-0666).
//

import Foundation
import NativeModelConverter

/// What a recognised PyTorch checkpoint turned out to describe.
///
/// - Important: **self-declaration, not provenance.** Whoever controls the file controls its tensor
///   table and its training `id`, so a hostile checkpoint can present itself as an ADAF detector
///   exactly as a genuine one does. Nothing here can tell them apart, and the strings these verdicts
///   choose are worded accordingly — "describes itself as", never "is".
enum ImportedCheckpointVerdict: Equatable {
	/// The pinned ADAF object-detection table, with its class name when the checkpoint carried one.
	case adafDetector(className: String?)
	/// A semantic-segmentation model. Not supported, and not planned (AIA-0654 scope decision).
	case segmentation
	/// A readable checkpoint holding some other model.
	case unrecognizedModel(tensorCount: Int)
	/// The container is a PyTorch checkpoint but could not be read — malformed, truncated, ZIP64, a
	/// serialization version this has never seen, or a pickle that was refused.
	case unreadable
}

/// Reads a checkpoint far enough to say which model it is.
enum ImportedCheckpointAnalyser {
	/// Identifies the checkpoint at `url`, or answers ``ImportedCheckpointVerdict/unreadable``.
	///
	/// **Total by construction**: every failure becomes `.unreadable`, because this runs on the shared
	/// import path and the caller's job is to choose a message, never to propagate a parser error to a
	/// user. The detail that would help a developer goes to the log; what reaches the alert is a
	/// closed set of cases and one bounded number.
	///
	/// Cheap despite the file size: the reader touches the archive's end records, its central
	/// directory, `data.pkl` and `version` and nothing else — under a megabyte of a 518 MB download,
	/// with the 344 MB of optimizer state never located.
	static func verdict(for url: URL) -> ImportedCheckpointVerdict {
		do {
			let checkpoint = try PyTorchCheckpointReader.read(contentsOf: url)
			switch ADAFCheckpointCatalog.identity(of: checkpoint) {
			case .objectDetection(let model):
				return .adafDetector(className: model.classLabel?.displayName)
			case .segmentation(let architecture):
				LoggingPolicy.info("Checkpoint describes a \(architecture) segmentation model", logger: .storage)
				return .segmentation
			case .unrecognized(let summary):
				// The prefixes are attacker-derived text; they are useful to a developer and must not
				// reach an alert, so this is the only place they are recorded.
				LoggingPolicy.info(
					"Unrecognised checkpoint: \(summary.tensorCount) tensors, keys \(summary.topLevelPrefixes.joined(separator: ", "))",
					logger: .storage
				)
				return .unrecognizedModel(tensorCount: summary.tensorCount)
			}
		} catch {
			LoggingPolicy.warning("Could not read PyTorch checkpoint: \(error)", logger: .storage)
			return .unreadable
		}
	}
}
