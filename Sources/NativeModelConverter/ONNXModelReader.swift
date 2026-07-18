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

		var lowering = Lowering(initializers: initializersByName)
		try lowering.seedInput(realInputs[0])
		for node in nodes {
			try lowering.lower(node)
		}

		let nativeGraph = NativeModelGraph(
			formatVersion: NativeModelGraph.currentFormatVersion,
			producer: NativeModelGraphProducer(name: "onnx", version: model.firstString(2) ?? "unknown"),
			inputs: [lowering.tensor(named: realInputs[0].name)],
			weights: lowering.weights,
			operations: lowering.operations,
			outputs: [outputs[0].name]
		)
		return ONNXConversionInput(graph: nativeGraph, weights: lowering.weightBlob)
	}

	// MARK: - ONNX message parsing

	private struct ONNXTensor {
		let name: String
		let dims: [Int]
		let dataType: Int
		let rawData: Data
	}

	private struct ONNXNode {
		let opType: String
		let inputs: [String]
		let outputs: [String]
		let name: String
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
		return ONNXNode(
			opType: fields.firstString(4) ?? "",
			inputs: inputs,
			outputs: outputs,
			name: fields.firstString(3) ?? (outputs.first ?? "node"),
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
			for dimData in try ProtobufReader.fields(in: shapeData).allBytes(1) {
				let dimValue = try ProtobufReader.fields(in: dimData).firstVarint(1) ?? 0
				// A dim_value of 0 denotes a symbolic dimension (dim_param); fix a dynamic batch to 1.
				shape.append(dimValue == 0 ? 1 : Int(bitPattern: UInt(dimValue)))
			}
		}
		return ONNXValueInfo(name: name, shape: shape)
	}

	// MARK: - Lowering ONNX ops into the native IR

	private struct Lowering {
		let initializers: [String: ONNXTensor]
		var operations: [NativeModelOperation] = []
		var weights: [NativeModelWeight] = []
		var weightBlob = Data()
		private var shapes: [String: [Int]] = [:]
		private var shapeTensors: Set<String> = []
		private var emittedWeights: Set<String> = []

		init(initializers: [String: ONNXTensor]) {
			self.initializers = initializers
		}

		func tensor(named name: String) -> NativeModelTensor {
			NativeModelTensor(name: name, dataType: .float32, shape: shapes[name] ?? [])
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
			switch node.opType {
			case "Conv": try lowerConvolution(node)
			case "BatchNormalization": try lowerBatchNorm(node)
			case "Relu": try lowerActivation(node, kind: .relu, outputShape: shapes[primaryInput])
			case "Clip": try lowerClip(node)
			case "Add": try lowerAdd(node)
			case "GlobalAveragePool": try lowerGlobalAveragePool(node)
			case "Reshape", "Flatten": try lowerFlatten(node)
			case "Gemm": try lowerGemm(node)
			default: throw ONNXModelReaderError.unsupportedOperation(node.opType)
			}
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
			let weightNames = try weightInputs.map { try weightName($0) }
			let outputName = node.outputs[0]
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
			// `auto_pad` (SAME_UPPER/SAME_LOWER/VALID) computes padding implicitly; assuming zero pads
			// would change the feature maps, so reject anything but explicit NOTSET padding.
			if let autoPad = node.attributes["auto_pad"]?.string, autoPad != "NOTSET" {
				throw ONNXModelReaderError.unsupportedAttribute(operation: node.name, detail: "Conv auto_pad=\(autoPad)")
			}
			let group = node.attributes["group"]?.int ?? 1
			let kernelShape = node.attributes["kernel_shape"]?.ints ?? [kernel.dims[2], kernel.dims[3]]
			let strides = node.attributes["strides"]?.ints ?? [1, 1]
			let dilations = node.attributes["dilations"]?.ints ?? [1, 1]
			let pads = node.attributes["pads"]?.ints ?? [0, 0, 0, 0]
			guard kernelShape.count == 2, strides.count == 2, dilations.count == 2, strides[0] > 0, strides[1] > 0 else {
				throw ONNXModelReaderError.unsupportedAttribute(
					operation: node.name,
					detail: "Conv requires 2-D kernel_shape/strides/dilations with positive strides"
				)
			}
			// ONNX pads are [top, left, bottom, right]; the emitter takes symmetric [padH, padW].
			guard pads.count == 4, pads[0] == pads[2], pads[1] == pads[3] else {
				throw ONNXModelReaderError.unsupportedAttribute(operation: node.name, detail: "asymmetric padding \(pads)")
			}
			let outH = (inputShape[2] + 2 * pads[0] - dilations[0] * (kernelShape[0] - 1) - 1) / strides[0] + 1
			let outW = (inputShape[3] + 2 * pads[1] - dilations[1] * (kernelShape[1] - 1) - 1) / strides[1] + 1
			let outputShape = [inputShape[0], kernel.dims[0], outH, outW]
			var weightInputs = [node.inputs[1]]
			if node.inputs.count > 2 { weightInputs.append(node.inputs[2]) }
			try record(node, kind: .convolution2D, activationInputs: [node.inputs[0]], weightInputs: weightInputs, attributes: [
				"kernelSize": .integers(kernelShape),
				"strides": .integers(strides),
				"padding": .integers([pads[0], pads[1]]),
				"dilations": .integers(dilations),
				"groups": .integer(group)
			], outputShape: outputShape)
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
			guard node.inputs.count >= 2 else {
				throw ONNXModelReaderError.invalidModel("Add '\(node.name)' requires 2 inputs")
			}
			guard let outputShape = shapes[node.inputs[0]] else {
				throw ONNXModelReaderError.shapeInferenceFailed(operation: node.name, detail: "unknown input shape")
			}
			try record(node, kind: .add, activationInputs: [node.inputs[0], node.inputs[1]], weightInputs: [], attributes: [:], outputShape: outputShape)
		}

		private mutating func lowerGlobalAveragePool(_ node: ONNXNode) throws {
			guard let inputShape = shapes[node.inputs[0]], inputShape.count == 4 else {
				throw ONNXModelReaderError.shapeInferenceFailed(operation: node.name, detail: "GlobalAveragePool expects a rank-4 NCHW input")
			}
			try record(node, kind: .globalAveragePool2D, activationInputs: [node.inputs[0]], weightInputs: [], attributes: [:],
				outputShape: [inputShape[0], inputShape[1], 1, 1])
		}

		private mutating func lowerFlatten(_ node: ONNXNode) throws {
			guard let inputShape = shapes[node.inputs[0]], !inputShape.isEmpty else {
				throw ONNXModelReaderError.shapeInferenceFailed(operation: node.name, detail: "unknown input shape")
			}
			// Both Reshape([N, -1]/[N, C, 1, 1]->[N, C]) and Flatten(axis=1) collapse to [batch, features].
			let features = inputShape[1...].reduce(1, *)
			try record(node, kind: .flatten, activationInputs: [node.inputs[0]], weightInputs: [], attributes: ["axis": .integer(1)],
				outputShape: [inputShape[0], features])
		}
	}
}
