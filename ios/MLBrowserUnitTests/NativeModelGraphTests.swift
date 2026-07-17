//
//  NativeModelGraphTests.swift
//  MLBrowserUnitTests
//

import XCTest
@testable import ML_Browser
import NativeModelConverter

final class NativeModelGraphTests: XCTestCase {

	func testValidate_mobileNetStyleGraph_isConvertible() {
		let result = NativeModelGraphValidator().validate(makeMobileNetStyleGraph())

		XCTAssertTrue(result.isConvertible, result.issues.map(\.localizedDescription).joined(separator: "\n"))
		XCTAssertTrue(result.issues.isEmpty)
	}

	func testValidate_unsupportedOperation_reportsOperationAndKind() {
		var graph = makeMobileNetStyleGraph()
		graph = NativeModelGraph(
			formatVersion: graph.formatVersion,
			producer: graph.producer,
			inputs: graph.inputs,
			weights: graph.weights,
			operations: [
				NativeModelOperation(
					name: "activation",
					kind: .unsupported("gelu"),
					inputs: ["image"],
					outputs: [tensor("output", [1, 3, 224, 224])],
					attributes: [:]
				)
			],
			outputs: ["output"]
		)

		let result = NativeModelGraphValidator().validate(graph)

		XCTAssertEqual(
			result.issues,
			[.unsupportedOperation(operation: "activation", kind: "gelu")]
		)
	}

	func testValidate_futureTensorReference_reportsMissingInput() {
		let graph = NativeModelGraph(
			formatVersion: 1,
			producer: NativeModelGraphProducer(name: "tests", version: "1.0"),
			inputs: [tensor("image", [1, 3, 224, 224])],
			weights: [],
			operations: [
				NativeModelOperation(
					name: "first",
					kind: .relu,
					inputs: ["second"],
					outputs: [tensor("first", [1, 3, 224, 224])],
					attributes: [:]
				),
				NativeModelOperation(
					name: "second",
					kind: .relu,
					inputs: ["image"],
					outputs: [tensor("second", [1, 3, 224, 224])],
					attributes: [:]
				)
			],
			outputs: ["first"]
		)

		let result = NativeModelGraphValidator().validate(graph)

		XCTAssertTrue(result.issues.contains(.missingInput(operation: "first", tensor: "second")))
	}

	func testValidate_invalidWeightSize_reportsExpectedByteCount() {
		var graph = makeMobileNetStyleGraph()
		var weights = graph.weights
		weights[0] = NativeModelWeight(
			name: weights[0].name,
			dataType: weights[0].dataType,
			shape: weights[0].shape,
			offset: weights[0].offset,
			byteCount: weights[0].byteCount - 4
		)
		graph = NativeModelGraph(
			formatVersion: graph.formatVersion,
			producer: graph.producer,
			inputs: graph.inputs,
			weights: weights,
			operations: graph.operations,
			outputs: graph.outputs
		)

		let result = NativeModelGraphValidator().validate(graph)

		XCTAssertTrue(
			result.issues.contains(
				.invalidWeightByteCount(name: "conv.weight", expected: 3_456, actual: 3_452)
			)
		)
	}

	func testDecode_graphJSON_preservesTypedAttributes() throws {
		let json = """
		{
		  "formatVersion": 1,
		  "producer": { "name": "aiarcheology-pytorch", "version": "0.1.0" },
		  "inputs": [
		    { "name": "input", "dataType": "float16", "shape": [1, 3, 224, 224] }
		  ],
		  "weights": [],
		  "operations": [
		    {
		      "name": "relu",
		      "kind": "relu",
		      "inputs": ["input"],
		      "outputs": [
		        { "name": "output", "dataType": "float16", "shape": [1, 3, 224, 224] }
		      ],
		      "attributes": { "inplace": false, "debugRank": 4 }
		    }
		  ],
		  "outputs": ["output"]
		}
		"""

		let graph = try JSONDecoder().decode(NativeModelGraph.self, from: Data(json.utf8))

		XCTAssertEqual(graph.inputs[0].dataType, .float16)
		XCTAssertEqual(graph.operations[0].attributes["inplace"], .boolean(false))
		XCTAssertEqual(graph.operations[0].attributes["debugRank"], .integer(4))
		XCTAssertTrue(NativeModelGraphValidator().validate(graph).isConvertible)
	}

	private func makeMobileNetStyleGraph() -> NativeModelGraph {
		NativeModelGraph(
			formatVersion: 1,
			producer: NativeModelGraphProducer(name: "aiarcheology-pytorch", version: "0.1.0"),
			inputs: [tensor("image", [1, 3, 224, 224])],
			weights: [
				weight("conv.weight", [32, 3, 3, 3], offset: 0),
				weight("conv.bias", [32], offset: 3_456),
				weight("bn.scale", [32], offset: 3_584),
				weight("bn.bias", [32], offset: 3_712),
				weight("bn.mean", [32], offset: 3_840),
				weight("bn.variance", [32], offset: 3_968),
				weight("classifier.weight", [5, 32], offset: 4_096),
				weight("classifier.bias", [5], offset: 4_736)
			],
			operations: [
				NativeModelOperation(
					name: "conv",
					kind: .convolution2D,
					inputs: ["image", "conv.weight", "conv.bias"],
					outputs: [tensor("conv", [1, 32, 112, 112])],
					attributes: [
						"kernelSize": .integers([3, 3]),
						"strides": .integers([2, 2]),
						"padding": .integers([1, 1]),
						"dilations": .integers([1, 1]),
						"groups": .integer(1)
					]
				),
				NativeModelOperation(
					name: "batchNorm",
					kind: .batchNormalization,
					inputs: ["conv", "bn.scale", "bn.bias", "bn.mean", "bn.variance"],
					outputs: [tensor("normalized", [1, 32, 112, 112])],
					attributes: ["epsilon": .floatingPoint(0.00001)]
				),
				NativeModelOperation(
					name: "relu6",
					kind: .relu6,
					inputs: ["normalized"],
					outputs: [tensor("activated", [1, 32, 112, 112])],
					attributes: [:]
				),
				NativeModelOperation(
					name: "pool",
					kind: .globalAveragePool2D,
					inputs: ["activated"],
					outputs: [tensor("pooled", [1, 32, 1, 1])],
					attributes: [:]
				),
				NativeModelOperation(
					name: "flatten",
					kind: .flatten,
					inputs: ["pooled"],
					outputs: [tensor("features", [1, 32])],
					attributes: ["axis": .integer(1)]
				),
				NativeModelOperation(
					name: "classifier",
					kind: .linear,
					inputs: ["features", "classifier.weight", "classifier.bias"],
					outputs: [tensor("logits", [1, 5])],
					attributes: [:]
				)
			],
			outputs: ["logits"]
		)
	}

	private func tensor(_ name: String, _ shape: [Int]) -> NativeModelTensor {
		NativeModelTensor(name: name, dataType: .float32, shape: shape)
	}

	private func weight(_ name: String, _ shape: [Int], offset: UInt64) -> NativeModelWeight {
		let byteCount = UInt64(shape.reduce(1, *)) * 4
		return NativeModelWeight(
			name: name,
			dataType: .float32,
			shape: shape,
			offset: offset,
			byteCount: byteCount
		)
	}
}
