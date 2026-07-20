//
//  NativeModelAnchorFreeRecognizer.swift
//  NativeModelConverter
//
//  Recognizes an anchor-free (YOLOv8/YOLO11-family) raw-prediction head in a lowered graph and,
//  on a confident match, extends the graph with the anchor-free decode so the emitter writes a
//  detector pipeline.
//
//  The recognition is deliberately a *structural audit*, not a channel-count guess: a `[1, 84, N]`
//  output could be anything, so before a model is activated as a detector the graph itself must
//  prove it is a real cxcywh-sigmoid head. The coordinate space is read from the graph the same way
//  (from a constant's value, never from a filename), so a model can never be silently mis-scaled or
//  mislabelled. When the audit does not hold, the model falls through to plain-network conversion.
//

import Foundation

enum NativeModelAnchorFreeRecognizer {

	/// Image normalization for anchor-free heads. Unlike tiny-yolov2 (which bakes `x·1/255` into its
	/// graph and so takes the identity), v8/v11 exports consume already-`[0,1]` input, so the Core ML
	/// image input must divide the incoming `[0,255]` pixels by 255 here. The oracle feeds onnxruntime
	/// the identically-scaled input.
	static let normalizedRGB = NativeModelImagePreprocessing(
		colorSpace: .rgb, scale: [1.0 / 255, 1.0 / 255, 1.0 / 255], bias: [0, 0, 0]
	)

	/// Returns the detection extension when `input`'s single output is a proven anchor-free head, nil
	/// otherwise. Throws only if a matched head fails to plan (a converter bug, not a non-match).
	static func conversion(of input: ONNXConversionInput) throws -> NativeModelDetectorCatalog.DetectionConversion? {
		let graph = input.graph
		guard graph.outputs.count == 1, let output = NativeModelDetectorCatalog.outputTensor(of: graph) else {
			return nil
		}
		// The output must be a rank-3 `[1, channels, boxes]` prediction with at least the four geometry
		// channels plus one class, and more than one box. (Rank-3 is what keeps this path disjoint from
		// the rank-4 anchor-based matcher — the two can never both fire.)
		let shape = output.shape
		guard shape.count == 3, shape[0] == 1, shape[1] >= 5, shape[2] > 1 else { return nil }
		let classCount = shape[1] - 4
		let boxCount = shape[2]

		// The output must be assembled by a channel-axis concat of exactly two branches.
		guard let concat = producer(of: output.name, in: graph),
			concat.kind == .concatenate,
			concat.attributes["axis"]?.integerValue == 1,
			concat.inputs.count == 2,
			let first = producer(of: concat.inputs[0], in: graph),
			let second = producer(of: concat.inputs[1], in: graph)
		else {
			return nil
		}

		// One branch is 4-channel box geometry ending in a scale multiply; the other is the class
		// scores ending in a sigmoid. Identify by channel count AND terminal kind, so the two are
		// unambiguous even when classCount == 4. (classifyBranches has already confirmed the score
		// branch is the sigmoid; only the box branch is needed past this point.)
		guard let (boxBranch, _) = classifyBranches(first, second, classCount: classCount) else {
			return nil
		}

		// The box branch's terminal scale constant reveals the coordinate space (its value, not its
		// shape — a normalized `÷size` and a pixel `×stride` are the same multiply op).
		guard let coordinateMode = coordinateMode(fromBoxScale: boxBranch, graph: graph, weights: input.weights, boxCount: boxCount) else {
			return nil
		}

		let (labels, provenance) = resolveLabels(hints: input.detectorHints, classCount: classCount)
		let plan = try NativeModelAnchorFreeHead.plan(
			output: output,
			classCount: classCount,
			labels: labels,
			coordinateMode: coordinateMode,
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
		return NativeModelDetectorCatalog.DetectionConversion(
			graph: extendedGraph,
			weights: input.weights + plan.weightData,
			interface: plan.interface,
			imagePreprocessing: normalizedRGB,
			labelProvenance: provenance,
			coordinateMode: coordinateMode
		)
	}

	// MARK: - Branch structure

	/// Splits the two concat branches into (box, score), requiring the box branch to be 4-channel and
	/// end in a multiply and the score branch to be `classCount`-channel and end in a sigmoid.
	private static func classifyBranches(
		_ a: NativeModelOperation, _ b: NativeModelOperation, classCount: Int
	) -> (box: NativeModelOperation, score: NativeModelOperation)? {
		func channels(_ op: NativeModelOperation) -> Int? {
			guard let shape = op.outputs.first?.shape, shape.count == 3, shape[0] == 1 else { return nil }
			return shape[1]
		}
		guard let aChannels = channels(a), let bChannels = channels(b) else { return nil }
		if aChannels == 4, a.kind == .multiply, bChannels == classCount, b.kind == .sigmoid {
			return (a, b)
		}
		if bChannels == 4, b.kind == .multiply, aChannels == classCount, a.kind == .sigmoid {
			return (b, a)
		}
		return nil
	}

	// MARK: - Coordinate space

	/// Classifies the coordinate space from the box branch's terminal scale multiply.
	///
	/// The graph's box path always ends in a multiply by a constant: a *normalized* export folds in a
	/// uniform `1/inputSize`, while a *pixel-space* export multiplies by the per-position stride. The
	/// two are the same op, so the constant's VALUE is the only signal — a range heuristic on the
	/// boxes would be fooled by out-of-frame predictions. An unrecognized constant (uniform but not the
	/// input reciprocal) is refused rather than guessed.
	private static func coordinateMode(
		fromBoxScale boxBranch: NativeModelOperation, graph: NativeModelGraph, weights: Data, boxCount: Int
	) -> NativeModelAnchorFreeHead.CoordinateMode? {
		guard let inputShape = graph.inputs.first?.shape, inputShape.count == 4 else { return nil }
		let height = inputShape[2], width = inputShape[3]
		guard width > 0, height > 0 else { return nil }
		guard let values = constantValues(feeding: boxBranch, in: graph, weights: weights), !values.isEmpty else {
			return nil
		}
		return classify(boxScale: values, boxCount: boxCount, width: width, height: height)
	}

	/// The value classification, factored out so it is unit-testable without a graph. A per-position
	/// (non-uniform) scale is a stride → pixels; a uniform scale equal to `[1/W, 1/H, 1/W, 1/H]` is the
	/// graph having normalized; a uniform scale that is anything else is ambiguous → refuse.
	static func classify(boxScale values: [Float], boxCount: Int, width: Int, height: Int) -> NativeModelAnchorFreeHead.CoordinateMode? {
		func channelValue(_ channel: Int) -> [Float]? {
			if values.count == 4 * boxCount {
				return Array(values[(channel * boxCount) ..< ((channel + 1) * boxCount)])
			}
			if values.count == 4 { return [values[channel]] }
			if values.count == 1 { return [values[0]] }
			return nil
		}
		let expected: [Float] = [1 / Float(width), 1 / Float(height), 1 / Float(width), 1 / Float(height)]
		var uniformPerChannel: [Float] = []
		for channel in 0 ..< 4 {
			guard let channelValues = channelValue(channel), let first = channelValues.first else { return nil }
			// Non-uniform within a channel means a per-position scale (the stride) — the boxes are in
			// pixels and the head must divide them down.
			guard channelValues.allSatisfy({ abs($0 - first) <= 1e-5 * max(1, abs(first)) }) else {
				return .pixelsOfInput(width: width, height: height)
			}
			uniformPerChannel.append(first)
		}
		// Uniform on every channel: normalized only if it is exactly the input reciprocal per axis.
		if zip(uniformPerChannel, expected).allSatisfy({ abs($0 - $1) <= 1e-3 * $1 }) {
			return .normalizedByGraph
		}
		// A uniform box scale that is not `1/inputSize` is an unknown convention — refuse it rather than
		// mislocate every box.
		return nil
	}

	// MARK: - Labels

	/// Resolves the class labels. The file's own `names` win when their count matches; otherwise the
	/// labels are honest `class_<i>` placeholders — never a channel-count-to-COCO guess, which would be
	/// the same silent mislabelling a URL heuristic causes.
	static func resolveLabels(
		hints: UltralyticsDetectorHints, classCount: Int
	) -> (labels: [String], provenance: NativeModelDetectorCatalog.DetectorLabelProvenance) {
		if let names = hints.names, names.count == classCount {
			return (names, .metadata)
		}
		return ((0 ..< classCount).map { "class_\($0)" }, .unnamed)
	}

	// MARK: - Graph helpers

	private static func producer(of tensorName: String, in graph: NativeModelGraph) -> NativeModelOperation? {
		for operation in graph.operations where operation.outputs.contains(where: { $0.name == tensorName }) {
			return operation
		}
		return nil
	}

	/// Reads the float32 values of the constant feeding `operation` (the first input whose producer is
	/// a `.constant`). Returns nil when no readable float constant feeds it.
	private static func constantValues(feeding operation: NativeModelOperation, in graph: NativeModelGraph, weights: Data) -> [Float]? {
		let weightsByName = Dictionary(graph.weights.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
		for inputName in operation.inputs {
			guard let producer = producer(of: inputName, in: graph), producer.kind == .constant,
				let weightName = producer.inputs.first,
				let weight = weightsByName[weightName],
				weight.dataType == .float32
			else {
				continue
			}
			let start = Int(weight.offset)
			let end = start + Int(weight.byteCount)
			guard start >= 0, end <= weights.count, (end - start) % 4 == 0 else { continue }
			return weights.subdata(in: start ..< end).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
		}
		return nil
	}
}
