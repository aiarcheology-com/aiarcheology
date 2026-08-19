//
//  ADAFCheckpointCatalog.swift
//  NativeModelConverter
//
//  Recognising which published ADAF model a checkpoint describes itself as (AIA-0666).
//

import Foundation

/// One of the four archaeological classes the ADAF detection models are trained for.
///
/// Names and display strings are taken from ADAF's own source, not invented here:
/// `adaf/adaf_inference.py:358-361` maps the four to `OD_<label>.tar`, and
/// `adaf/adaf_widget.py:218-244` and `:564-565` give the labels a person sees.
public enum ADAFClass: String, CaseIterable, Equatable, Sendable {
	case allArchaeology = "AO"
	case barrow
	case enclosure
	case ringfort

	public var displayName: String {
		switch self {
		case .allArchaeology: return "All archaeology"
		case .barrow: return "Barrow"
		case .enclosure: return "Enclosure"
		case .ringfort: return "Ringfort"
		}
	}
}

/// How a checkpoint's class was arrived at. Mirrors the converter's existing
/// ``NativeModelDetectorCatalog/DetectorLabelProvenance`` tiers.
public enum ADAFLabelProvenance: String, Equatable, Sendable {
	/// Read from the checkpoint's own training `id`.
	case checkpointIdentifier
	/// Nothing in the file named a class, or more than one name appeared. The label is a placeholder.
	case unnamed
}

/// A bounded, sanitised description of a checkpoint that was not recognised.
///
/// Everything here is derived from a file the user pasted a URL for, so it is attacker-controlled
/// text on its way to a message. It is therefore restricted to a short alphanumeric alphabet and a
/// handful of short fragments; the full detail belongs in a log, not in an alert.
public struct ADAFCheckpointSummary: Equatable, Sendable {
	public let tensorCount: Int
	/// At most four top-level key prefixes, each at most 24 characters of `[A-Za-z0-9._]`.
	public let topLevelPrefixes: [String]
	/// A family name when the probes recognise the shape without the table matching exactly.
	public let architectureFamily: String?

	static let maximumPrefixes = 4
	static let maximumPrefixLength = 24
}

/// What a checkpoint says it is.
///
/// - Important: **this is self-declaration, not provenance.** Whoever controls the bytes controls
///   the tensor table and the training `id`, so a hostile file can present itself as an ADAF
///   detector as easily as a real one can. No parser can tell them apart, and nothing built on this
///   should claim otherwise — the user-facing wording says the file *describes itself as*, never
///   that it *is*.
public enum ADAFCheckpointIdentity: Equatable, Sendable {
	/// The pinned ADAF object-detection table: torchvision `fasterrcnn_resnet50_fpn_v2`.
	case objectDetection(ADAFObjectDetectionModel)
	/// A semantic-segmentation model. **Not supported, and not planned** — the app has no
	/// representation for a per-pixel mask anywhere (AIA-0654 scope decision, 2026-08-19), so this is
	/// permanent rather than "not yet".
	case segmentation(architecture: String)
	case unrecognized(ADAFCheckpointSummary)
}

public struct ADAFObjectDetectionModel: Equatable, Sendable {
	public let architecture: String
	/// The width of `roi_heads.box_predictor.cls_score`, which is **background plus the detectable
	/// classes**. Named for what it is: calling it a class count puts "2 classes" in front of a
	/// person looking at a model that finds one thing.
	public let predictorLogitCount: Int
	public let classLabel: ADAFClass?
	public let labelProvenance: ADAFLabelProvenance

	/// What the model actually detects — one, for every published ADAF checkpoint.
	public var detectableClassCount: Int { max(0, predictorLogitCount - 1) }
}

/// Matches a decoded checkpoint against the published ADAF models.
public enum ADAFCheckpointCatalog {

	/// Digest of the canonical tensor table — every `name|dtype|shape` row, sorted, joined by
	/// newlines — for the four `OD_*` detection checkpoints.
	///
	/// Measured 2026-08-19: `OD_AO`, `OD_barrow`, `OD_enclosure` and `OD_ringfort` are
	/// tensor-for-tensor identical in name, shape and dtype, so one digest covers all four. That is
	/// also why the label cannot come from the table and has to be parsed out of the training `id`.
	static let objectDetectionDigest: UInt64 = 0xFECF_A10D_77B1_D51E
	/// The same for the `*_HRNet_SLRM_512px_*` segmentation checkpoints.
	static let segmentationDigest: UInt64 = 0x03A9_812C_CA74_3EC4

	static let objectDetectionArchitecture = "fasterrcnn_resnet50_fpn_v2"

	/// Structural probes, used **only** to describe a checkpoint that did not match a pinned digest.
	///
	/// They are not a recognition rule. Six probes match a six-tensor fragment, and an unrelated
	/// torchvision Faster R-CNN would satisfy every one of them — so a positive answer needs the
	/// whole table, and probes exist to turn "not recognised" into a sentence that says what was
	/// there instead.
	private static let objectDetectionProbes = [
		"backbone.body.conv1.weight",
		"backbone.fpn.inner_blocks.0.1.weight",
		"rpn.head.conv.0.0.weight",
		"rpn.head.conv.1.0.weight",
		"rpn.head.cls_logits.weight",
		"roi_heads.box_head.5.weight",
		"roi_heads.box_predictor.cls_score.weight"
	]

	private static let segmentationProbes = [
		"head.projection.0.weight",
		"backbone.classifier.weight",
		"backbone.final_layer.1.weight"
	]

	private static let logitTensorName = "roi_heads.box_predictor.cls_score.weight"

	/// Identifies `checkpoint`.
	public static func identity(of checkpoint: PyTorchCheckpoint) -> ADAFCheckpointIdentity {
		let digest = tableDigest(of: checkpoint.tensors)

		if digest == objectDetectionDigest {
			let (label, provenance) = classLabel(from: checkpoint.identifier)
			return .objectDetection(ADAFObjectDetectionModel(
				architecture: objectDetectionArchitecture,
				predictorLogitCount: logitCount(of: checkpoint) ?? 0,
				classLabel: label,
				labelProvenance: provenance
			))
		}
		if digest == segmentationDigest {
			return .segmentation(architecture: "HRNet")
		}

		// Probes describe, they do not identify — including here. Three names with arbitrary shapes
		// are not a segmentation model, and answering `.segmentation` for them would hand a
		// three-tensor fragment the permanent "never supported" refusal. Measured before removing the
		// shortcut: all four published HRNet checkpoints digest to the same value, so nothing real
		// reaches this path.
		let names = Set(checkpoint.tensors.map(\.name))
		return .unrecognized(summary(
			of: checkpoint,
			family: familyName(matching: names)
		))
	}

	/// A digest of the canonical `name|dtype|shape` table.
	///
	/// FNV-1a rather than a cryptographic hash, deliberately. Collision resistance would buy nothing
	/// here: anyone who wants a file recognised as an ADAF detector does not need to find a collision,
	/// they can simply write the real tensor table — recognition is self-declaration either way (see
	/// ``ADAFCheckpointIdentity``). What this needs is to be stable and accidental-collision-proof
	/// across 404 rows, and 64 bits is ample for that.
	static func tableDigest(of tensors: [PyTorchTensorRef]) -> UInt64 {
		let rows = tensors
			.map { "\($0.name)|\($0.dataType.rawValue)|\($0.shape.map(String.init).joined(separator: ","))" }
			.sorted()
		var hash: UInt64 = 0xCBF2_9CE4_8422_2325
		for byte in rows.joined(separator: "\n").utf8 {
			hash ^= UInt64(byte)
			hash = hash &* 0x0000_0100_0000_01B3
		}
		return hash
	}

	private static func logitCount(of checkpoint: PyTorchCheckpoint) -> Int? {
		checkpoint.tensors.first { $0.name == logitTensorName }?.shape.first
	}

	/// Derives the archaeological class from the training `id`, tri-state.
	///
	/// The `id` is aitlas's `run_id`, written verbatim (`aitlas/base/models.py:751`) — e.g.
	/// `train_ringfort_OD_SLRM_512px pretrained_train_12_val_124`. Since all four detection
	/// checkpoints share one tensor table, this string is the only thing in the file that
	/// distinguishes them.
	///
	/// Exactly one class token resolves; **two or more is ambiguous and resolves to nothing**, rather
	/// than picking whichever came first. There is deliberately no fallback to the download URL's
	/// filename: a `.tar` download keeps its `URLSession` temporary name so the stem is not even
	/// present (`ImportedModelStaging.restoringNativeConvertibleExtension` renames only `.aiagraph`
	/// and `.onnx`), and it would be user-typed text feeding a sentence that names a model.
	static func classLabel(from identifier: String?) -> (ADAFClass?, ADAFLabelProvenance) {
		guard let identifier else { return (nil, .unnamed) }
		let tokens = identifier.split(whereSeparator: { $0.isLetter == false && $0.isNumber == false })
		let matched = Set(
			tokens.compactMap { token in
				ADAFClass.allCases.first { $0.rawValue.lowercased() == token.lowercased() }
			}
		)
		guard matched.count == 1, let single = matched.first else { return (nil, .unnamed) }
		return (single, .checkpointIdentifier)
	}

	/// The architecture family the probes suggest, for the message only.
	private static func familyName(matching names: Set<String>) -> String? {
		if objectDetectionProbes.allSatisfy(names.contains) { return "Faster R-CNN" }
		if segmentationProbes.allSatisfy(names.contains) { return "HRNet" }
		return nil
	}

	private static func summary(
		of checkpoint: PyTorchCheckpoint,
		family: String?
	) -> ADAFCheckpointSummary {
		var seen: [String] = []
		for tensor in checkpoint.tensors {
			let prefix = sanitised(String(tensor.name.prefix(while: { $0 != "." })))
			if prefix.isEmpty == false, seen.contains(prefix) == false {
				seen.append(prefix)
				if seen.count == ADAFCheckpointSummary.maximumPrefixes { break }
			}
		}
		return ADAFCheckpointSummary(
			tensorCount: checkpoint.tensors.count,
			topLevelPrefixes: seen,
			architectureFamily: family
		)
	}

	/// Reduces attacker-controlled text to something safe to show.
	///
	/// A tensor name comes from a file the user pasted a URL for: it can be arbitrarily long, carry
	/// bidirectional overrides, newlines, or characters that render as something else entirely. A
	/// short alphanumeric alphabet is the only thing that makes it printable without thought.
	private static func sanitised(_ text: String) -> String {
		String(
			text
				.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_") }
				.prefix(ADAFCheckpointSummary.maximumPrefixLength)
		)
	}
}
