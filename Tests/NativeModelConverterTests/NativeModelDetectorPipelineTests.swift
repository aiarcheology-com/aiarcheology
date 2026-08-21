//
//  NativeModelDetectorPipelineTests.swift
//  NativeModelConverterTests
//
//  Compiles and runs the emitted detector pipeline. The Core ML pipeline and non-maximum-suppression
//  protobufs are hand-encoded, and a wrong field number there produces a model that still compiles
//  and then misbehaves — so these tests assert real predictions, never just successful emission.
//

import CoreML
import Foundation
import XCTest
@testable import NativeModelConverter

final class NativeModelDetectorPipelineTests: XCTestCase {

	// MARK: - Fixtures

	/// A graph that republishes its two inputs, so a test can drive exact boxes and scores through
	/// the suppression stage.
	///
	/// Each output is `add(input, input)`, i.e. **twice** the fed value: the emitter has no identity
	/// layer, and elementwise add is already covered by the classifier path. Tests therefore feed
	/// half of the value they want the suppression stage to see.
	private func passThroughGraph(boxCount: Int, classCount: Int) -> NativeModelGraph {
		let coordinatesIn = NativeModelTensor(name: "coordinates_in", dataType: .float32, shape: [boxCount, 4])
		let confidenceIn = NativeModelTensor(name: "confidence_in", dataType: .float32, shape: [boxCount, classCount])
		return NativeModelGraph(
			formatVersion: NativeModelGraph.currentFormatVersion,
			producer: NativeModelGraphProducer(name: "test", version: "1"),
			inputs: [coordinatesIn, confidenceIn],
			weights: [],
			operations: [
				NativeModelOperation(
					name: "raw_coordinates", kind: .add, inputs: ["coordinates_in", "coordinates_in"],
					outputs: [NativeModelTensor(name: "raw_coordinates", dataType: .float32, shape: [boxCount, 4])],
					attributes: [:]
				),
				NativeModelOperation(
					name: "raw_confidence", kind: .add, inputs: ["confidence_in", "confidence_in"],
					outputs: [NativeModelTensor(name: "raw_confidence", dataType: .float32, shape: [boxCount, classCount])],
					attributes: [:]
				)
			],
			outputs: ["raw_coordinates", "raw_confidence"]
		)
	}

	private func interface(boxCount: Int, labels: [String], iou: Double = 0.45, confidence: Double = 0.25) -> NativeModelDetectionInterface {
		NativeModelDetectionInterface(
			labels: labels,
			boxCount: boxCount,
			coordinatesBlobName: "raw_coordinates",
			confidenceBlobName: "raw_confidence",
			iouThreshold: iou,
			confidenceThreshold: confidence
		)
	}

	/// A detector whose two in-graph NMS layers already own terminal policy. Their deliberately
	/// permissive threshold lets the test prove that the Vision-facing NMS model is an adapter — the
	/// legacy pipeline threshold would otherwise remove one of the overlapping boxes below.
	private func graphOwnedSuppressionGraph() -> NativeModelGraph {
		let boxes = NativeModelTensor(name: "boxes_in", dataType: .float32, shape: [1, 2, 4])
		let scores = NativeModelTensor(name: "scores_in", dataType: .float32, shape: [1, 2, 1])
		let nmsOutput = { (prefix: String) in
			[
				NativeModelTensor(name: "\(prefix).boxes", dataType: .float32, shape: [1, 2, 4]),
				NativeModelTensor(name: "\(prefix).scores", dataType: .float32, shape: [1, 2, 1]),
				NativeModelTensor(name: "\(prefix).indices", dataType: .float32, shape: [1, 2]),
				NativeModelTensor(name: "\(prefix).valid_count", dataType: .float32, shape: [1])
			]
		}
		let suppressionAttributes: [String: NativeModelAttribute] = [
			"iouThreshold": .floatingPoint(0.99),
			"scoreThreshold": .floatingPoint(0),
			"maxBoxes": .integer(2),
			"perClassSuppression": .boolean(false)
		]
		return NativeModelGraph(
			formatVersion: NativeModelGraph.exactNDFormatVersion,
			producer: NativeModelGraphProducer(name: "test", version: "1"),
			inputs: [boxes, scores],
			weights: [],
			operations: [
				NativeModelOperation(
					name: "first_nms", kind: .nonMaximumSuppression, inputs: [boxes.name, scores.name],
					outputs: nmsOutput("first_nms"), attributes: suppressionAttributes
				),
				NativeModelOperation(
					name: "second_nms", kind: .nonMaximumSuppression,
					inputs: ["first_nms.boxes", "first_nms.scores"],
					outputs: nmsOutput("second_nms"), attributes: suppressionAttributes
				),
				NativeModelOperation(
					name: "raw_coordinates", kind: .reshapeND, inputs: ["second_nms.boxes"],
					outputs: [NativeModelTensor(name: "raw_coordinates", dataType: .float32, shape: [2, 4])],
					attributes: ["shape": .integers([2, 4])]
				),
				NativeModelOperation(
					name: "raw_confidence", kind: .reshapeND, inputs: ["second_nms.scores"],
					outputs: [NativeModelTensor(name: "raw_confidence", dataType: .float32, shape: [2, 1])],
					attributes: ["shape": .integers([2, 1])]
				)
			],
			outputs: ["raw_coordinates", "raw_confidence"]
		)
	}

	private func graphOwnedInterface() -> NativeModelDetectionInterface {
		NativeModelDetectionInterface(
			labels: ["thing"], boxCount: 2,
			coordinatesBlobName: "raw_coordinates", confidenceBlobName: "raw_confidence",
			suppressionOwnership: .graph
		)
	}

	private func compile(_ graph: NativeModelGraph, _ detection: NativeModelDetectionInterface) async throws -> MLModel {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mlmodel")
		addTeardownBlock { try? FileManager.default.removeItem(at: url) }
		try NativeModelCoreMLEmitter().emit(
			graph: graph, weights: Data(), to: url, detection: detection,
			detectionTarget: NativeModelDetectionTargetInfo(
				classCount: detection.labels.count, labelProvenance: .convention, coordinateMode: .normalizedByGraph
			)
		)
		let compiled = try await MLModel.compileModel(at: url)
		addTeardownBlock { try? FileManager.default.removeItem(at: compiled) }
		let configuration = MLModelConfiguration()
		configuration.computeUnits = .cpuOnly
		return try MLModel(contentsOf: compiled, configuration: configuration)
	}

	/// Feeds boxes as (centerX, centerY, width, height) normalized, and per-class scores.
	/// Values are halved on the way in to cancel the fixture graph's doubling.
	private func predict(
		_ model: MLModel, boxes: [[Double]], scores: [[Double]]
	) throws -> (coordinates: [[Double]], confidence: [[Double]]) {
		let coordinates = try MLMultiArray(shape: [NSNumber(value: boxes.count), 4], dataType: .double)
		for (row, box) in boxes.enumerated() {
			for (column, value) in box.enumerated() {
				coordinates[row * 4 + column] = NSNumber(value: value / 2)
			}
		}
		let classCount = scores[0].count
		let confidence = try MLMultiArray(shape: [NSNumber(value: scores.count), NSNumber(value: classCount)], dataType: .double)
		for (row, score) in scores.enumerated() {
			for (column, value) in score.enumerated() {
				confidence[row * classCount + column] = NSNumber(value: value / 2)
			}
		}
		let provider = try MLDictionaryFeatureProvider(dictionary: [
			"coordinates_in": MLFeatureValue(multiArray: coordinates),
			"confidence_in": MLFeatureValue(multiArray: confidence)
		])
		let prediction = try model.prediction(from: provider)
		return (
			try rows(of: XCTUnwrap(prediction.featureValue(for: "coordinates")?.multiArrayValue), columns: 4),
			try rows(of: XCTUnwrap(prediction.featureValue(for: "confidence")?.multiArrayValue), columns: classCount)
		)
	}

	private func predictGraphOwnedPipeline(
		_ model: MLModel, boxes: [[Double]], scores: [[Double]]
	) throws -> (coordinates: [[Double]], confidence: [[Double]]) {
		let coordinates = try MLMultiArray(shape: [1, NSNumber(value: boxes.count), 4], dataType: .double)
		for (row, box) in boxes.enumerated() {
			for (column, value) in box.enumerated() {
				coordinates[row * 4 + column] = NSNumber(value: value)
			}
		}
		let confidence = try MLMultiArray(shape: [1, NSNumber(value: scores.count), 1], dataType: .double)
		for (row, score) in scores.enumerated() {
			confidence[row] = NSNumber(value: score[0])
		}
		let prediction = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [
			"boxes_in": MLFeatureValue(multiArray: coordinates),
			"scores_in": MLFeatureValue(multiArray: confidence)
		]))
		return (
			try rows(of: XCTUnwrap(prediction.featureValue(for: "coordinates")?.multiArrayValue), columns: 4),
			try rows(of: XCTUnwrap(prediction.featureValue(for: "confidence")?.multiArrayValue), columns: 1)
		)
	}

	private func rows(of array: MLMultiArray, columns: Int) -> [[Double]] {
		let rowCount = array.count / columns
		return (0 ..< rowCount).map { row in
			(0 ..< columns).map { array[row * columns + $0].doubleValue }
		}
	}

	// MARK: - Interface

	func testDetectorPipeline_publishesTheCoordinatesAndConfidenceVisionRequires() async throws {
		let model = try await compile(passThroughGraph(boxCount: 3, classCount: 2), interface(boxCount: 3, labels: ["a", "b"]))

		let outputs = model.modelDescription.outputDescriptionsByName
		// These exact names are what `ModelLoadingService.inferType` keys the detector on.
		XCTAssertNotNil(outputs["coordinates"])
		XCTAssertNotNil(outputs["confidence"])
		// A detector must not look like a classifier, or the app would route it to the wrong driver.
		XCTAssertTrue(model.modelDescription.predictedFeatureName?.isEmpty ?? true)
		// Suppression removes a data-dependent number of rows, so the row count must be a range.
		XCTAssertNotNil(outputs["coordinates"]?.multiArrayConstraint?.shapeConstraint)
	}

	func testDetectorPipeline_thresholdInputsAreOptional() async throws {
		let model = try await compile(passThroughGraph(boxCount: 3, classCount: 2), interface(boxCount: 3, labels: ["a", "b"]))

		let inputs = model.modelDescription.inputDescriptionsByName
		// Vision predicts without supplying these; a non-optional threshold would fail every request.
		XCTAssertTrue(try XCTUnwrap(inputs["iouThreshold"]).isOptional)
		XCTAssertTrue(try XCTUnwrap(inputs["confidenceThreshold"]).isOptional)
	}

	func testGraphOwnedSuppression_keepsTheVisionAdapterFromApplyingAThirdPolicyPass() async throws {
		let model = try await compile(graphOwnedSuppressionGraph(), graphOwnedInterface())

		let inputs = model.modelDescription.inputDescriptionsByName
		XCTAssertNil(inputs["iouThreshold"])
		XCTAssertNil(inputs["confidenceThreshold"])

		// These boxes overlap at roughly 0.82: the two graph NMS layers use 0.99 and retain both.
		// The old pipeline-owned default of 0.45 would have reduced the result to one, making this a
		// direct behaviour check that the Vision-required terminal model is only an adapter.
		let (coordinates, confidence) = try predictGraphOwnedPipeline(
			model,
			boxes: [[0.50, 0.50, 0.60, 0.60], [0.52, 0.52, 0.60, 0.60]],
			scores: [[0.9], [0.8]]
		)
		XCTAssertEqual(coordinates.count, 2)
		XCTAssertEqual(confidence.count, 2)
	}

	// MARK: - Suppression behaviour

	func testDetectorPipeline_suppressesTheOverlappingLowerScoringBox() async throws {
		let model = try await compile(passThroughGraph(boxCount: 3, classCount: 1), interface(boxCount: 3, labels: ["thing"]))

		// Boxes 0 and 1 overlap almost completely (IoU well above 0.45); box 2 is disjoint.
		let (coordinates, confidence) = try predict(
			model,
			boxes: [[0.50, 0.50, 0.40, 0.40], [0.52, 0.52, 0.40, 0.40], [0.10, 0.10, 0.10, 0.10]],
			scores: [[0.90], [0.60], [0.80]]
		)

		XCTAssertEqual(coordinates.count, 2, "The lower-scoring overlapping box should have been suppressed.")
		XCTAssertEqual(confidence.count, 2)
		// Highest score first, and the geometry must survive suppression unmodified — this is the
		// assertion that catches a coordinate convention silently reinterpreted by Core ML.
		XCTAssertEqual(coordinates[0][0], 0.50, accuracy: 0.001)
		XCTAssertEqual(coordinates[0][1], 0.50, accuracy: 0.001)
		XCTAssertEqual(coordinates[0][2], 0.40, accuracy: 0.001)
		XCTAssertEqual(coordinates[0][3], 0.40, accuracy: 0.001)
		XCTAssertEqual(confidence[0][0], 0.90, accuracy: 0.001)
		XCTAssertEqual(coordinates[1][0], 0.10, accuracy: 0.001)
		XCTAssertEqual(confidence[1][0], 0.80, accuracy: 0.001)
	}

	func testDetectorPipeline_dropsBoxesBelowTheConfidenceThreshold() async throws {
		let model = try await compile(
			passThroughGraph(boxCount: 3, classCount: 1),
			interface(boxCount: 3, labels: ["thing"], confidence: 0.5)
		)

		let (coordinates, _) = try predict(
			model,
			boxes: [[0.10, 0.10, 0.10, 0.10], [0.50, 0.50, 0.10, 0.10], [0.90, 0.90, 0.10, 0.10]],
			scores: [[0.90], [0.10], [0.60]]
		)

		// All three are disjoint, so only the score floor removes anything.
		XCTAssertEqual(coordinates.count, 2)
		XCTAssertEqual(coordinates[0][0], 0.10, accuracy: 0.001)
		XCTAssertEqual(coordinates[1][0], 0.90, accuracy: 0.001)
	}

	func testDetectorPipeline_keepsPerClassRowCorrespondence() async throws {
		// Row i of coordinates must describe the same box as row i of confidence. A divergent
		// permute order in the decode would silently pair boxes with other boxes' scores.
		let model = try await compile(passThroughGraph(boxCount: 2, classCount: 3), interface(boxCount: 2, labels: ["a", "b", "c"]))

		let (coordinates, confidence) = try predict(
			model,
			boxes: [[0.20, 0.20, 0.10, 0.10], [0.80, 0.80, 0.10, 0.10]],
			scores: [[0.10, 0.90, 0.10], [0.70, 0.10, 0.10]]
		)

		XCTAssertEqual(coordinates.count, 2)
		// The 0.90 'b' score belongs to the box at 0.20, and it outranks the 0.70 'a' box.
		XCTAssertEqual(coordinates[0][0], 0.20, accuracy: 0.001)
		XCTAssertEqual(confidence[0][1], 0.90, accuracy: 0.001)
		XCTAssertEqual(coordinates[1][0], 0.80, accuracy: 0.001)
		XCTAssertEqual(confidence[1][0], 0.70, accuracy: 0.001)
	}

	// MARK: - Rejection

	func testDetectorPipeline_rejectsAnInterfaceTheGraphDoesNotProduce() {
		let graph = passThroughGraph(boxCount: 3, classCount: 2)
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mlmodel")
		defer { try? FileManager.default.removeItem(at: url) }

		// The graph emits 2 class columns; claiming 3 labels must fail loudly rather than produce a
		// model whose confidence matrix is silently misread.
		XCTAssertThrowsError(
			try NativeModelCoreMLEmitter().emit(
				graph: graph, weights: Data(), to: url,
				detection: interface(boxCount: 3, labels: ["a", "b", "c"]),
				detectionTarget: NativeModelDetectionTargetInfo(classCount: 3, labelProvenance: .convention, coordinateMode: .normalizedByGraph)
			)
		) { error in
			guard case .invalidDetectionInterface = error as? NativeModelCoreMLEmissionError else {
				return XCTFail("Expected invalidDetectionInterface, got \(error).")
			}
		}
	}

	func testDetectorPipeline_rejectsAMissingOutputBlob() {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mlmodel")
		defer { try? FileManager.default.removeItem(at: url) }

		XCTAssertThrowsError(
			try NativeModelCoreMLEmitter().emit(
				graph: passThroughGraph(boxCount: 3, classCount: 2), weights: Data(), to: url,
				detection: NativeModelDetectionInterface(
					labels: ["a", "b"], boxCount: 3,
					coordinatesBlobName: "not_a_blob", confidenceBlobName: "raw_confidence"
				),
				detectionTarget: NativeModelDetectionTargetInfo(classCount: 2, labelProvenance: .convention, coordinateMode: .normalizedByGraph)
			)
		) { error in
			guard case .invalidDetectionInterface = error as? NativeModelCoreMLEmissionError else {
				return XCTFail("Expected invalidDetectionInterface, got \(error).")
			}
		}
	}

	func testDetectorPipeline_rejectsATargetClassCountThatDisagreesWithLabels() {
		// A target class count that disagrees with the label vector would emit metadata that lies about
		// the model's class count; it must fail loudly instead.
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mlmodel")
		defer { try? FileManager.default.removeItem(at: url) }

		XCTAssertThrowsError(
			try NativeModelCoreMLEmitter().emit(
				graph: passThroughGraph(boxCount: 3, classCount: 2), weights: Data(), to: url,
				detection: interface(boxCount: 3, labels: ["a", "b"]),
				detectionTarget: NativeModelDetectionTargetInfo(classCount: 3, labelProvenance: .unnamed, coordinateMode: .normalizedByGraph)
			)
		) { error in
			guard case .invalidDetectionInterface = error as? NativeModelCoreMLEmissionError else {
				return XCTFail("Expected invalidDetectionInterface, got \(error).")
			}
		}
	}
}
