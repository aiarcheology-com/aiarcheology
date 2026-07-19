//
//  ONNXModelReader.swift
//  NativeModelConverter
//
//  Parses an ONNX model into the native graph IR so the existing Core ML emitter can convert it.
//

import Foundation

/// A native graph lowered from an ONNX model, ready for ``NativeModelCoreMLEmitter``.
public struct ONNXConversionInput: Sendable {
	public let graph: NativeModelGraph
	public let weights: Data
}

public enum ONNXModelReaderError: Error, Equatable, LocalizedError, Sendable {
	case invalidModel(String)
	case unsupportedOperation(String)
	case unsupportedAttribute(operation: String, detail: String)
	case missingInitializer(String)
	case unsupportedDataType(tensor: String, dataType: Int)
	case shapeInferenceFailed(operation: String, detail: String)
	case modelTooLarge(byteCount: UInt64, limit: UInt64)

	public var errorDescription: String? {
		switch self {
		case .invalidModel(let reason): "ONNX model is invalid: \(reason)."
		case .unsupportedOperation(let op): "ONNX operator '\(op)' is not supported by the native converter yet."
		case .unsupportedAttribute(let operation, let detail): "ONNX operator '\(operation)' has an unsupported attribute: \(detail)."
		case .missingInitializer(let name): "ONNX model references initializer '\(name)' that is not present."
		case .unsupportedDataType(let tensor, let dataType): "ONNX tensor '\(tensor)' uses unsupported data type \(dataType)."
		case .shapeInferenceFailed(let operation, let detail): "Could not infer output shape for ONNX operator '\(operation)': \(detail)."
		case .modelTooLarge(let byteCount, let limit): "ONNX model is \(byteCount) bytes, which exceeds the \(limit)-byte limit."
		}
	}
}

/// Reads a self-contained ONNX file entirely in Swift (no Python, no framework) and lowers the
/// supported classifier operator set into the native graph IR.
public struct ONNXModelReader {
	/// Upper bound on the on-disk `.onnx` size, checked before the file is materialized. ONNX imports
	/// are user-supplied, and the bytes are subsequently copied into the weight blob and output
	/// protobuf, so an unbounded read could exhaust memory. Matches the package reader's graph +
	/// weights budget.
	private let maximumFileByteCount: UInt64

	public init(maximumFileByteCount: UInt64 = 516 * 1_024 * 1_024) {
		self.maximumFileByteCount = maximumFileByteCount
	}

	public func read(from url: URL) throws -> ONNXConversionInput {
		if let fileSize = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
			fileSize.uint64Value > maximumFileByteCount {
			throw ONNXModelReaderError.modelTooLarge(byteCount: fileSize.uint64Value, limit: maximumFileByteCount)
		}
		return try read(data: Data(contentsOf: url, options: .mappedIfSafe))
	}

	public func read(data: Data) throws -> ONNXConversionInput {
		let model = try ProtobufReader.fields(in: data)
		guard let graphData = model.firstBytes(7) else {
			throw ONNXModelReaderError.invalidModel("no graph")
		}
		let graph = try ProtobufReader.fields(in: graphData)

		// ModelProto.opset_import (field 8) fixes the operator-set semantics. ONNX Softmax's normalization
		// axis changed at opset 13, so a missing default-domain entry would force a guess that could
		// convert a model silently wrong — reject it rather than assume a version.
		guard let opsetVersion = try defaultDomainOpsetVersion(model) else {
			throw ONNXModelReaderError.invalidModel("no default-domain opset_import entry")
		}

		let initializers = try graph.allBytes(5).map(parseTensor)
		let initializersByName = Dictionary(initializers.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
		let nodes = try graph.allBytes(1).map(parseNode)
		let inputs = try graph.allBytes(11).map(parseValueInfo)
		let outputs = try graph.allBytes(12).map(parseValueInfo)

		// The graph inputs that are not initializers are the real model inputs.
		let realInputs = inputs.filter { initializersByName[$0.name] == nil }
		guard realInputs.count == 1 else {
			throw ONNXModelReaderError.invalidModel("expected exactly one model input, found \(realInputs.count)")
		}
		guard outputs.count == 1 else {
			throw ONNXModelReaderError.invalidModel("expected exactly one model output, found \(outputs.count)")
		}

		var lowering = Lowering(initializers: initializersByName, opsetVersion: opsetVersion)
		try lowering.seedInput(realInputs[0])
		for node in nodes {
			try lowering.lower(node)
		}

		let nativeGraph = NativeModelGraph(
			formatVersion: NativeModelGraph.currentFormatVersion,
			// ModelProto.producer_version is field 3 (field 2 is producer_name).
			producer: NativeModelGraphProducer(name: "onnx", version: model.firstString(3) ?? "unknown"),
			inputs: [lowering.tensor(named: realInputs[0].name)],
			weights: lowering.weights,
			operations: lowering.operations,
			// A graph that ends in Identity/Dropout emits no op for its declared output; resolve the name
			// through the alias table so the emitted output points at the real upstream tensor.
			outputs: [lowering.resolve(outputs[0].name)]
		)
		return ONNXConversionInput(graph: nativeGraph, weights: lowering.weightBlob)
	}

	// MARK: - ONNX message parsing

	/// The version of the default ONNX operator set. `ModelProto.opset_import` is repeated field 8; each
	/// `OperatorSetIdProto` carries a `domain` (field 1) and `version` (field 2), and an absent/empty or
	/// "ai.onnx" domain is the default set. Returns nil when no default-domain entry is present.
	private func defaultDomainOpsetVersion(_ model: [(field: Int, value: ProtobufValue)]) throws -> Int? {
		for entry in model.allBytes(8) {
			let opset = try ProtobufReader.fields(in: entry)
			let domain = opset.firstString(1) ?? ""
			if domain.isEmpty || domain == "ai.onnx" {
				// A missing or zero version pins no semantics at all — reject rather than guess an era.
				guard let version = opset.firstVarint(2), version > 0 else {
					throw ONNXModelReaderError.invalidModel("default-domain opset_import has no valid version")
				}
				// A crafted version beyond Int.max must not trap; clamp it — only "before/after opset 13"
				// ever matters, so any absurdly large version behaves as the newest semantics.
				return Int(exactly: version) ?? Int.max
			}
		}
		return nil
	}

	private struct ONNXTensor {
		let name: String
		let dims: [Int]
		let dataType: Int
		let rawData: Data
	}

	private struct ONNXNode {
		let opType: String
		// Mutable so `lower` can substitute alias-resolved input names before dispatching to an op lowerer.
		var inputs: [String]
		let outputs: [String]
		let name: String
		let domain: String
		let attributes: [String: ONNXAttribute]
	}

	private struct ONNXAttribute {
		var int: Int?
		var float: Double?
		var ints: [Int]?
		var string: String?
	}

	private struct ONNXValueInfo {
		let name: String
		let shape: [Int]
	}

	private func parseTensor(_ data: Data) throws -> ONNXTensor {
		let fields = try ProtobufReader.fields(in: data)
		let dims = try fields.repeatedInts(1)
		let name = fields.firstString(8) ?? ""
		let dataType = Int(fields.firstVarint(2) ?? 0)
		var raw = fields.firstBytes(9) ?? Data()
		if raw.isEmpty {
			// Weights may be stored as packed float_data (field 4) rather than raw_data.
			let packed = fields.first { $0.field == 4 }
			if case .lengthDelimited(let floats)? = packed?.value { raw = floats }
		}
		return ONNXTensor(name: name, dims: dims, dataType: dataType, rawData: raw)
	}

	private func parseNode(_ data: Data) throws -> ONNXNode {
		let fields = try ProtobufReader.fields(in: data)
		let inputs = fields.allBytes(1).compactMap { String(data: $0, encoding: .utf8) }
		let outputs = fields.allBytes(2).compactMap { String(data: $0, encoding: .utf8) }
		var attributes: [String: ONNXAttribute] = [:]
		for attributeData in fields.allBytes(5) {
			let attributeFields = try ProtobufReader.fields(in: attributeData)
			guard let attrName = attributeFields.firstString(1) else { continue }
			var attribute = ONNXAttribute()
			if let i = attributeFields.firstVarint(3) { attribute.int = Int(bitPattern: UInt(i)) }
			if let f = attributeFields.first(where: { $0.field == 2 }), case .fixed32(let bits) = f.value {
				attribute.float = Double(Float(bitPattern: bits))
			}
			attribute.string = attributeFields.firstString(4) // AttributeProto.s (e.g. Conv auto_pad)
			let ints = try attributeFields.repeatedInts(8)
			if !ints.isEmpty { attribute.ints = ints }
			attributes[attrName] = attribute
		}
		// Caffe-era exporters (e.g. the zoo's SqueezeNet) write nodes with an *empty* name field, which
		// the graph validator rejects; fall back to the first output name for empty as well as absent.
		let declaredName = fields.firstString(3) ?? ""
		return ONNXNode(
			opType: fields.firstString(4) ?? "",
			inputs: inputs,
			outputs: outputs,
			name: declaredName.isEmpty ? (outputs.first ?? "node") : declaredName,
			// NodeProto.domain is field 7; an absent/empty domain is the default "ai.onnx" operator set.
			domain: fields.firstString(7) ?? "",
			attributes: attributes
		)
	}

	private func parseValueInfo(_ data: Data) throws -> ONNXValueInfo {
		let fields = try ProtobufReader.fields(in: data)
		let name = fields.firstString(1) ?? ""
		var shape: [Int] = []
		if let typeData = fields.firstBytes(2),
			let tensorType = try ProtobufReader.fields(in: typeData).firstBytes(1),
			let shapeData = try ProtobufReader.fields(in: tensorType).firstBytes(2) {
			for (index, dimData) in try ProtobufReader.fields(in: shapeData).allBytes(1).enumerated() {
				let dimValue = try ProtobufReader.fields(in: dimData).firstVarint(1) ?? 0
				// dim_value 0 denotes a symbolic dimension (dim_param). Coerce a symbolic batch (first
				// dim) to 1, but leave any other symbolic dim as 0 so `seedInput` rejects a model with
				// dynamic spatial dimensions rather than silently converting it as size 1.
				if dimValue == 0 {
					shape.append(index == 0 ? 1 : 0)
				} else {
					shape.append(Int(bitPattern: UInt(dimValue)))
				}
			}
		}
		return ONNXValueInfo(name: name, shape: shape)
	}

	// MARK: - Lowering ONNX ops into the native IR

	private struct Lowering {
		let initializers: [String: ONNXTensor]
		// The default-domain opset version, retained so opset-sensitive ops (e.g. Softmax at opset 13) can
		// branch on it as coverage grows.
		let opsetVersion: Int
		var operations: [NativeModelOperation] = []
		var weights: [NativeModelWeight] = []
		var weightBlob = Data()
		private var shapes: [String: [Int]] = [:]
		private var shapeTensors: Set<String> = []
		private var emittedWeights: Set<String> = []
		// Maps a pass-through op output (Identity, inference-mode Dropout) to its upstream tensor. Targets
		// are stored already-resolved, so a single lookup collapses any chain of aliases.
		private var aliases: [String: String] = [:]

		init(initializers: [String: ONNXTensor], opsetVersion: Int) {
			self.initializers = initializers
			self.opsetVersion = opsetVersion
		}

		func tensor(named name: String) -> NativeModelTensor {
			NativeModelTensor(name: name, dataType: .float32, shape: shapes[name] ?? [])
		}

		/// Resolves a tensor name through the alias table. A name that was never aliased maps to itself.
		func resolve(_ name: String) -> String {
			aliases[name] ?? name
		}

		mutating func seedInput(_ input: ONNXValueInfo) throws {
			guard input.shape.allSatisfy({ $0 > 0 }) else {
				throw ONNXModelReaderError.invalidModel("model input '\(input.name)' has a non-fixed shape \(input.shape)")
			}
			shapes[input.name] = input.shape
		}

		/// Registers an initializer as a native weight, appending its bytes to the shared blob once.
		private mutating func weightName(_ name: String) throws -> String {
			guard let tensor = initializers[name] else { throw ONNXModelReaderError.missingInitializer(name) }
			if emittedWeights.insert(name).inserted {
				guard tensor.dataType == 1 || tensor.dataType == 10 else {
					throw ONNXModelReaderError.unsupportedDataType(tensor: name, dataType: tensor.dataType)
				}
				weights.append(NativeModelWeight(
					name: name,
					dataType: tensor.dataType == 10 ? .float16 : .float32,
					shape: tensor.dims,
					offset: UInt64(weightBlob.count),
					byteCount: UInt64(tensor.rawData.count)
				))
				weightBlob.append(tensor.rawData)
			}
			return name
		}

		/// Reads the first float32 scalar from a constant initializer — used for Clip's opset-11 `min`/
		/// `max` tensor inputs. Returns nil when the name is not a float initializer or carries no data.
		private func constantFloat(_ name: String) -> Double? {
			guard let tensor = initializers[name], tensor.dataType == 1, tensor.rawData.count >= 4 else { return nil }
			return tensor.rawData.withUnsafeBytes { raw in
				Double(Float(bitPattern: raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self)))
			}
		}

		mutating func lower(_ node: ONNXNode) throws {
			// Substitute alias-resolved input names first so every downstream lookup (shapes, initializers,
			// recorded op inputs) sees the real upstream tensor. Aliases store their final target, so a
			// single hop is always enough.
			var node = node
			node.inputs = node.inputs.map { aliases[$0] ?? $0 }

			// A node outside the default operator set is a custom op: one named e.g. "Softmax" in another
			// domain must NOT be given standard ONNX semantics, so reject it rather than misconvert.
			guard node.domain.isEmpty || node.domain == "ai.onnx" else {
				throw ONNXModelReaderError.unsupportedOperation("\(node.domain).\(node.opType)")
			}

			// Identity and inference-mode Dropout are pure pass-throughs: alias the output to the resolved
			// input and emit nothing. This runs before the `consumesActivation` guard below because an
			// Identity/Dropout over an *initializer* has no activation input and would otherwise be folded
			// into the shape-tensor set, dropping the alias a downstream weight lookup relies on.
			if node.opType == "Identity" || node.opType == "Dropout" {
				return try lowerPassThrough(node)
			}

			// Shape-metadata ops (and any op that reads only shape tensors/constants) don't transform
			// activations. A classifier's dynamic flatten is emitted as Shape -> Gather -> Unsqueeze ->
			// Concat -> Reshape to preserve a symbolic batch; fold that whole subgraph away and treat the
			// final Reshape as a flatten inferred from the real activation shape.
			if node.opType == "Shape" || node.opType == "Constant" || node.opType == "ConstantOfShape" {
				node.outputs.forEach { shapeTensors.insert($0) }
				return
			}
			let consumesActivation = node.inputs.contains { shapes[$0] != nil && !shapeTensors.contains($0) }
			guard consumesActivation else {
				node.outputs.forEach { shapeTensors.insert($0) }
				return
			}
			guard let primaryInput = node.inputs.first else {
				throw ONNXModelReaderError.invalidModel("operator '\(node.opType)' (\(node.name)) has no inputs")
			}
			try dispatch(node, primaryInput: primaryInput)
		}

		/// Routes a validated activation-consuming node to its op lowerer. Split from `lower(_:)` so the
		/// growing operator table doesn't push the pre-dispatch checks past the complexity limit.
		private mutating func dispatch(_ node: ONNXNode, primaryInput: String) throws {
			switch node.opType {
			case "Conv": try lowerConvolution(node)
			case "BatchNormalization": try lowerBatchNorm(node)
			case "Relu": try lowerActivation(node, kind: .relu, outputShape: shapes[primaryInput])
			case "LeakyRelu": try lowerLeakyRelu(node)
			case "Clip": try lowerClip(node)
			case "Add": try lowerAdd(node)
			case "Mul": try lowerMul(node)
			case "Concat": try lowerConcat(node)
			case "GlobalAveragePool": try lowerGlobalAveragePool(node)
			case "MaxPool": try lowerMaxPool(node)
			case "Reshape", "Flatten": try lowerFlatten(node)
			case "Gemm": try lowerGemm(node)
			case "Softmax": try lowerSoftmax(node)
			default: throw ONNXModelReaderError.unsupportedOperation(node.opType)
			}
		}

		/// Records the alias for a pass-through node (Identity, inference-mode Dropout). Inputs arrive
		/// already alias-resolved, so the stored target keeps every chain one hop deep.
		private mutating func lowerPassThrough(_ node: ONNXNode) throws {
			// A third `training_mode` input means dropout is active and no longer the identity.
			guard node.opType != "Dropout" || node.inputs.count <= 2 else {
				throw ONNXModelReaderError.unsupportedAttribute(operation: node.name, detail: "Dropout with a training_mode input")
			}
			// Opsets 1–6 flag inference via `is_test`, which DEFAULTS to 0 (training): only an explicit
			// non-zero value makes this dropout the identity.
			if node.opType == "Dropout", opsetVersion < 7, (node.attributes["is_test"]?.int ?? 0) == 0 {
				throw ONNXModelReaderError.unsupportedAttribute(operation: node.name, detail: "pre-opset-7 Dropout without is_test=1")
			}
			// Dropout's optional second (mask) output is discarded; only the data output aliases the input.
			guard let input = node.inputs.first, let output = node.outputs.first else {
				throw ONNXModelReaderError.invalidModel("\(node.opType) '\(node.name)' requires an input and an output")
			}
			aliases[output] = input
		}

		private mutating func lowerGemm(_ node: ONNXNode) throws {
			guard node.inputs.count >= 2 else {
				throw ONNXModelReaderError.invalidModel("Gemm '\(node.name)' requires at least 2 inputs")
			}
			guard let inputShape = shapes[node.inputs[0]], !inputShape.isEmpty else {
				throw ONNXModelReaderError.shapeInferenceFailed(operation: node.name, detail: "unknown input shape")
			}
			guard let weight = initializers[node.inputs[1]] else { throw ONNXModelReaderError.missingInitializer(node.inputs[1]) }
			guard !weight.dims.isEmpty else {
				throw ONNXModelReaderError.invalidModel("Gemm '\(node.name)' weight has no dimensions")
			}
			// The native linear op expects a [outputChannels, inputChannels] weight, matching ONNX Gemm
			// with transB=1 (the standard classifier head). transB=0 would need a transpose first, and
			// transA / alpha / beta all change the result but are not encoded in the inner-product layer,
			// so reject anything other than the standard `y = xWᵀ + b` form rather than misconvert.
			guard (node.attributes["transB"]?.int ?? 0) == 1 else {
				throw ONNXModelReaderError.unsupportedAttribute(operation: node.name, detail: "Gemm without transB=1")
			}
			guard (node.attributes["transA"]?.int ?? 0) == 0 else {
				throw ONNXModelReaderError.unsupportedAttribute(operation: node.name, detail: "Gemm with transA=1")
			}
			if let alpha = node.attributes["alpha"]?.float, alpha != 1 {
				throw ONNXModelReaderError.unsupportedAttribute(operation: node.name, detail: "Gemm alpha=\(alpha) != 1")
			}
			if let beta = node.attributes["beta"]?.float, beta != 1 {
				throw ONNXModelReaderError.unsupportedAttribute(operation: node.name, detail: "Gemm beta=\(beta) != 1")
			}
			var weightInputs = [node.inputs[1]]
			if node.inputs.count > 2 { weightInputs.append(node.inputs[2]) }
			try record(node, kind: .linear, activationInputs: [node.inputs[0]], weightInputs: weightInputs, attributes: [:],
				outputShape: [inputShape[0], weight.dims[0]])
		}

		private mutating func record(_ node: ONNXNode, kind: NativeModelOperationKind, activationInputs: [String], weightInputs: [String], attributes: [String: NativeModelAttribute], outputShape: [Int]) throws {
			// Central malformed-input net: every lowerer funnels through here, so one guard keeps a
			// node with no declared outputs from crashing on the index below.
			guard let outputName = node.outputs.first else {
				throw ONNXModelReaderError.invalidModel("operator '\(node.opType)' (\(node.name)) has no outputs")
			}
			let weightNames = try weightInputs.map { try weightName($0) }
			shapes[outputName] = outputShape
			operations.append(NativeModelOperation(
				name: node.name,
				kind: kind,
				inputs: activationInputs + weightNames,
				outputs: [NativeModelTensor(name: outputName, dataType: .float32, shape: outputShape)],
				attributes: attributes
			))
		}

		private mutating func lowerConvolution(_ node: ONNXNode) throws {
			guard node.inputs.count >= 2 else {
				throw ONNXModelReaderError.invalidModel("Conv '\(node.name)' requires at least 2 inputs")
			}
			guard let inputShape = shapes[node.inputs[0]], inputShape.count == 4 else {
				throw ONNXModelReaderError.shapeInferenceFailed(operation: node.name, detail: "Conv expects a rank-4 NCHW input")
			}
			guard let kernel = initializers[node.inputs[1]], kernel.dims.count == 4 else {
				throw ONNXModelReaderError.invalidModel("Conv '\(node.name)' kernel must be a rank-4 initializer")
			}
			let group = node.attributes["group"]?.int ?? 1
			let kernelShape = node.attributes["kernel_shape"]?.ints ?? [kernel.dims[2], kernel.dims[3]]
			let strides = node.attributes["strides"]?.ints ?? [1, 1]
			let dilations = node.attributes["dilations"]?.ints ?? [1, 1]
			guard kernelShape.count == 2, strides.count == 2, dilations.count == 2,
				(kernelShape + strides + dilations).allSatisfy({ $0 > 0 }) else {
				throw ONNXModelReaderError.unsupportedAttribute(
					operation: node.name,
					detail: "Conv requires 2-D positive kernel_shape/strides/dilations"
				)
			}
			// Bound the spatial dimensions and every attribute BEFORE the padding resolution: the
			// SAME_UPPER arithmetic multiplies file-supplied strides, so unbounded crafted values
			// would overflow-trap inside `resolvedPads` rather than fail cleanly. With everything
			// clamped to 2^20 all later products stay well within Int.
			let dimensionLimit = 1 << 20
			guard inputShape[2] <= dimensionLimit, inputShape[3] <= dimensionLimit,
				kernelShape.allSatisfy({ $0 <= dimensionLimit }),
				strides.allSatisfy({ $0 <= dimensionLimit }),
				dilations.allSatisfy({ $0 <= dimensionLimit }) else {
				throw ONNXModelReaderError.unsupportedAttribute(operation: node.name, detail: "Conv dimensions exceed the supported range")
			}
			let pads = try resolvedPads(node, inputShape: inputShape, kernelShape: kernelShape, strides: strides, dilations: dilations)
			guard pads.allSatisfy({ $0 <= dimensionLimit }) else {
				throw ONNXModelReaderError.unsupportedAttribute(operation: node.name, detail: "Conv dimensions exceed the supported range")
			}
			// An effective kernel larger than the padded input must be rejected BEFORE the division:
			// Swift's `/` truncates toward zero while ONNX floor-divides, so a negative numerator
			// would "round up" to a bogus 1-wide output instead of the zero-sized result ONNX
			// computes (the same trap the MaxPool lowering guards against).
			let paddedH = inputShape[2] + pads[0] + pads[2]
			let paddedW = inputShape[3] + pads[1] + pads[3]
			let effectiveKernelH = dilations[0] * (kernelShape[0] - 1) + 1
			let effectiveKernelW = dilations[1] * (kernelShape[1] - 1) + 1
			guard paddedH >= effectiveKernelH, paddedW >= effectiveKernelW else {
				throw ONNXModelReaderError.shapeInferenceFailed(operation: node.name, detail: "Conv kernel is larger than the padded input")
			}
			let outH = (paddedH - effectiveKernelH) / strides[0] + 1
			let outW = (paddedW - effectiveKernelW) / strides[1] + 1
			let outputShape = [inputShape[0], kernel.dims[0], outH, outW]
			var weightInputs = [node.inputs[1]]
			if node.inputs.count > 2 { weightInputs.append(node.inputs[2]) }
			try record(node, kind: .convolution2D, activationInputs: [node.inputs[0]], weightInputs: weightInputs, attributes: [
				"kernelSize": .integers(kernelShape),
				"strides": .integers(strides),
				"padding": paddingAttribute(pads),
				"dilations": .integers(dilations),
				"groups": .integer(group)
			], outputShape: outputShape)
		}

		/// Resolves a Conv/MaxPool node's padding to explicit ONNX-order `[top, left, bottom, right]`.
		///
		/// `auto_pad` NOTSET (the modern default) reads the explicit `pads` attribute. VALID means no
		/// padding at all. SAME_UPPER — the form Caffe-era exporters wrote on every node — pads so the
		/// output keeps `ceil(in / stride)`, with the odd pixel going to the bottom/right edge; it can
		/// therefore be *asymmetric* (tiny-yolov2's final stride-1 pool resolves to [0, 0, 1, 1]).
		/// SAME_LOWER is rejected rather than approximated with the wrong edge.
		private func resolvedPads(
			_ node: ONNXNode, inputShape: [Int], kernelShape: [Int], strides: [Int], dilations: [Int]
		) throws -> [Int] {
			let autoPad = node.attributes["auto_pad"]?.string ?? "NOTSET"
			switch autoPad {
			case "NOTSET":
				let pads = node.attributes["pads"]?.ints ?? [0, 0, 0, 0]
				guard pads.count == 4, pads.allSatisfy({ $0 >= 0 }) else {
					throw ONNXModelReaderError.unsupportedAttribute(operation: node.name, detail: "pads must be four non-negative integers, got \(pads)")
				}
				return pads
			case "VALID":
				// pads must not accompany auto_pad; a file carrying both is contradictory.
				guard (node.attributes["pads"]?.ints ?? []).allSatisfy({ $0 == 0 }) else {
					throw ONNXModelReaderError.unsupportedAttribute(operation: node.name, detail: "both auto_pad and explicit pads are set")
				}
				return [0, 0, 0, 0]
			case "SAME_UPPER":
				guard (node.attributes["pads"]?.ints ?? []).allSatisfy({ $0 == 0 }) else {
					throw ONNXModelReaderError.unsupportedAttribute(operation: node.name, detail: "both auto_pad and explicit pads are set")
				}
				var edges = [0, 0, 0, 0]
				for axis in 0 ..< 2 {
					let input = inputShape[2 + axis]
					let effectiveKernel = dilations[axis] * (kernelShape[axis] - 1) + 1
					let output = (input + strides[axis] - 1) / strides[axis]
					let total = max((output - 1) * strides[axis] + effectiveKernel - input, 0)
					edges[axis] = total / 2               // top / left
					edges[2 + axis] = total - total / 2   // bottom / right take the odd pixel
				}
				return edges
			default:
				throw ONNXModelReaderError.unsupportedAttribute(operation: node.name, detail: "\(node.opType) auto_pad=\(autoPad)")
			}
		}

		/// The IR padding attribute: the compact symmetric `[padH, padW]` form whenever possible,
		/// per-edge `[top, left, bottom, right]` only when the edges actually differ.
		private func paddingAttribute(_ pads: [Int]) -> NativeModelAttribute {
			pads[0] == pads[2] && pads[1] == pads[3] ? .integers([pads[0], pads[1]]) : .integers(pads)
		}

		private mutating func lowerBatchNorm(_ node: ONNXNode) throws {
			guard node.inputs.count >= 5 else {
				throw ONNXModelReaderError.invalidModel("BatchNormalization '\(node.name)' requires 5 inputs")
			}
			guard let inputShape = shapes[node.inputs[0]] else {
				throw ONNXModelReaderError.shapeInferenceFailed(operation: node.name, detail: "unknown input shape")
			}
			let epsilon = node.attributes["epsilon"]?.float ?? 1e-5
			try record(node, kind: .batchNormalization, activationInputs: [node.inputs[0]],
				weightInputs: Array(node.inputs[1 ..< 5]),
				attributes: ["epsilon": .floatingPoint(epsilon)], outputShape: inputShape)
		}

		private mutating func lowerActivation(_ node: ONNXNode, kind: NativeModelOperationKind, outputShape: [Int]?) throws {
			guard let outputShape else { throw ONNXModelReaderError.shapeInferenceFailed(operation: node.name, detail: "unknown input shape") }
			try record(node, kind: kind, activationInputs: [node.inputs[0]], weightInputs: [], attributes: [:], outputShape: outputShape)
		}

		/// ONNX `Clip` maps to the native ReLU6 only when its bounds are exactly [0, 6]. Bounds come from
		/// `min`/`max` attributes (opset < 11) or the optional min/max tensor inputs (opset >= 11).
		/// Anything else — unbounded, dynamic (non-constant), or different limits — is rejected rather
		/// than silently converted to ReLU6 with the wrong activation.
		private mutating func lowerClip(_ node: ONNXNode) throws {
			guard let outputShape = shapes[node.inputs[0]] else {
				throw ONNXModelReaderError.shapeInferenceFailed(operation: node.name, detail: "unknown input shape")
			}
			let minBound = node.attributes["min"]?.float ?? (node.inputs.count > 1 ? constantFloat(node.inputs[1]) : nil)
			let maxBound = node.attributes["max"]?.float ?? (node.inputs.count > 2 ? constantFloat(node.inputs[2]) : nil)
			guard minBound == 0.0, maxBound == 6.0 else {
				let describe: (Double?) -> String = { bound in bound.map { "\($0)" } ?? "unbounded" }
				throw ONNXModelReaderError.unsupportedAttribute(
					operation: node.name,
					detail: "Clip bounds must be [0, 6] to map to ReLU6 (got [\(describe(minBound)), \(describe(maxBound))])"
				)
			}
			try record(node, kind: .relu6, activationInputs: [node.inputs[0]], weightInputs: [], attributes: [:], outputShape: outputShape)
		}

		private mutating func lowerAdd(_ node: ONNXNode) throws {
			try lowerBinaryElementwise(node, kind: .add)
		}

		private mutating func lowerMul(_ node: ONNXNode) throws {
			try lowerBinaryElementwise(node, kind: .multiply)
		}

		/// Elementwise Add/Mul. Two forms convert:
		/// - two same-shape activations (the residual-connection form), and
		/// - one activation with one *constant* broadcast operand of scalar/`[1]`/`[C]`/`[C, 1, 1]`
		///   shape (the graph-embedded normalization form, e.g. tiny-yolov2's `x · 1/255 + bias`) —
		///   the exact broadcasts Core ML's classic elementwise layers implement.
		/// Anything else — activation broadcasting, spatial constants — is rejected rather than
		/// silently mis-broadcast.
		private mutating func lowerBinaryElementwise(_ node: ONNXNode, kind: NativeModelOperationKind) throws {
			guard node.inputs.count == 2 else {
				throw ONNXModelReaderError.invalidModel("\(node.opType) '\(node.name)' requires 2 inputs")
			}
			// Pre-opset-7 Add/Mul use explicit `broadcast`/`axis` attributes with *left*-aligned
			// semantics — the opposite of the numpy alignment everything below assumes. Reject them
			// rather than convert with flipped axes.
			guard node.attributes["broadcast"]?.int ?? 0 == 0, node.attributes["axis"] == nil else {
				throw ONNXModelReaderError.unsupportedAttribute(
					operation: node.name,
					detail: "\(node.opType) with legacy broadcast/axis attributes"
				)
			}
			// The activation operand is whichever input carries a known activation shape; ONNX allows
			// the constant on either side (tiny-yolov2 writes `Add(bias, x)`).
			let activationIndex = node.inputs.firstIndex { shapes[$0] != nil }
			guard let activationIndex, let outputShape = shapes[node.inputs[activationIndex]] else {
				throw ONNXModelReaderError.shapeInferenceFailed(operation: node.name, detail: "unknown input shape")
			}
			let activation = node.inputs[activationIndex]
			let other = node.inputs[1 - activationIndex]

			if let otherShape = shapes[other] {
				guard otherShape == outputShape else {
					throw ONNXModelReaderError.unsupportedAttribute(
						operation: node.name,
						detail: "\(node.opType) requires same-shape activations or a constant broadcast operand"
					)
				}
				try record(node, kind: kind, activationInputs: [activation, other], weightInputs: [], attributes: [:], outputShape: outputShape)
				return
			}

			let constant = try broadcastConstant(named: other, over: outputShape, operation: node.name)
			try record(node, kind: kind, activationInputs: [activation, constant], weightInputs: [], attributes: [:], outputShape: outputShape)
		}

		/// Registers `name` (which must be an initializer) as a `constant` operation whose shape is
		/// normalized to the rank-3 `[C, 1, 1]` layout Core ML's load-constant layer takes, and which
		/// classic elementwise layers can broadcast over a `[1, C, H, W]` activation.
		private mutating func broadcastConstant(named name: String, over activationShape: [Int], operation: String) throws -> String {
			guard let tensor = initializers[name] else {
				throw ONNXModelReaderError.shapeInferenceFailed(operation: operation, detail: "operand '\(name)' is neither an activation nor an initializer")
			}
			guard tensor.dataType == 1 else {
				throw ONNXModelReaderError.unsupportedDataType(tensor: name, dataType: tensor.dataType)
			}
			// Accepted broadcast forms, under ONNX's *right-aligned* broadcasting: any all-unit shape
			// (a scalar), or a per-channel vector whose channel extent sits three-from-last —
			// `[C, 1, 1]` / `[1, C, 1, 1]`. A rank-1 `[C]` is NOT a channel vector: right-alignment
			// pairs it with the width axis, so converting it channel-wise would be silently wrong.
			// Constants with spatial extent have no classic channel broadcast and are rejected too.
			let significant = tensor.dims.filter { $0 != 1 }
			let channels: Int
			if significant.isEmpty {
				channels = 1
			} else if significant.count == 1, tensor.dims.count >= 3, tensor.dims.suffix(2) == [1, 1],
				tensor.dims[tensor.dims.count - 3] == significant[0] {
				guard activationShape.count == 4, significant[0] == activationShape[1] else {
					throw ONNXModelReaderError.unsupportedAttribute(
						operation: operation,
						detail: "constant operand '\(name)' with \(significant[0]) channels does not match activation shape \(activationShape)"
					)
				}
				channels = significant[0]
			} else {
				throw ONNXModelReaderError.unsupportedAttribute(
					operation: operation,
					detail: "constant operand '\(name)' of shape \(tensor.dims) has no channel-wise broadcast"
				)
			}
			// Overflow-reporting: `channels` traces back to file-declared dims, so a crafted value must
			// fail as an invalid model, not trap in the multiplication.
			let (expectedByteCount, byteCountOverflow) = channels.multipliedReportingOverflow(by: 4)
			guard !byteCountOverflow, tensor.rawData.count == expectedByteCount else {
				throw ONNXModelReaderError.invalidModel("initializer '\(name)' declares \(channels) channels but carries \(tensor.rawData.count) bytes")
			}

			let constantOutput = "\(name)__const"
			// Idempotent: the same initializer may feed several nodes.
			if shapes[constantOutput] == nil {
				let weightName = "\(name)__constWeight"
				weights.append(NativeModelWeight(
					name: weightName, dataType: .float32, shape: [channels, 1, 1],
					offset: UInt64(weightBlob.count), byteCount: UInt64(tensor.rawData.count)
				))
				weightBlob.append(tensor.rawData)
				shapes[constantOutput] = [channels, 1, 1]
				operations.append(NativeModelOperation(
					name: constantOutput, kind: .constant, inputs: [weightName],
					outputs: [NativeModelTensor(name: constantOutput, dataType: .float32, shape: [channels, 1, 1])],
					attributes: [:]
				))
			}
			return constantOutput
		}

		/// ONNX LeakyRelu: `y = x` for positive x, `alpha · x` otherwise; alpha defaults to 0.01.
		private mutating func lowerLeakyRelu(_ node: ONNXNode) throws {
			guard let outputShape = shapes[node.inputs[0]] else {
				throw ONNXModelReaderError.shapeInferenceFailed(operation: node.name, detail: "unknown input shape")
			}
			let alpha = node.attributes["alpha"]?.float ?? 0.01
			try record(node, kind: .leakyReLU, activationInputs: [node.inputs[0]], weightInputs: [],
				attributes: ["alpha": .floatingPoint(alpha)], outputShape: outputShape)
		}

		/// ONNX `Concat` lowers to the native concatenate op, which joins rank-4 NCHW activations along
		/// the channel axis only. Every input must be a produced activation — a missing shape means an
		/// initializer or shape/constant tensor the native op does not model — and the non-channel dims
		/// must agree, since the output simply stacks the inputs' channels.
		private mutating func lowerConcat(_ node: ONNXNode) throws {
			guard node.inputs.count >= 2 else {
				throw ONNXModelReaderError.invalidModel("Concat '\(node.name)' requires at least 2 inputs")
			}
			let inputShapes = try node.inputs.map { input -> [Int] in
				guard let shape = shapes[input] else {
					throw ONNXModelReaderError.shapeInferenceFailed(operation: node.name, detail: "unknown input shape")
				}
				return shape
			}
			guard inputShapes.allSatisfy({ $0.count == 4 }) else {
				throw ONNXModelReaderError.shapeInferenceFailed(operation: node.name, detail: "Concat expects rank-4 NCHW inputs, got \(inputShapes)")
			}
			// ONNX Concat requires an explicit axis from opset 4 on (only the long-dead opset-1 form
			// defaulted it), so a missing one is unconvertible rather than assumed. A negative axis
			// counts back from the rank (4); the native op only joins the channel axis, so anything but
			// axis 1 after normalization is unsupported.
			guard let rawAxis = node.attributes["axis"]?.int else {
				throw ONNXModelReaderError.unsupportedAttribute(operation: node.name, detail: "Concat requires an axis attribute")
			}
			let axis = rawAxis < 0 ? rawAxis + 4 : rawAxis
			guard axis == 1 else {
				throw ONNXModelReaderError.unsupportedAttribute(operation: node.name, detail: "Concat axis \(rawAxis) — only channel concatenation (axis 1) is supported")
			}
			// Channel concat keeps batch/height/width identical across inputs and sums the channel dim.
			let reference = inputShapes[0]
			for shape in inputShapes.dropFirst() where shape[0] != reference[0] || shape[2] != reference[2] || shape[3] != reference[3] {
				throw ONNXModelReaderError.shapeInferenceFailed(operation: node.name, detail: "Concat inputs disagree outside the channel axis: \(reference) vs \(shape)")
			}
			// Sum with overflow reporting: crafted channel counts must throw, not trap (same rationale as
			// the flatten feature-count product).
			var channels = 0
			for shape in inputShapes {
				let (sum, overflow) = channels.addingReportingOverflow(shape[1])
				guard !overflow else {
					throw ONNXModelReaderError.shapeInferenceFailed(operation: node.name, detail: "Concat channel count overflows")
				}
				channels = sum
			}
			try record(node, kind: .concatenate, activationInputs: node.inputs, weightInputs: [],
				attributes: ["axis": .integer(1)], outputShape: [reference[0], channels, reference[2], reference[3]])
		}

		/// ONNX `Softmax` semantics depend on the opset: before 13 the input is coerced to a 2-D matrix
		/// split at `axis` (default 1) and rows are normalized jointly; from 13 on it normalizes along
		/// `axis` (default −1) independently per slice. Core ML's softmaxND implements the per-axis form.
		/// The two coincide exactly when every dimension after `axis` is 1 — true for classifier heads
		/// like SqueezeNet's `[1, 1000, 1, 1]` — so pre-13 graphs outside that shape are rejected rather
		/// than converted with the wrong normalization group.
		private mutating func lowerSoftmax(_ node: ONNXNode) throws {
			guard let inputShape = shapes[node.inputs[0]], !inputShape.isEmpty else {
				throw ONNXModelReaderError.shapeInferenceFailed(operation: node.name, detail: "unknown input shape")
			}
			let rank = inputShape.count
			let rawAxis = node.attributes["axis"]?.int ?? (opsetVersion >= 13 ? -1 : 1)
			let axis = rawAxis < 0 ? rawAxis + rank : rawAxis
			guard axis >= 0, axis < rank else {
				throw ONNXModelReaderError.unsupportedAttribute(operation: node.name, detail: "Softmax axis \(rawAxis) is out of range for rank \(rank)")
			}
			if opsetVersion < 13 {
				guard inputShape[(axis + 1)...].allSatisfy({ $0 == 1 }) else {
					throw ONNXModelReaderError.unsupportedAttribute(
						operation: node.name,
						detail: "pre-opset-13 Softmax over \(inputShape) at axis \(axis) normalizes across multiple dimensions"
					)
				}
			}
			try record(node, kind: .softmax, activationInputs: [node.inputs[0]], weightInputs: [],
				attributes: ["axis": .integer(axis)], outputShape: inputShape)
		}

		private mutating func lowerGlobalAveragePool(_ node: ONNXNode) throws {
			guard let inputShape = shapes[node.inputs[0]], inputShape.count == 4 else {
				throw ONNXModelReaderError.shapeInferenceFailed(operation: node.name, detail: "GlobalAveragePool expects a rank-4 NCHW input")
			}
			try record(node, kind: .globalAveragePool2D, activationInputs: [node.inputs[0]], weightInputs: [], attributes: [:],
				outputShape: [inputShape[0], inputShape[1], 1, 1])
		}

		private mutating func lowerMaxPool(_ node: ONNXNode) throws {
			// ONNX MaxPool may declare a second `Indices` output (the argmax positions). Core ML pooling
			// only produces the pooled values, so a model that consumes those indices cannot be converted.
			guard node.outputs.count == 1 else {
				throw ONNXModelReaderError.unsupportedAttribute(operation: node.name, detail: "MaxPool with an Indices output")
			}
			guard let inputShape = shapes[node.inputs[0]], inputShape.count == 4 else {
				throw ONNXModelReaderError.shapeInferenceFailed(operation: node.name, detail: "MaxPool expects a rank-4 NCHW input")
			}
			// `ceil_mode` rounds the output size up (the default floor-division below assumes down) and
			// `storage_order` transposes the argmax layout; both change results the native op can't match.
			if let ceilMode = node.attributes["ceil_mode"]?.int, ceilMode != 0 {
				throw ONNXModelReaderError.unsupportedAttribute(operation: node.name, detail: "MaxPool ceil_mode=\(ceilMode)")
			}
			if let storageOrder = node.attributes["storage_order"]?.int, storageOrder != 0 {
				throw ONNXModelReaderError.unsupportedAttribute(operation: node.name, detail: "MaxPool storage_order=\(storageOrder)")
			}
			// Dilated pooling spreads the window across the input; the native pooling op is dense only.
			if let dilations = node.attributes["dilations"]?.ints, dilations != [1, 1] {
				throw ONNXModelReaderError.unsupportedAttribute(operation: node.name, detail: "MaxPool dilations=\(dilations)")
			}
			// Unlike Conv, MaxPool has no kernel initializer to infer the window from, so `kernel_shape` is
			// required — without it the pool size is undefined.
			guard let kernelShape = node.attributes["kernel_shape"]?.ints, kernelShape.count == 2,
				kernelShape[0] > 0, kernelShape[1] > 0 else {
				throw ONNXModelReaderError.unsupportedAttribute(operation: node.name, detail: "MaxPool requires a 2-D positive kernel_shape")
			}
			let strides = node.attributes["strides"]?.ints ?? [1, 1]
			guard strides.count == 2, strides[0] > 0, strides[1] > 0 else {
				throw ONNXModelReaderError.unsupportedAttribute(operation: node.name, detail: "MaxPool requires 2-D positive strides")
			}
			// Bound the spatial dimensions and every attribute BEFORE the padding resolution — the
			// SAME_UPPER arithmetic multiplies file-supplied strides, and unbounded crafted values
			// would overflow-trap inside `resolvedPads` rather than fail cleanly.
			let dimensionLimit = 1 << 20
			guard inputShape[2] <= dimensionLimit, inputShape[3] <= dimensionLimit,
				kernelShape.allSatisfy({ $0 <= dimensionLimit }),
				strides.allSatisfy({ $0 <= dimensionLimit }) else {
				throw ONNXModelReaderError.unsupportedAttribute(operation: node.name, detail: "MaxPool dimensions exceed the supported range")
			}
			let pads = try resolvedPads(node, inputShape: inputShape, kernelShape: kernelShape, strides: strides, dilations: [1, 1])
			guard pads.allSatisfy({ $0 <= dimensionLimit }) else {
				throw ONNXModelReaderError.unsupportedAttribute(operation: node.name, detail: "MaxPool dimensions exceed the supported range")
			}
			// A kernel larger than the padded input must be rejected BEFORE the division: Swift's `/`
			// truncates toward zero while ONNX floor-divides, so e.g. (2 − 3)/2 + 1 would "round up" the
			// negative numerator to a bogus 1-wide output instead of the non-positive size ONNX computes.
			let paddedH = inputShape[2] + pads[0] + pads[2]
			let paddedW = inputShape[3] + pads[1] + pads[3]
			guard paddedH >= kernelShape[0], paddedW >= kernelShape[1] else {
				throw ONNXModelReaderError.shapeInferenceFailed(operation: node.name, detail: "MaxPool kernel is larger than the padded input")
			}
			let outH = (paddedH - kernelShape[0]) / strides[0] + 1
			let outW = (paddedW - kernelShape[1]) / strides[1] + 1
			// maxPool2D's IR signature is exactly kernelSize/strides/padding — no dilations/groups.
			try record(node, kind: .maxPool2D, activationInputs: [node.inputs[0]], weightInputs: [], attributes: [
				"kernelSize": .integers(kernelShape),
				"strides": .integers(strides),
				"padding": paddingAttribute(pads)
			], outputShape: [inputShape[0], inputShape[1], outH, outW])
		}

		private mutating func lowerFlatten(_ node: ONNXNode) throws {
			guard let inputShape = shapes[node.inputs[0]], !inputShape.isEmpty else {
				throw ONNXModelReaderError.shapeInferenceFailed(operation: node.name, detail: "unknown input shape")
			}
			// Both Reshape([N, -1]/[N, C, 1, 1]->[N, C]) and Flatten(axis=1) collapse to [batch, features].
			// Multiply with overflow reporting: a crafted shape must throw, not trap.
			var features = 1
			for dimension in inputShape[1...] {
				let (product, overflow) = features.multipliedReportingOverflow(by: dimension)
				guard !overflow else {
					throw ONNXModelReaderError.shapeInferenceFailed(operation: node.name, detail: "flatten feature count overflows")
				}
				features = product
			}
			try record(node, kind: .flatten, activationInputs: [node.inputs[0]], weightInputs: [], attributes: ["axis": .integer(1)],
				outputShape: [inputShape[0], features])
		}
	}
}
