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
		file: StaticString = #filePath,
		line: UInt = #line
	) {
		let graph = NativeModelGraph(
			formatVersion: formatVersion,
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
