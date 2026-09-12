//
//  NativeModelYOLOHeadTests.swift
//  NativeModelConverterTests
//
//  Numeric verification of the synthesized YOLO decode. The planner's output is compiled and run
//  through Core ML, then compared against an independent decode written here in plain arithmetic —
//  the two share only the YOLO formulas, not code. This is what catches the two silent failure
//  modes: a wrong coordinate convention and boxes paired with other boxes' scores.
//

import CoreML
import Foundation
import XCTest
@testable import NativeModelConverter

final class NativeModelYOLOHeadTests: XCTestCase {

	/// S=2 grid, 2 anchors, 3 classes: 16 channels, 8 boxes. Small enough to reason about by hand,
	/// large enough that any axis mix-up misplaces most values.
	private let size = 2
	private let anchors = [
		NativeModelYOLOHead.Anchor(width: 1.1, height: 1.7),
		NativeModelYOLOHead.Anchor(width: 3.0, height: 2.2)
	]
	private let labels = ["cat", "dog", "bird"]
	private var attributeCount: Int { 5 + labels.count }
	private var channelCount: Int { anchors.count * attributeCount }
	private var boxCount: Int { anchors.count * size * size }

	// MARK: - Independent decode (the oracle)

	private func sigmoid(_ x: Double) -> Double { 1 / (1 + exp(-x)) }

	/// Reads logit for (anchor, attribute, row, column) from the grid laid out as [A·K, S, S].
	private func logit(_ grid: [Double], _ anchor: Int, _ attribute: Int, _ row: Int, _ column: Int) -> Double {
		grid[((anchor * attributeCount + attribute) * size + row) * size + column]
	}

	/// The reference decode: plain YOLOv2 arithmetic, no shared code with the planner.
	private func referenceDecode(_ grid: [Double]) -> (coordinates: [[Double]], confidence: [[Double]]) {
		var coordinates = [[Double]](repeating: [], count: boxCount)
		var confidence = [[Double]](repeating: [], count: boxCount)
		for anchor in 0 ..< anchors.count {
			for row in 0 ..< size {
				for column in 0 ..< size {
					let box = anchor * size * size + row * size + column
					let x = (Double(column) + sigmoid(logit(grid, anchor, 0, row, column))) / Double(size)
					let y = (Double(row) + sigmoid(logit(grid, anchor, 1, row, column))) / Double(size)
					let width = anchors[anchor].width * exp(logit(grid, anchor, 2, row, column)) / Double(size)
					let height = anchors[anchor].height * exp(logit(grid, anchor, 3, row, column)) / Double(size)
					coordinates[box] = [x, y, width, height]

					let objectness = sigmoid(logit(grid, anchor, 4, row, column))
					let classLogits = (0 ..< labels.count).map { logit(grid, anchor, 5 + $0, row, column) }
					let peak = classLogits.max() ?? 0
					let exponentials = classLogits.map { exp($0 - peak) }
					let total = exponentials.reduce(0, +)
					confidence[box] = exponentials.map { objectness * $0 / total }
				}
			}
		}
		return (coordinates, confidence)
	}

	/// Deterministic pseudo-random logits in [-2, 0) — `state >> 33` is 31 bits against a 32-bit
	/// denominator. The skew is irrelevant here (the reference decode consumes the same values);
	/// only determinism matters.
	private func fixtureGrid() -> [Double] {
		var state: UInt64 = 0x2463_AD42
		return (0 ..< channelCount * size * size).map { _ in
			state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
			return Double(state >> 33) / Double(UInt32.max) * 4 - 2
		}
	}

	// MARK: - Harness

	private func plannedGraph() throws -> (graph: NativeModelGraph, weights: Data, interface: NativeModelDetectionInterface) {
		// The graph input is the raw grid itself; under Core ML's legacy layout a plain multi-array
		// input must be rank 3, while the planner reasons about the conventional rank-4 trunk output.
		let plan = try NativeModelYOLOHead.plan(
			grid: NativeModelTensor(name: "grid_in", dataType: .float32, shape: [1, channelCount, size, size]),
			anchors: anchors,
			labels: labels,
			weightOffset: 0
		)
		let graph = NativeModelGraph(
			formatVersion: NativeModelGraph.currentFormatVersion,
			producer: NativeModelGraphProducer(name: "test", version: "1"),
			inputs: [NativeModelTensor(name: "grid_in", dataType: .float32, shape: [channelCount, size, size])],
			weights: plan.weights,
			operations: plan.operations,
			outputs: [plan.interface.coordinatesBlobName, plan.interface.confidenceBlobName]
		)
		return (graph, plan.weightData, plan.interface)
	}

	private func compileAndPredict(detection: Bool, grid: [Double]) async throws -> (coordinates: [[Double]], confidence: [[Double]]) {
		let (graph, weights, interface) = try plannedGraph()
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mlmodel")
		addTeardownBlock { try? FileManager.default.removeItem(at: url) }
		if detection {
			try NativeModelCoreMLEmitter().emit(
				graph: graph, weights: weights, to: url, detection: interface,
				detectionTarget: NativeModelDetectionTargetInfo(
					classCount: interface.labels.count, labelProvenance: .convention, coordinateMode: .normalizedByGraph
				)
			)
		} else {
			try NativeModelCoreMLEmitter().emit(graph: graph, weights: weights, to: url)
		}
		let compiled = try await MLModel.compileModel(at: url)
		addTeardownBlock { try? FileManager.default.removeItem(at: compiled) }
		let configuration = MLModelConfiguration()
		configuration.computeUnits = .cpuOnly
		let model = try MLModel(contentsOf: compiled, configuration: configuration)

		let input = try MLMultiArray(shape: [channelCount, size, size].map { NSNumber(value: $0) }, dataType: .float32)
		for (index, value) in grid.enumerated() {
			input[index] = NSNumber(value: Float(value))
		}
		let prediction = try await model.prediction(
			from: MLDictionaryFeatureProvider(dictionary: ["grid_in": MLFeatureValue(multiArray: input)])
		)
		let coordinatesName = detection ? "coordinates" : interface.coordinatesBlobName
		let confidenceName = detection ? "confidence" : interface.confidenceBlobName
		let coordinates = try XCTUnwrap(prediction.featureValue(for: coordinatesName)?.multiArrayValue)
		let confidence = try XCTUnwrap(prediction.featureValue(for: confidenceName)?.multiArrayValue)
		return (rows(of: coordinates, columns: 4), rows(of: confidence, columns: labels.count))
	}

	private func rows(of array: MLMultiArray, columns: Int) -> [[Double]] {
		(0 ..< array.count / columns).map { row in
			(0 ..< columns).map { array[row * columns + $0].doubleValue }
		}
	}

	// MARK: - Numeric decode verification

	func testDecode_matchesTheIndependentReferenceForEveryBoxAndClass() async throws {
		let grid = fixtureGrid()
		let expected = referenceDecode(grid)

		let (coordinates, confidence) = try await compileAndPredict(detection: false, grid: grid)

		XCTAssertEqual(coordinates.count, boxCount)
		XCTAssertEqual(confidence.count, boxCount)
		for box in 0 ..< boxCount {
			for attribute in 0 ..< 4 {
				XCTAssertEqual(
					coordinates[box][attribute], expected.coordinates[box][attribute], accuracy: 0.001,
					"box \(box) coordinate \(attribute)"
				)
			}
			for classIndex in 0 ..< labels.count {
				XCTAssertEqual(
					confidence[box][classIndex], expected.confidence[box][classIndex], accuracy: 0.001,
					"box \(box) class \(classIndex)"
				)
			}
		}
	}

	// MARK: - End-to-end through suppression

	func testDetectorPipeline_endToEnd_returnsTheTwoPlantedObjects() async throws {
		// Plant two objects on different anchors/cells/classes; suppress everything else by driving
		// objectness far negative (σ ≈ 0, below the 0.25 confidence floor).
		var grid = [Double](repeating: 0, count: channelCount * size * size)
		for index in grid.indices {
			grid[index] = -8 // neutral geometry logits are fine; objectness -8 kills the box
		}
		func put(_ anchor: Int, _ attribute: Int, _ row: Int, _ column: Int, _ value: Double) {
			grid[((anchor * attributeCount + attribute) * size + row) * size + column] = value
		}
		// Object A: anchor 0, cell (0, 0), class "dog" — high objectness, centred box.
		put(0, 0, 0, 0, 0); put(0, 1, 0, 0, 0); put(0, 2, 0, 0, 0); put(0, 3, 0, 0, 0)
		put(0, 4, 0, 0, 6)
		put(0, 6, 0, 0, 5)
		// Object B: anchor 1, cell (1, 1), class "cat".
		put(1, 0, 1, 1, 0); put(1, 1, 1, 1, 0); put(1, 2, 1, 1, -1); put(1, 3, 1, 1, -1)
		put(1, 4, 1, 1, 6)
		put(1, 5, 1, 1, 5)

		let expected = referenceDecode(grid)
		let boxA = 0 // anchor 0 · 4 + row 0 · 2 + col 0
		let boxB = 1 * 4 + 1 * 2 + 1

		let (coordinates, confidence) = try await compileAndPredict(detection: true, grid: grid)

		XCTAssertEqual(coordinates.count, 2, "Only the two planted objects should survive suppression.")
		// Suppression orders by score; both objects share the same objectness/class logits, so sort
		// by x to make the comparison deterministic.
		let ordered = zip(coordinates, confidence).sorted { $0.0[0] < $1.0[0] }
		for (result, box) in zip(ordered, [boxA, boxB]) {
			for attribute in 0 ..< 4 {
				XCTAssertEqual(result.0[attribute], expected.coordinates[box][attribute], accuracy: 0.001, "box \(box) attr \(attribute)")
			}
			for classIndex in 0 ..< labels.count {
				XCTAssertEqual(result.1[classIndex], expected.confidence[box][classIndex], accuracy: 0.001, "box \(box) class \(classIndex)")
			}
		}
	}

	// MARK: - Planner rejection

	func testPlan_rejectsAChannelCountThatDoesNotFactor() {
		XCTAssertThrowsError(
			try NativeModelYOLOHead.plan(
				grid: NativeModelTensor(name: "grid", dataType: .float32, shape: [1, 15, 2, 2]),
				anchors: anchors, labels: labels, weightOffset: 0
			)
		) { error in
			guard case .channelMismatch = error as? NativeModelYOLOHead.PlanError else {
				return XCTFail("Expected channelMismatch, got \(error).")
			}
		}
	}

	func testPlan_rejectsAnOversizedGrid() {
		// The decode materializes dense S²-sized constants, so a crafted small-on-disk model
		// declaring a huge grid must be rejected before any allocation.
		let size = NativeModelYOLOHead.maximumGridSize + 1
		XCTAssertThrowsError(
			try NativeModelYOLOHead.plan(
				grid: NativeModelTensor(name: "grid", dataType: .float32, shape: [1, channelCount, size, size]),
				anchors: anchors, labels: labels, weightOffset: 0
			)
		) { error in
			guard case .gridTooLarge = error as? NativeModelYOLOHead.PlanError else {
				return XCTFail("Expected gridTooLarge, got \(error).")
			}
		}
	}

	func testPlan_rejectsANonSquareGrid() {
		XCTAssertThrowsError(
			try NativeModelYOLOHead.plan(
				grid: NativeModelTensor(name: "grid", dataType: .float32, shape: [1, channelCount, 2, 3]),
				anchors: anchors, labels: labels, weightOffset: 0
			)
		) { error in
			guard case .notAGridTensor = error as? NativeModelYOLOHead.PlanError else {
				return XCTFail("Expected notAGridTensor, got \(error).")
			}
		}
	}
}
