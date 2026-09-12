//
//  NativeModelDetectorCatalog.swift
//  NativeModelConverter
//
//  Recognizes detector head signatures the converter knows how to decode.
//

import Foundation

/// The detector facts recorded in a converted model's target metadata (AIA-0469/0471): how many
/// classes, whether the labels are trustworthy or inferred, and the coordinate space. The import UI
/// reads these to be honest about inferred labels. The typed values are kept typed here and rendered
/// to their wire strings only when the metadata is written.
public struct NativeModelDetectionTargetInfo: Equatable, Sendable {
	public let classCount: Int
	public let labelProvenance: NativeModelDetectorCatalog.DetectorLabelProvenance
	public let coordinateMode: NativeModelAnchorFreeHead.CoordinateMode

	public init(
		classCount: Int,
		labelProvenance: NativeModelDetectorCatalog.DetectorLabelProvenance,
		coordinateMode: NativeModelAnchorFreeHead.CoordinateMode
	) {
		self.classCount = classCount
		self.labelProvenance = labelProvenance
		self.coordinateMode = coordinateMode
	}

	/// The wire string recorded under `…target.label-provenance`.
	var labelProvenanceValue: String { labelProvenance.rawValue }
	/// The wire string recorded under `…target.coordinate-space`.
	var coordinateSpaceValue: String {
		switch coordinateMode {
		case .normalizedByGraph: return "normalized-by-graph"
		case .pixelsOfInput: return "pixels-of-input"
		}
	}
}

/// Matches a lowered ONNX graph against known detector heads and, on a match, appends the
/// synthesized decode so the emitter can write a detector pipeline.
///
/// This is the detection analog of the ImageNet-1000 classifier convention: an ONNX file carries no
/// anchors and no label list, so — exactly as a 1000-wide output is taken to be ImageNet — a raw
/// YOLO grid whose channel count factors as `anchors · (5 + classes)` for a catalogued head is
/// decoded with that head's published constants. A graph matching no entry is left untouched.
public enum NativeModelDetectorCatalog {

	/// A recognized raw-output detector head.
	struct Entry {
		let anchors: [NativeModelYOLOHead.Anchor]
		let labels: [String]
		/// What the emitter's image-normalization layer must apply. Heads that embed their own
		/// pixel scaling in the graph (tiny-yolov2's `x · 1/255`) take the identity here — the
		/// Core ML image input then feeds raw `[0, 255]` pixels to the graph unchanged, matching
		/// what onnxruntime is fed on the oracle side.
		let preprocessing: NativeModelImagePreprocessing

		var channelCount: Int { anchors.count * (5 + labels.count) }
	}

	/// YOLOv2-family heads. Channel counts must be unique across entries, since the channel count
	/// is what selects one.
	static let entries: [Entry] = [
		// Tiny YOLOv2 trained on Pascal VOC (the ONNX Model Zoo `tinyyolov2` export):
		// 5 anchors × (5 + 20 classes) = 125 channels. Anchors are the published
		// tiny-yolo-voc.cfg values, in grid-cell units.
		Entry(
			anchors: [
				NativeModelYOLOHead.Anchor(width: 1.08, height: 1.19),
				NativeModelYOLOHead.Anchor(width: 3.42, height: 4.41),
				NativeModelYOLOHead.Anchor(width: 6.63, height: 11.38),
				NativeModelYOLOHead.Anchor(width: 9.42, height: 5.11),
				NativeModelYOLOHead.Anchor(width: 16.62, height: 10.52)
			],
			labels: pascalVOCLabels,
			preprocessing: identityRGB
		)
	]

	/// The Pascal VOC 2007/2012 class list in darknet's `voc.names` order — the order YOLOv2-family
	/// class scores are emitted in.
	static let pascalVOCLabels = [
		"aeroplane", "bicycle", "bird", "boat", "bottle", "bus", "car", "cat", "chair", "cow",
		"diningtable", "dog", "horse", "motorbike", "person", "pottedplant", "sheep", "sofa",
		"train", "tvmonitor"
	]

	/// Pass-through pixel normalization: `1 · pixel + 0` per channel. Used when the graph embeds its
	/// own scaling, so the model still gets an image input (and the layer that renames the image
	/// feature onto the graph's input blob) without normalizing twice.
	static let identityRGB = NativeModelImagePreprocessing(colorSpace: .rgb, scale: [1, 1, 1], bias: [0, 0, 0])

	/// How a detector's labels were determined, surfaced in the converted model's metadata so the
	/// import UI (AIA-0471) can be honest when labels are inferred rather than read from the file.
	public enum DetectorLabelProvenance: String, Equatable, Sendable {
		/// Labels came from the file's own `names` map — trustworthy, no warning needed.
		case metadata
		/// Labels are a catalogued convention for a recognized head (e.g. tiny-yolov2's Pascal VOC).
		case convention
		/// The file named no classes; labels are generic `class_<i>` placeholders.
		case unnamed
	}

	/// A conversion input whose graph has been extended with a recognized head's decode.
	public struct DetectionConversion {
		public let graph: NativeModelGraph
		public let weights: Data
		public let interface: NativeModelDetectionInterface
		public let imagePreprocessing: NativeModelImagePreprocessing
		/// How the labels in `interface` were determined.
		public let labelProvenance: DetectorLabelProvenance
		/// The trusted, closed label and preprocessing profile selected by this recognizer. The emitter
		/// resolves it against the final image interface before recording it in Core ML metadata.
		public let targetSemanticsIntent: NativeModelTargetSemanticsIntent
		/// The coordinate space the head decoded from, recorded as provenance.
		public let coordinateMode: NativeModelAnchorFreeHead.CoordinateMode

		/// The detector facts to record in the converted model's target metadata.
		public var targetInfo: NativeModelDetectionTargetInfo {
			NativeModelDetectionTargetInfo(
				classCount: interface.labels.count,
				labelProvenance: labelProvenance,
				coordinateMode: coordinateMode
			)
		}
	}

	/// Returns the detection extension of `input` when its single output is a recognized detector head
	/// — a catalogued anchor-based grid, or an anchor-free raw-prediction tensor — or nil when it is
	/// not a known detector. Throws only if a matched head fails to plan (a converter bug or corrupt
	/// graph, not an unrecognized model).
	public static func detectionConversion(of input: ONNXConversionInput) throws -> DetectionConversion? {
		if let anchorBased = try anchorBasedConversion(of: input) { return anchorBased }
		return try NativeModelAnchorFreeRecognizer.conversion(of: input)
	}

	private static func anchorBasedConversion(of input: ONNXConversionInput) throws -> DetectionConversion? {
		let graph = input.graph
		// The grid-size ceiling keeps a crafted small-on-disk model declaring an enormous grid from
		// matching: planning materializes dense S²-sized constants, and an oversized tensor is not a
		// real YOLO head anyway — it falls through to the plain-network path instead.
		guard graph.outputs.count == 1,
			let output = outputTensor(of: graph),
			output.shape.count == 4, output.shape[0] == 1,
			output.shape[2] > 1, output.shape[2] == output.shape[3],
			output.shape[2] <= NativeModelYOLOHead.maximumGridSize,
			let entry = entries.first(where: { $0.channelCount == output.shape[1] })
		else {
			return nil
		}

		let plan = try NativeModelYOLOHead.plan(
			grid: output,
			anchors: entry.anchors,
			labels: entry.labels,
			weightOffset: UInt64(input.weights.count)
		)
		let extendedGraph = NativeModelGraph(
			formatVersion: graph.formatVersion,
			producer: graph.producer,
			inputs: graph.inputs,
			weights: graph.weights + plan.weights,
			operations: graph.operations + plan.operations,
			outputs: [plan.interface.coordinatesBlobName, plan.interface.confidenceBlobName]
		)
		return DetectionConversion(
			graph: extendedGraph,
			weights: input.weights + plan.weightData,
			interface: plan.interface,
			imagePreprocessing: entry.preprocessing,
			// A catalogued head brings its published class list, and it folds 1/S into its decode so the
			// boxes it emits are already normalized.
			labelProvenance: .convention,
			targetSemanticsIntent: NativeModelTargetSemanticsIntent(
				labelProfile: .pascalVOC,
				preprocessingProfile: .identityRGB
			),
			coordinateMode: .normalizedByGraph
		)
	}

	static func outputTensor(of graph: NativeModelGraph) -> NativeModelTensor? {
		let name = graph.outputs[0]
		for operation in graph.operations {
			for tensor in operation.outputs where tensor.name == name {
				return tensor
			}
		}
		return nil
	}
}
