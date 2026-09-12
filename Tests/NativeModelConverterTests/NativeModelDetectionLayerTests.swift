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
		formatVersion: Int = NativeModelGraph.currentFormatVersion,
		inputShape: [Int],
		outputShape: [Int],
		values: [Float]
	) async throws -> [Float] {
		let input = NativeModelTensor(name: "x", dataType: .float32, shape: inputShape)
		let graph = NativeModelGraph(
			formatVersion: formatVersion,
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
		let outputs = try await predict(
			graph: graph, weights: weights, inputs: inputs, outputShapes: ["y": outputShape]
		)
		return try XCTUnwrap(outputs["y"])
	}

	/// The multi-output form. `topK` is why it exists: a harness that can only read a blob called `y`
	/// makes no assertion an emitter wiring output 0 alone would fail, so every declared output is read
	/// back by name and shape-checked.
	private func predict(
		graph: NativeModelGraph,
		weights: Data,
		inputs: [String: ([Int], [Float])],
		outputShapes: [String: [Int]]
	) async throws -> [String: [Float]] {
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
		var results: [String: [Float]] = [:]
		for (name, shape) in outputShapes {
			let output = try XCTUnwrap(prediction.featureValue(for: name)?.multiArrayValue)
			XCTAssertEqual(
				output.shape.map(\.intValue), shape,
				"The emitted '\(name)' shape drifted from the graph's declaration."
			)
			results[name] = (0 ..< output.count).map { output[$0].floatValue }
		}
		return results
	}

	private func assertClose(_ actual: [Float], _ expected: [Float], accuracy: Float = 0.0005, file: StaticString = #filePath, line: UInt = #line) {
		XCTAssertEqual(actual.count, expected.count, file: file, line: line)
		for (index, pair) in zip(actual, expected).enumerated() {
			XCTAssertEqual(pair.0, pair.1, accuracy: accuracy, "element \(index)", file: file, line: line)
		}
	}

	/// Accumulates an exact-ND graph whose blobs all share one shape — the row-per-box shape the box
	/// arithmetic below works in. A bound or coefficient becomes a `constantND` repeated over the whole
	/// blob rather than a scalar, because classic add (230) and multiply (231) are per-position layers
	/// with no broadcasting. The one-operation `run` harness cannot express these chains.
	private struct BoxArithmeticGraph {
		let shape: [Int]
		private(set) var weightData = Data()
		private var weights: [NativeModelWeight] = []
		private var operations: [NativeModelOperation] = []

		init(shape: [Int]) {
			self.shape = shape
		}

		mutating func constant(_ value: Float, name: String) -> String {
			let values = [Float](repeating: value, count: shape.reduce(1, *))
			let payload = values.withUnsafeBytes { Data($0) }
			let weightName = "\(name)_values"
			weights.append(NativeModelWeight(
				name: weightName, dataType: .float32, shape: shape,
				offset: UInt64(weightData.count), byteCount: UInt64(payload.count)
			))
			weightData.append(payload)
			return apply(.constantND, [weightName], name: name)
		}

		@discardableResult
		mutating func apply(
			_ kind: NativeModelOperationKind,
			_ inputs: [String],
			name: String,
			attributes: [String: NativeModelAttribute] = [:],
			shape outputShape: [Int]? = nil
		) -> String {
			operations.append(NativeModelOperation(
				name: name, kind: kind, inputs: inputs,
				outputs: [NativeModelTensor(name: name, dataType: .float32, shape: outputShape ?? shape)],
				attributes: attributes
			))
			return name
		}

		func graph(inputs: [String], output: String) -> NativeModelGraph {
			NativeModelGraph(
				formatVersion: NativeModelGraph.exactNDFormatVersion,
				producer: NativeModelGraphProducer(name: "test", version: "1"),
				inputs: inputs.map { NativeModelTensor(name: $0, dataType: .float32, shape: shape) },
				weights: weights,
				operations: operations,
				outputs: [output]
			)
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

	func testSliceChannels_atRank3SplitsTheChannelAxis() async throws {
		// Under the legacy declaration convention the reshape/transpose tests use, a plain multi-array is
		// declared rank-3 [C, H, W]: five channels of a 2×1 grid, slicing channels [1, 3) keeps two intact.
		let output = try await run(
			operation: .sliceChannels, attributes: ["startChannel": .integer(1), "endChannel": .integer(3)],
			inputShape: [5, 2, 1], outputShape: [2, 2, 1],
			values: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
		)
		assertClose(output, [3, 4, 5, 6])
	}

	// MARK: - Upsample

	func testUpsample_nearestNeighborRepeatsSamples2x() async throws {
		// A 2×2 grid upsampled 2× must repeat each sample into a 2×2 block — the field-210 proof that
		// the classic Core ML upsample layer nearest-samples `out[i, j] = in[i / f, j / f]`.
		let output = try await run(
			operation: .upsample2D, attributes: ["scalingFactor": .integers([2, 2])],
			inputShape: [1, 1, 2, 2], outputShape: [1, 1, 4, 4],
			values: [1, 2, 3, 4]
		)
		assertClose(output, [
			1, 1, 2, 2,
			1, 1, 2, 2,
			3, 3, 4, 4,
			3, 3, 4, 4
		])
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

	func testMultiply_withFullSpatialConstant_scalesPerPosition() async throws {
		// The spatial-constant expansion (YOLOv8's stride table) emits a full `[C, H, W]` load-constant
		// and a *same-shape* multiply, a layout the earlier `[C, 1, 1]` constants never exercised. This
		// proves classic Core ML multiply is genuinely per-position over two equal `[C, H, W]` tensors.
		let constantValues: [Float] = [1, 2, 3, 4, 5, 6]
		let weights = constantValues.withUnsafeBytes { Data($0) }
		let graph = NativeModelGraph(
			formatVersion: NativeModelGraph.currentFormatVersion,
			producer: NativeModelGraphProducer(name: "test", version: "1"),
			inputs: [NativeModelTensor(name: "x", dataType: .float32, shape: [1, 2, 1, 3])],
			weights: [
				NativeModelWeight(name: "k", dataType: .float32, shape: [2, 1, 3], offset: 0, byteCount: UInt64(weights.count))
			],
			operations: [
				NativeModelOperation(
					name: "c", kind: .constant, inputs: ["k"],
					outputs: [NativeModelTensor(name: "c", dataType: .float32, shape: [2, 1, 3])], attributes: [:]
				),
				NativeModelOperation(
					name: "y", kind: .multiply, inputs: ["x", "c"],
					outputs: [NativeModelTensor(name: "y", dataType: .float32, shape: [1, 2, 1, 3])], attributes: [:]
				)
			],
			outputs: ["y"]
		)
		let output = try await predict(
			graph: graph, weights: weights,
			inputs: ["x": ([1, 2, 1, 3], [10, 20, 30, 40, 50, 60])], outputShape: [1, 2, 1, 3]
		)
		assertClose(output, [10, 40, 90, 160, 250, 360])
	}

	// MARK: - Elementwise and mask primitives

	// These are exact-ND only: the classic layer set has no floor, no comparison, and no subtract, so
	// each is a spec-4 layer and each is rejected under format version 1 (see the rejection section).

	func testFloor_roundsTowardNegativeInfinity() async throws {
		// Toward negative infinity, not toward zero: a box below the canonical scale reaches `floor`
		// with a negative level, where truncation would round it up into the wrong FPN level.
		let output = try await run(
			operation: .floor, formatVersion: NativeModelGraph.exactNDFormatVersion,
			inputShape: [1, 4], outputShape: [1, 4],
			values: [-1.5, -0.25, 0.5, 3]
		)
		assertClose(output, [-2, -1, 0, 3])
	}

	func testNaturalLogarithm_isBaseEAndNotBaseTwo() async throws {
		// ln(2) = 0.6931, log2(2) = 1: the unary type must be LOG (5) and the base conversion must stay
		// an explicit multiply, otherwise every level assignment is off by a factor of ln 2.
		let output = try await run(
			operation: .naturalLogarithm, formatVersion: NativeModelGraph.exactNDFormatVersion,
			inputShape: [1, 4], outputShape: [1, 4],
			values: [1, 2, 2.718282, 0.5]
		)
		assertClose(output, [0, 0.693147, 1, -0.693147], accuracy: 0.0001)
	}

	func testGreaterOrEqual_isInclusiveAtTheThreshold() async throws {
		// `>=`, not `>`. The boundary sample is the whole difference between this layer (832) and the
		// strictly-greater one two field numbers below it (830), and it decides whether a box exactly
		// at the minimum size survives.
		let output = try await run(
			operation: .greaterOrEqual, attributes: ["threshold": .floatingPoint(3)],
			formatVersion: NativeModelGraph.exactNDFormatVersion,
			inputShape: [1, 4], outputShape: [1, 4],
			values: [2.5, 3, 3.5, -1]
		)
		assertClose(output, [0, 1, 1, 0])
	}

	func testMinimumAndMaximum_boundAgainstAConstantTensor() async throws {
		var builder = BoxArithmeticGraph(shape: [1, 4])
		let lower = builder.constant(1, name: "lower")
		let upper = builder.constant(3, name: "upper")
		let raised = builder.apply(.maximumND, ["x", lower], name: "raised")
		builder.apply(.minimumND, [raised, upper], name: "y")

		let output = try await predict(
			graph: builder.graph(inputs: ["x"], output: "y"), weights: builder.weightData,
			inputs: ["x": ([1, 4], [0, 1.5, 2.5, 9])], outputShape: [1, 4]
		)
		// Both ends bound, and the interior values pass through untouched — 870 and 875 must not be swapped.
		assertClose(output, [1, 1.5, 2.5, 3])
	}

	func testSubtract_isLeftMinusRight() async throws {
		// The emitter had no case for subtract at all until the box arithmetic needed one, even though
		// the graph validator has always accepted it. A reversed operand order still compiles.
		var builder = BoxArithmeticGraph(shape: [1, 3])
		let offset = builder.constant(1.5, name: "offset")
		builder.apply(.subtract, ["x", offset], name: "y")

		let output = try await predict(
			graph: builder.graph(inputs: ["x"], output: "y"), weights: builder.weightData,
			inputs: ["x": ([1, 3], [1, 2, 3])], outputShape: [1, 3]
		)
		assertClose(output, [-0.5, 0.5, 1.5])
	}

	// MARK: - Box post-processing compositions

	func testLevelAssignment_productFreeFormMatchesTorchvision() async throws {
		// torchvision's LevelMapper (`ops/poolers.py`) assigns
		// floor(4 + log2(sqrt(w·h) / 224) + 1e-6), clamped to [2, 5]. The graph evaluates the
		// product-free form 4 + 0.5·log2(w) + 0.5·log2(h) − log2(224) + 1e-6, which never forms the
		// area: three of these six boxes have an area above fp16's 65504 (120000, 720000, 1200000) and
		// would come out of an fp16 area as infinity, while every intermediate here stays under 21.
		//
		// The two forms are equal in exact arithmetic and *not* in float32 — they accumulate different
		// rounding — so the epsilon is not decoration carried over for symmetry. It is what keeps the
		// two on the same side of `floor` at the sizes where the difference lands, which
		// `testLevelAssignment_agreesWithTorchvisionOnTheCanonicalScale` below measures directly.
		//
		// Fixture: `.venv-m3a` python (torch 2.8.0, torchvision 0.23.0), levels taken from the mapper's
		// own expression.
		let widths: [Float] = [10, 32, 100, 300, 800, 1200]
		let heights: [Float] = [8, 32, 150, 400, 900, 1000]
		var builder = BoxArithmeticGraph(shape: [1, 6])
		let halfInverseLn2 = builder.constant(0.5 / Float(log(2.0)), name: "half_inverse_ln2")
		let canonicalLevel = builder.constant(4, name: "canonical_level")
		let canonicalScale = builder.constant(Float(log2(224.0)), name: "canonical_scale")
		let epsilon = builder.constant(1e-6, name: "epsilon")
		let lowestLevel = builder.constant(2, name: "lowest_level")
		let highestLevel = builder.constant(5, name: "highest_level")
		let logWidth = builder.apply(.naturalLogarithm, ["w"], name: "log_width")
		let logHeight = builder.apply(.naturalLogarithm, ["h"], name: "log_height")
		let halfLog2Width = builder.apply(.multiply, [logWidth, halfInverseLn2], name: "half_log2_width")
		let halfLog2Height = builder.apply(.multiply, [logHeight, halfInverseLn2], name: "half_log2_height")
		let halfLog2Area = builder.apply(.add, [halfLog2Width, halfLog2Height], name: "half_log2_area")
		let biased = builder.apply(.add, [halfLog2Area, canonicalLevel], name: "biased")
		let level = builder.apply(.subtract, [biased, canonicalScale], name: "level")
		let nudged = builder.apply(.add, [level, epsilon], name: "nudged")
		let floored = builder.apply(.floor, [nudged], name: "floored")
		let raised = builder.apply(.maximumND, [floored, lowestLevel], name: "raised")
		builder.apply(.minimumND, [raised, highestLevel], name: "y")

		let output = try await predict(
			graph: builder.graph(inputs: ["w", "h"], output: "y"), weights: builder.weightData,
			inputs: ["w": ([1, 6], widths), "h": ([1, 6], heights)], outputShape: [1, 6]
		)
		// Pre-clamp values are −0.65, 1.19, 3.13, 4.63, 5.92, 6.29 — both clamps are exercised.
		assertClose(output, [2, 2, 3, 4, 5, 5])
	}

	func testLevelAssignment_agreesWithTorchvisionOnTheCanonicalScale() async throws {
		// The sizes the test above avoids, and the reason the epsilon is in the composition at all.
		//
		// Every box here has sqrt(w·h) an exact power of two times 224, so torchvision's level lands
		// exactly on an integer and `floor` is deciding between it and the integer below. In float32
		// the product-free form does not reach that integer from the same side: 0.5·log2(w) +
		// 0.5·log2(h) − log2(224) evaluates to a few ulps *below* zero for a 224 × 224 box where
		// torchvision's log2(sqrt(w·h)/224) evaluates to exactly zero. Without the 1e-6 the graph
		// therefore floors to 3 where torchvision floors to 4 — a full level, on the canonical scale
		// the whole formula is defined around, sending those ROIs to the wrong FPN stride.
		//
		// This is not a rare-input concern that random testing would have surfaced: 20 000 randomly
		// sized boxes disagree zero times, because a random float essentially never lands on the
		// boundary. Only these sizes show it, which is why they are pinned here rather than left to a
		// sweep. Measured in float32 with `.venv-m3a` (numpy 2.x, torchvision 0.23.0); each expectation
		// is torchvision's LevelMapper output for that box, clamped to [2, 5].
		let widths: [Float] = [224, 112, 56, 224, 56, 448]
		let heights: [Float] = [224, 112, 224, 56, 56, 448]
		var builder = BoxArithmeticGraph(shape: [1, 6])
		let halfInverseLn2 = builder.constant(0.5 / Float(log(2.0)), name: "half_inverse_ln2")
		let canonicalLevel = builder.constant(4, name: "canonical_level")
		let canonicalScale = builder.constant(Float(log2(224.0)), name: "canonical_scale")
		let epsilon = builder.constant(1e-6, name: "epsilon")
		let lowestLevel = builder.constant(2, name: "lowest_level")
		let highestLevel = builder.constant(5, name: "highest_level")
		let logWidth = builder.apply(.naturalLogarithm, ["w"], name: "log_width")
		let logHeight = builder.apply(.naturalLogarithm, ["h"], name: "log_height")
		let halfLog2Width = builder.apply(.multiply, [logWidth, halfInverseLn2], name: "half_log2_width")
		let halfLog2Height = builder.apply(.multiply, [logHeight, halfInverseLn2], name: "half_log2_height")
		let halfLog2Area = builder.apply(.add, [halfLog2Width, halfLog2Height], name: "half_log2_area")
		let biased = builder.apply(.add, [halfLog2Area, canonicalLevel], name: "biased")
		let level = builder.apply(.subtract, [biased, canonicalScale], name: "level")
		let nudged = builder.apply(.add, [level, epsilon], name: "nudged")
		let floored = builder.apply(.floor, [nudged], name: "floored")
		let raised = builder.apply(.maximumND, [floored, lowestLevel], name: "raised")
		builder.apply(.minimumND, [raised, highestLevel], name: "y")

		let output = try await predict(
			graph: builder.graph(inputs: ["w", "h"], output: "y"), weights: builder.weightData,
			inputs: ["w": ([1, 6], widths), "h": ([1, 6], heights)], outputShape: [1, 6]
		)
		// Remove the `nudged` node and this becomes [3, 2, 2, 2, 2, 4] — every entry one level low.
		assertClose(output, [4, 3, 3, 3, 2, 5])
	}

	func testSmallBoxMask_requiresBothSidesAndKeepsTheBoundary() async throws {
		// torchvision's remove_small_boxes keeps a box when (w >= min_size) AND (h >= min_size) — two
		// per-side comparisons, not one area threshold. Box 3 is 10 × 3.5, an area of 35 against a
		// min_size² of 16, and is still dropped; box 0 is exactly 4 wide, which `>` would drop and `>=`
		// keeps. Fixture: torchvision 0.23.0 `remove_small_boxes` under `.venv-m3a`.
		let widths: [Float] = [4, 3.9, 10, 10, 5]
		let heights: [Float] = [10, 10, 4, 3.5, 5]
		var builder = BoxArithmeticGraph(shape: [1, 5])
		let wideEnough = builder.apply(
			.greaterOrEqual, ["w"], name: "wide_enough", attributes: ["threshold": .floatingPoint(4)]
		)
		let tallEnough = builder.apply(
			.greaterOrEqual, ["h"], name: "tall_enough", attributes: ["threshold": .floatingPoint(4)]
		)
		// Both masks are 0/1, so the product is their logical AND.
		builder.apply(.multiply, [wideEnough, tallEnough], name: "y")

		let output = try await predict(
			graph: builder.graph(inputs: ["w", "h"], output: "y"), weights: builder.weightData,
			inputs: ["w": ([1, 5], widths), "h": ([1, 5], heights)], outputShape: [1, 5]
		)
		assertClose(output, [1, 0, 1, 0, 1])
	}

	func testBoxClip_boundsEachAxisToItsOwnImageSide() async throws {
		// `clip_boxes_to_image` on a 640 × 384 image: x into [0, 640], y into [0, 384]. A scalar Clip
		// layer carries one interval for the whole blob, so it cannot express this at all once W != H —
		// the reason the bound is a tensor operand here. Fixture: torchvision 0.23.0 under `.venv-m3a`.
		let horizontal: [Float] = [-5, 0, 100, 700, 640]
		let vertical: [Float] = [-10, 20, 400, 384, 383]
		var builder = BoxArithmeticGraph(shape: [1, 5])
		let zero = builder.constant(0, name: "zero")
		let imageWidth = builder.constant(640, name: "image_width")
		let imageHeight = builder.constant(384, name: "image_height")
		let leftRaised = builder.apply(.maximumND, ["left", zero], name: "left_raised")
		let leftClipped = builder.apply(.minimumND, [leftRaised, imageWidth], name: "left_clipped")
		let topRaised = builder.apply(.maximumND, ["top", zero], name: "top_raised")
		let topClipped = builder.apply(.minimumND, [topRaised, imageHeight], name: "top_clipped")
		builder.apply(
			.concatenateND, [leftClipped, topClipped], name: "y",
			attributes: ["axis": .integer(1)], shape: [1, 10]
		)

		let output = try await predict(
			graph: builder.graph(inputs: ["left", "top"], output: "y"), weights: builder.weightData,
			inputs: ["left": ([1, 5], horizontal), "top": ([1, 5], vertical)], outputShape: [1, 10]
		)
		// A shared bound would have let y reach 640; each axis stops at its own side.
		assertClose(output, [0, 0, 100, 640, 640, 0, 20, 384, 384, 383])
	}

	func testScoreMask_pushesDroppedRowsBelowEveryKeptOne() async throws {
		// score' = score·mask + (mask − 1)·BIG: a dropped row is zeroed and then driven to −BIG, so a
		// following top-k or suppression can never select it. Every blob keeps the same shape, which is
		// what classic add (230) and multiply (231) require — they are per-position, not broadcasting.
		let scores: [Float] = [0.9, 0.5, 0.49, 0.1]
		var builder = BoxArithmeticGraph(shape: [1, 4])
		let one = builder.constant(1, name: "one")
		let big = builder.constant(1000, name: "big")
		let mask = builder.apply(
			.greaterOrEqual, ["score"], name: "mask", attributes: ["threshold": .floatingPoint(0.5)]
		)
		let kept = builder.apply(.multiply, ["score", mask], name: "kept")
		let dropped = builder.apply(.subtract, [mask, one], name: "dropped")
		let penalty = builder.apply(.multiply, [dropped, big], name: "penalty")
		builder.apply(.add, [kept, penalty], name: "y")

		let output = try await predict(
			graph: builder.graph(inputs: ["score"], output: "y"), weights: builder.weightData,
			inputs: ["score": ([1, 4], scores)], outputShape: [1, 4]
		)
		// 0.5 is kept because the comparison is inclusive; 0.49 lands at exactly −1000, not −999.51,
		// because the multiply zeroes the score before the penalty is added.
		assertClose(output, [0.9, 0.5, -1000, -1000], accuracy: 0.001)
	}

	// MARK: - ROI feature extraction

	func testAveragePool_averagesEachWindowAndKeepsTheNonSquareShape() async throws {
		// AVERAGE is `PoolingLayerParams.type` 1; leaving the field at its proto3 default emits MAX, which
		// on this input returns 8, 10, 12, 20, 22, 24 — plausible, larger, and wrong. The 4x6 input pooled
		// to 2x3 also catches a kernel/stride pair written height-last.
		let output = try await run(
			operation: .averagePool2D,
			attributes: [
				"kernelSize": .integers([2, 2]),
				"strides": .integers([2, 2]),
				"padding": .integers([0, 0])
			],
			inputShape: [1, 1, 4, 6], outputShape: [1, 1, 2, 3],
			values: (1 ... 24).map(Float.init)
		)
		assertClose(output, [4.5, 6.5, 8.5, 16.5, 18.5, 20.5])
	}

	func testAveragePool_dividesByTheRealSamplesOnly() async throws {
		// The pinned `avgPoolExcludePadding` (field 50), made observable. A 3x3 window at stride 2 over a
		// padded 4x4 sees 4, 6, 6 and 9 real cells; excluding the padding divides by those counts, giving
		// 14/4, 30/6, 57/6, 99/9. Including it would divide all four by 9 — 1.56, 3.33, 6.33, 11 — which
		// is ONNX AveragePool's `count_include_pad=1` and PyTorch's default, and is not what is emitted.
		let output = try await run(
			operation: .averagePool2D,
			attributes: [
				"kernelSize": .integers([3, 3]),
				"strides": .integers([2, 2]),
				"padding": .integers([1, 1])
			],
			inputShape: [1, 1, 4, 4], outputShape: [1, 1, 2, 2],
			values: (1 ... 16).map(Float.init)
		)
		assertClose(output, [3.5, 5, 9.5, 11])
	}

	func testCropResize_overARampMatchesTheAnalyticSamplingGrid() async throws {
		// The coordinate-convention control, and the only test with a non-square target. Channel 0 of the
		// feature map is the row index and channel 1 the column index; bilinear interpolation is exact on
		// an affine function and a bin's 2x2 sub-samples are symmetric about its centre, so every output
		// cell must come out as its own sample position — analytically `start + (i + 0.5) * extent`. A
		// swapped box packing then shows up as channel 0 varying along the wrong axis, and a `targetSize`
		// written width-first as a 6x4 patch, neither of which a square target could tell apart.
		// [x0, y0, x1, y1] = [1.5, 2.25, 7.5, 6.75], packed CORNERS_HEIGHT_FIRST as [y0, x0, y1, x1].
		let output = try await roiAlign(
			featureShape: [1, 1, 2, Self.rampSide, Self.rampSide], features: Self.coordinateRamp,
			boxes: [[2.25, 1.5, 6.75, 7.5]], outputHeight: 4, outputWidth: 6
		)
		assertClose(output, Self.rampSamplingGrid(outputHeight: 4, outputWidth: 6))
	}

	func testCropResize_appliesTheSpatialScaleToTheBoxCoordinates() async throws {
		// Boxes arrive in *image* coordinates and `spatialScale` converts them to feature pixels — in a
		// real FPN it is the level's stride reciprocal, so it differs per level and a dropped one is not
		// visible at the 1.0 the tests above use. Doubling the box and halving the scale must land on the
		// identical sampling grid; a scale that divided instead of multiplied would sample four times out.
		let output = try await roiAlign(
			featureShape: [1, 1, 2, Self.rampSide, Self.rampSide], features: Self.coordinateRamp,
			boxes: [[4.5, 3, 13.5, 15]], outputHeight: 4, outputWidth: 6, spatialScale: 0.5
		)
		assertClose(output, Self.rampSamplingGrid(outputHeight: 4, outputWidth: 6))
	}

	private static let rampSide = 10

	/// Channel 0 is the row index and channel 1 the column index, shaped `[1, 1, 2, 10, 10]`.
	private static let coordinateRamp: [Float] = {
		var ramp = [Float](repeating: 0, count: 2 * rampSide * rampSide)
		for row in 0 ..< rampSide {
			for column in 0 ..< rampSide {
				ramp[row * rampSide + column] = Float(row)
				ramp[rampSide * rampSide + row * rampSide + column] = Float(column)
			}
		}
		return ramp
	}()

	/// The sample position of every output cell for the ROI `[x0, y0, x1, y1] = [1.5, 2.25, 7.5, 6.75]`,
	/// which is what the coordinate ramp must reproduce: channel 0 the row, channel 1 the column.
	private static func rampSamplingGrid(outputHeight: Int, outputWidth: Int) -> [Float] {
		let cells = outputHeight * outputWidth
		var expected = [Float](repeating: 0, count: 2 * cells)
		let rowExtent = (6.75 - 2.25) / Float(outputHeight)
		let columnExtent = (7.5 - 1.5) / Float(outputWidth)
		for row in 0 ..< outputHeight {
			for column in 0 ..< outputWidth {
				expected[row * outputWidth + column] = 2.25 + (Float(row) + 0.5) * rowExtent
				expected[cells + row * outputWidth + column] = 1.5 + (Float(column) + 0.5) * columnExtent
			}
		}
		return expected
	}

	func testCropResizeThenAveragePool_matchesTorchvisionRoIAlign() async throws {
		// The RoIAlign construction, end to end: `cropResize` at 14x14 followed by a 2x2 average pool is
		// `roi_align(output_size=7, sampling_ratio=2, aligned=False)`, because that sampling ratio averages
		// exactly the 2x2 bilinear sub-samples the 14x14 crop grid lands on. Two boxes, so a K-indexing
		// mistake in the [K, 1, 4, 1, 1] box blob cannot pass as a coordinate error.
		//
		// Fixture: `.venv-m3a` python (torch 2.8.0, torchvision 0.23.0, coremltools 9.0) — feature map
		// seeded with numpy default_rng(20260820), expected values from `torchvision.ops.roi_align`
		// itself. Both boxes are interior: `criterion_edge_rois.overhang` reports 0.0 for each, so the
		// boundary divergence the next test pins plays no part here.
		let output = try await roiAlign(
			featureShape: [1, 1, 1, 8, 8], features: Self.featureMap8x8,
			boxes: [[0.75, 1.5, 5.5, 6.25], [3.5, 2, 6.9, 6.75]], outputHeight: 7, outputWidth: 7
		)
		assertClose(output, [
			4.19382, 3.70912, 3.38148, 3.47984, 3.65668, 3.81946, 3.81178,
			2.49284, 2.60012, 2.83532, 3.3557, 2.58873, 2.19378, 3.14934,
			1.80274, 2.19287, 2.51383, 2.73358, 2.37198, 2.19137, 2.65162,
			2.03919, 2.41547, 2.50567, 2.22828, 2.63821, 2.85526, 2.34388,
			3.38059, 3.40899, 3.12648, 2.88494, 2.80706, 2.65432, 2.31443,
			3.54529, 3.91925, 3.91715, 3.59509, 3.13916, 2.90404, 3.15978,
			3.35744, 4.08551, 4.38203, 3.91671, 3.14457, 2.94876, 3.94358,
			3.38166, 3.13471, 2.87955, 2.78347, 2.74488, 2.37677, 2.4409,
			3.85536, 3.66096, 3.4028, 3.08423, 2.77569, 2.70077, 2.9029,
			3.9143, 4.21637, 3.94176, 3.4388, 3.01275, 3.46278, 3.62136,
			3.92331, 4.35561, 4.01086, 3.31685, 2.76467, 3.72086, 3.90918,
			3.86102, 3.90031, 3.40877, 2.51415, 1.82355, 3.25905, 3.58179,
			3.63306, 3.46475, 3.10517, 2.29336, 1.58238, 2.8953, 3.22461,
			3.10138, 3.06538, 3.34881, 3.13941, 2.62447, 2.71132, 2.81282
		])
	}

	func testCropResize_zeroesSamplesPastTheFeatureMapEdge() async throws {
		// A known, measured divergence from `roi_align`, pinned so a Core ML runtime change is caught.
		// The box [3, 3, 8, 8] over an 8x8 map samples up to 0.82 feature pixels past the last
		// interpolable row and column (index 7): `roi_align` CLAMPS there, replicating the edge, while
		// CropResize contributes exactly zero. Every value in this feature map is positive, so the whole
		// last output row and column coming out as 0 is unmistakably the zeroing rule and not a clamp.
		//
		// Measured, not assumed: `scripts/m3a_parity_spike/criterion_edge_rois.py` reproduced each
		// operator with its own numpy behavioural model and reports the divergence at 0.13–0.34 relative
		// on edge-touching and overhanging populations (`results/criterion_edge_rois.json`); this single
		// deliberately overhanging box sits at 0.38. M3c closes it with a replicate ring plus a
		// one-feature-pixel ROI shift — a zero ring, the obvious-looking fix, only halves it.
		//
		// Fixture: `.venv-m3a` python (coremltools 9.0), expected values from that file's
		// `crop_resize_zero` behavioural model, confirmed against a compiled CropResize to 5.8e-07.
		let output = try await roiAlign(
			featureShape: [1, 1, 1, 8, 8], features: Self.featureMap8x8,
			boxes: [[3, 3, 8, 8]], outputHeight: 7, outputWidth: 7
		)
		assertClose(output, [
			2.62765, 2.44405, 2.84981, 2.60639, 2.24, 1.14053, 0,
			3.35901, 3.09221, 2.8306, 2.61105, 2.60239, 1.46688, 0,
			4.20815, 3.76224, 3.09379, 3.35661, 3.77466, 1.82236, 0,
			3.90329, 3.25042, 2.18425, 2.9335, 3.85429, 1.72625, 0,
			3.28899, 2.80259, 1.69617, 2.39286, 3.3087, 1.49013, 0,
			1.58055, 1.73336, 1.48419, 1.35687, 1.34281, 0.704453, 0,
			0, 0, 0, 0, 0, 0, 0
		])
	}

	func testReplicatedRingAndFeaturePixelShift_matchTorchvisionAtTheFeatureMapEdge() async throws {
		// This is the assembled correction for the preceding regression: copy the four boundary edges
		// into a one-feature-pixel ring, then add one feature pixel to *every* ROI coordinate before
		// CropResize. `spatialScale` is deliberately 0.25, so the constant must be four image pixels;
		// adding one in image space would move the ROI by only a quarter of a feature pixel and leave the
		// boundary error intact. The expected values come directly from torchvision's `roi_align` for the
		// original (unshifted) 8×8 feature map and `[3, 3, 8, 8]` edge-touching ROI.
		let output = try await replicatedROIAlign(
			featureShape: [1, 1, 1, 8, 8], features: Self.featureMap8x8,
			boxes: [[12, 12, 32, 32]], outputHeight: 7, outputWidth: 7, spatialScale: 0.25
		)
		assertClose(output, [
			2.62765, 2.44405, 2.84981, 2.60639, 2.24, 2.29063, 2.30021,
			3.35901, 3.09221, 2.8306, 2.61105, 2.60239, 3.01107, 3.08839,
			4.20815, 3.76224, 3.09379, 3.35661, 3.77466, 3.61439, 3.58407,
			3.90329, 3.25042, 2.18425, 2.9335, 3.85429, 3.35875, 3.265,
			3.28899, 2.80259, 1.69617, 2.39286, 3.3087, 2.90363, 2.827,
			3.13127, 3.62169, 3.26522, 2.78863, 2.54024, 2.83583, 2.89175,
			3.10143, 3.77666, 3.56207, 2.8635, 2.39486, 2.823, 2.904
		])
	}

	/// The seeded 8x8 feature map shared by the interior-parity and edge-behaviour tests, so the only
	/// thing that differs between them is where the box sits. Every value is positive by construction
	/// (`default_rng(20260820).normal() + 3`), which is what makes a zeroed output cell legible.
	private static let featureMap8x8: [Float] = [
		3.967, 4.601, 3.219, 4.144, 1.577, 3.124, 3.967, 3.932,
		3.03, 5.258, 4.468, 3.46, 3.586, 4.237, 4.04, 1.182,
		4.949, 1.428, 1.94, 2.429, 3.498, 1.114, 3.164, 3.375,
		3.31, 0.859, 1.905, 2.46, 1.944, 3.151, 2.23, 1.872,
		3.11, 2.411, 4.058, 3.379, 3.049, 2.698, 2.212, 3.071,
		3.63, 1.84, 3.571, 4.685, 4.073, 2.938, 4.267, 3.724,
		3.256, 2.633, 3.894, 3.678, 2.732, 0.766, 3.763, 2.806,
		5.438, 1.483, 2.76, 2.66, 3.896, 3.471, 2.256, 2.904
	]

	/// The RoIAlign construction as a two-operation graph: `cropResize` at twice the target size, then a
	/// 2x2 `averagePool2D`. It stays a composition rather than one fused operation so neither half is
	/// welded to a single sampling ratio. `boxes` rows are CORNERS_HEIGHT_FIRST — `[y0, x0, y1, x1]` —
	/// laid into the `[K, 1, 4, 1, 1]` blob the layer requires.
	private func roiAlign(
		featureShape: [Int],
		features: [Float],
		boxes: [[Float]],
		outputHeight: Int,
		outputWidth: Int,
		spatialScale: Double = 1
	) async throws -> [Float] {
		let batch = featureShape[1]
		let channels = featureShape[2]
		let (cropHeight, cropWidth) = (outputHeight * 2, outputWidth * 2)
		let boxShape = [boxes.count, 1, 4, 1, 1]
		let outputShape = [boxes.count, batch, channels, outputHeight, outputWidth]
		let graph = NativeModelGraph(
			formatVersion: NativeModelGraph.exactNDFormatVersion,
			producer: NativeModelGraphProducer(name: "test", version: "1"),
			inputs: [
				NativeModelTensor(name: "features", dataType: .float32, shape: featureShape),
				NativeModelTensor(name: "rois", dataType: .float32, shape: boxShape)
			],
			weights: [],
			operations: [
				NativeModelOperation(
					name: "cropped", kind: .cropResize, inputs: ["features", "rois"],
					outputs: [NativeModelTensor(
						name: "cropped", dataType: .float32,
						shape: [boxes.count, batch, channels, cropHeight, cropWidth]
					)],
					attributes: [
						"targetHeight": .integer(cropHeight),
						"targetWidth": .integer(cropWidth),
						"spatialScale": .floatingPoint(spatialScale)
					]
				),
				NativeModelOperation(
					name: "y", kind: .averagePool2D, inputs: ["cropped"],
					outputs: [NativeModelTensor(name: "y", dataType: .float32, shape: outputShape)],
					attributes: [
						"kernelSize": .integers([2, 2]),
						"strides": .integers([2, 2]),
						"padding": .integers([0, 0])
					]
				)
			],
			outputs: ["y"]
		)
		return try await predict(
			graph: graph, weights: Data(),
			inputs: ["features": (featureShape, features), "rois": (boxShape, boxes.flatMap { $0 })],
			outputShape: outputShape
		)
	}

	/// The M3c edge construction as graph operations: static slices select the outer rows and columns,
	/// concatenation duplicates them into a replicate ring, and the ROI shift lands the old feature-map
	/// origin at `[1, 1]` in that ring. CropResize then sees the same clampable values as torchvision.
	private func replicatedROIAlign(
		featureShape: [Int],
		features: [Float],
		boxes: [[Float]],
		outputHeight: Int,
		outputWidth: Int,
		spatialScale: Double
	) async throws -> [Float] {
		let batch = featureShape[1]
		let channels = featureShape[2]
		let height = featureShape[3]
		let width = featureShape[4]
		let (cropHeight, cropWidth) = (outputHeight * 2, outputWidth * 2)
		let boxShape = [boxes.count, 1, 4, 1, 1]
		let outputShape = [boxes.count, batch, channels, outputHeight, outputWidth]
		let ringWidth = width + 2
		let horizontalShape = [1, batch, channels, height, ringWidth]
		let paddedShape = [1, batch, channels, height + 2, ringWidth]
		let shift = [Float](repeating: Float(1 / spatialScale), count: boxes.count * 4)
		let shiftData = shift.withUnsafeBytes { Data($0) }
		let shiftWeight = NativeModelWeight(
			name: "roi_shift.values", dataType: .float32, shape: boxShape,
			offset: 0, byteCount: UInt64(shiftData.count)
		)
		func slice(
			_ name: String,
			input: String,
			begin: [Int],
			end: [Int],
			shape: [Int]
		) -> NativeModelOperation {
			NativeModelOperation(
				name: name, kind: .sliceND, inputs: [input],
				outputs: [NativeModelTensor(name: name, dataType: .float32, shape: shape)],
				attributes: ["beginIds": .integers(begin), "endIds": .integers(end), "strides": .integers([1, 1, 1, 1, 1])]
			)
		}
		let graph = NativeModelGraph(
			formatVersion: NativeModelGraph.exactNDFormatVersion,
			producer: NativeModelGraphProducer(name: "test", version: "1"),
			inputs: [
				NativeModelTensor(name: "features", dataType: .float32, shape: featureShape),
				NativeModelTensor(name: "rois", dataType: .float32, shape: boxShape)
			],
			weights: [shiftWeight],
			operations: [
				slice("left", input: "features", begin: [0, 0, 0, 0, 0], end: [1, batch, channels, height, 1], shape: [1, batch, channels, height, 1]),
				slice("right", input: "features", begin: [0, 0, 0, 0, width - 1], end: [1, batch, channels, height, width], shape: [1, batch, channels, height, 1]),
				NativeModelOperation(
					name: "ring_columns", kind: .concatenateND, inputs: ["left", "features", "right"],
					outputs: [NativeModelTensor(name: "ring_columns", dataType: .float32, shape: horizontalShape)],
					attributes: ["axis": .integer(4)]
				),
				slice("top", input: "ring_columns", begin: [0, 0, 0, 0, 0], end: [1, batch, channels, 1, ringWidth], shape: [1, batch, channels, 1, ringWidth]),
				slice("bottom", input: "ring_columns", begin: [0, 0, 0, height - 1, 0], end: [1, batch, channels, height, ringWidth], shape: [1, batch, channels, 1, ringWidth]),
				NativeModelOperation(
					name: "replicate_ring", kind: .concatenateND, inputs: ["top", "ring_columns", "bottom"],
					outputs: [NativeModelTensor(name: "replicate_ring", dataType: .float32, shape: paddedShape)],
					attributes: ["axis": .integer(3)]
				),
				NativeModelOperation(
					name: "roi_shift", kind: .constantND, inputs: [shiftWeight.name],
					outputs: [NativeModelTensor(name: "roi_shift", dataType: .float32, shape: boxShape)], attributes: [:]
				),
				NativeModelOperation(
					name: "shifted_rois", kind: .add, inputs: ["rois", "roi_shift"],
					outputs: [NativeModelTensor(name: "shifted_rois", dataType: .float32, shape: boxShape)], attributes: [:]
				),
				NativeModelOperation(
					name: "cropped", kind: .cropResize, inputs: ["replicate_ring", "shifted_rois"],
					outputs: [NativeModelTensor(
						name: "cropped", dataType: .float32,
						shape: [boxes.count, batch, channels, cropHeight, cropWidth]
					)],
					attributes: [
						"targetHeight": .integer(cropHeight),
						"targetWidth": .integer(cropWidth),
						"spatialScale": .floatingPoint(spatialScale)
					]
				),
				NativeModelOperation(
					name: "y", kind: .averagePool2D, inputs: ["cropped"],
					outputs: [NativeModelTensor(name: "y", dataType: .float32, shape: outputShape)],
					attributes: [
						"kernelSize": .integers([2, 2]),
						"strides": .integers([2, 2]),
						"padding": .integers([0, 0])
					]
				)
			],
			outputs: ["y"]
		)
		return try await predict(
			graph: graph, weights: shiftData,
			inputs: ["features": (featureShape, features), "rois": (boxShape, boxes.flatMap { $0 })],
			outputShape: outputShape
		)
	}

	// MARK: - Multi-output arity

	func testSplitND_withThreeOutputsSplitsByItsOwnSizes() async throws {
		// The output-count rule became a table when `topK` joined `splitND` as a multi-output operation.
		// splitND's row is the one with no other unskipped coverage — the graphs that exercise it are the
		// fixture-gated trunk conversions — so this pins that an uneven three-way split is still admitted
		// and still cut at its declared sizes. A rule collapsed to "exactly one" or "exactly two" outputs
		// would reject this graph outright rather than mis-split it.
		let outputNames = ["first", "second", "third"]
		let outputShapes = [[1, 1], [1, 2], [1, 3]]
		let graph = NativeModelGraph(
			formatVersion: NativeModelGraph.exactNDFormatVersion,
			producer: NativeModelGraphProducer(name: "test", version: "1"),
			inputs: [NativeModelTensor(name: "x", dataType: .float32, shape: [1, 6])],
			weights: [],
			operations: [
				NativeModelOperation(
					name: "split", kind: .splitND, inputs: ["x"],
					outputs: zip(outputNames, outputShapes).map {
						NativeModelTensor(name: $0.0, dataType: .float32, shape: $0.1)
					},
					attributes: ["axis": .integer(1), "splitSizes": .integers([1, 2, 3])]
				)
			],
			outputs: outputNames
		)
		let outputs = try await predict(
			graph: graph, weights: Data(), inputs: ["x": ([1, 6], [1, 2, 3, 4, 5, 6])],
			outputShapes: Dictionary(uniqueKeysWithValues: zip(outputNames, outputShapes))
		)
		assertClose(try XCTUnwrap(outputs["first"]), [1])
		assertClose(try XCTUnwrap(outputs["second"]), [2, 3])
		assertClose(try XCTUnwrap(outputs["third"]), [4, 5, 6])
	}

	// MARK: - Proposal selection

	// `topK` picks the K best-scoring proposals and `gather` fetches the rows they name. Both are
	// exact-ND only: the classic layer set has neither, and gather's output rank varies with its index
	// blob (see the rejection section).

	func testTopK_returnsTheLargestValuesAndTheirSourceIndices() async throws {
		// Both outputs are asserted. A values-only emitter would satisfy everything an assertion about
		// the values can say — and Core ML rejects such a layer anyway — but one that wrote the two output
		// names in the wrong order compiles and hands the next operation ranks where scores belong, which
		// only the indices assertion catches.
		//
		// The six values are unique on purpose: nothing in `TopKLayerParams` orders equal values, so a tie
		// would be asserting an unspecified detail. Observed and deliberately NOT asserted: on this
		// runtime equal values come back in ascending source-index order.
		//
		// Fixture: `.venv-m3a` python (numpy 2.0.2, coremltools 9.0). Expected values are
		// `np.sort(x)[::-1][:3]` and indices `np.argsort(-x)[:3]`, confirmed identical to a compiled
		// `NeuralNetworkBuilder.add_topk(k=3, axis=1)` probe predicted on CPU.
		let outputs = try await topK(input: ([1, 6], [3, 9, 1, 7, 5, 2]), k: 3, axis: 1, outputShape: [1, 3])
		assertClose(try XCTUnwrap(outputs["values"]), [9, 7, 5])
		assertClose(try XCTUnwrap(outputs["indices"]), [1, 3, 4])
	}

	func testTopK_ranksAlongTheSelectedAxisAndNotTheDefaultZero() async throws {
		// The same layer over a [4, 2] blob at axis 0 ranks each column independently and cuts the row
		// count to k. A single flat sort would give [9, 8] rather than the interleaved [9, 8, 5, 6], and a
		// dropped axis field would rank the wrong dimension at a shape the declaration does not match.
		// Fixture: same venv — `-np.sort(-y, axis=0)[:2]` and `np.argsort(-y, axis=0)[:2]`.
		let outputs = try await topK(
			input: ([4, 2], [1, 8, 5, 2, 9, 4, 3, 6]), k: 2, axis: 0, outputShape: [2, 2]
		)
		assertClose(try XCTUnwrap(outputs["values"]), [9, 8, 5, 6])
		assertClose(try XCTUnwrap(outputs["indices"]), [2, 0, 1, 3])
	}

	func testGather_selectsRowsByIndexAndNotByPosition() async throws {
		// [2, 0, 3] is deliberately neither sorted nor the identity, and is one shorter than the data's row
		// count: an emitter that ignored the indices blob would return the first three rows, which has the
		// same shape and equally plausible values.
		// Fixture: `.venv-m3a` python (numpy 2.0.2, coremltools 9.0),
		// `np.take(np.arange(12).reshape(4, 3), [2, 0, 3], axis=0)`, confirmed against a compiled
		// `NeuralNetworkBuilder.add_gather` probe.
		let output = try await gather(
			data: ([4, 3], Self.rowMajorRange12), indices: ([3], [2, 0, 3]),
			axis: 0, outputShape: [3, 3]
		)
		assertClose(output, [6, 7, 8, 0, 1, 2, 9, 10, 11])
	}

	func testGather_appliesTheSelectedAxisAndNotTheDefaultZero() async throws {
		// The same data along axis 1 selects columns, so both the shape and the values differ from the
		// axis-0 case; a dropped axis field (proto3 default 0) cannot pass here.
		let output = try await gather(
			data: ([4, 3], Self.rowMajorRange12), indices: ([2], [2, 0]),
			axis: 1, outputShape: [4, 2]
		)
		assertClose(output, [2, 0, 5, 3, 8, 6, 11, 9])
	}

	func testGather_withRankTwoIndicesRaisesTheOutputRank() async throws {
		// The rank rule made observable rather than merely documented: `data.rank - 1 + indices.rank` is
		// 2 − 1 + 2 = 3, so a rank-2 index blob over rank-2 data produces a rank-3 result. The shape check
		// inside `predict` is what proves the declared [2, 2, 3] is what Core ML really returns.
		// Fixture: `np.take(np.arange(12).reshape(4, 3), [[2, 0], [1, 3]], axis=0)`, same venv, confirmed
		// against the compiled probe.
		let output = try await gather(
			data: ([4, 3], Self.rowMajorRange12), indices: ([2, 2], [2, 0, 1, 3]),
			axis: 0, outputShape: [2, 2, 3]
		)
		assertClose(output, [6, 7, 8, 0, 1, 2, 3, 4, 5, 9, 10, 11])
	}

	/// Four rows of three consecutive values, so a gathered row is legible at a glance and no two rows
	/// share a value.
	private static let rowMajorRange12 = (0 ..< 12).map(Float.init)

	/// One `topK` over a single input, returning both of its outputs by name.
	private func topK(
		input: ([Int], [Float]),
		k: Int,
		axis: Int,
		outputShape: [Int]
	) async throws -> [String: [Float]] {
		let outputNames = ["values", "indices"]
		let graph = NativeModelGraph(
			formatVersion: NativeModelGraph.exactNDFormatVersion,
			producer: NativeModelGraphProducer(name: "test", version: "1"),
			inputs: [NativeModelTensor(name: "x", dataType: .float32, shape: input.0)],
			weights: [],
			operations: [
				NativeModelOperation(
					name: "selected", kind: .topK, inputs: ["x"],
					outputs: outputNames.map { NativeModelTensor(name: $0, dataType: .float32, shape: outputShape) },
					attributes: ["k": .integer(k), "axis": .integer(axis)]
				)
			],
			outputs: outputNames
		)
		return try await predict(
			graph: graph, weights: Data(), inputs: ["x": input],
			outputShapes: Dictionary(uniqueKeysWithValues: outputNames.map { ($0, outputShape) })
		)
	}

	/// One `gather` over two runtime inputs, in the layer's order: data first, indices second.
	private func gather(
		data: ([Int], [Float]),
		indices: ([Int], [Float]),
		axis: Int,
		outputShape: [Int]
	) async throws -> [Float] {
		let graph = NativeModelGraph(
			formatVersion: NativeModelGraph.exactNDFormatVersion,
			producer: NativeModelGraphProducer(name: "test", version: "1"),
			inputs: [
				NativeModelTensor(name: "data", dataType: .float32, shape: data.0),
				NativeModelTensor(name: "indices", dataType: .float32, shape: indices.0)
			],
			weights: [],
			operations: [
				NativeModelOperation(
					name: "y", kind: .gather, inputs: ["data", "indices"],
					outputs: [NativeModelTensor(name: "y", dataType: .float32, shape: outputShape)],
					attributes: ["axis": .integer(axis)]
				)
			],
			outputs: ["y"]
		)
		return try await predict(
			graph: graph, weights: Data(),
			inputs: ["data": data, "indices": indices], outputShape: outputShape
		)
	}

	// MARK: - Suppression

	// The NMS *layer*, which is not the standalone NMS *model* `NativeModelDetectorPipeline` emits as its
	// terminal stage. This one lives inside the graph with fixed padded outputs, so everything after it
	// has to cope with the padding — and with the phantom the layer emits when nothing survives at all.

	func testNonMaximumSuppression_suppressesTheOverlapAndPadsTheRemainingSlots() async throws {
		// Fixture: `.venv-m3a` python (torch 2.8.0, torchvision 0.23.0, coremltools 9.0). The three boxes
		// below are center-size; decoded to corners they are (0, 0, 60, 60), (5, 5, 55, 55) and
		// (180, 180, 220, 220), where `torchvision.ops.nms(..., 0.5)` keeps [0, 2] — box 1 has IoU 0.6944
		// with box 0 and loses on score.
		//
		// The first two are concentric on purpose, which is what makes this fixture decide the coordinate
		// convention rather than merely exercise it: read as corners the same six numbers are a 20 × 20 rect
		// nested in a 30 × 30 one, IoU 0.4444, and a corners-mode layer would keep all three and report a
		// valid count of 3. Two is only reachable by reading them as center-size, which is the layer's
		// mandatory and unparameterised convention.
		let outputs = try await suppress(
			boxes: [[30, 30, 60, 60], [30, 30, 50, 50], [200, 200, 40, 40]],
			scores: [[0.9], [0.8], [0.7]],
			iouThreshold: 0.5, scoreThreshold: 0, maxBoxes: 3
		)
		assertClose(try XCTUnwrap(outputs["valid_count"]), [2])
		// Survivors come back in descending score order, and the trailing index slot is −1 rather than 0 —
		// which is the only thing separating "no third box" from "the third box is input 0".
		assertClose(try XCTUnwrap(outputs["kept_indices"]), [0, 2, -1])
		assertClose(try XCTUnwrap(outputs["kept_scores"]), [0.9, 0.7, 0])
		// Boxes come back in the coordinates they went in; the layer does not rewrite them.
		assertClose(
			try XCTUnwrap(outputs["kept_boxes"]),
			[30, 30, 60, 60, 200, 200, 40, 40, 0, 0, 0, 0]
		)
	}

	func testNonMaximumSuppression_appliesItsOwnIouThresholdAndNotTheDefault() async throws {
		// The threshold decides the answer here rather than merely accompanying it. The two boxes overlap at
		// IoU 0.2857 — decoded corners (0, 0, 60, 60) and (20, 20, 80, 80) — which is above 0.2 and below 0.5,
		// so torchvision keeps [0, 1] at 0.5 and [0] at 0.2, and so does the layer. A threshold written to the
		// wrong parameter field falls back to the proto3 default of 0.0, which suppresses on any overlap at
		// all and collapses both cases onto the second. Fixture: same venv and probe harness.
		let boxes: [[Float]] = [[30, 30, 60, 60], [50, 50, 60, 60]]
		let scores: [[Float]] = [[0.9], [0.8]]
		let lenient = try await suppress(
			boxes: boxes, scores: scores, iouThreshold: 0.5, scoreThreshold: 0, maxBoxes: 2
		)
		assertClose(try XCTUnwrap(lenient["valid_count"]), [2])
		assertClose(try XCTUnwrap(lenient["kept_indices"]), [0, 1])

		let strict = try await suppress(
			boxes: boxes, scores: scores, iouThreshold: 0.2, scoreThreshold: 0, maxBoxes: 2
		)
		assertClose(try XCTUnwrap(strict["valid_count"]), [1])
		assertClose(try XCTUnwrap(strict["kept_indices"]), [0, -1])
	}

	func testNonMaximumSuppression_treatingCornersAsCentresChangesWhichBoxesSurvive() async throws {
		// The coordinates below are corners. At IoU 0.5 the actual layer keeps both after the required
		// conversion, but treats the same four values as center-size boxes as overlapping enough to drop
		// the lower-scoring row. This is deliberately a compiled Core ML prediction, not a second Swift
		// IoU implementation: the regression is about the layer's unlabelled input convention.
		let corners: [[Float]] = [
			[0.285_098, 0.013_272, 0.881_965, 0.610_640],
			[0.234_736, 0.189_350, 0.828_344, 0.951_902]
		]
		let scores: [[Float]] = [[0.9], [0.8]]

		let converted = try await suppress(
			boxes: corners.map(Self.centreSize), scores: scores,
			iouThreshold: 0.5, scoreThreshold: 0, maxBoxes: 2
		)
		let mistaken = try await suppress(
			boxes: corners, scores: scores,
			iouThreshold: 0.5, scoreThreshold: 0, maxBoxes: 2
		)

		assertClose(try XCTUnwrap(converted["valid_count"]), [2])
		assertClose(try XCTUnwrap(mistaken["valid_count"]), [1])
	}

	func testNonMaximumSuppression_perClassKeepsWhatTheClassAgnosticPassSuppresses() async throws {
		// `perClassSuppression` is the one parameter with no effect on a single-class detector, so it needs a
		// two-class fixture to be observable at all. The boxes overlap at IoU 0.6944; box 0 wins class 0 and
		// box 1 wins class 1. Class-agnostic suppression compares the two across classes and keeps one box;
		// per-class suppression runs the groups separately and keeps both. A dropped field 4 collapses the
		// second case onto the first. Fixture: same venv and probe harness as above.
		let boxes: [[Float]] = [[30, 30, 60, 60], [30, 30, 50, 50]]
		let scores: [[Float]] = [[0.9, 0.3], [0.2, 0.85]]
		let agnostic = try await suppress(
			boxes: boxes, scores: scores, iouThreshold: 0.5, scoreThreshold: 0, maxBoxes: 2
		)
		assertClose(try XCTUnwrap(agnostic["valid_count"]), [1])
		assertClose(try XCTUnwrap(agnostic["kept_indices"]), [0, -1])

		let perClass = try await suppress(
			boxes: boxes, scores: scores, iouThreshold: 0.5, scoreThreshold: 0, maxBoxes: 2,
			perClassSuppression: true
		)
		assertClose(try XCTUnwrap(perClass["valid_count"]), [2])
		assertClose(try XCTUnwrap(perClass["kept_indices"]), [0, 1])
		// The whole score vector rides along per slot, not just the winning class.
		assertClose(try XCTUnwrap(perClass["kept_scores"]), [0.9, 0.3, 0.2, 0.85])
	}

	func testNonMaximumSuppression_reportsOneValidBoxWhenNothingClearsTheThreshold() async throws {
		// The defect, pinned rather than described. Every score here is below the layer's own
		// `scoreThreshold`, so the honest answer is zero survivors — and the layer answers 1, filling slot 0
		// with the highest-scoring box and its real, sub-threshold score. Measured on coremltools 9.0 / this
		// runtime; if a future Core ML release fixes it, this test fails and says so, which is the point of
		// asserting the wrong answer on purpose.
		//
		// Index 1, not 0: the phantom is the top-scoring input box, not whatever happened to be first.
		let outputs = try await suppress(
			boxes: Self.spreadOutBoxes, scores: [[0.10], [0.40], [0.25]],
			iouThreshold: 0.5, scoreThreshold: 0.5, maxBoxes: 3
		)
		assertClose(try XCTUnwrap(outputs["valid_count"]), [1])
		assertClose(try XCTUnwrap(outputs["kept_indices"]), [1, -1, -1])
		assertClose(try XCTUnwrap(outputs["kept_scores"]), [0.4, 0, 0])
		assertClose(
			try XCTUnwrap(outputs["kept_boxes"]),
			[110, 110, 20, 20, 0, 0, 0, 0, 0, 0, 0, 0]
		)
	}

	func testNonMaximumSuppression_keepsAScoreExactlyAtItsThreshold() async throws {
		// Core ML's score threshold is inclusive. This matters to the assembled mask: it must use the
		// same boundary as the first NMS pass, or an exact-threshold survivor becomes a phantom only
		// after the second pass. Torchvision's ROI-head filter is strict, but that stage is deliberately
		// not what the current RPN-objectness loadability slice claims to reproduce.
		let outputs = try await suppress(
			boxes: Self.spreadOutBoxes, scores: [[0.50], [0.49], [0.10]],
			iouThreshold: 0.5, scoreThreshold: 0.5, maxBoxes: 3
		)
		assertClose(try XCTUnwrap(outputs["valid_count"]), [1])
		assertClose(try XCTUnwrap(outputs["kept_scores"]), [0.5, 0, 0])
	}

	func testNonMaximumSuppressionMaskedByScore_leavesAnEmptyTileEmpty() async throws {
		// The acceptance criterion. Same inputs as the test above — nothing clears 0.5 — but the suppression
		// is followed by the score mask, and the composed result is entirely zero: the phantom has been
		// turned into padding, which is what the rest of the graph already knows how to ignore.
		//
		// Delete `survivors`, `masked_scores` and `masked_boxes` from the graph below and this test fails on
		// the first blob, because the raw layer hands back score 0.4 and box [110, 110, 20, 20]. That is the
		// mutation this test exists to fail.
		//
		// Placement in the assembled ADAF detector is M3c's obligation, not this test's: nothing here can
		// check that the real graph masks in the right place, because the real graph does not exist yet.
		// What this pins is that the primitives compose into the fix, so M3c cannot forget it silently and
		// still be green.
		let outputs = try await suppressAndMask(
			boxes: Self.spreadOutBoxes, scores: [[0.10], [0.40], [0.25]], scoreThreshold: 0.5
		)
		assertClose(try XCTUnwrap(outputs["masked_scores"]), [0, 0, 0])
		assertClose(try XCTUnwrap(outputs["masked_boxes"]), [Float](repeating: 0, count: 12))
	}

	func testNonMaximumSuppressionMaskedByScore_leavesRealDetectionsAlone() async throws {
		// The other half of the mutation argument: a mask that zeroed everything would pass the test above.
		// Two boxes clear 0.5 here and both come through untouched, so the mask is selecting rather than
		// erasing. Box 0 scores 0.10 and is dropped by the layer's own threshold before the mask is reached,
		// which is why only two slots are populated at all.
		let outputs = try await suppressAndMask(
			boxes: Self.spreadOutBoxes, scores: [[0.10], [0.90], [0.70]], scoreThreshold: 0.5
		)
		assertClose(try XCTUnwrap(outputs["masked_scores"]), [0.9, 0.7, 0])
		assertClose(
			try XCTUnwrap(outputs["masked_boxes"]),
			[110, 110, 20, 20, 210, 210, 20, 20, 0, 0, 0, 0]
		)
	}

	/// Three center-size boxes far enough apart that suppression never fires, so a test using them is
	/// measuring the score path and nothing else.
	private static let spreadOutBoxes: [[Float]] = [[10, 10, 20, 20], [110, 110, 20, 20], [210, 210, 20, 20]]

	private static func centreSize(_ corners: [Float]) -> [Float] {
		let x0 = corners[0]
		let y0 = corners[1]
		let x1 = corners[2]
		let y1 = corners[3]
		return [(x0 + x1) / 2, (y0 + y1) / 2, x1 - x0, y1 - y0]
	}

	/// One `nms` over its two runtime inputs, returning all four outputs by name. Both inputs are rank 3
	/// exactly — `[1, N, 4]` and `[1, N, classes]` — because the kernel refuses anything else, and the
	/// outputs are padded to `maxBoxes` with the valid count arriving as a rank-1 blob of one element.
	private func suppress(
		boxes: [[Float]],
		scores: [[Float]],
		iouThreshold: Double,
		scoreThreshold: Double,
		maxBoxes: Int,
		perClassSuppression: Bool = false
	) async throws -> [String: [Float]] {
		let classCount = try XCTUnwrap(scores.first).count
		let shapes = Self.suppressionShapes(boxCount: boxes.count, classCount: classCount, maxBoxes: maxBoxes)
		let graph = NativeModelGraph(
			formatVersion: NativeModelGraph.exactNDFormatVersion,
			producer: NativeModelGraphProducer(name: "test", version: "1"),
			inputs: [
				NativeModelTensor(name: "boxes", dataType: .float32, shape: shapes.boxInput),
				NativeModelTensor(name: "scores", dataType: .float32, shape: shapes.scoreInput)
			],
			weights: [],
			operations: [Self.suppression(
				iouThreshold: iouThreshold, scoreThreshold: scoreThreshold,
				maxBoxes: maxBoxes, perClassSuppression: perClassSuppression, shapes: shapes
			)],
			outputs: Self.suppressionOutputNames
		)
		return try await predict(
			graph: graph, weights: Data(),
			inputs: [
				"boxes": (shapes.boxInput, boxes.flatMap { $0 }),
				"scores": (shapes.scoreInput, scores.flatMap { $0 })
			],
			outputShapes: shapes.outputs
		)
	}

	/// The composed form: the same suppression, then the mask that cancels the phantom. `survivors` is a
	/// 1.0/0.0 blob over the returned scores, which zeroes the phantom and the padding by the same rule —
	/// a padded slot scores 0 and fails the same comparison. The box mask is that blob concatenated to the
	/// coordinate width, because classic multiply (231) is per-position and does not broadcast.
	private func suppressAndMask(
		boxes: [[Float]],
		scores: [[Float]],
		scoreThreshold: Double
	) async throws -> [String: [Float]] {
		let maxBoxes = boxes.count
		let shapes = Self.suppressionShapes(boxCount: boxes.count, classCount: 1, maxBoxes: maxBoxes)
		let survivorShape = shapes.outputs["kept_scores"] ?? []
		let boxShape = shapes.outputs["kept_boxes"] ?? []
		let graph = NativeModelGraph(
			formatVersion: NativeModelGraph.exactNDFormatVersion,
			producer: NativeModelGraphProducer(name: "test", version: "1"),
			inputs: [
				NativeModelTensor(name: "boxes", dataType: .float32, shape: shapes.boxInput),
				NativeModelTensor(name: "scores", dataType: .float32, shape: shapes.scoreInput)
			],
			weights: [],
			operations: [
				Self.suppression(
					iouThreshold: 0.5, scoreThreshold: scoreThreshold,
					maxBoxes: maxBoxes, perClassSuppression: false, shapes: shapes
				),
				NativeModelOperation(
					name: "survivors", kind: .greaterOrEqual, inputs: ["kept_scores"],
					outputs: [NativeModelTensor(name: "survivors", dataType: .float32, shape: survivorShape)],
					attributes: ["threshold": .floatingPoint(scoreThreshold)]
				),
				NativeModelOperation(
					name: "masked_scores", kind: .multiply, inputs: ["kept_scores", "survivors"],
					outputs: [NativeModelTensor(name: "masked_scores", dataType: .float32, shape: survivorShape)],
					attributes: [:]
				),
				NativeModelOperation(
					name: "box_mask", kind: .concatenateND,
					inputs: [String](repeating: "survivors", count: 4),
					outputs: [NativeModelTensor(name: "box_mask", dataType: .float32, shape: boxShape)],
					attributes: ["axis": .integer(2)]
				),
				NativeModelOperation(
					name: "masked_boxes", kind: .multiply, inputs: ["kept_boxes", "box_mask"],
					outputs: [NativeModelTensor(name: "masked_boxes", dataType: .float32, shape: boxShape)],
					attributes: [:]
				)
			],
			outputs: ["masked_scores", "masked_boxes"]
		)
		return try await predict(
			graph: graph, weights: Data(),
			inputs: [
				"boxes": (shapes.boxInput, boxes.flatMap { $0 }),
				"scores": (shapes.scoreInput, scores.flatMap { $0 })
			],
			outputShapes: ["masked_scores": survivorShape, "masked_boxes": boxShape]
		)
	}

	/// Output order is the layer's, not a choice: boxes, scores, source indices, then the valid count.
	private static let suppressionOutputNames = ["kept_boxes", "kept_scores", "kept_indices", "valid_count"]

	private static func suppressionShapes(
		boxCount: Int, classCount: Int, maxBoxes: Int
	) -> (boxInput: [Int], scoreInput: [Int], outputs: [String: [Int]]) {
		(
			boxInput: [1, boxCount, 4],
			scoreInput: [1, boxCount, classCount],
			outputs: [
				"kept_boxes": [1, maxBoxes, 4],
				"kept_scores": [1, maxBoxes, classCount],
				"kept_indices": [1, maxBoxes],
				"valid_count": [1]
			]
		)
	}

	private static func suppression(
		iouThreshold: Double,
		scoreThreshold: Double,
		maxBoxes: Int,
		perClassSuppression: Bool,
		shapes: (boxInput: [Int], scoreInput: [Int], outputs: [String: [Int]])
	) -> NativeModelOperation {
		NativeModelOperation(
			name: "suppressed", kind: .nonMaximumSuppression, inputs: ["boxes", "scores"],
			outputs: suppressionOutputNames.map {
				NativeModelTensor(name: $0, dataType: .float32, shape: shapes.outputs[$0] ?? [])
			},
			attributes: [
				"iouThreshold": .floatingPoint(iouThreshold),
				"scoreThreshold": .floatingPoint(scoreThreshold),
				"maxBoxes": .integer(maxBoxes),
				"perClassSuppression": .boolean(perClassSuppression)
			]
		)
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

	func testUpsample_withoutScalingFactorIsRejected() {
		assertEmissionFails(kind: .upsample2D, attributes: [:])
	}

	func testGreaterOrEqual_withoutThresholdIsRejectedByTheValidator() {
		// The validator owns this rule, so it is the validator that must refuse the graph. The emitter
		// carries a matching guard for callers that reach `greaterOrEqualLayer` without validating, which
		// `emit` never does — asserting `.validator` here keeps that unreachable guard from being
		// mistaken for the thing under test.
		assertEmissionFails(
			kind: .greaterOrEqual, attributes: [:],
			formatVersion: NativeModelGraph.exactNDFormatVersion, rejection: .validator
		)
	}

	func testFloor_underTheLegacyFormatIsRejected() {
		assertLegacyFormatRejects(kind: .floor)
	}

	func testNaturalLogarithm_underTheLegacyFormatIsRejected() {
		assertLegacyFormatRejects(kind: .naturalLogarithm)
	}

	func testGreaterOrEqual_underTheLegacyFormatIsRejected() {
		assertLegacyFormatRejects(kind: .greaterOrEqual, attributes: ["threshold": .floatingPoint(1)])
	}

	func testMinimum_underTheLegacyFormatIsRejected() {
		assertLegacyFormatRejects(kind: .minimumND, inputCount: 2)
	}

	func testMaximum_underTheLegacyFormatIsRejected() {
		assertLegacyFormatRejects(kind: .maximumND, inputCount: 2)
	}

	func testSubtract_underTheLegacyFormatIsRejected() {
		assertLegacyFormatRejects(kind: .subtract, inputCount: 2)
	}

	func testCropResize_underTheLegacyFormatIsRejected() {
		assertLegacyFormatRejects(kind: .cropResize, attributes: Self.cropResizeAttributes, inputCount: 2)
	}

	func testCropResize_withOnlyAFeatureMapIsRejected() {
		// One input is a crop with nothing to crop to. The arity is exact rather than a range because the
		// second input is not optional the way a convolution's bias is.
		assertEmissionFails(
			kind: .cropResize, attributes: Self.cropResizeAttributes,
			formatVersion: NativeModelGraph.exactNDFormatVersion
		)
	}

	func testCropResize_withoutATargetSizeIsRejected() {
		var attributes = Self.cropResizeAttributes
		attributes["targetHeight"] = nil
		assertEmissionFails(
			kind: .cropResize, attributes: attributes,
			formatVersion: NativeModelGraph.exactNDFormatVersion, inputCount: 2
		)
	}

	func testCropResize_withoutASpatialScaleIsRejected() {
		var attributes = Self.cropResizeAttributes
		attributes["spatialScale"] = nil
		assertEmissionFails(
			kind: .cropResize, attributes: attributes,
			formatVersion: NativeModelGraph.exactNDFormatVersion, inputCount: 2
		)
	}

	func testCropResize_withANonBooleanNormalizedROIIsRejectedByTheValidator() {
		// Optional means "absent or a boolean", never "anything at all". `1` is the shape a hand-written
		// or machine-generated graph most easily takes, and `booleanValue` returns nil for it — so
		// without this rule the emitter's `?? false` would read a normalized full-image ROI as absolute
		// feature-pixel coordinates and crop a 1x1 corner, with nothing reported.
		var attributes = Self.cropResizeAttributes
		attributes["normalizedROI"] = .integer(1)
		assertEmissionFails(
			kind: .cropResize, attributes: attributes,
			formatVersion: NativeModelGraph.exactNDFormatVersion, inputCount: 2, rejection: .validator
		)
	}

	func testNonMaximumSuppression_withANonBooleanPerClassSuppressionIsRejectedByTheValidator() {
		// The same optional-attribute rule on the other operation that has one: a `"true"` string would
		// otherwise silently select class-agnostic suppression.
		var attributes = Self.nmsAttributes
		attributes["perClassSuppression"] = .string("true")
		assertEmissionFails(
			kind: .nonMaximumSuppression, attributes: attributes,
			formatVersion: NativeModelGraph.exactNDFormatVersion, inputCount: 2, outputCount: 4, rejection: .validator
		)
	}

	func testTopK_underTheLegacyFormatIsRejected() {
		assertLegacyFormatRejects(kind: .topK, attributes: Self.topKAttributes)
	}

	func testGather_underTheLegacyFormatIsRejected() {
		assertLegacyFormatRejects(kind: .gather, attributes: Self.gatherAttributes, inputCount: 2)
	}

	func testTopK_withASingleOutputIsRejected() {
		// The generalised output-arity rule. One output is not "the values now, the indices later": Core
		// ML rejects a topK layer with any count but two, so the graph contract refuses it first, naming
		// the operation rather than surfacing a Core ML compiler message.
		//
		// `.validator` is what makes this test about that rule: the emitter's `topKLayer` carries its own
		// output-count guard, so weakening the arity table to `.atLeast(1)` would still throw here — from
		// somewhere else, with the rule under test gone.
		assertEmissionFails(
			kind: .topK, attributes: Self.topKAttributes,
			formatVersion: NativeModelGraph.exactNDFormatVersion, rejection: .validator
		)
	}

	func testTopK_withoutAPositiveKIsRejected() {
		var attributes = Self.topKAttributes
		attributes["k"] = .integer(0)
		assertEmissionFails(
			kind: .topK, attributes: attributes,
			formatVersion: NativeModelGraph.exactNDFormatVersion, outputCount: 2
		)
	}

	func testTopK_withoutAnAxisIsRejected() {
		var attributes = Self.topKAttributes
		attributes["axis"] = nil
		assertEmissionFails(
			kind: .topK, attributes: attributes,
			formatVersion: NativeModelGraph.exactNDFormatVersion, outputCount: 2
		)
	}

	func testTopK_withANegativeAxisIsRejectedByTheValidator() {
		// The readers normalize a negative axis before a graph is ever built; nothing normalizes a
		// hand-written one. Protobuf can encode a negative int64 perfectly well — this repository's own
		// `appendSignedVarintField` does it, in ten bytes of two's complement — but the axis here is
		// written through the *unsigned* `appendVarintField`, where −1 becomes 18446744073709551615. So
		// the rule is the graph contract's, and the validator owns it; the emitter keeps a matching guard
		// for callers that reach `topKLayer` without validating, which `emit` never does.
		var attributes = Self.topKAttributes
		attributes["axis"] = .integer(-1)
		assertEmissionFails(
			kind: .topK, attributes: attributes,
			formatVersion: NativeModelGraph.exactNDFormatVersion, outputCount: 2, rejection: .validator
		)
	}

	func testTopK_withASecondInputIsRejected() {
		// Core ML's layer takes an optional second input carrying K. The graph contract does not, because
		// a runtime K leaves every downstream extent undeclarable — so the arity here is exact.
		assertEmissionFails(
			kind: .topK, attributes: Self.topKAttributes,
			formatVersion: NativeModelGraph.exactNDFormatVersion, inputCount: 2, outputCount: 2
		)
	}

	func testGather_withOnlyADataInputIsRejected() {
		assertEmissionFails(
			kind: .gather, attributes: Self.gatherAttributes,
			formatVersion: NativeModelGraph.exactNDFormatVersion
		)
	}

	func testGather_withoutAnAxisIsRejected() {
		assertEmissionFails(
			kind: .gather, attributes: [:],
			formatVersion: NativeModelGraph.exactNDFormatVersion, inputCount: 2
		)
	}

	func testGather_withANegativeAxisIsRejectedByTheValidator() {
		// Same rule as `topK`'s, owned in the same place: an axis that reaches `appendVarintField`
		// negative would be emitted as a colossal unsigned one.
		assertEmissionFails(
			kind: .gather, attributes: ["axis": .integer(-1)],
			formatVersion: NativeModelGraph.exactNDFormatVersion, inputCount: 2, rejection: .validator
		)
	}

	func testNonMaximumSuppression_underTheLegacyFormatIsRejected() {
		assertLegacyFormatRejects(kind: .nonMaximumSuppression, attributes: Self.nmsAttributes, inputCount: 2)
	}

	func testNonMaximumSuppression_withThreeOutputsIsRejected() {
		// The generalised output-arity table's four-output row. Three outputs is not "the valid count is
		// optional": Core ML requires exactly four, and a graph that declares three would be refused by the
		// Core ML compiler with a message naming a layer type number instead of the operation.
		//
		// `.validator` for the same reason as the topK arity test: the emitter's own four-output guard
		// would keep this test green with the table's row weakened to `.atLeast(1)`.
		assertEmissionFails(
			kind: .nonMaximumSuppression, attributes: Self.nmsAttributes,
			formatVersion: NativeModelGraph.exactNDFormatVersion, inputCount: 2, outputCount: 3, rejection: .validator
		)
	}

	func testNonMaximumSuppression_withoutAnIouThresholdIsRejected() {
		var attributes = Self.nmsAttributes
		attributes["iouThreshold"] = nil
		assertEmissionFails(
			kind: .nonMaximumSuppression, attributes: attributes,
			formatVersion: NativeModelGraph.exactNDFormatVersion, inputCount: 2, outputCount: 4
		)
	}

	func testNonMaximumSuppression_withoutAScoreThresholdIsRejected() {
		// Missing rather than zero. A dropped threshold would fall back to the proto3 default of 0.0, which
		// admits every box and is exactly the silent-nonsense case a required attribute prevents.
		var attributes = Self.nmsAttributes
		attributes["scoreThreshold"] = nil
		assertEmissionFails(
			kind: .nonMaximumSuppression, attributes: attributes,
			formatVersion: NativeModelGraph.exactNDFormatVersion, inputCount: 2, outputCount: 4
		)
	}

	func testNonMaximumSuppression_withoutAPositiveMaxBoxesIsRejected() {
		// `maxBoxes` is the fixed extent of all four outputs, so zero declares blobs with no slots at all.
		var attributes = Self.nmsAttributes
		attributes["maxBoxes"] = .integer(0)
		assertEmissionFails(
			kind: .nonMaximumSuppression, attributes: attributes,
			formatVersion: NativeModelGraph.exactNDFormatVersion, inputCount: 2, outputCount: 4
		)
	}

	func testNonMaximumSuppression_withOnlyBoxesIsRejected() {
		// Suppression with no scores has nothing to rank by. Core ML's layer also accepts three more inputs
		// carrying the thresholds and `maxBoxes` at runtime; the graph contract takes none of them, so the
		// arity is exact in both directions.
		assertEmissionFails(
			kind: .nonMaximumSuppression, attributes: Self.nmsAttributes,
			formatVersion: NativeModelGraph.exactNDFormatVersion, outputCount: 4
		)
	}

	private static let nmsAttributes: [String: NativeModelAttribute] = [
		"iouThreshold": .floatingPoint(0.5),
		"scoreThreshold": .floatingPoint(0.05),
		"maxBoxes": .integer(2)
	]

	private static let topKAttributes: [String: NativeModelAttribute] = [
		"k": .integer(2),
		"axis": .integer(1)
	]

	private static let gatherAttributes: [String: NativeModelAttribute] = ["axis": .integer(0)]

	private static let cropResizeAttributes: [String: NativeModelAttribute] = [
		"targetHeight": .integer(14),
		"targetWidth": .integer(14),
		"spatialScale": .floatingPoint(1)
	]

	/// A V2-only operation must be turned away by the graph validator, naming the operation, rather
	/// than reaching the emitter's layer table — where a legacy graph would otherwise be handed a
	/// spec-4 layer sitting among rank-5 ones.
	private func assertLegacyFormatRejects(
		kind: NativeModelOperationKind,
		attributes: [String: NativeModelAttribute] = [:],
		inputCount: Int = 1,
		file: StaticString = #filePath,
		line: UInt = #line
	) {
		let inputNames = (0 ..< inputCount).map { "x\($0)" }
		let graph = NativeModelGraph(
			formatVersion: NativeModelGraph.legacyFormatVersion,
			producer: NativeModelGraphProducer(name: "test", version: "1"),
			inputs: inputNames.map { NativeModelTensor(name: $0, dataType: .float32, shape: [1, 4, 1, 1]) },
			weights: [],
			operations: [
				NativeModelOperation(
					name: "y", kind: kind, inputs: inputNames,
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
			"Format version 1 must reject \(kind.serializedValue).",
			file: file, line: line
		) { error in
			guard case .invalidGraph(let issues) = error as? NativeModelCoreMLEmissionError else {
				XCTFail("Expected a validation failure for \(kind.serializedValue), got \(error).", file: file, line: line)
				return
			}
			XCTAssertTrue(
				issues.contains(.unsupportedOperation(operation: "y", kind: kind.serializedValue)),
				"Format version 1 must report \(kind.serializedValue) as unsupported, got \(issues).",
				file: file, line: line
			)
		}
	}

	private func assertEmissionFails(
		kind: NativeModelOperationKind,
		attributes: [String: NativeModelAttribute],
		formatVersion: Int = NativeModelGraph.currentFormatVersion,
		inputCount: Int = 1,
		outputCount: Int = 1,
		rejection: ExpectedRejection? = nil,
		file: StaticString = #filePath,
		line: UInt = #line
	) {
		let inputNames = (0 ..< inputCount).map { "x\($0)" }
		// A multi-output operation has to declare all of its outputs here, or the arity rule fails the
		// graph before the attribute actually under test is ever read.
		let outputNames = outputCount == 1 ? ["y"] : (0 ..< outputCount).map { "y\($0)" }
		let graph = NativeModelGraph(
			formatVersion: formatVersion,
			producer: NativeModelGraphProducer(name: "test", version: "1"),
			inputs: inputNames.map { NativeModelTensor(name: $0, dataType: .float32, shape: [1, 4, 1, 1]) },
			weights: [],
			operations: [
				NativeModelOperation(
					name: "y", kind: kind, inputs: inputNames,
					outputs: outputNames.map { NativeModelTensor(name: $0, dataType: .float32, shape: [1, 4, 1, 1]) },
					attributes: attributes
				)
			],
			outputs: outputNames
		)
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mlmodel")
		defer { try? FileManager.default.removeItem(at: url) }
		XCTAssertThrowsError(
			try NativeModelCoreMLEmitter().emit(graph: graph, weights: Data(), to: url),
			"A malformed \(kind.serializedValue) must be rejected, not emitted.",
			file: file, line: line
		) { error in
			guard let rejection else { return }
			guard let emission = error as? NativeModelCoreMLEmissionError else {
				XCTFail("Expected a NativeModelCoreMLEmissionError, got \(error).", file: file, line: line)
				return
			}
			// Naming the rejection is the point. `emit` validates the whole graph before it writes a
			// single layer, so a malformed operation is normally refused by the *validator* and the
			// emitter's own guard for the same mistake never runs. A test that accepted any error at all
			// would read as covering the emitter guard while actually covering the validator, and would
			// keep passing if the guard it names were deleted.
			switch rejection {
			case .validator:
				guard case .invalidGraph = emission else {
					XCTFail("Expected the validator to reject this, got \(emission).", file: file, line: line)
					return
				}
			case .emitter:
				guard case .invalidOperation = emission else {
					XCTFail("Expected the emitter to reject this, got \(emission).", file: file, line: line)
					return
				}
			}
		}
	}
}

/// Which layer of `emit` is expected to refuse a malformed operation.
///
/// The two are not interchangeable: the validator runs first and covers every rule it declares, so an
/// emitter guard for a rule the validator already enforces is unreachable through the public entry
/// point. Keeping the distinction in the tests is what stops "rejected" from quietly meaning "rejected
/// by something, somewhere".
private enum ExpectedRejection {
	case validator
	case emitter
}
