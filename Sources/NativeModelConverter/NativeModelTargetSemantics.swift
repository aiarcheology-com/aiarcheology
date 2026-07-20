//
//  NativeModelTargetSemantics.swift
//  NativeModelConverter
//
//  Versioned, target-correct semantics recorded in converted Core ML metadata.
//

import Foundation

/// The closed target-semantics contract written into the converted Core ML model's
/// `creatorDefined` metadata.
///
/// Source metadata is intentionally not enough to describe a runnable target model: a converter
/// may have selected labels, added an image interface, or left a graph as a raw tensor network.
/// These facts describe only what was actually emitted. Consumers must use ``init?(userDefined:)``
/// and fail closed when an older or malformed contract cannot be understood.
public struct NativeModelTargetSemantics: Equatable, Sendable {

	/// The target metadata contract revision. This is intentionally separate from the converter
	/// revision: a newer converter can still write a contract an older app understands.
	public static let currentFormatVersion = "1"

	public enum Task: String, Equatable, Sendable {
		case classification
		case detection
	}

	/// Where the emitted label vector came from. This is the only fact that controls the import
	/// assumption notice: source metadata is not a fallback, while a catalogued convention or
	/// generic generated labels is.
	public enum LabelProvenance: String, Equatable, Sendable {
		case metadata
		case convention
		case unnamed
	}

	/// The exact closed label set selected for the target interface. A provenance alone is not
	/// useful UI copy: both ImageNet-1k and Pascal VOC are conventions, but they mean very different
	/// things to a person importing a model.
	public enum LabelProfile: String, Equatable, Sendable {
		case sourceMetadata = "source-metadata"
		case imageNet1K = "imagenet-1k"
		case pascalVOC = "pascal-voc"
		case genericClassIndex = "generic-class-index"

		public var provenance: LabelProvenance {
			switch self {
			case .sourceMetadata: .metadata
			case .imageNet1K, .pascalVOC: .convention
			case .genericClassIndex: .unnamed
			}
		}
	}

	/// The actual target image-input treatment. `.none` means no image preprocessing layer or image
	/// interface was emitted; it does not mean the source model has no preprocessing requirements.
	public enum PreprocessingProfile: String, Equatable, Sendable {
		case imageNetRGB = "image-net-rgb"
		case rgbZeroToOne = "rgb-0-to-1"
		case identityRGB = "identity-rgb"
		case none

		public var origin: PreprocessingOrigin {
			switch self {
			case .imageNetRGB, .rgbZeroToOne: .convention
			case .identityRGB: .embeddedInGraph
			case .none: .notApplied
			}
		}
	}

	/// Why the target applies the recorded preprocessing profile. This is deliberately narrower than
	/// a claim that arbitrary source metadata is trustworthy: current ONNX paths either use a known
	/// converter convention, preserve scaling embedded in the graph, or add nothing.
	public enum PreprocessingOrigin: String, Equatable, Sendable {
		case convention
		case embeddedInGraph = "embedded-in-graph"
		case notApplied = "not-applied"
	}

	public let task: Task
	public let classCount: Int
	public let labelProfile: LabelProfile
	public let preprocessingProfile: PreprocessingProfile

	public var labelProvenance: LabelProvenance { labelProfile.provenance }
	public var preprocessingOrigin: PreprocessingOrigin { preprocessingProfile.origin }
	/// Only fallback labels can silently mislabel results. Converter-selected preprocessing by itself
	/// does not create a notice: a YOLO export with source-provided labels remains metadata-backed.
	public var requiresImportAssumptionNotice: Bool { labelProvenance != .metadata }

	public init(
		task: Task,
		classCount: Int,
		labelProfile: LabelProfile,
		preprocessingProfile: PreprocessingProfile
	) {
		self.task = task
		self.classCount = classCount
		self.labelProfile = labelProfile
		self.preprocessingProfile = preprocessingProfile
	}

	/// Parses only a complete v1 contract from a Core ML `creatorDefined` dictionary. The converter
	/// marker is required so similarly named keys from unrelated models cannot create an import
	/// warning. Unknown values and invalid task/profile combinations deliberately parse as nil.
	public init?(userDefined: [String: String]) {
		guard userDefined[Keys.converterPackageVersion]?.isEmpty == false,
			userDefined[Keys.semanticsVersion] == Self.currentFormatVersion,
			let taskRaw = userDefined[Keys.task],
			let task = Task(rawValue: taskRaw),
			let classCountRaw = userDefined[Keys.classCount],
			let classCount = Int(classCountRaw), classCount > 0,
			let labelProvenanceRaw = userDefined[Keys.labelProvenance],
			let labelProvenance = LabelProvenance(rawValue: labelProvenanceRaw),
			let labelProfileRaw = userDefined[Keys.labelProfile],
			let labelProfile = LabelProfile(rawValue: labelProfileRaw),
			let preprocessingOriginRaw = userDefined[Keys.preprocessingOrigin],
			let preprocessingOrigin = PreprocessingOrigin(rawValue: preprocessingOriginRaw),
			let preprocessingProfileRaw = userDefined[Keys.preprocessingProfile],
			let preprocessingProfile = PreprocessingProfile(rawValue: preprocessingProfileRaw),
			labelProfile.provenance == labelProvenance,
			preprocessingProfile.origin == preprocessingOrigin,
			userDefined[Keys.modelFormat] == Self.modelFormat(for: task),
			Self.isValid(labelProfile: labelProfile, for: task),
			(labelProfile != .imageNet1K || classCount == 1000),
			(labelProfile != .pascalVOC || classCount == 20)
			return nil
		}
		self.init(
			task: task,
			classCount: classCount,
			labelProfile: labelProfile,
			preprocessingProfile: preprocessingProfile
		)
	}

	/// Writes the semantics v1 fields into the target metadata. Callers must also ensure the
	/// converter marker and model-format keys are present so the contract is parseable.
	func write(to userDefined: inout [String: String]) {
		userDefined[Keys.semanticsVersion] = Self.currentFormatVersion
		userDefined[Keys.task] = task.rawValue
		userDefined[Keys.classCount] = String(classCount)
		userDefined[Keys.labelProvenance] = labelProvenance.rawValue
		userDefined[Keys.labelProfile] = labelProfile.rawValue
		userDefined[Keys.preprocessingOrigin] = preprocessingOrigin.rawValue
		userDefined[Keys.preprocessingProfile] = preprocessingProfile.rawValue
	}

	private static func modelFormat(for task: Task) -> String {
		switch task {
		case .classification: "neuralNetworkClassifier"
		case .detection: "pipeline"
		}
	}

	static func isValid(labelProfile: LabelProfile, for task: Task) -> Bool {
		switch task {
		case .classification:
			return labelProfile == .sourceMetadata || labelProfile == .imageNet1K
		case .detection:
			return labelProfile == .sourceMetadata || labelProfile == .pascalVOC || labelProfile == .genericClassIndex
		}
	}

	private enum Keys {
		static let converterPackageVersion = "com.aiarcheology.native.converter.package-version"
		static let semanticsVersion = "com.aiarcheology.native.target.semantics-version"
		static let modelFormat = "com.aiarcheology.native.target.model-format"
		static let task = "com.aiarcheology.native.target.task"
		static let classCount = "com.aiarcheology.native.target.class-count"
		static let labelProvenance = "com.aiarcheology.native.target.label-provenance"
		static let labelProfile = "com.aiarcheology.native.target.label-profile"
		static let preprocessingOrigin = "com.aiarcheology.native.target.preprocessing-origin"
		static let preprocessingProfile = "com.aiarcheology.native.target.preprocessing-profile"
	}
}

/// A trusted conversion path's declaration of the closed semantics it intends to emit.
///
/// This prevents the public generic emitter from trying to infer provenance by comparing arbitrary
/// caller-provided labels or affine preprocessing values to built-in conventions. The emitter
/// resolves this intent against the real classifier and image plans before writing any metadata.
public struct NativeModelTargetSemanticsIntent: Equatable, Sendable {
	public let labelProfile: NativeModelTargetSemantics.LabelProfile
	public let preprocessingProfile: NativeModelTargetSemantics.PreprocessingProfile

	public init(
		labelProfile: NativeModelTargetSemantics.LabelProfile,
		preprocessingProfile: NativeModelTargetSemantics.PreprocessingProfile
	) {
		self.labelProfile = labelProfile
		self.preprocessingProfile = preprocessingProfile
	}

	func resolved(
		task: NativeModelTargetSemantics.Task,
		classCount: Int,
		imagePreprocessingWasApplied: Bool
	) -> NativeModelTargetSemantics? {
		guard NativeModelTargetSemantics.isValid(labelProfile: labelProfile, for: task) else { return nil }
		// A raw-tensor classifier may still have an eligible label wrapper. It must record that no
		// image preprocessing was actually emitted, not the convention that was merely requested.
		let resolvedPreprocessing = imagePreprocessingWasApplied ? preprocessingProfile : .none
		// `none` is only truthful when no image plan exists. A caller who explicitly provides an
		// incompatible intent gets no semantics rather than a false metadata claim.
		guard preprocessingProfile != .none || !imagePreprocessingWasApplied else { return nil }
		return NativeModelTargetSemantics(
			task: task,
			classCount: classCount,
			labelProfile: labelProfile,
			preprocessingProfile: resolvedPreprocessing
		)
	}
}
