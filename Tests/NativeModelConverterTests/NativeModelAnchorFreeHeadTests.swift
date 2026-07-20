//
//  NativeModelAnchorFreeHeadTests.swift
//  NativeModelConverterTests
//
//  Numeric verification of the anchor-free decode adapter. The planner's output is compiled and run
//  through Core ML, then compared against values computed here by plain arithmetic. This is what
//  catches the two silent failure modes a wrong reshape/permute axis produces: a transposed
//  coordinate layout, and boxes paired with other boxes' scores.
//
//  Axis note: the planner reasons about the batch-leading `[1, 4 + C, N]` tensor the real lowered
//  graph declares, but Core ML's legacy rank-5 layout (forced by the reshape/permute the head emits)
//  maps a rank-3 feature `[a, b, c]` onto `[channel, height, width]` — and only rank-1 or rank-3
//  multi-array inputs are accepted. So the fed input is `[4 + C, N, 1]`: the batch axis dropped and a
//  unit width appended, which lands the channel axis on `4 + C` where `sliceChannels` splits it —
//  exactly the convention the anchor-based head test uses for its grid input.
//

import CoreML
import Foundation
import XCTest
@testable import NativeModelConverter

final class NativeModelAnchorFreeHeadTests: XCTestCase {

	private let classCount = 2
	private let boxCount = 4
	private let labels = ["cat", "dog"]
	private var channelCount: Int { 4 + classCount }

	// MARK: - Fixture

	/// Channel `ch` (0..<4 + C), box `n`: a distinct value `ch·10 + n`. The 10× channel spread makes a
	/// channel/box axis swap impossible to pass by coincidence.
	private func fixtureValues() -> [Float] {
		var values = [Float](repeating: 0, count: channelCount * boxCount)
		for channel in 0 ..< channelCount {
			for box in 0 ..< boxCount {
				values[channel * boxCount + box] = Float(channel * 10 + box)
			}
		}
		return values
	}

	// MARK: - Harness

	private func plannedGraph(coordinateMode: NativeModelAnchorFreeHead.CoordinateMode) throws
		-> (graph: NativeModelGraph, weights: Data, interface: NativeModelDetectionInterface) {
		let plan = try NativeModelAnchorFreeHead.plan(
			output: NativeModelTensor(name: "pred", dataType: .float32, shape: [1, channelCount, boxCount]),
			classCount: classCount,
			labels: labels,
			coordinateMode: coordinateMode,
			weightOffset: 0
		)
		let graph = NativeModelGraph(
			formatVersion: NativeModelGraph.currentFormatVersion,
			producer: NativeModelGraphProducer(name: "test", version: "1"),
			// The decoded prediction is fed as `[channels, boxes, 1]` (see the axis note above).
			inputs: [NativeModelTensor(name: "pred", dataType: .float32, shape: [channelCount, boxCount, 1])],
			weights: plan.weights,
			operations: plan.operations,
			outputs: [plan.interface.coordinatesBlobName, plan.interface.confidenceBlobName]
		)
		return (graph, plan.weightData, plan.interface)
	}

	private func compileAndPredict(coordinateMode: NativeModelAnchorFreeHead.CoordinateMode) async throws
		-> (coordinates: [[Double]], confidence: [[Double]]) {
		let (graph, weights, interface) = try plannedGraph(coordinateMode: coordinateMode)
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mlmodel")
		addTeardownBlock { try? FileManager.default.removeItem(at: url) }
		try NativeModelCoreMLEmitter().emit(graph: graph, weights: weights, to: url)
		let compiled = try await MLModel.compileModel(at: url)
		addTeardownBlock { try? FileManager.default.removeItem(at: compiled) }
		let configuration = MLModelConfiguration()
		configuration.computeUnits = .cpuOnly
		let model = try MLModel(contentsOf: compiled, configuration: configuration)

		let input = try MLMultiArray(shape: [channelCount, boxCount, 1].map { NSNumber(value: $0) }, dataType: .float32)
		for (index, value) in fixtureValues().enumerated() {
			input[index] = NSNumber(value: value)
		}
		let prediction = try await model.prediction(
			from: MLDictionaryFeatureProvider(dictionary: ["pred": MLFeatureValue(multiArray: input)])
		)
		let coordinates = try XCTUnwrap(prediction.featureValue(for: interface.coordinatesBlobName)?.multiArrayValue)
		let confidence = try XCTUnwrap(prediction.featureValue(for: interface.confidenceBlobName)?.multiArrayValue)
		XCTAssertEqual(coordinates.shape.map(\.intValue), [boxCount, 4, 1], "coordinates blob shape drifted.")
		XCTAssertEqual(confidence.shape.map(\.intValue), [boxCount, classCount, 1], "confidence blob shape drifted.")
		return (rows(of: coordinates, columns: 4), rows(of: confidence, columns: classCount))
	}

	private func rows(of array: MLMultiArray, columns: Int) -> [[Double]] {
		(0 ..< array.count / columns).map { row in
			(0 ..< columns).map { array[row * columns + $0].doubleValue }
		}
	}

	private func assertClose(_ actual: [Double], _ expected: [Double], _ label: String, accuracy: Double = 0.001) {
		XCTAssertEqual(actual.count, expected.count, label)
		for (index, pair) in zip(actual, expected).enumerated() {
			XCTAssertEqual(pair.0, pair.1, accuracy: accuracy, "\(label) element \(index)")
		}
	}

	// MARK: - Numeric decode verification

	func testDecode_normalizedByGraph_movesEachBoxIntoItsOwnRow() async throws {
		let (coordinates, confidence) = try await compileAndPredict(coordinateMode: .normalizedByGraph)

		XCTAssertEqual(coordinates.count, boxCount)
		XCTAssertEqual(confidence.count, boxCount)
		for box in 0 ..< boxCount {
			// Box channels 0..3 land as this box's row, in order — proving the permute reorders and did
			// not leave the tensor channel-major.
			assertClose(
				coordinates[box],
				[Double(box), Double(10 + box), Double(20 + box), Double(30 + box)],
				"coordinates box \(box)"
			)
			// Class channels 4..5 become this box's confidence row.
			assertClose(confidence[box], [Double(40 + box), Double(50 + box)], "confidence box \(box)")
		}
	}

	func testDecode_pixelsOfInput_dividesCentreAndSizePerAxis() async throws {
		let (coordinates, confidence) = try await compileAndPredict(coordinateMode: .pixelsOfInput(width: 10, height: 20))

		XCTAssertEqual(coordinates.count, boxCount)
		for box in 0 ..< boxCount {
			// cx, w scaled by 1/width (10); cy, h scaled by 1/height (20).
			assertClose(
				coordinates[box],
				[
					Double(box) / 10,
					Double(10 + box) / 20,
					Double(20 + box) / 10,
					Double(30 + box) / 20
				],
				"coordinates box \(box)"
			)
			// Scores are geometry-independent, so the pixel rescale must leave them untouched.
			assertClose(confidence[box], [Double(40 + box), Double(50 + box)], "confidence box \(box)")
		}
	}

	// MARK: - Planner rejection

	func testPlan_rejectsAClassCountThatDisagreesWithTheLabels() {
		XCTAssertThrowsError(
			try NativeModelAnchorFreeHead.plan(
				output: NativeModelTensor(name: "pred", dataType: .float32, shape: [1, channelCount, boxCount]),
				classCount: classCount, labels: ["only-one"], coordinateMode: .normalizedByGraph, weightOffset: 0
			)
		) { error in
			guard case .classCountMismatch = error as? NativeModelAnchorFreeHead.PlanError else {
				return XCTFail("Expected classCountMismatch, got \(error).")
			}
		}
	}

	func testPlan_rejectsAnOversizedBoxAxis() {
		// A crafted tensor declaring a huge box count is bytes-cheap on disk but would materialize a
		// large pixel-scale constant, so it must be rejected before any allocation.
		let boxes = NativeModelAnchorFreeHead.maximumBoxCount + 1
		XCTAssertThrowsError(
			try NativeModelAnchorFreeHead.plan(
				output: NativeModelTensor(name: "pred", dataType: .float32, shape: [1, channelCount, boxes]),
				classCount: classCount, labels: labels, coordinateMode: .normalizedByGraph, weightOffset: 0
			)
		) { error in
			guard case .tooManyBoxes = error as? NativeModelAnchorFreeHead.PlanError else {
				return XCTFail("Expected tooManyBoxes, got \(error).")
			}
		}
	}

	func testPlan_rejectsARankFourTensor() {
		XCTAssertThrowsError(
			try NativeModelAnchorFreeHead.plan(
				output: NativeModelTensor(name: "pred", dataType: .float32, shape: [1, channelCount, boxCount, 1]),
				classCount: classCount, labels: labels, coordinateMode: .normalizedByGraph, weightOffset: 0
			)
		) { error in
			guard case .notAPredictionTensor = error as? NativeModelAnchorFreeHead.PlanError else {
				return XCTFail("Expected notAPredictionTensor, got \(error).")
			}
		}
	}

	func testPlan_rejectsATensorWithoutEnoughChannels() {
		XCTAssertThrowsError(
			try NativeModelAnchorFreeHead.plan(
				output: NativeModelTensor(name: "pred", dataType: .float32, shape: [1, 3, boxCount]),
				classCount: classCount, labels: labels, coordinateMode: .normalizedByGraph, weightOffset: 0
			)
		) { error in
			guard case .notAPredictionTensor = error as? NativeModelAnchorFreeHead.PlanError else {
				return XCTFail("Expected notAPredictionTensor, got \(error).")
			}
		}
	}
}
