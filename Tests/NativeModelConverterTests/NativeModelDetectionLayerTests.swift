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
		// torchvision's LevelMapper (`ops/poolers.py`) assigns floor(4 + log2(sqrt(w·h) / 224)), clamped
		// to [2, 5]. The graph evaluates the algebraically identical product-free form
		// 4 + 0.5·log2(w) + 0.5·log2(h) − log2(224), which never forms the area: three of these six
		// boxes have an area above fp16's 65504 (120000, 720000, 1200000) and would come out of an fp16
		// area as infinity, while every intermediate here stays under 21.
		//
		// Fixture: `.venv-m3a` python (torch 2.8.0, torchvision 0.23.0), levels taken from the mapper's
		// own expression and confirmed equal to the product-free form. The sizes deliberately avoid
		// exact powers of two, where the mapper's 1e-6 epsilon — added outside the logarithm — is what
		// decides which side `floor` falls on.
		let widths: [Float] = [10, 32, 100, 300, 800, 1200]
		let heights: [Float] = [8, 32, 150, 400, 900, 1000]
		var builder = BoxArithmeticGraph(shape: [1, 6])
		let halfInverseLn2 = builder.constant(0.5 / Float(log(2.0)), name: "half_inverse_ln2")
		let canonicalLevel = builder.constant(4, name: "canonical_level")
		let canonicalScale = builder.constant(Float(log2(224.0)), name: "canonical_scale")
		let lowestLevel = builder.constant(2, name: "lowest_level")
		let highestLevel = builder.constant(5, name: "highest_level")
		let logWidth = builder.apply(.naturalLogarithm, ["w"], name: "log_width")
		let logHeight = builder.apply(.naturalLogarithm, ["h"], name: "log_height")
		let halfLog2Width = builder.apply(.multiply, [logWidth, halfInverseLn2], name: "half_log2_width")
		let halfLog2Height = builder.apply(.multiply, [logHeight, halfInverseLn2], name: "half_log2_height")
		let halfLog2Area = builder.apply(.add, [halfLog2Width, halfLog2Height], name: "half_log2_area")
		let biased = builder.apply(.add, [halfLog2Area, canonicalLevel], name: "biased")
		let level = builder.apply(.subtract, [biased, canonicalScale], name: "level")
		let floored = builder.apply(.floor, [level], name: "floored")
		let raised = builder.apply(.maximumND, [floored, lowestLevel], name: "raised")
		builder.apply(.minimumND, [raised, highestLevel], name: "y")

		let output = try await predict(
			graph: builder.graph(inputs: ["w", "h"], output: "y"), weights: builder.weightData,
			inputs: ["w": ([1, 6], widths), "h": ([1, 6], heights)], outputShape: [1, 6]
		)
		// Pre-clamp values are −0.65, 1.19, 3.13, 4.63, 5.92, 6.29 — both clamps are exercised.
		assertClose(output, [2, 2, 3, 4, 5, 5])
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

	func testGreaterOrEqual_withoutThresholdIsRejected() {
		assertEmissionFails(kind: .greaterOrEqual, attributes: [:], formatVersion: NativeModelGraph.exactNDFormatVersion)
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
		assertEmissionFails(
			kind: .topK, attributes: Self.topKAttributes,
			formatVersion: NativeModelGraph.exactNDFormatVersion
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
		)
	}
}
