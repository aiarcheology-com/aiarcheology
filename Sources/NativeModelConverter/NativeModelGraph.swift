//
//  NativeModelGraph.swift
//  NativeModelConverter
//
//  The portable, versioned input to the native model converter.
//

import Foundation

/// A fixed-shape inference graph produced by an external exporter.
///
/// This is deliberately *not* an ONNX mirror. The format is small, explicit, and stable enough
/// that the iOS converter can give a precise answer about an unsupported model before reading a
/// large weights file. See `NATIVE_MODEL_CONVERSION.md` for the package layout and Python-side
/// exporter contract.
public struct NativeModelGraph: Codable, Equatable, Sendable {
	/// The original graph contract. It uses the classic Core ML rank-5 shape layers for the
	/// detection decode and must remain readable/emittable for existing `.aiagraph` packages.
	public static let legacyFormatVersion = 1
	/// Exact-rank Core ML operations added for attention-style ONNX graphs (AIA-0469 PR 3).
	public static let exactNDFormatVersion = 2
	/// Kept as the conservative default for callers constructing a legacy graph directly. ONNX
	/// lowering selects V2 explicitly only after its preflight chooses the exact-ND backend.
	public static let currentFormatVersion = 1
	public static let supportedFormatVersions: Set<Int> = [legacyFormatVersion, exactNDFormatVersion]

	public static func isSupportedFormatVersion(_ version: Int) -> Bool {
		supportedFormatVersions.contains(version)
	}

	public let formatVersion: Int
	public let producer: NativeModelGraphProducer
	public let inputs: [NativeModelTensor]
	public let weights: [NativeModelWeight]
	public let operations: [NativeModelOperation]
	public let outputs: [String]

	public init(
		formatVersion: Int,
		producer: NativeModelGraphProducer,
		inputs: [NativeModelTensor],
		weights: [NativeModelWeight],
		operations: [NativeModelOperation],
		outputs: [String]
	) {
		self.formatVersion = formatVersion
		self.producer = producer
		self.inputs = inputs
		self.weights = weights
		self.operations = operations
		self.outputs = outputs
	}
}

/// Identifies the exporter that produced a graph, making compatibility failures actionable.
public struct NativeModelGraphProducer: Codable, Equatable, Sendable {
	public let name: String
	public let version: String

	public init(name: String, version: String) {
		self.name = name
		self.version = version
	}
}

/// The element type supported by the first native-converter milestone.
public enum NativeModelDataType: Equatable, Sendable {
	case float16
	case float32
	case unsupported(String)

	public var serializedValue: String {
		switch self {
		case .float16: "float16"
		case .float32: "float32"
		case .unsupported(let value): value
		}
	}

	public var byteWidth: UInt64? {
		switch self {
		case .float16: 2
		case .float32: 4
		case .unsupported: nil
		}
	}
}

extension NativeModelDataType: Codable {
	public init(from decoder: Decoder) throws {
		let container = try decoder.singleValueContainer()
		switch try container.decode(String.self) {
		case "float16": self = .float16
		case "float32": self = .float32
		case let value: self = .unsupported(value)
		}
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.singleValueContainer()
		try container.encode(serializedValue)
	}
}

/// A named fixed-shape tensor. Tensor names can contain dots so a Python exporter can retain
/// familiar module names such as `features.0.weight`.
public struct NativeModelTensor: Codable, Equatable, Sendable {
	public let name: String
	public let dataType: NativeModelDataType
	public let shape: [Int]

	public init(name: String, dataType: NativeModelDataType, shape: [Int]) {
		self.name = name
		self.dataType = dataType
		self.shape = shape
	}

	public func byteCount() -> UInt64? {
		guard let byteWidth = dataType.byteWidth else { return nil }
		var elementCount: UInt64 = 1
		for dimension in shape {
			guard dimension > 0 else { return nil }
			let (result, overflow) = elementCount.multipliedReportingOverflow(by: UInt64(dimension))
			guard !overflow else { return nil }
			elementCount = result
		}

		let (byteCount, overflow) = elementCount.multipliedReportingOverflow(by: byteWidth)
		return overflow ? nil : byteCount
	}
}

/// A tensor stored in the package's single `weights.bin` file.
///
/// Keeping weights outside JSON avoids base64 expansion and lets a future emitter stream a model
/// without materializing every parameter in memory.
public struct NativeModelWeight: Codable, Equatable, Sendable {
	public let name: String
	public let dataType: NativeModelDataType
	public let shape: [Int]
	public let offset: UInt64
	public let byteCount: UInt64

	public init(name: String, dataType: NativeModelDataType, shape: [Int], offset: UInt64, byteCount: UInt64) {
		self.name = name
		self.dataType = dataType
		self.shape = shape
		self.offset = offset
		self.byteCount = byteCount
	}

	public var tensor: NativeModelTensor {
		NativeModelTensor(name: name, dataType: dataType, shape: shape)
	}
}

/// Operations intentionally supported by the first native conversion milestone.
///
/// The list is selected to cover MobileNetV2 style classifiers and the backbone portions of
/// common compact detectors. Detection post-processing (decode/NMS) remains an explicit later
/// milestone because the app's Vision driver needs a well-defined observation interface.
public enum NativeModelOperationKind: Equatable, Sendable {
	case convolution2D
	case linear
	case relu
	case relu6
	case maxPool2D
	case averagePool2D
	case upsample2D
	case globalAveragePool2D
	case reshape
	case transpose
	case concatenate
	case reshapeND
	case transposeND
	case concatenateND
	case sliceND
	case splitND
	case batchedMatrixMultiplicationND
	case constantND
	case softmax
	case matrixMultiplication
	case add
	case subtract
	case multiply
	case divide
	/// Elementwise bounds taken against a *second tensor* rather than a scalar attribute. A box clip
	/// needs a different bound per coordinate (x to `[0, W]`, y to `[0, H]`), which is exactly what a
	/// single scalar cannot express; the second operand is already expressible as a `constantND`, so a
	/// tensor-valued attribute would duplicate the weight-blob mechanism inside the graph JSON.
	case minimumND
	case maximumND
	case floor
	case naturalLogarithm
	/// `x >= threshold` as a 1.0/0.0 mask. The threshold is a scalar attribute because Core ML's
	/// comparison layer carries one itself; a per-element threshold is a `minimumND`-style two-tensor
	/// problem and would be a separate operation.
	case greaterOrEqual
	/// Bilinear ROI extraction: one fixed-size patch resampled from a feature map per box. The first
	/// operation with two *heterogeneous* runtime inputs — input 0 is the rank-5 feature map
	/// `[1, B, C, H, W]` and input 1 the box blob `[K, 1, 4, 1, 1]`, giving `[K, B, C, targetHeight,
	/// targetWidth]`. Swapping them is not a shape error Core ML catches; it is a different model.
	///
	/// Deliberately *only* the crop. torchvision's `roi_align(sampling_ratio=2)` averages 2x2 bilinear
	/// samples per output bin, which is reproduced by cropping at twice the target size and following
	/// with a separate `averagePool2D` — a graph-level composition, so neither operation is welded to
	/// one sampling ratio. Sampling mode and box-coordinate order are pinned at emission
	/// (ROI_ALIGN_MODE, CORNERS_HEIGHT_FIRST) rather than carried as attributes that could only ever
	/// hold one legal value.
	case cropResize
	/// The `k` largest values along `axis`, and the source index of each. The second operation in this
	/// IR with more than one output, and the first whose outputs mean different things: output 0 carries
	/// the values and output 1 the indices, each with the input's rank and `axis` reduced to `k`. Wiring
	/// only the values does not compile — Core ML requires exactly two outputs — but swapping the two
	/// does, and then everything downstream reads ranks where it expects scores.
	///
	/// `k` is an attribute rather than the second runtime input the layer also accepts: a data-dependent
	/// K makes every downstream extent dynamic, which a fixed-shape graph has no way to declare.
	case topK
	/// Slices of the first input selected by index from the second — what turns `topK`'s indices back
	/// into the rows they came from. Two runtime inputs that are not interchangeable, and the only
	/// operation whose output rank is not simply the data input's: it is `data.rank - 1 + indices.rank`,
	/// because the indices tensor's own shape takes the place of the gathered axis. So rank-2 indices
	/// over rank-2 data produce a rank-3 result. Indices travel in an ordinary float blob — the
	/// neural-network spec has no integer one — and are truncated by the layer.
	case gather
	/// Greedy non-maximum suppression *inside* the graph — Core ML's NMS **layer**, which is not the
	/// standalone NMS **model** `NativeModelDetectorPipeline` already emits as its terminal stage.
	/// Conflating the two was a measured near-miss in the M3a spike: the model has flexible outputs and a
	/// Vision-facing interface and can only be last, while this one has fixed padded outputs and sits
	/// mid-graph, where its survivors are an input to everything after it.
	///
	/// Two runtime inputs, boxes `[1, N, 4]` then scores `[1, N, classes]`, and both must be rank 3
	/// exactly — the kernel says so ("first two inputs must have rank 3") rather than merely preferring it.
	///
	/// The box coordinates are mandatorily `[center-x, center-y, width, height]`. Unlike `cropResize`,
	/// which carries a `BoxCoordinatesMode`, this layer has no coordinate-mode parameter at all, so
	/// corners fed here are not an error but a different model — and every other box operation in this IR
	/// works in corners.
	///
	/// Four outputs, each padded out to `maxBoxes`: kept boxes, kept scores, kept source indices, and the
	/// count of leading slots that mean anything. That count is not trustworthy at zero survivors — see
	/// the emitter — which is why a graph must mask on the scores rather than read slot 0.
	case nonMaximumSuppression
	case batchNormalization
	case sigmoid
	case tanh
	case leakyReLU
	case exponential
	case sliceChannels
	case softmaxChannel
	case constant
	case flatten
	case identity
	case unsupported(String)

	public var serializedValue: String {
		switch self {
		case .convolution2D: "conv2d"
		case .linear: "linear"
		case .relu: "relu"
		case .relu6: "relu6"
		case .maxPool2D: "maxPool2d"
		case .averagePool2D: "averagePool2d"
		case .upsample2D: "upsample2d"
		case .globalAveragePool2D: "globalAveragePool2d"
		case .reshape: "reshape"
		case .transpose: "transpose"
		case .concatenate: "concat"
		case .reshapeND: "reshapeND"
		case .transposeND: "transposeND"
		case .concatenateND: "concatND"
		case .sliceND: "sliceND"
		case .splitND: "splitND"
		case .batchedMatrixMultiplicationND: "batchedMatmulND"
		case .constantND: "constantND"
		case .softmax: "softmax"
		case .matrixMultiplication: "matmul"
		case .add: "add"
		case .subtract: "subtract"
		case .multiply: "multiply"
		case .divide: "divide"
		case .minimumND: "minND"
		case .maximumND: "maxND"
		case .floor: "floor"
		case .naturalLogarithm: "log"
		case .greaterOrEqual: "greaterEqual"
		case .cropResize: "cropResize"
		case .topK: "topK"
		case .gather: "gather"
		case .nonMaximumSuppression: "nms"
		case .batchNormalization: "batchNorm"
		case .sigmoid: "sigmoid"
		case .tanh: "tanh"
		case .leakyReLU: "leakyRelu"
		case .exponential: "exp"
		case .sliceChannels: "sliceChannels"
		case .softmaxChannel: "softmaxChannel"
		case .constant: "constant"
		case .flatten: "flatten"
		case .identity: "identity"
		case .unsupported(let value): value
		}
	}

	public var isSupported: Bool {
		if case .unsupported = self {
			return false
		}
		return true
	}

	private static let kindsBySerializedValue: [String: NativeModelOperationKind] = [
		"conv2d": .convolution2D,
		"linear": .linear,
		"relu": .relu,
		"relu6": .relu6,
		"maxPool2d": .maxPool2D,
		"averagePool2d": .averagePool2D,
		"upsample2d": .upsample2D,
		"globalAveragePool2d": .globalAveragePool2D,
		"reshape": .reshape,
		"transpose": .transpose,
		"concat": .concatenate,
		"reshapeND": .reshapeND,
		"transposeND": .transposeND,
		"concatND": .concatenateND,
		"sliceND": .sliceND,
		"splitND": .splitND,
		"batchedMatmulND": .batchedMatrixMultiplicationND,
		"constantND": .constantND,
		"softmax": .softmax,
		"matmul": .matrixMultiplication,
		"add": .add,
		"subtract": .subtract,
		"multiply": .multiply,
		"divide": .divide,
		"minND": .minimumND,
		"maxND": .maximumND,
		"floor": .floor,
		"log": .naturalLogarithm,
		"greaterEqual": .greaterOrEqual,
		"cropResize": .cropResize,
		"topK": .topK,
		"gather": .gather,
		"nms": .nonMaximumSuppression,
		"batchNorm": .batchNormalization,
		"sigmoid": .sigmoid,
		"tanh": .tanh,
		"leakyRelu": .leakyReLU,
		"exp": .exponential,
		"sliceChannels": .sliceChannels,
		"softmaxChannel": .softmaxChannel,
		"constant": .constant,
		"flatten": .flatten,
		"identity": .identity
	]
}

extension NativeModelOperationKind: Codable {
	public init(from decoder: Decoder) throws {
		let container = try decoder.singleValueContainer()
		let value = try container.decode(String.self)
		self = Self.kindsBySerializedValue[value] ?? .unsupported(value)
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.singleValueContainer()
		try container.encode(serializedValue)
	}
}

/// JSON attribute values used by the fixed-shape graph format.
///
/// Attribute values are deliberately limited to scalar and vector literals. Shape and weight
/// values must not be generated at runtime in version 1.
public enum NativeModelAttribute: Codable, Equatable, Sendable {
	case boolean(Bool)
	case integer(Int)
	case floatingPoint(Double)
	case string(String)
	case integers([Int])
	case floatingPoints([Double])
	case strings([String])

	public var booleanValue: Bool? {
		guard case .boolean(let value) = self else { return nil }
		return value
	}

	public var integerValue: Int? {
		guard case .integer(let value) = self else { return nil }
		return value
	}

	public var floatingPointValue: Double? {
		switch self {
		case .floatingPoint(let value): value
		case .integer(let value): Double(value)
		default: nil
		}
	}

	public var integerArrayValue: [Int]? {
		guard case .integers(let value) = self else { return nil }
		return value
	}
}

extension NativeModelAttribute {
	public init(from decoder: Decoder) throws {
		let container = try decoder.singleValueContainer()

		if let value = try? container.decode(Bool.self) {
			self = .boolean(value)
		} else if let value = try? container.decode(Int.self) {
			self = .integer(value)
		} else if let value = try? container.decode(Double.self) {
			self = .floatingPoint(value)
		} else if let value = try? container.decode(String.self) {
			self = .string(value)
		} else if let value = try? container.decode([Int].self) {
			self = .integers(value)
		} else if let value = try? container.decode([Double].self) {
			self = .floatingPoints(value)
		} else if let value = try? container.decode([String].self) {
			self = .strings(value)
		} else {
			throw DecodingError.dataCorruptedError(
				in: container,
				debugDescription: "Native model graph attributes must be scalar or vector literals."
			)
		}
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.singleValueContainer()
		switch self {
		case .boolean(let value): try container.encode(value)
		case .integer(let value): try container.encode(value)
		case .floatingPoint(let value): try container.encode(value)
		case .string(let value): try container.encode(value)
		case .integers(let value): try container.encode(value)
		case .floatingPoints(let value): try container.encode(value)
		case .strings(let value): try container.encode(value)
		}
	}
}

public struct NativeModelOperation: Codable, Equatable, Sendable {
	public let name: String
	public let kind: NativeModelOperationKind
	public let inputs: [String]
	public let outputs: [NativeModelTensor]
	public let attributes: [String: NativeModelAttribute]

	public init(
		name: String,
		kind: NativeModelOperationKind,
		inputs: [String],
		outputs: [NativeModelTensor],
		attributes: [String: NativeModelAttribute]
	) {
		self.name = name
		self.kind = kind
		self.inputs = inputs
		self.outputs = outputs
		self.attributes = attributes
	}
}

/// Reads the graph JSON. Package integrity and the Core ML emitter intentionally live in separate
/// services so an untrusted import can be rejected before the app touches a weights payload.
public actor NativeModelGraphReader {
	public init() {}

	public func read(from url: URL) throws -> NativeModelGraph {
		let decoder = JSONDecoder()
		return try decoder.decode(NativeModelGraph.self, from: Data(contentsOf: url))
	}
}

/// A deterministic explanation of whether a graph is suitable for native conversion.
public struct NativeModelGraphValidationResult: Equatable, Sendable {
	public let issues: [NativeModelGraphValidationIssue]

	public var isConvertible: Bool {
		issues.isEmpty
	}
}

public enum NativeModelGraphValidationIssue: Equatable, Sendable, LocalizedError {
	case unsupportedFormatVersion(Int)
	case missingProducerField(String)
	case invalidTensorName(String)
	case duplicateTensor(String)
	case unsupportedDataType(tensor: String, dataType: String)
	case invalidTensorShape(tensor: String)
	case invalidWeightByteCount(name: String, expected: UInt64, actual: UInt64)
	case overflowingWeightRange(name: String)
	case overlappingWeights(first: String, second: String)
	case invalidOperationName(String)
	case duplicateOperation(String)
	case unsupportedOperation(operation: String, kind: String)
	case missingInput(operation: String, tensor: String)
	case duplicateOutput(operation: String, tensor: String)
	case invalidArity(operation: String, expected: String, actual: Int)
	case invalidAttribute(operation: String, attribute: String, expected: String)
	case invalidOutput(String)

	public var errorDescription: String? {
		switch self {
		case .unsupportedFormatVersion(let version):
			"Unsupported native model graph format version \(version)."
		case .missingProducerField(let field):
			"The graph producer is missing its \(field) field."
		case .invalidTensorName(let name):
			"Tensor name '\(name)' is invalid."
		case .duplicateTensor(let name):
			"Tensor '\(name)' is declared more than once."
		case .unsupportedDataType(let tensor, let dataType):
			"Tensor '\(tensor)' uses unsupported data type '\(dataType)'."
		case .invalidTensorShape(let tensor):
			"Tensor '\(tensor)' must have a fixed, positive shape."
		case .invalidWeightByteCount(let name, let expected, let actual):
			"Weight '\(name)' declares \(actual) bytes; \(expected) bytes are required by its type and shape."
		case .overflowingWeightRange(let name):
			"Weight '\(name)' has an offset and byte count that overflow when added."
		case .overlappingWeights(let first, let second):
			"Weights '\(first)' and '\(second)' overlap in weights.bin."
		case .invalidOperationName(let name):
			"Operation name '\(name)' is invalid."
		case .duplicateOperation(let name):
			"Operation '\(name)' is declared more than once."
		case .unsupportedOperation(let operation, let kind):
			"Operation '\(operation)' uses unsupported kind '\(kind)'."
		case .missingInput(let operation, let tensor):
			"Operation '\(operation)' reads unknown or future tensor '\(tensor)'."
		case .duplicateOutput(let operation, let tensor):
			"Operation '\(operation)' produces duplicate tensor '\(tensor)'."
		case .invalidArity(let operation, let expected, let actual):
			"Operation '\(operation)' expects \(expected) input tensors, got \(actual)."
		case .invalidAttribute(let operation, let attribute, let expected):
			"Operation '\(operation)' requires attribute '\(attribute)' to be \(expected)."
		case .invalidOutput(let tensor):
			"Graph output '\(tensor)' is not produced by the graph."
		}
	}
}

/// Validates the graph contract before a future Core ML protobuf emitter sees it.
///
/// It intentionally enforces a topologically ordered graph. This removes the need for an
/// on-device graph scheduler in the first release and makes error diagnostics deterministic.
public struct NativeModelGraphValidator {
	public init() {}

	public func validate(_ graph: NativeModelGraph) -> NativeModelGraphValidationResult {
		var issues: [NativeModelGraphValidationIssue] = []
		var knownTensors: [String: NativeModelTensor] = [:]

		if !NativeModelGraph.isSupportedFormatVersion(graph.formatVersion) {
			issues.append(.unsupportedFormatVersion(graph.formatVersion))
		}
		if graph.producer.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			issues.append(.missingProducerField("name"))
		}
		if graph.producer.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			issues.append(.missingProducerField("version"))
		}

		for tensor in graph.inputs {
			validate(tensor: tensor, knownTensors: &knownTensors, issues: &issues)
		}
		for weight in graph.weights {
			validate(weight: weight, knownTensors: &knownTensors, issues: &issues)
		}
		validateWeightRanges(graph.weights, issues: &issues)

		var operationNames = Set<String>()
		for operation in graph.operations {
			validate(
				operation: operation,
				formatVersion: graph.formatVersion,
				knownTensors: &knownTensors,
				operationNames: &operationNames,
				issues: &issues
			)
		}

		for output in graph.outputs where knownTensors[output] == nil {
			issues.append(.invalidOutput(output))
		}

		return NativeModelGraphValidationResult(issues: issues)
	}

	private func validate(
		tensor: NativeModelTensor,
		knownTensors: inout [String: NativeModelTensor],
		issues: inout [NativeModelGraphValidationIssue]
	) {
		guard isValidName(tensor.name) else {
			issues.append(.invalidTensorName(tensor.name))
			return
		}
		guard knownTensors[tensor.name] == nil else {
			issues.append(.duplicateTensor(tensor.name))
			return
		}
		guard tensor.shape.allSatisfy({ $0 > 0 }) else {
			issues.append(.invalidTensorShape(tensor: tensor.name))
			return
		}
		guard tensor.dataType.byteWidth != nil else {
			issues.append(.unsupportedDataType(tensor: tensor.name, dataType: tensor.dataType.serializedValue))
			return
		}
		guard tensor.byteCount() != nil else {
			issues.append(.invalidTensorShape(tensor: tensor.name))
			return
		}

		knownTensors[tensor.name] = tensor
	}

	private func validate(
		weight: NativeModelWeight,
		knownTensors: inout [String: NativeModelTensor],
		issues: inout [NativeModelGraphValidationIssue]
	) {
		let tensor = weight.tensor
		validate(tensor: tensor, knownTensors: &knownTensors, issues: &issues)

		if let expectedByteCount = tensor.byteCount(), expectedByteCount != weight.byteCount {
			issues.append(.invalidWeightByteCount(name: weight.name, expected: expectedByteCount, actual: weight.byteCount))
		}
		// Every weight's end offset must be representable. The adjacent-pair check below only inspects
		// gaps between sorted weights, so a single weight — or the highest-offset weight — would
		// otherwise reach the unchecked `offset + byteCount` in the reader/emitter and trap.
		if weight.offset.addingReportingOverflow(weight.byteCount).overflow {
			issues.append(.overflowingWeightRange(name: weight.name))
		}
	}

	private func validateWeightRanges(
		_ weights: [NativeModelWeight],
		issues: inout [NativeModelGraphValidationIssue]
	) {
		let orderedWeights = weights.sorted { $0.offset < $1.offset }
		for (first, second) in zip(orderedWeights, orderedWeights.dropFirst()) {
			let (end, overflow) = first.offset.addingReportingOverflow(first.byteCount)
			if overflow || end > second.offset {
				issues.append(.overlappingWeights(first: first.name, second: second.name))
			}
		}
	}

	private func validate(
		operation: NativeModelOperation,
		formatVersion: Int,
		knownTensors: inout [String: NativeModelTensor],
		operationNames: inout Set<String>,
		issues: inout [NativeModelGraphValidationIssue]
	) {
		guard isValidName(operation.name) else {
			issues.append(.invalidOperationName(operation.name))
			return
		}
		guard operationNames.insert(operation.name).inserted else {
			issues.append(.duplicateOperation(operation.name))
			return
		}
		if !operation.kind.isSupported {
			issues.append(.unsupportedOperation(operation: operation.name, kind: operation.kind.serializedValue))
		}
		if !isValid(operation.kind, forFormatVersion: formatVersion) {
			issues.append(.unsupportedOperation(operation: operation.name, kind: operation.kind.serializedValue))
		}

		for input in operation.inputs where knownTensors[input] == nil {
			issues.append(.missingInput(operation: operation.name, tensor: input))
		}
		validateOperationSignature(operation, knownTensors: knownTensors, issues: &issues)

		for output in operation.outputs {
			if knownTensors[output.name] != nil {
				issues.append(.duplicateOutput(operation: operation.name, tensor: output.name))
				continue
			}
			validate(tensor: output, knownTensors: &knownTensors, issues: &issues)
		}
	}

	/// How many output tensors an operation may declare.
	///
	/// The counts used to be the cases — `.one`, `.two`, `.twoOrMore` — which made a four-output operation
	/// a fourth case differing from its neighbours only by a number. Generalised instead of extended: the
	/// count is data, and the two cases left are the two rules that genuinely differ. Adding the next
	/// arity is now a row in the table below rather than a case, an `admits` branch and an `expectation`
	/// branch that must be kept consistent with each other.
	private enum OutputArity {
		case exactly(Int)
		case atLeast(Int)

		func admits(_ outputCount: Int) -> Bool {
			switch self {
			case .exactly(let count): outputCount == count
			case .atLeast(let count): outputCount >= count
			}
		}

		var expectation: String {
			switch self {
			case .exactly(let count): "exactly \(count) output\(count == 1 ? "" : "s")"
			case .atLeast(let count): "at least \(count) outputs"
			}
		}
	}

	/// The output rule for one operation kind.
	///
	/// Multi-output used to be a single `splitND` branch written inline in the arity check. `topK` is the
	/// second, and a second inline branch would spread the answer to "how many outputs" across as many
	/// places as there are multi-output operations — each free to disagree. This is the one place that
	/// answers it: a kind named here carries its own rule, everything else produces exactly one output,
	/// and the next multi-output operation is a line in this switch with the check below untouched.
	private func outputArity(of kind: NativeModelOperationKind) -> OutputArity {
		switch kind {
		// One blob per split size; that the count matches `splitSizes` is checked with the attributes.
		case .splitND: .atLeast(2)
		// Values then indices. Core ML's own validator rejects a topK layer with any other output count
		// ("has 1 outputs but expects exactly 2"), so this is the layer's rule rather than a house one.
		case .topK: .exactly(2)
		// Boxes, scores, source indices, valid count — the layer's rule again: coremltools' `add_nms`
		// documents "must be of length 4 exactly", and none of the four is optional even when a graph
		// consumes only the boxes.
		case .nonMaximumSuppression: .exactly(4)
		default: .exactly(1)
		}
	}

	private func validateOperationSignature(
		_ operation: NativeModelOperation,
		knownTensors: [String: NativeModelTensor],
		issues: inout [NativeModelGraphValidationIssue]
	) {
		guard operation.kind.isSupported else { return }

		let outputArity = outputArity(of: operation.kind)
		guard outputArity.admits(operation.outputs.count) else {
			issues.append(.invalidArity(
				operation: operation.name, expected: outputArity.expectation, actual: operation.outputs.count
			))
			return
		}

		switch operation.kind {
		case .convolution2D:
			requireArity(operation, range: 2 ... 3, issues: &issues)
			requirePositiveIntegerArray(operation, name: "kernelSize", count: 2, issues: &issues)
			requirePositiveIntegerArray(operation, name: "strides", count: 2, issues: &issues)
			requireNonNegativeIntegerArray(operation, name: "padding", validCounts: Set([2, 4]), issues: &issues)
			requirePositiveIntegerArray(operation, name: "dilations", count: 2, issues: &issues)
			requirePositiveInteger(operation, name: "groups", issues: &issues)
		case .linear:
			requireArity(operation, range: 2 ... 3, issues: &issues)
		case .maxPool2D, .averagePool2D:
			requireArity(operation, exact: 1, issues: &issues)
			requirePositiveIntegerArray(operation, name: "kernelSize", count: 2, issues: &issues)
			requirePositiveIntegerArray(operation, name: "strides", count: 2, issues: &issues)
			requireNonNegativeIntegerArray(operation, name: "padding", validCounts: Set([2, 4]), issues: &issues)
		case .upsample2D:
			// A nearest-neighbor upsample repeats each sample an integer number of times along H and W,
			// so its only parameter is a positive [H, W] scaling factor.
			requireArity(operation, exact: 1, issues: &issues)
			requirePositiveIntegerArray(operation, name: "scalingFactor", count: 2, issues: &issues)
		case .batchedMatrixMultiplicationND, .add, .subtract, .multiply, .divide, .minimumND, .maximumND:
			requireArity(operation, exact: 2, issues: &issues)
		case .cropResize:
			// Two inputs, and the arity is exact rather than a range: a crop with only a feature map has
			// no boxes to crop to, and a third input has nowhere to go.
			requireArity(operation, exact: 2, issues: &issues)
			requirePositiveInteger(operation, name: "targetHeight", issues: &issues)
			requirePositiveInteger(operation, name: "targetWidth", issues: &issues)
			// A zero or negative scale maps every box onto the same degenerate point; the attribute is
			// the feature map's stride reciprocal, so it is positive by construction.
			requirePositiveFloatingPoint(operation, name: "spatialScale", issues: &issues)
		case .splitND:
			requireArity(operation, exact: 1, issues: &issues)
			requireInteger(operation, name: "axis", issues: &issues)
			requirePositiveIntegerArray(operation, name: "splitSizes", count: operation.outputs.count, issues: &issues)
		case .topK:
			// One activation input. Core ML's layer accepts an optional second input carrying K, which
			// this graph cannot use: a runtime K leaves every downstream extent undeclarable.
			requireArity(operation, exact: 1, issues: &issues)
			requirePositiveInteger(operation, name: "k", issues: &issues)
			requireInteger(operation, name: "axis", issues: &issues)
		case .nonMaximumSuppression:
			// Boxes then scores, and exactly those two. Core ML's layer accepts up to five inputs, the last
			// three carrying the IoU threshold, the score threshold and `maxBoxes` at runtime; none is
			// admitted here, because a runtime `maxBoxes` leaves the padded output extent undeclarable and a
			// runtime threshold costs a constant blob to say what an attribute already says.
			requireArity(operation, exact: 2, issues: &issues)
			// Both thresholds are plain floats. An IoU outside [0, 1] is a calibration mistake rather than a
			// structural one — the layer accepts it and suppresses accordingly — and a score threshold is
			// legitimately any real number, so neither gets a range rule this validator would have to guess.
			requireFloatingPoint(operation, name: "iouThreshold", issues: &issues)
			requireFloatingPoint(operation, name: "scoreThreshold", issues: &issues)
			// `maxBoxes` is the fixed extent of all four outputs, so zero would declare blobs with no slots.
			// `perClassSuppression` stays optional and defaults to false, like `cropResize`'s `normalizedROI`:
			// ADAF's detectors are single-class, where the flag is vacuous.
			requirePositiveInteger(operation, name: "maxBoxes", issues: &issues)
		case .gather:
			// Data then indices. Their ranks decide the output rank — `data.rank - 1 + indices.rank`, see
			// the operation's own documentation — which this validator deliberately does not verify: it
			// checks declarations against the contract, never inferred shapes.
			requireArity(operation, exact: 2, issues: &issues)
			requireInteger(operation, name: "axis", issues: &issues)
		case .batchNormalization:
			requireArity(operation, exact: 5, issues: &issues)
			requirePositiveFloatingPoint(operation, name: "epsilon", issues: &issues)
		case .unsupported:
			break
		default:
			validateUnaryOperationSignature(operation, knownTensors: knownTensors, issues: &issues)
		}
	}

	/// Signature rules for the single-input operations — activations, shape manipulation, and the
	/// input-free constant. Split from `validateOperationSignature` so neither switch outgrows the
	/// cyclomatic-complexity limit as the operator set expands.
	private func validateUnaryOperationSignature(
		_ operation: NativeModelOperation,
		knownTensors: [String: NativeModelTensor],
		issues: inout [NativeModelGraphValidationIssue]
	) {
		switch operation.kind {
		case .globalAveragePool2D, .relu, .relu6, .sigmoid, .tanh, .exponential, .softmaxChannel, .identity,
			.floor, .naturalLogarithm:
			requireArity(operation, exact: 1, issues: &issues)
		case .leakyReLU:
			requireArity(operation, exact: 1, issues: &issues)
			requireFloatingPoint(operation, name: "alpha", issues: &issues)
		case .greaterOrEqual:
			requireArity(operation, exact: 1, issues: &issues)
			requireFloatingPoint(operation, name: "threshold", issues: &issues)
		case .sliceChannels:
			// Half-open [startChannel, endChannel) on the channel axis, as Core ML's slice layer takes it.
			requireArity(operation, exact: 1, issues: &issues)
			requireNonNegativeInteger(operation, name: "startChannel", issues: &issues)
			requirePositiveInteger(operation, name: "endChannel", issues: &issues)
			requireOrderedChannelRange(operation, issues: &issues)
		case .constant, .constantND:
			// The single input names the weight holding the constant's values; there is no activation.
			requireArity(operation, exact: 1, issues: &issues)
		case .reshape, .reshapeND:
			requireArity(operation, exact: 1, issues: &issues)
			requirePositiveIntegerArray(operation, name: "shape", count: nil, issues: &issues)
		case .transpose:
			requireArity(operation, exact: 1, issues: &issues)
			requireLegacyPermutation(operation, issues: &issues)
		case .transposeND:
			requireArity(operation, exact: 1, issues: &issues)
			guard let input = operation.inputs.first.flatMap({ knownTensors[$0] }) else { return }
			requireExactNDPermutation(operation, rank: input.shape.count, issues: &issues)
		case .concatenate, .concatenateND:
			requireArity(operation, minimum: 2, issues: &issues)
			requireInteger(operation, name: "axis", issues: &issues)
		case .softmax:
			requireArity(operation, exact: 1, issues: &issues)
			requireInteger(operation, name: "axis", issues: &issues)
		case .flatten:
			requireArity(operation, exact: 1, issues: &issues)
			requireInteger(operation, name: "axis", issues: &issues)
		case .sliceND:
			requireArity(operation, exact: 1, issues: &issues)
			guard let input = operation.inputs.first.flatMap({ knownTensors[$0] }) else { return }
			requireNonNegativeIntegerArray(operation, name: "beginIds", count: input.shape.count, issues: &issues)
			requireNonNegativeIntegerArray(operation, name: "endIds", count: input.shape.count, issues: &issues)
			requirePositiveIntegerArray(operation, name: "strides", count: input.shape.count, issues: &issues)
		default:
			break
		}
	}

	/// V2 is an exact-ND graph family. V1 retains the classic rank-5 layout operations exactly as
	/// shipped; the two families may share ordinary convolution/activation/elementwise nodes only.
	///
	/// The box-arithmetic primitives are exact-ND only for a second reason: the classic layer set has
	/// no floor, no comparison, and no subtract at all, so their only Core ML form is a spec-4 layer.
	/// Admitting them into V1 would mean writing exact-rank layers into a graph whose other layers
	/// address the rank-5 layout — a mix that compiles and then reads the blob differently.
	///
	/// `cropResize` is exact-ND only for a third reason again: its blobs are rank 5 *as data* — the box
	/// input is `[K, 1, 4, 1, 1]` and the output batches over K — so the legacy mapping, which reads a
	/// declared rank-4 shape as `[1, C, H, W]`, cannot name those axes at all.
	///
	/// `topK` and `gather` share the first reason — the classic layer set has neither — and `gather` adds
	/// a fourth: its output rank is `data.rank - 1 + indices.rank`, a rank that varies with the indices
	/// blob and that the legacy mapping's fixed four-axis reading cannot express.
	///
	/// `nonMaximumSuppression` shares the first reason and adds a fifth: its kernel refuses inputs that are
	/// not rank 3 exactly, and rank 3 is a shape the legacy mapping reads as `[C, H, W]` rather than as the
	/// `[batch, boxes, 4]` the layer means.
	private func isValid(_ kind: NativeModelOperationKind, forFormatVersion formatVersion: Int) -> Bool {
		let exactNDOnly: [NativeModelOperationKind] = [
			.reshapeND, .transposeND, .concatenateND, .sliceND, .splitND,
			.batchedMatrixMultiplicationND, .constantND,
			.minimumND, .maximumND, .floor, .naturalLogarithm, .greaterOrEqual, .subtract,
			.cropResize, .topK, .gather, .nonMaximumSuppression
		]
		let legacyLayoutOnly: [NativeModelOperationKind] = [
			.reshape, .transpose, .concatenate, .sliceChannels, .softmaxChannel, .constant
		]
		if kind == .matrixMultiplication { return false }
		switch formatVersion {
		case NativeModelGraph.legacyFormatVersion:
			return !exactNDOnly.contains(kind)
		case NativeModelGraph.exactNDFormatVersion:
			return !legacyLayoutOnly.contains(kind)
		default:
			return false
		}
	}

	private func requireArity(
		_ operation: NativeModelOperation,
		exact: Int,
		issues: inout [NativeModelGraphValidationIssue]
	) {
		guard operation.inputs.count == exact else {
			issues.append(.invalidArity(operation: operation.name, expected: "\(exact)", actual: operation.inputs.count))
			return
		}
	}

	private func requireArity(
		_ operation: NativeModelOperation,
		range: ClosedRange<Int>,
		issues: inout [NativeModelGraphValidationIssue]
	) {
		guard range.contains(operation.inputs.count) else {
			issues.append(.invalidArity(operation: operation.name, expected: "\(range.lowerBound)–\(range.upperBound)", actual: operation.inputs.count))
			return
		}
	}

	private func requireArity(
		_ operation: NativeModelOperation,
		minimum: Int,
		issues: inout [NativeModelGraphValidationIssue]
	) {
		guard operation.inputs.count >= minimum else {
			issues.append(.invalidArity(operation: operation.name, expected: "at least \(minimum)", actual: operation.inputs.count))
			return
		}
	}

	private func requireInteger(
		_ operation: NativeModelOperation,
		name: String,
		issues: inout [NativeModelGraphValidationIssue]
	) {
		guard operation.attributes[name]?.integerValue != nil else {
			issues.append(.invalidAttribute(operation: operation.name, attribute: name, expected: "an integer"))
			return
		}
	}

	private func requirePositiveInteger(
		_ operation: NativeModelOperation,
		name: String,
		issues: inout [NativeModelGraphValidationIssue]
	) {
		guard let value = operation.attributes[name]?.integerValue, value > 0 else {
			issues.append(.invalidAttribute(operation: operation.name, attribute: name, expected: "a positive integer"))
			return
		}
	}

	private func requireNonNegativeInteger(
		_ operation: NativeModelOperation,
		name: String,
		issues: inout [NativeModelGraphValidationIssue]
	) {
		guard let value = operation.attributes[name]?.integerValue, value >= 0 else {
			issues.append(.invalidAttribute(operation: operation.name, attribute: name, expected: "a non-negative integer"))
			return
		}
	}

	private func requireFloatingPoint(
		_ operation: NativeModelOperation,
		name: String,
		issues: inout [NativeModelGraphValidationIssue]
	) {
		guard operation.attributes[name]?.floatingPointValue != nil else {
			issues.append(.invalidAttribute(operation: operation.name, attribute: name, expected: "a floating-point number"))
			return
		}
	}

	/// A channel slice must select a non-empty range; an inverted or empty one would emit a Core ML
	/// slice layer that produces a zero-width blob and fails only later, inside Core ML.
	private func requireOrderedChannelRange(
		_ operation: NativeModelOperation,
		issues: inout [NativeModelGraphValidationIssue]
	) {
		guard let start = operation.attributes["startChannel"]?.integerValue,
			let end = operation.attributes["endChannel"]?.integerValue,
			end > start
		else {
			issues.append(.invalidAttribute(operation: operation.name, attribute: "endChannel", expected: "greater than startChannel"))
			return
		}
	}

	private func requirePositiveFloatingPoint(
		_ operation: NativeModelOperation,
		name: String,
		issues: inout [NativeModelGraphValidationIssue]
	) {
		guard let value = operation.attributes[name]?.floatingPointValue, value > 0 else {
			issues.append(.invalidAttribute(operation: operation.name, attribute: name, expected: "a positive number"))
			return
		}
	}

	private func requirePositiveIntegerArray(
		_ operation: NativeModelOperation,
		name: String,
		count: Int?,
		issues: inout [NativeModelGraphValidationIssue]
	) {
		guard let values = operation.attributes[name]?.integerArrayValue,
			  !values.isEmpty,
			  values.allSatisfy({ $0 > 0 }),
			  count.map({ values.count == $0 }) ?? true
		else {
			let description = count.map { "\($0) positive integers" } ?? "positive integers"
			issues.append(.invalidAttribute(operation: operation.name, attribute: name, expected: description))
			return
		}
	}

	private func requireNonNegativeIntegerArray(
		_ operation: NativeModelOperation,
		name: String,
		count: Int,
		issues: inout [NativeModelGraphValidationIssue]
	) {
		guard let values = operation.attributes[name]?.integerArrayValue,
			values.count == count,
			values.allSatisfy({ $0 >= 0 })
		else {
			issues.append(.invalidAttribute(operation: operation.name, attribute: name, expected: "\(count) non-negative integers"))
			return
		}
	}

	private func requireNonNegativeIntegerArray(
		_ operation: NativeModelOperation,
		name: String,
		validCounts: Set<Int>,
		issues: inout [NativeModelGraphValidationIssue]
	) {
		guard let values = operation.attributes[name]?.integerArrayValue,
			  validCounts.contains(values.count),
			  values.allSatisfy({ $0 >= 0 })
		else {
			issues.append(.invalidAttribute(operation: operation.name, attribute: name, expected: "\(validCounts.sorted()) non-negative integers"))
			return
		}
	}

	/// Core ML's permute layer always addresses the four `(sequence, channel, height, width)` axes of
	/// its internal layout, whatever rank the declared tensor has — so the permutation is checked
	/// against those four axes rather than against the input's own rank.
	private func requireLegacyPermutation(
		_ operation: NativeModelOperation,
		issues: inout [NativeModelGraphValidationIssue]
	) {
		guard let values = operation.attributes["permutation"]?.integerArrayValue,
			  values.count == 4,
			  Set(values) == Set(0 ..< 4)
		else {
			issues.append(.invalidAttribute(operation: operation.name, attribute: "permutation", expected: "a permutation of the four Core ML axes"))
			return
		}
	}

	private func requireExactNDPermutation(
		_ operation: NativeModelOperation,
		rank: Int,
		issues: inout [NativeModelGraphValidationIssue]
	) {
		guard let values = operation.attributes["permutation"]?.integerArrayValue,
			values.count == rank,
			Set(values) == Set(0 ..< rank)
		else {
			issues.append(.invalidAttribute(operation: operation.name, attribute: "permutation", expected: "a permutation of the \(rank) tensor axes"))
			return
		}
	}

	private func isValidName(_ name: String) -> Bool {
		guard !name.isEmpty else { return false }
		let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_./:-"))
		return name.unicodeScalars.allSatisfy(allowedCharacters.contains)
	}
}
