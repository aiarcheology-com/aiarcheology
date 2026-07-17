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
	public static let currentFormatVersion = 1

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
	case globalAveragePool2D
	case reshape
	case transpose
	case concatenate
	case softmax
	case matrixMultiplication
	case add
	case subtract
	case multiply
	case divide
	case batchNormalization
	case sigmoid
	case tanh
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
		case .globalAveragePool2D: "globalAveragePool2d"
		case .reshape: "reshape"
		case .transpose: "transpose"
		case .concatenate: "concat"
		case .softmax: "softmax"
		case .matrixMultiplication: "matmul"
		case .add: "add"
		case .subtract: "subtract"
		case .multiply: "multiply"
		case .divide: "divide"
		case .batchNormalization: "batchNorm"
		case .sigmoid: "sigmoid"
		case .tanh: "tanh"
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
		"globalAveragePool2d": .globalAveragePool2D,
		"reshape": .reshape,
		"transpose": .transpose,
		"concat": .concatenate,
		"softmax": .softmax,
		"matmul": .matrixMultiplication,
		"add": .add,
		"subtract": .subtract,
		"multiply": .multiply,
		"divide": .divide,
		"batchNorm": .batchNormalization,
		"sigmoid": .sigmoid,
		"tanh": .tanh,
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

		if graph.formatVersion != NativeModelGraph.currentFormatVersion {
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

	private func validateOperationSignature(
		_ operation: NativeModelOperation,
		knownTensors: [String: NativeModelTensor],
		issues: inout [NativeModelGraphValidationIssue]
	) {
		guard operation.kind.isSupported else { return }

		guard operation.outputs.count == 1 else {
			issues.append(.invalidArity(operation: operation.name, expected: "exactly one output", actual: operation.outputs.count))
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
		case .globalAveragePool2D, .relu, .relu6, .sigmoid, .tanh, .identity:
			requireArity(operation, exact: 1, issues: &issues)
		case .reshape:
			requireArity(operation, exact: 1, issues: &issues)
			requirePositiveIntegerArray(operation, name: "shape", count: nil, issues: &issues)
		case .transpose:
			requireArity(operation, exact: 1, issues: &issues)
			requirePermutation(operation, input: operation.inputs.first.flatMap { knownTensors[$0] }, issues: &issues)
		case .concatenate:
			requireArity(operation, minimum: 2, issues: &issues)
			requireInteger(operation, name: "axis", issues: &issues)
		case .softmax:
			requireArity(operation, exact: 1, issues: &issues)
			requireInteger(operation, name: "axis", issues: &issues)
		case .matrixMultiplication, .add, .subtract, .multiply, .divide:
			requireArity(operation, exact: 2, issues: &issues)
		case .batchNormalization:
			requireArity(operation, exact: 5, issues: &issues)
			requirePositiveFloatingPoint(operation, name: "epsilon", issues: &issues)
		case .flatten:
			requireArity(operation, exact: 1, issues: &issues)
			requireInteger(operation, name: "axis", issues: &issues)
		case .unsupported:
			break
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

	private func requirePermutation(
		_ operation: NativeModelOperation,
		input: NativeModelTensor?,
		issues: inout [NativeModelGraphValidationIssue]
	) {
		guard let input,
			  let values = operation.attributes["permutation"]?.integerArrayValue,
			  values.count == input.shape.count,
			  Set(values) == Set(0 ..< input.shape.count)
		else {
			issues.append(.invalidAttribute(operation: operation.name, attribute: "permutation", expected: "a permutation of input axes"))
			return
		}
	}

	private func isValidName(_ name: String) -> Bool {
		guard !name.isEmpty else { return false }
		let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_./:-"))
		return name.unicodeScalars.allSatisfy(allowedCharacters.contains)
	}
}
