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
	/// Display-only attribution carried from the source ONNX model's `doc_string` / `metadata_props`
	/// (AIA-0473). `nil` when the file records nothing worth attributing, so a bare model keeps its
	/// existing filename fallback rather than acquiring an empty metadata block.
	public let metadata: NativeModelCoreMLMetadata?

	public init(graph: NativeModelGraph, weights: Data, metadata: NativeModelCoreMLMetadata? = nil) {
		self.graph = graph
		self.weights = weights
		self.metadata = metadata
	}
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

		// ModelProto.producer_name is field 2; fall back to "onnx" when the file omits it so the
		// producer namespace is never empty. producer_name identifies the exporting TOOL, not the
		// model's author — the author comes only from metadata_props["author"] (see ONNXMetadataMapping).
		// Untrusted like every metadata field: an oversized name falls back rather than flowing into
		// the emitted model's producer metadata unbounded.
		let trimmedProducerName = model.firstString(2)?.trimmingCharacters(in: .whitespacesAndNewlines)
		let producerName = trimmedProducerName.flatMap { name -> String? in
			name.utf8.count <= ONNXMetadataMapping.maximumValueByteCount ? name : nil
		}
		let nativeGraph = NativeModelGraph(
			formatVersion: NativeModelGraph.currentFormatVersion,
			// ModelProto.producer_version is field 3.
			producer: NativeModelGraphProducer(
				name: producerName.flatMap { $0.isEmpty ? nil : $0 } ?? "onnx",
				version: model.firstString(3) ?? "unknown"
			),
			inputs: [lowering.tensor(named: realInputs[0].name)],
			weights: lowering.weights,
			operations: lowering.operations,
			// A graph that ends in Identity/Dropout emits no op for its declared output; resolve the name
			// through the alias table so the emitted output points at the real upstream tensor.
			outputs: [lowering.resolve(outputs[0].name)]
		)
		return ONNXConversionInput(
			graph: nativeGraph,
			weights: lowering.weightBlob,
			metadata: ONNXMetadataMapping.metadata(from: rawMetadata(from: model))
		)
	}

	/// Pulls the ModelProto attribution fields into raw strings for `ONNXMetadataMapping`. Reads
	/// `producer_name` (2), `model_version` (5, a varint that defaults to 0), `doc_string` (6), and
	/// `metadata_props` (14): a repeated `StringStringEntryProto` whose key is field 1 and value is
	/// field 2. All values are untrusted and treated as display-only downstream.
	/// Internal (not private) so a deterministic test can exercise the field-number and
	/// StringStringEntryProto parsing against hand-built ModelProto bytes without a full fixture.
	func rawMetadata(from model: [(field: Int, value: ProtobufValue)]) -> ONNXRawMetadata {
		let props: [(key: String, value: String)] = model.allBytes(14).compactMap { entryData in
			guard let entry = try? ProtobufReader.fields(in: entryData),
				let key = entry.firstString(1) else { return nil }
			return (key, entry.firstString(2) ?? "")
		}
		return ONNXRawMetadata(
			props: props,
			docString: model.firstString(6),
			producerName: model.firstString(2),
			modelVersion: model.firstVarint(5)
		)
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
		// Names the reader itself synthesized (…__const, …__neg, …__t0, …). They share the model's
		// namespace and ONNX places no constraints on tensor names, so a crafted file can pre-claim
		// one — silently adopting that activation would change arithmetic. See `claimSynthesized`.
		private var synthesizedNames: Set<String> = []
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

		/// Reads an int64/int32 constant initializer as `[Int]` — the encoding ONNX uses for Reshape
		/// targets and Slice bounds. Returns nil when the name is not an integer initializer or its
		/// payload does not match its element width (raw_data is the only int encoding exporters in
		/// the supported set write; packed int64_data fields simply read as absent here).
		private func constantInts(_ name: String) -> [Int]? {
			guard let tensor = initializers[name] else { return nil }
			switch tensor.dataType {
			case 7: // int64
				guard !tensor.rawData.isEmpty, tensor.rawData.count % 8 == 0 else { return nil }
				return tensor.rawData.withUnsafeBytes { raw in
					(0 ..< tensor.rawData.count / 8).map {
						Int(truncatingIfNeeded: raw.loadUnaligned(fromByteOffset: $0 * 8, as: Int64.self))
					}
				}
			case 6: // int32
				guard !tensor.rawData.isEmpty, tensor.rawData.count % 4 == 0 else { return nil }
				return tensor.rawData.withUnsafeBytes { raw in
					(0 ..< tensor.rawData.count / 4).map {
						Int(raw.loadUnaligned(fromByteOffset: $0 * 4, as: Int32.self))
					}
				}
			default:
				return nil
			}
		}

		/// Reads the first float32 scalar from a constant initializer — used for Clip's opset-11 `min`/
		/// `max` tensor inputs. Returns nil when the name is not a float initializer or carries no data.
		private func constantFloat(_ name: String) -> Double? {
			guard let tensor = initializers[name], tensor.dataType == 1, tensor.rawData.count >= 4 else { return nil }
			return tensor.rawData.withUnsafeBytes { raw in
				Double(Float(bitPattern: raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self)))
			}
		}

		/// Reads a float32 constant initializer as `[Double]` — the encoding ONNX uses for Resize
		/// `scales`. Returns nil when the name is not a float initializer or its payload is not a whole
		/// number of float32 values.
		private func constantFloats(_ name: String) -> [Double]? {
			guard let tensor = initializers[name], tensor.dataType == 1,
				!tensor.rawData.isEmpty, tensor.rawData.count % 4 == 0 else { return nil }
			return tensor.rawData.withUnsafeBytes { raw in
				(0 ..< tensor.rawData.count / 4).map {
					Double(Float(bitPattern: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)))
				}
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
			case "Flatten": try lowerFlatten(node)
			case "Gemm": try lowerGemm(node)
			case "Softmax": try lowerSoftmax(node)
			default: try dispatchDetectionDecode(node, primaryInput: primaryInput)
			}
		}

		/// The detection-decode operator table, split out of `dispatch(_:primaryInput:)` for the same
		/// reason `dispatch` was split from `lower(_:)`: keeping either switch small enough that its
		/// cyclomatic complexity stays under the linter's limit as the operator set grows. These are the
		/// element-shuffling and elementwise ops the object-detection graphs add (Sigmoid, Transpose,
		/// Reshape, and the Sub/Div that lower to negate-then-add / reciprocal-then-multiply).
		private mutating func dispatchDetectionDecode(_ node: ONNXNode, primaryInput: String) throws {
			switch node.opType {
			case "Sigmoid": try lowerActivation(node, kind: .sigmoid, outputShape: shapes[primaryInput])
			case "Transpose": try lowerTranspose(node)
			case "Reshape": try lowerReshape(node)
			case "Slice": try lowerSlice(node)
			case "Sub": try lowerSub(node)
			case "Div": try lowerDiv(node)
			case "Resize": try lowerResize(node)
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

		/// ONNX `Sub`. Core ML's classic elementwise layers add and multiply but never subtract, so every
		/// form is rewritten into an add:
		/// - `activation − constant`: negate the constant at read time and add it (one broadcast constant).
		/// - `activation − activation` (same shape): multiply the subtrahend by a synthesized scalar −1 and
		///   add — `a − b = a + (b · −1)`.
		/// - `constant − activation` (YOLOv8's `anchors − lt`): negate the *activation* via the shared
		///   scalar −1 multiply, then add the constant — the operand order matters, so this is a distinct
		///   rewrite from the first form, never a fallthrough into it.
		private mutating func lowerSub(_ node: ONNXNode) throws {
			guard node.inputs.count == 2 else {
				throw ONNXModelReaderError.invalidModel("Sub '\(node.name)' requires 2 inputs")
			}
			try rejectLegacyBroadcast(node)
			let lhsShape = shapes[node.inputs[0]]
			let rhsShape = shapes[node.inputs[1]]

			// activation − constant: fold the subtraction into the constant by negating it.
			if let lhsShape, rhsShape == nil {
				let negated = try broadcastConstant(named: node.inputs[1], over: lhsShape, operation: node.name, transform: .negate)
				try record(node, kind: .add, activationInputs: [node.inputs[0], negated], weightInputs: [], attributes: [:], outputShape: lhsShape)
				return
			}

			// activation − activation: rewrite as `a + (b · −1)` via a synthesized −1 multiply.
			if let lhsShape, let rhsShape {
				guard lhsShape == rhsShape else {
					throw ONNXModelReaderError.unsupportedAttribute(
						operation: node.name,
						detail: "Sub requires same-shape activations (got \(lhsShape) and \(rhsShape))"
					)
				}
				let negated = try negate(node.inputs[1], shape: rhsShape)
				try record(node, kind: .add, activationInputs: [node.inputs[0], negated], weightInputs: [], attributes: [:], outputShape: lhsShape)
				return
			}

			// constant − activation (YOLOv8's `anchors − lt` box decode): negate the activation with the
			// shared scalar −1 multiply, then add the constant — `c − a = (a · −1) + c`.
			if lhsShape == nil, let rhsShape {
				let negated = try negate(node.inputs[1], shape: rhsShape)
				let constant = try broadcastConstant(named: node.inputs[0], over: rhsShape, operation: node.name)
				try record(node, kind: .add, activationInputs: [negated, constant], weightInputs: [], attributes: [:], outputShape: rhsShape)
				return
			}
			throw ONNXModelReaderError.shapeInferenceFailed(operation: node.name, detail: "unknown input shape")
		}

		/// ONNX `Div`. Only `activation ÷ constant-initializer` converts, lowered to a multiply by the
		/// element-wise reciprocal computed at read time — Core ML's classic layers have no divide. A zero
		/// element is rejected rather than turned into a silent multiply-by-infinity. Dividing two
		/// activations has no classic Core ML layer and is rejected.
		private mutating func lowerDiv(_ node: ONNXNode) throws {
			guard node.inputs.count == 2 else {
				throw ONNXModelReaderError.invalidModel("Div '\(node.name)' requires 2 inputs")
			}
			try rejectLegacyBroadcast(node)
			guard let outputShape = shapes[node.inputs[0]] else {
				// The dividend must be the activation; a constant ÷ activation has no divide layer either.
				throw ONNXModelReaderError.unsupportedAttribute(
					operation: node.name,
					detail: shapes[node.inputs[1]] != nil
						? "Div requires the dividend to be an activation, not a constant"
						: "unknown input shape"
				)
			}
			guard shapes[node.inputs[1]] == nil else {
				throw ONNXModelReaderError.unsupportedAttribute(
					operation: node.name,
					detail: "no classic Core ML layer divides two activations"
				)
			}
			let reciprocal = try broadcastConstant(named: node.inputs[1], over: outputShape, operation: node.name, transform: .reciprocal)
			try record(node, kind: .multiply, activationInputs: [node.inputs[0], reciprocal], weightInputs: [], attributes: [:], outputShape: outputShape)
		}

		/// Pre-opset-7 Add/Mul/Sub/Div use explicit `broadcast`/`axis` attributes with *left*-aligned
		/// semantics — the opposite of the numpy alignment the lowering assumes — so they are rejected
		/// rather than converted with flipped axes.
		private func rejectLegacyBroadcast(_ node: ONNXNode) throws {
			guard node.attributes["broadcast"]?.int ?? 0 == 0, node.attributes["axis"] == nil else {
				throw ONNXModelReaderError.unsupportedAttribute(
					operation: node.name,
					detail: "\(node.opType) with legacy broadcast/axis attributes"
				)
			}
		}

		/// Claims a converter-synthesized tensor name. Returns true when the name is fresh (create the
		/// tensor), false when this reader already synthesized it (reuse the cache) — and throws when a
		/// *model* tensor occupies the name, because reusing an arbitrary user activation in place of a
		/// synthesized constant/transpose would silently change the arithmetic.
		private mutating func claimSynthesized(_ name: String) throws -> Bool {
			if synthesizedNames.contains(name) { return false }
			// Check every namespace a model tensor can occupy, not just `shapes`: an initializer, a
			// pass-through alias target, and a folded shape tensor all carry NO `shapes` entry, so a
			// crafted file could squat a synthesized name through any of them and have the reader
			// reinterpret an initializer as an activation (or vice versa) further down.
			guard shapes[name] == nil, initializers[name] == nil,
				aliases[name] == nil, !shapeTensors.contains(name) else {
				throw ONNXModelReaderError.invalidModel("tensor name '\(name)' collides with a converter-synthesized name")
			}
			synthesizedNames.insert(name)
			return true
		}

		/// Materializes a shared `[1, 1, 1]` load-constant holding scalar −1 and multiplies `activation`
		/// by it, returning the product tensor's name. This expresses the `· −1` half of `a − b = a + (−b)`
		/// for activation operands, which have no read-time floats to negate. Both the constant and the
		/// per-activation product are cached so repeated Subs reuse them.
		private mutating func negate(_ activation: String, shape: [Int]) throws -> String {
			let negOne = try negativeOneConstant()
			let product = "\(activation)__neg"
			if try claimSynthesized(product) {
				shapes[product] = shape
				operations.append(NativeModelOperation(
					name: product, kind: .multiply, inputs: [activation, negOne],
					outputs: [NativeModelTensor(name: product, dataType: .float32, shape: shape)],
					attributes: [:]
				))
			}
			return product
		}

		/// The single `[1, 1, 1]` load-constant carrying scalar −1, created lazily and shared by every
		/// `negate(_:shape:)` call.
		private mutating func negativeOneConstant() throws -> String {
			let constantOutput = "__aiaNegativeOne"
			if try claimSynthesized(constantOutput) {
				let weightName = "\(constantOutput)Weight"
				let payload = withUnsafeBytes(of: Float(-1)) { Data($0) }
				weights.append(NativeModelWeight(
					name: weightName, dataType: .float32, shape: [1, 1, 1],
					offset: UInt64(weightBlob.count), byteCount: UInt64(payload.count)
				))
				weightBlob.append(payload)
				shapes[constantOutput] = [1, 1, 1]
				operations.append(NativeModelOperation(
					name: constantOutput, kind: .constant, inputs: [weightName],
					outputs: [NativeModelTensor(name: constantOutput, dataType: .float32, shape: [1, 1, 1])],
					attributes: [:]
				))
			}
			return constantOutput
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
			try rejectLegacyBroadcast(node)
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

		/// A read-time rewrite of a constant initializer's floats. `negate` folds a `Sub`'s subtrahend into
		/// an add; `reciprocal` folds a `Div`'s divisor into a multiply (and rejects a zero, which would
		/// become a silent multiply-by-infinity). Each carries a distinct name suffix so the same
		/// initializer used un-transformed elsewhere is cached under its own key, never clobbered.
		private enum ConstantTransform {
			case identity, negate, reciprocal

			var nameSuffix: String {
				switch self {
				case .identity: "__const"
				case .negate: "__negConst"
				case .reciprocal: "__recipConst"
				}
			}

			func apply(_ value: Float, name: String, operation: String) throws -> Float {
				switch self {
				case .identity: return value
				case .negate: return -value
				case .reciprocal:
					// A zero divisor is the obvious case, but a subnormal one overflows to +∞ too —
					// `0 / d` is 0 in ONNX while the lowered `0 · ∞` is NaN — so gate on the *result*.
					let reciprocal = 1 / value
					guard value != 0, reciprocal.isFinite else {
						throw ONNXModelReaderError.unsupportedAttribute(
							operation: operation,
							detail: "Div by constant '\(name)' whose reciprocal is not finite"
						)
					}
					return reciprocal
				}
			}
		}

		/// Registers `name` (which must be a float initializer) as a `constant` operation the classic
		/// elementwise layers can combine with a `[1, C, H, W]`/`[1, C, N]` activation, applying an
		/// optional read-time `transform` to its values. Three broadcast forms are handled, tried in
		/// order — scalar and per-channel (both emitted as the `[C, 1, 1]` load-constant layout), then a
		/// static spatial expansion for anything else that right-aligns against the activation.
		private mutating func broadcastConstant(named name: String, over activationShape: [Int], operation: String, transform: ConstantTransform = .identity) throws -> String {
			guard let tensor = initializers[name] else {
				throw ONNXModelReaderError.shapeInferenceFailed(operation: operation, detail: "operand '\(name)' is neither an activation nor an initializer")
			}
			guard tensor.dataType == 1 else {
				throw ONNXModelReaderError.unsupportedDataType(tensor: name, dataType: tensor.dataType)
			}
			// Fast paths, under ONNX's *right-aligned* broadcasting: any all-unit shape (a scalar), or a
			// per-channel vector whose channel extent sits three-from-last — `[C, 1, 1]` / `[1, C, 1, 1]`.
			// A rank-1 `[C]` is NOT a channel vector: right-alignment pairs it with the width axis, so
			// converting it channel-wise would be silently wrong — that falls through to the expansion path,
			// which either tiles it correctly or rejects it.
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
				return try expandSpatialConstant(named: name, tensor: tensor, over: activationShape, operation: operation, transform: transform)
			}
			// Overflow-reporting: `channels` traces back to file-declared dims, so a crafted value must
			// fail as an invalid model, not trap in the multiplication.
			let (expectedByteCount, byteCountOverflow) = channels.multipliedReportingOverflow(by: 4)
			guard !byteCountOverflow, tensor.rawData.count == expectedByteCount else {
				throw ONNXModelReaderError.invalidModel("initializer '\(name)' declares \(channels) channels but carries \(tensor.rawData.count) bytes")
			}

			let payload = try transformedFloatBytes(tensor.rawData, name: name, operation: operation, transform: transform)
			return try emitConstant(baseName: name, suffix: transform.nameSuffix, shape: [channels, 1, 1], payload: payload)
		}

		/// Statically expands a constant with spatial extent to the activation's full canonical
		/// `[C, H, W]` and emits it as one load-constant, so a same-shape elementwise op combines them —
		/// the fallback for constants (e.g. the YOLOv8 per-position stride table) that right-align against
		/// the activation but have no classic scalar or per-channel broadcast. The activation's leading
		/// batch axis is dropped; a rank-3 `[1, C, N]` activation canonicalizes to `[C, N, 1]`, matching
		/// `lowerReshape`/`lowerTranspose`. The expanded element count is bounded to guard crafted dims.
		private mutating func expandSpatialConstant(named name: String, tensor: ONNXTensor, over activationShape: [Int], operation: String, transform: ConstantTransform) throws -> String {
			guard activationShape.count == 3 || activationShape.count == 4 else {
				throw ONNXModelReaderError.unsupportedAttribute(
					operation: operation,
					detail: "constant operand '\(name)' of shape \(tensor.dims) needs a rank-3 or rank-4 activation to expand against, got \(activationShape)"
				)
			}
			// The target the constant must fill: the activation without its (unit) batch axis, row-major.
			let targetDims = Array(activationShape.dropFirst())
			// Right-align the constant's dims against the target; excess leading constant dims (a declared
			// batch, say) must be unit, and every aligned dim must match or be a unit that broadcasts.
			var aligned = Array(repeating: 1, count: max(0, targetDims.count - tensor.dims.count)) + tensor.dims
			if aligned.count > targetDims.count {
				let excess = aligned.count - targetDims.count
				guard aligned.prefix(excess).allSatisfy({ $0 == 1 }) else {
					throw ONNXModelReaderError.unsupportedAttribute(
						operation: operation,
						detail: "constant operand '\(name)' of shape \(tensor.dims) does not broadcast against activation \(activationShape)"
					)
				}
				aligned = Array(aligned.suffix(targetDims.count))
			}
			for (constantDim, targetDim) in zip(aligned, targetDims) {
				guard constantDim == targetDim || constantDim == 1 else {
					throw ONNXModelReaderError.unsupportedAttribute(
						operation: operation,
						detail: "constant operand '\(name)' of shape \(tensor.dims) does not broadcast against activation \(activationShape)"
					)
				}
			}
			// Bound the expansion before allocating: overflow-report the product, then cap it well under
			// what a legitimate detection table needs — a crafted huge shape must throw, not exhaust memory.
			var total = 1
			for dimension in targetDims {
				let (product, overflow) = total.multipliedReportingOverflow(by: dimension)
				guard !overflow else {
					throw ONNXModelReaderError.shapeInferenceFailed(operation: operation, detail: "expanded constant element count overflows")
				}
				total = product
			}
			guard total <= 8_000_000 else {
				throw ONNXModelReaderError.unsupportedAttribute(
					operation: operation,
					detail: "constant operand '\(name)' expands to \(total) elements, over the 8000000 limit"
				)
			}
			// The declared constant must carry exactly its own element count of floats.
			let sourceCount = aligned.reduce(1, *)
			guard tensor.rawData.count == sourceCount * 4 else {
				throw ONNXModelReaderError.invalidModel("initializer '\(name)' declares shape \(tensor.dims) but carries \(tensor.rawData.count) bytes")
			}
			let source = floats(from: tensor.rawData)
			// Row-major strides over `aligned`, with unit (broadcast) axes given stride 0 so they repeat.
			var strides = [Int](repeating: 0, count: targetDims.count)
			var running = 1
			for axis in stride(from: targetDims.count - 1, through: 0, by: -1) where aligned[axis] != 1 {
				strides[axis] = running
				running *= aligned[axis]
			}
			var expanded = Data(capacity: total * 4)
			var coordinate = [Int](repeating: 0, count: targetDims.count)
			for _ in 0 ..< total {
				var offset = 0
				for axis in 0 ..< targetDims.count { offset += coordinate[axis] * strides[axis] }
				let value = try transform.apply(source[offset], name: name, operation: operation)
				withUnsafeBytes(of: value) { expanded.append(contentsOf: $0) }
				var axis = targetDims.count - 1
				while axis >= 0 {
					coordinate[axis] += 1
					if coordinate[axis] < targetDims[axis] { break }
					coordinate[axis] = 0
					axis -= 1
				}
			}
			// The load-constant layer takes a rank-3 `[C, H, W]`; a rank-3 activation's `[C, N]` target
			// gains the trailing unit axis. The expanded buffer's row-major order already matches. The
			// cache suffix carries the target shape: the same broadcastable initializer expanded against
			// two different activations must yield two constants, not a shape-mismatched reuse.
			let constantShape = targetDims.count == 3 ? targetDims : targetDims + [1]
			let shapeKey = constantShape.map(String.init).joined(separator: "x")
			return try emitConstant(baseName: name, suffix: "__expanded\(shapeKey)\(transform.nameSuffix)", shape: constantShape, payload: expanded)
		}

		/// Interprets `data` as host-order float32 and rewrites each value through `transform`.
		private func transformedFloatBytes(_ data: Data, name: String, operation: String, transform: ConstantTransform) throws -> Data {
			if case .identity = transform { return data }
			var out = Data(capacity: data.count)
			for value in floats(from: data) {
				let mapped = try transform.apply(value, name: name, operation: operation)
				withUnsafeBytes(of: mapped) { out.append(contentsOf: $0) }
			}
			return out
		}

		/// Decodes host-order float32 bytes into a `[Float]`.
		private func floats(from data: Data) -> [Float] {
			data.withUnsafeBytes { raw in
				(0 ..< data.count / 4).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
			}
		}

		/// Appends `payload` as a weight and records a `constant` load-constant op of `shape`, returning
		/// its output name. Idempotent: the same base name + suffix (which encodes any transform) reuses
		/// the already-emitted constant, so one initializer can feed several nodes without duplication.
		private mutating func emitConstant(baseName: String, suffix: String, shape: [Int], payload: Data) throws -> String {
			let constantOutput = "\(baseName)\(suffix)"
			if try claimSynthesized(constantOutput) {
				let weightName = "\(constantOutput)Weight"
				weights.append(NativeModelWeight(
					name: weightName, dataType: .float32, shape: shape,
					offset: UInt64(weightBlob.count), byteCount: UInt64(payload.count)
				))
				weightBlob.append(payload)
				shapes[constantOutput] = shape
				operations.append(NativeModelOperation(
					name: constantOutput, kind: .constant, inputs: [weightName],
					outputs: [NativeModelTensor(name: constantOutput, dataType: .float32, shape: shape)],
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

		/// ONNX `Concat` lowers to the native concatenate op, which joins activations along the channel
		/// axis only. Every input must be a produced activation — a missing shape means an initializer
		/// or shape/constant tensor the native op does not model — and the non-concatenated dims must
		/// agree. Two forms convert:
		/// - channel concatenation (axis 1) at rank 3 or 4, directly;
		/// - the rank-3 axis-2 form (YOLOv8's stride merge `[1, C, Nᵢ] → [1, C, ΣN]`), which classic
		///   Core ML cannot concat directly — it is rewritten as transpose → channel concat → transpose,
		///   putting the merge axis on channels for the one layer that can join it.
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
			let rank = inputShapes[0].count
			guard rank == 3 || rank == 4, inputShapes.allSatisfy({ $0.count == rank }) else {
				throw ONNXModelReaderError.shapeInferenceFailed(operation: node.name, detail: "Concat expects same-rank rank-3/rank-4 inputs, got \(inputShapes)")
			}
			// ONNX Concat requires an explicit axis from opset 4 on (only the long-dead opset-1 form
			// defaulted it), so a missing one is unconvertible rather than assumed. A negative axis
			// counts back from the actual rank.
			guard let rawAxis = node.attributes["axis"]?.int else {
				throw ONNXModelReaderError.unsupportedAttribute(operation: node.name, detail: "Concat requires an axis attribute")
			}
			let axis = rawAxis < 0 ? rawAxis + rank : rawAxis
			// Non-concatenated dims must agree; the concatenated dim sums (overflow-reported: crafted
			// counts must throw, not trap — same rationale as the flatten feature-count product).
			let joined = try joinedConcatShape(inputShapes, axis: axis, rank: rank, operation: node.name)
			switch axis {
			case 1:
				try record(node, kind: .concatenate, activationInputs: node.inputs, weightInputs: [],
					attributes: ["axis": .integer(1)], outputShape: joined)
			case 2 where rank == 3:
				try lowerAxis2Concat(node, inputShapes: inputShapes, joined: joined)
			default:
				throw ONNXModelReaderError.unsupportedAttribute(operation: node.name, detail: "Concat axis \(rawAxis) — only channel concatenation (axis 1), or axis 2 at rank 3, is supported")
			}
		}

		/// Validates that `inputShapes` agree outside `axis` and returns the joined output shape.
		private func joinedConcatShape(_ inputShapes: [[Int]], axis: Int, rank: Int, operation: String) throws -> [Int] {
			guard axis >= 0, axis < rank else {
				throw ONNXModelReaderError.unsupportedAttribute(operation: operation, detail: "Concat axis \(axis) is out of range for rank \(rank)")
			}
			let reference = inputShapes[0]
			for shape in inputShapes.dropFirst() {
				for dimension in 0 ..< rank where dimension != axis && shape[dimension] != reference[dimension] {
					throw ONNXModelReaderError.shapeInferenceFailed(operation: operation, detail: "Concat inputs disagree outside axis \(axis): \(reference) vs \(shape)")
				}
			}
			var total = 0
			for shape in inputShapes {
				let (sum, overflow) = total.addingReportingOverflow(shape[axis])
				guard !overflow else {
					throw ONNXModelReaderError.shapeInferenceFailed(operation: operation, detail: "Concat joined extent overflows")
				}
				total = sum
			}
			var joined = reference
			joined[axis] = total
			return joined
		}

		/// The rank-3 axis-2 concat, rewritten so the channel-only classic concat can express it:
		/// each `[1, C, Nᵢ]` input is transposed to `[1, Nᵢ, C]` (perm `[0, 2, 1]`, canonicalized with
		/// the fixed trailing axis like every rank-3 permute), the transposed tensors are channel-
		/// concatenated to `[1, ΣN, C]`, and one transpose back restores `[1, C, ΣN]` as the node's
		/// declared output. The synthesized permutes force the legacy rank-5 mapping — acceptable,
		/// since any graph reaching this path already reshapes.
		private mutating func lowerAxis2Concat(_ node: ONNXNode, inputShapes: [[Int]], joined: [Int]) throws {
			var transposedNames: [String] = []
			for (index, input) in node.inputs.enumerated() {
				let name = "\(node.name)__t\(index)"
				let shape = inputShapes[index]
				let transposed = [shape[0], shape[2], shape[1]]
				if try claimSynthesized(name) {
					shapes[name] = transposed
					operations.append(NativeModelOperation(
						name: name, kind: .transpose, inputs: [input],
						outputs: [NativeModelTensor(name: name, dataType: .float32, shape: transposed)],
						attributes: ["permutation": .integers([0, 2, 1, 3])]
					))
				}
				transposedNames.append(name)
			}
			let concatenated = "\(node.name)__cat"
			guard try claimSynthesized(concatenated) else {
				// The same node is never lowered twice, so a cache hit here can only be a duplicate name.
				throw ONNXModelReaderError.invalidModel("duplicate Concat node name '\(node.name)'")
			}
			let concatenatedShape = [joined[0], joined[2], joined[1]]
			shapes[concatenated] = concatenatedShape
			operations.append(NativeModelOperation(
				name: concatenated, kind: .concatenate, inputs: transposedNames,
				outputs: [NativeModelTensor(name: concatenated, dataType: .float32, shape: concatenatedShape)],
				attributes: ["axis": .integer(1)]
			))
			try record(node, kind: .transpose, activationInputs: [concatenated], weightInputs: [],
				attributes: ["permutation": .integers([0, 2, 1, 3])], outputShape: joined)
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

		/// ONNX `Resize` in its opset-10+ tensor form (`X`, optional `roi`, optional `scales`, optional
		/// `sizes`). Lowered to `.upsample2D`, which the emitter emits as Core ML's classic
		/// nearest-neighbor upsample layer. Only the exact case that layer reproduces bit-for-bit is
		/// accepted — nearest mode, `asymmetric` coordinate transform, `floor` rounding, and integer
		/// scale factors — because Core ML computes `out[c, i, j] = in[c, i / f, j / f]` (a floor) and any
		/// other Resize configuration would resample the feature map differently than the source graph.
		private mutating func lowerResize(_ node: ONNXNode) throws {
			guard let inputShape = shapes[node.inputs[0]], inputShape.count == 4 else {
				throw ONNXModelReaderError.shapeInferenceFailed(operation: node.name, detail: "Resize expects a rank-4 NCHW input")
			}
			// `mode` defaults to "nearest" when absent in ONNX; only nearest maps to the upsample layer.
			let mode = node.attributes["mode"]?.string ?? "nearest"
			guard mode == "nearest" else {
				throw ONNXModelReaderError.unsupportedAttribute(operation: node.name, detail: "Resize mode '\(mode)' (only nearest is supported)")
			}
			// coordinate_transformation_mode's ONNX default is "half_pixel", which samples at shifted
			// coordinates Core ML's nearest upsample does NOT reproduce; require the explicit "asymmetric".
			let coordinateTransform = node.attributes["coordinate_transformation_mode"]?.string ?? "half_pixel"
			guard coordinateTransform == "asymmetric" else {
				throw ONNXModelReaderError.unsupportedAttribute(operation: node.name, detail: "Resize coordinate_transformation_mode '\(coordinateTransform)' (only asymmetric is supported)")
			}
			// nearest_mode's ONNX default is "round_prefer_floor", which differs from floor whenever a
			// sampled coordinate is fractional (e.g. a scale of 3 samples j/3 = 0.67 → 1 under rounding but
			// 0 under floor). Core ML upsamples with floor, so require the explicit "floor" rather than
			// assume the default matches.
			let nearestMode = node.attributes["nearest_mode"]?.string ?? "round_prefer_floor"
			guard nearestMode == "floor" else {
				throw ONNXModelReaderError.unsupportedAttribute(operation: node.name, detail: "Resize nearest_mode '\(nearestMode)' (only floor is supported)")
			}
			// asymmetric ignores roi, but a non-empty roi signals a crop-and-resize the upsample layer
			// cannot perform; reject it rather than silently drop it.
			if node.inputs.count > 1, !node.inputs[1].isEmpty {
				throw ONNXModelReaderError.unsupportedAttribute(operation: node.name, detail: "Resize with a region-of-interest input")
			}
			let (factorH, factorW) = try resizeFactors(node, inputShape: inputShape)
			// Overflow-report the scaled extents: both the factor and the input dims are file-supplied,
			// so a crafted pair must fail as an unsupported model, not trap in the multiplication.
			let (outH, overflowH) = inputShape[2].multipliedReportingOverflow(by: factorH)
			let (outW, overflowW) = inputShape[3].multipliedReportingOverflow(by: factorW)
			guard !overflowH, !overflowW else {
				throw ONNXModelReaderError.shapeInferenceFailed(operation: node.name, detail: "Resize output extent overflows")
			}
			try record(node, kind: .upsample2D, activationInputs: [node.inputs[0]], weightInputs: [], attributes: [
				"scalingFactor": .integers([factorH, factorW])
			], outputShape: [inputShape[0], inputShape[1], outH, outW])
		}

		/// Resolves the integer height/width upsampling factors from a Resize node's `scales` (input 2)
		/// or `sizes` (input 3); exactly one must be present. `scales` must be `[1, 1, fH, fW]` positive
		/// integers (no batch/channel resampling); `sizes` must divide the input's spatial dimensions
		/// exactly.
		private func resizeFactors(_ node: ONNXNode, inputShape: [Int]) throws -> (Int, Int) {
			let scales = node.inputs.count > 2 && !node.inputs[2].isEmpty ? node.inputs[2] : nil
			let sizes = node.inputs.count > 3 && !node.inputs[3].isEmpty ? node.inputs[3] : nil
			if let scales {
				guard sizes == nil else {
					throw ONNXModelReaderError.invalidModel("Resize '\(node.name)' sets both scales and sizes")
				}
				guard let values = constantFloats(scales), values.count == 4 else {
					throw ONNXModelReaderError.unsupportedAttribute(operation: node.name, detail: "Resize scales '\(scales)' is not a 4-element constant float initializer")
				}
				guard values[0] == 1, values[1] == 1 else {
					throw ONNXModelReaderError.unsupportedAttribute(operation: node.name, detail: "Resize must keep the batch and channel scales at 1, got \(values)")
				}
				return (try integerScale(values[2], node: node), try integerScale(values[3], node: node))
			}
			guard let sizes, let values = constantInts(sizes), values.count == 4 else {
				throw ONNXModelReaderError.unsupportedAttribute(operation: node.name, detail: "Resize needs a constant scales or sizes input")
			}
			guard values[0] == inputShape[0], values[1] == inputShape[1] else {
				throw ONNXModelReaderError.unsupportedAttribute(operation: node.name, detail: "Resize must keep the batch and channel sizes, got \(values)")
			}
			return (try divisorFactor(output: values[2], input: inputShape[2], node: node),
				try divisorFactor(output: values[3], input: inputShape[3], node: node))
		}

		/// A Resize `scales` value read as a float must be a positive whole number — Core ML's upsample
		/// only repeats samples an integer number of times.
		private func integerScale(_ value: Double, node: ONNXNode) throws -> Int {
			// The upper bound both rejects absurd factors and keeps `Int(value)` off the trap for
			// crafted values beyond Int.max (2^63 as a Double converts loudly, not silently).
			let scaleLimit = Double(1 << 20)
			guard value.isFinite, value >= 1, value <= scaleLimit, value == value.rounded(.towardZero) else {
				throw ONNXModelReaderError.unsupportedAttribute(operation: node.name, detail: "Resize scale \(value) is not a positive integer within the supported range")
			}
			return Int(value)
		}

		/// A Resize `sizes` output extent must be an exact integer multiple of the input extent.
		private func divisorFactor(output: Int, input: Int, node: ONNXNode) throws -> Int {
			guard input > 0, output >= input, output % input == 0 else {
				throw ONNXModelReaderError.unsupportedAttribute(operation: node.name, detail: "Resize output size \(output) is not an integer multiple of input size \(input)")
			}
			return output / input
		}

		/// ONNX `Reshape`. Three routes, in order:
		/// - a target folded from a `Shape → … → Concat` subgraph (the classifier's dynamic flatten)
		///   keeps today's flatten lowering — this is what MobileNetV2/ResNet50 ship with, and routing
		///   them to a general reshape would flip the whole network to Core ML's legacy rank-5 mapping,
		///   which the emitter (correctly) refuses for classifier interfaces;
		/// - a static target that collapses to `[batch, features]` (e.g. `[1, -1]`) is the same flatten
		///   in initializer form and takes the same fast-path;
		/// - any other static target becomes a general `.reshape`, resolved (`-1` inferred from the
		///   element count) and canonicalized to the rank-4 layout the emitter's classic reshape layer
		///   takes (a rank-3 target gains a trailing unit axis).
		private mutating func lowerReshape(_ node: ONNXNode) throws {
			guard let inputShape = shapes[node.inputs[0]], !inputShape.isEmpty else {
				throw ONNXModelReaderError.shapeInferenceFailed(operation: node.name, detail: "unknown input shape")
			}
			// The target: the second input (opset ≥ 5), or the legacy `shape` attribute (opset < 5).
			let staticTarget: [Int]?
			if node.inputs.count >= 2 {
				if shapeTensors.contains(node.inputs[1]) {
					// Folded dynamic-flatten subgraph — exactly the case lowerFlatten always handled.
					return try lowerFlatten(node)
				}
				guard let target = constantInts(node.inputs[1]) else {
					throw ONNXModelReaderError.unsupportedAttribute(
						operation: node.name,
						detail: "Reshape target '\(node.inputs[1])' is not a constant integer initializer"
					)
				}
				staticTarget = target
			} else {
				staticTarget = node.attributes["shape"]?.ints
			}
			guard let staticTarget else {
				// No target at all — never valid ONNX; preserve the historical flatten behavior rather
				// than start rejecting files that previously converted.
				return try lowerFlatten(node)
			}
			let resolved = try resolveReshapeTarget(staticTarget, inputShape: inputShape, operation: node.name)
			// Flatten fast-path: a [batch, features] collapse stays a flatten so classifier graphs never
			// acquire a .reshape op (which would force the legacy rank-5 mapping network-wide).
			if resolved.count == 2, resolved[0] == inputShape[0] {
				return try lowerFlatten(node)
			}
			guard resolved.count == 3 || resolved.count == 4 else {
				// Rank 2 reaches here only when it did NOT collapse to [batch, features] above, so
				// naming ranks 2–4 as supported would misdescribe exactly the case being rejected.
				throw ONNXModelReaderError.unsupportedAttribute(
					operation: node.name,
					detail: "Reshape target \(resolved) has rank \(resolved.count); a general reshape supports rank 3 or 4, and rank 2 only when it collapses to [batch, features]"
				)
			}
			let canonical = resolved.count == 4 ? resolved : resolved + [1]
			try record(node, kind: .reshape, activationInputs: [node.inputs[0]], weightInputs: [],
				attributes: ["shape": .integers(canonical)], outputShape: resolved)
		}

		/// Resolves an ONNX Reshape target against the input's element count: at most one `-1` is
		/// inferred from the remainder; `0` (copy-the-input-dim) is rejected rather than guessed; the
		/// resolved product must equal the input's element count exactly.
		private func resolveReshapeTarget(_ target: [Int], inputShape: [Int], operation: String) throws -> [Int] {
			var elementCount = 1
			for dimension in inputShape {
				let (product, overflow) = elementCount.multipliedReportingOverflow(by: dimension)
				guard !overflow else {
					throw ONNXModelReaderError.shapeInferenceFailed(operation: operation, detail: "input element count overflows")
				}
				elementCount = product
			}
			guard target.filter({ $0 == -1 }).count <= 1 else {
				throw ONNXModelReaderError.unsupportedAttribute(operation: operation, detail: "Reshape target \(target) has more than one -1")
			}
			guard !target.contains(0) else {
				throw ONNXModelReaderError.unsupportedAttribute(operation: operation, detail: "Reshape target \(target) uses 0 (copy-dimension), which is not supported")
			}
			guard target.allSatisfy({ $0 > 0 || $0 == -1 }) else {
				throw ONNXModelReaderError.unsupportedAttribute(operation: operation, detail: "Reshape target \(target) has a negative dimension other than -1")
			}
			var knownProduct = 1
			for dimension in target where dimension > 0 {
				let (product, overflow) = knownProduct.multipliedReportingOverflow(by: dimension)
				guard !overflow else {
					throw ONNXModelReaderError.shapeInferenceFailed(operation: operation, detail: "Reshape target element count overflows")
				}
				knownProduct = product
			}
			var resolved = target
			if let inferredIndex = target.firstIndex(of: -1) {
				guard knownProduct > 0, elementCount % knownProduct == 0 else {
					throw ONNXModelReaderError.shapeInferenceFailed(
						operation: operation,
						detail: "cannot infer -1: \(elementCount) elements do not divide by \(knownProduct)"
					)
				}
				resolved[inferredIndex] = elementCount / knownProduct
			} else {
				guard knownProduct == elementCount else {
					throw ONNXModelReaderError.shapeInferenceFailed(
						operation: operation,
						detail: "Reshape target \(target) has \(knownProduct) elements; input has \(elementCount)"
					)
				}
			}
			return resolved
		}

		/// ONNX `Transpose` lowers to the native permute op. Core ML's permute layer always addresses the
		/// four `(sequence, channel, height, width)` axes whatever the declared rank, so a rank-3 input is
		/// canonicalized to rank 4 by appending a trailing unit axis — the same canonicalization
		/// `lowerReshape` applies to a rank-3 target — and its perm gains the fixed last axis that maps
		/// that unit dimension to itself. `perm` is required: ONNX defaults to reversing every axis when
		/// it is absent, which the four-axis permute cannot express, so a missing `perm` is rejected
		/// rather than silently applied.
		private mutating func lowerTranspose(_ node: ONNXNode) throws {
			guard let inputShape = shapes[node.inputs[0]], inputShape.count == 3 || inputShape.count == 4 else {
				throw ONNXModelReaderError.shapeInferenceFailed(operation: node.name, detail: "Transpose expects a rank-3 or rank-4 input")
			}
			guard let perm = node.attributes["perm"]?.ints else {
				throw ONNXModelReaderError.unsupportedAttribute(
					operation: node.name,
					detail: "Transpose requires an explicit perm; the reverse-all-axes default is not supported"
				)
			}
			let rank = inputShape.count
			guard perm.count == rank, Set(perm) == Set(0 ..< rank) else {
				throw ONNXModelReaderError.unsupportedAttribute(operation: node.name, detail: "Transpose perm \(perm) is not a permutation of 0..<\(rank)")
			}
			// The IR/output shape is the ONNX result (perm applied to the real input), but the recorded
			// permutation is over the canonical four axes: a rank-3 perm gains the trailing axis 3.
			let outputShape = perm.map { inputShape[$0] }
			let canonicalPerm = rank == 4 ? perm : perm + [3]
			try record(node, kind: .transpose, activationInputs: [node.inputs[0]], weightInputs: [],
				attributes: ["permutation": .integers(canonicalPerm)], outputShape: outputShape)
		}

		/// ONNX `Slice` — supported only as a single-axis slice over the channel axis, which is the sole
		/// form the object-detection graphs use: the DFL tail splits a packed `[1, C, N]` tensor into its
		/// box- and class-channel ranges. Both encodings feed one validation path — the opset-≥10 tensor
		/// inputs (`starts`/`ends`/`axes`/`steps` as constant integer initializers) and the pre-opset-10
		/// attribute form. Anything that steps, spans multiple axes, or touches a non-channel axis is
		/// rejected rather than misconverted, because the native IR's `.sliceChannels` addresses only axis 1.
		private mutating func lowerSlice(_ node: ONNXNode) throws {
			guard let inputShape = shapes[node.inputs[0]], inputShape.count == 3 || inputShape.count == 4 else {
				throw ONNXModelReaderError.shapeInferenceFailed(operation: node.name, detail: "Slice expects a rank-3 or rank-4 input")
			}
			// starts/ends are required; a missing or non-constant one is unrepresentable, so reject it.
			guard let starts = sliceInts(node, inputIndex: 1, attribute: "starts") else {
				throw ONNXModelReaderError.unsupportedAttribute(operation: node.name, detail: "Slice 'starts' must be a constant integer initializer or attribute")
			}
			guard let ends = sliceInts(node, inputIndex: 2, attribute: "ends") else {
				throw ONNXModelReaderError.unsupportedAttribute(operation: node.name, detail: "Slice 'ends' must be a constant integer initializer or attribute")
			}
			// axes absent defaults to [0, 1, …] over starts.count (ONNX rule); steps absent defaults to [1].
			let axes = sliceInts(node, inputIndex: 3, attribute: "axes") ?? Array(0 ..< starts.count)
			if let steps = sliceInts(node, inputIndex: 4, attribute: "steps"), steps != [1] {
				throw ONNXModelReaderError.unsupportedAttribute(operation: node.name, detail: "Slice step \(steps) is unsupported; only a unit step (1) lowers to a channel slice")
			}
			guard starts.count == 1, ends.count == 1, axes.count == 1 else {
				throw ONNXModelReaderError.unsupportedAttribute(operation: node.name, detail: "Slice supports only a single-axis channel slice; got starts \(starts), ends \(ends), axes \(axes)")
			}
			// Negative axes count back from the rank; the only axis the channel slice can express is 1.
			let rank = inputShape.count
			let axis = axes[0] < 0 ? axes[0] + rank : axes[0]
			guard axis == 1 else {
				throw ONNXModelReaderError.unsupportedAttribute(operation: node.name, detail: "Slice axis \(axes[0]) is not the channel axis (1); only channel slices are supported")
			}
			// ONNX bounds: negative indices add the dim; anything past the dim (INT64_MAX sentinels truncate
			// through `constantInts` to Int.max) clamps to it. `min(max(…))` folds both directions.
			let channelCount = inputShape[1]
			let start = min(max(starts[0] < 0 ? starts[0] + channelCount : starts[0], 0), channelCount)
			let end = min(max(ends[0] < 0 ? ends[0] + channelCount : ends[0], 0), channelCount)
			guard end > start else {
				throw ONNXModelReaderError.unsupportedAttribute(operation: node.name, detail: "Slice channel range [\(starts[0]), \(ends[0])) is empty after normalization against \(channelCount) channels")
			}
			var outputShape = inputShape
			outputShape[1] = end - start
			try record(node, kind: .sliceChannels, activationInputs: [node.inputs[0]], weightInputs: [],
				attributes: ["startChannel": .integer(start), "endChannel": .integer(end)], outputShape: outputShape)
		}

		/// Resolves one of Slice's integer bound lists from whichever encoding the exporter used: the
		/// opset-≥10 tensor input at `inputIndex` (a constant int64/int32 initializer) when present and
		/// non-empty — an omitted optional input is the empty string — otherwise the pre-opset-10 `attribute`.
		private func sliceInts(_ node: ONNXNode, inputIndex: Int, attribute: String) -> [Int]? {
			if node.inputs.count > inputIndex, !node.inputs[inputIndex].isEmpty {
				return constantInts(node.inputs[inputIndex])
			}
			return node.attributes[attribute]?.ints
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
