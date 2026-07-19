//
//  NativeModelDetectionLayerTests.swift
//  NativeModelConverterTests
//
//  Numeric checks for the layers the detection decode is built from. Each test compiles a
//  single-operation model and compares a real prediction against hand-computed values, because a
//  wrong Core ML parameter field number produces a model that compiles and returns plausible
//  nonsense.
//

import CoreML
import Foundation
import XCTest
@testable import NativeModelConverter

final class NativeModelDetectionLayerTests: XCTestCase {

	// MARK: - Harness

	/// Builds, compiles and runs a one-operation graph over a `[1, C, H, W]` input.
	private func run(
		operation kind: NativeModelOperationKind,
		attributes: [String: NativeModelAttribute] = [:],
		inputShape: [Int],
		outputShape: [Int],
		values: [Float]
	) async throws -> [Float] {
		let input = NativeModelTensor(name: "x", dataType: .float32, shape: inputShape)
		let graph = NativeModelGraph(
			formatVersion: NativeModelGraph.currentFormatVersion,
			producer: NativeModelGraphProducer(name: "test", version: "1"),
			inputs: [input],
			weights: [],
			operations: [
				NativeModelOperation(
					name: "y", kind: kind, inputs: ["x"],
					outputs: [NativeModelTensor(name: "y", dataType: .float32, shape: outputShape)],
					attributes: attributes
				)
			],
			outputs: ["y"]
		)
		return try await predict(graph: graph, weights: Data(), inputs: ["x": (inputShape, values)], outputShape: outputShape)
	}

	private func predict(
		graph: NativeModelGraph,
		weights: Data,
		inputs: [String: ([Int], [Float])],
		outputShape: [Int]
	) async throws -> [Float] {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mlmodel")
		addTeardownBlock { try? FileManager.default.removeItem(at: url) }
		try NativeModelCoreMLEmitter().emit(graph: graph, weights: weights, to: url)
		let compiled = try await MLModel.compileModel(at: url)
		addTeardownBlock { try? FileManager.default.removeItem(at: compiled) }
		let configuration = MLModelConfiguration()
		configuration.computeUnits = .cpuOnly
		let model = try MLModel(contentsOf: compiled, configuration: configuration)

		var features: [String: MLFeatureValue] = [:]
		for (name, (shape, values)) in inputs {
			let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float32)
			for (index, value) in values.enumerated() {
				array[index] = NSNumber(value: value)
			}
			features[name] = MLFeatureValue(multiArray: array)
		}
		let prediction = try await model.prediction(from: try MLDictionaryFeatureProvider(dictionary: features))
		let output = try XCTUnwrap(prediction.featureValue(for: "y")?.multiArrayValue)
		XCTAssertEqual(output.shape.map(\.intValue), outputShape, "The emitted output shape drifted from the graph's declaration.")
		return (0 ..< output.count).map { output[$0].floatValue }
	}

	private func assertClose(_ actual: [Float], _ expected: [Float], accuracy: Float = 0.0005, file: StaticString = #filePath, line: UInt = #line) {
		XCTAssertEqual(actual.count, expected.count, file: file, line: line)
		for (index, pair) in zip(actual, expected).enumerated() {
			XCTAssertEqual(pair.0, pair.1, accuracy: accuracy, "element \(index)", file: file, line: line)
		}
	}

	// MARK: - Activations

	func testLeakyReLU_scalesOnlyTheNegativeSide() async throws {
		let output = try await run(
			operation: .leakyReLU, attributes: ["alpha": .floatingPoint(0.1)],
			inputShape: [1, 4, 1, 1], outputShape: [1, 4, 1, 1],
			values: [-2, -0.5, 0.5, 3]
		)
		assertClose(output, [-0.2, -0.05, 0.5, 3])
	}

	func testLeakyReLU_withZeroAlphaMatchesReLU() async throws {
		let output = try await run(
			operation: .leakyReLU, attributes: ["alpha": .floatingPoint(0)],
			inputShape: [1, 3, 1, 1], outputShape: [1, 3, 1, 1],
			values: [-4, 0, 4]
		)
		assertClose(output, [0, 0, 4])
	}

	func testSigmoid_matchesTheLogisticCurve() async throws {
		let output = try await run(
			operation: .sigmoid, inputShape: [1, 3, 1, 1], outputShape: [1, 3, 1, 1],
			values: [-1, 0, 2]
		)
		assertClose(output, [0.268941, 0.5, 0.880797])
	}

	func testExponential_matchesEulerPowers() async throws {
		let output = try await run(
			operation: .exponential, inputShape: [1, 3, 1, 1], outputShape: [1, 3, 1, 1],
			values: [0, 1, -1]
		)
		assertClose(output, [1, 2.718282, 0.367879], accuracy: 0.0001)
	}

	// MARK: - Shape manipulation

	// Reshape and Permute force the legacy rank-5 blob layout, where a plain multi-array input must
	// be declared rank-3 `[channel, height, width]` and both layers address the rank-4
	// `(sequence, channel, height, width)` tuple.

	func testReshape_reindexesInChannelFirstOrder() async throws {
		// [4,1,1] -> (seq 1, C 2, H 2, W 1): the flat order must be preserved, which is what lets the
		// decode split a packed grid tensor into per-anchor attributes.
		let output = try await run(
			operation: .reshape, attributes: ["shape": .integers([1, 2, 2, 1])],
			inputShape: [4, 1, 1], outputShape: [2, 2, 1],
			values: [1, 2, 3, 4]
		)
		assertClose(output, [1, 2, 3, 4])
	}

	func testTranspose_swapsTheChannelAndHeightAxes() async throws {
		// C=2, H=3 with permutation [0,2,1,3] becomes C=3, H=2 — the exact reshuffle the decode uses
		// to move box attributes onto the channel axis before slicing them apart.
		let output = try await run(
			operation: .transpose, attributes: ["permutation": .integers([0, 2, 1, 3])],
			inputShape: [2, 3, 1], outputShape: [3, 2, 1],
			values: [1, 2, 3, 4, 5, 6]
		)
		assertClose(output, [1, 4, 2, 5, 3, 6])
	}

	func testSliceChannels_selectsAHalfOpenRange() async throws {
		let output = try await run(
			operation: .sliceChannels, attributes: ["startChannel": .integer(1), "endChannel": .integer(3)],
			inputShape: [1, 5, 1, 1], outputShape: [1, 2, 1, 1],
			values: [10, 20, 30, 40, 50]
		)
		assertClose(output, [20, 30])
	}

	func testSliceChannels_fromZeroKeepsTheLeadingChannels() async throws {
		// startIndex is omitted from the protobuf when zero; this covers that the default is 0 and
		// not "whole tensor".
		let output = try await run(
			operation: .sliceChannels, attributes: ["startChannel": .integer(0), "endChannel": .integer(2)],
			inputShape: [1, 4, 1, 1], outputShape: [1, 2, 1, 1],
			values: [7, 8, 9, 10]
		)
		assertClose(output, [7, 8])
	}

	// MARK: - Binary and constant

	func testMultiply_isElementwiseAndNotAnAdd() async throws {
		let input = NativeModelTensor(name: "x", dataType: .float32, shape: [1, 3, 1, 1])
		let graph = NativeModelGraph(
			formatVersion: NativeModelGraph.currentFormatVersion,
			producer: NativeModelGraphProducer(name: "test", version: "1"),
			inputs: [input],
			weights: [],
			operations: [
				NativeModelOperation(
					name: "y", kind: .multiply, inputs: ["x", "x"],
					outputs: [NativeModelTensor(name: "y", dataType: .float32, shape: [1, 3, 1, 1])],
					attributes: [:]
				)
			],
			outputs: ["y"]
		)
		let output = try await predict(
			graph: graph, weights: Data(),
			inputs: ["x": ([1, 3, 1, 1], [2, 3, 4])], outputShape: [1, 3, 1, 1]
		)
		// Squares, not doubles: 231 must not be confused with add's 230.
		assertClose(output, [4, 9, 16])
	}

	func testConstant_materializesItsWeightAndScalesTheInput() async throws {
		// constant -> multiply exercises the decode's anchor path: a fixed tensor scaling activations.
		let constantValues: [Float] = [2, 5, 10]
		let weights = constantValues.withUnsafeBytes { Data($0) }
		let graph = NativeModelGraph(
			formatVersion: NativeModelGraph.currentFormatVersion,
			producer: NativeModelGraphProducer(name: "test", version: "1"),
			inputs: [NativeModelTensor(name: "x", dataType: .float32, shape: [1, 3, 1, 1])],
			weights: [
				NativeModelWeight(name: "k", dataType: .float32, shape: [3, 1, 1], offset: 0, byteCount: UInt64(weights.count))
			],
			operations: [
				NativeModelOperation(
					name: "c", kind: .constant, inputs: ["k"],
					outputs: [NativeModelTensor(name: "c", dataType: .float32, shape: [3, 1, 1])],
					attributes: [:]
				),
				NativeModelOperation(
					name: "y", kind: .multiply, inputs: ["x", "c"],
					outputs: [NativeModelTensor(name: "y", dataType: .float32, shape: [1, 3, 1, 1])],
					attributes: [:]
				)
			],
			outputs: ["y"]
		)
		let output = try await predict(
			graph: graph, weights: weights,
			inputs: ["x": ([1, 3, 1, 1], [1, 2, 3])], outputShape: [1, 3, 1, 1]
		)
		assertClose(output, [2, 10, 30])
	}

	func testConstant_broadcastsAScalarAndAPerChannelTensor() async throws {
		// tiny-yolov2 embeds its pixel normalization as Mul(image, [1]-scalar) then
		// Add([3,1,1]-bias, x); both lower to a constant plus a broadcast elementwise op, so classic
		// Core ML broadcasting of [1,1,1] and [C,1,1] over [C,H,W] must actually hold.
		let scalar: [Float] = [0.5]
		let bias: [Float] = [10, 20]
		var blob = scalar.withUnsafeBytes { Data($0) }
		blob.append(bias.withUnsafeBytes { Data($0) })
		let graph = NativeModelGraph(
			formatVersion: NativeModelGraph.currentFormatVersion,
			producer: NativeModelGraphProducer(name: "test", version: "1"),
			inputs: [NativeModelTensor(name: "x", dataType: .float32, shape: [1, 2, 2, 2])],
			weights: [
				NativeModelWeight(name: "s", dataType: .float32, shape: [1, 1, 1], offset: 0, byteCount: 4),
				NativeModelWeight(name: "b", dataType: .float32, shape: [2, 1, 1], offset: 4, byteCount: 8)
			],
			operations: [
				NativeModelOperation(
					name: "sc", kind: .constant, inputs: ["s"],
					outputs: [NativeModelTensor(name: "sc", dataType: .float32, shape: [1, 1, 1])], attributes: [:]
				),
				NativeModelOperation(
					name: "bc", kind: .constant, inputs: ["b"],
					outputs: [NativeModelTensor(name: "bc", dataType: .float32, shape: [2, 1, 1])], attributes: [:]
				),
				NativeModelOperation(
					name: "scaled", kind: .multiply, inputs: ["x", "sc"],
					outputs: [NativeModelTensor(name: "scaled", dataType: .float32, shape: [1, 2, 2, 2])], attributes: [:]
				),
				NativeModelOperation(
					name: "y", kind: .add, inputs: ["bc", "scaled"],
					outputs: [NativeModelTensor(name: "y", dataType: .float32, shape: [1, 2, 2, 2])], attributes: [:]
				)
			],
			outputs: ["y"]
		)
		let output = try await predict(
			graph: graph, weights: blob,
			inputs: ["x": ([1, 2, 2, 2], [2, 4, 6, 8, 10, 12, 14, 16])], outputShape: [1, 2, 2, 2]
		)
		// channel 0: x·0.5 + 10; channel 1: x·0.5 + 20.
		assertClose(output, [11, 12, 13, 14, 25, 26, 27, 28])
	}

	// MARK: - Rejection

	func testLeakyReLU_withoutAlphaIsRejected() {
		assertEmissionFails(kind: .leakyReLU, attributes: [:])
	}

	func testSliceChannels_withInvertedRangeIsRejected() {
		assertEmissionFails(kind: .sliceChannels, attributes: ["startChannel": .integer(3), "endChannel": .integer(1)])
	}

	func testTranspose_withNonPermutationIsRejected() {
		assertEmissionFails(kind: .transpose, attributes: ["permutation": .integers([0, 1, 1, 3])])
	}

	private func assertEmissionFails(
		kind: NativeModelOperationKind,
		attributes: [String: NativeModelAttribute],
		file: StaticString = #filePath,
		line: UInt = #line
	) {
		let graph = NativeModelGraph(
			formatVersion: NativeModelGraph.currentFormatVersion,
			producer: NativeModelGraphProducer(name: "test", version: "1"),
			inputs: [NativeModelTensor(name: "x", dataType: .float32, shape: [1, 4, 1, 1])],
			weights: [],
			operations: [
				NativeModelOperation(
					name: "y", kind: kind, inputs: ["x"],
					outputs: [NativeModelTensor(name: "y", dataType: .float32, shape: [1, 4, 1, 1])],
					attributes: attributes
				)
			],
			outputs: ["y"]
		)
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mlmodel")
		defer { try? FileManager.default.removeItem(at: url) }
		XCTAssertThrowsError(
			try NativeModelCoreMLEmitter().emit(graph: graph, weights: Data(), to: url),
			"A malformed \(kind.serializedValue) must be rejected, not emitted.",
			file: file, line: line
		)
	}
}
