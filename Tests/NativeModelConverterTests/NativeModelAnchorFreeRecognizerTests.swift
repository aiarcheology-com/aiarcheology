//
//  NativeModelAnchorFreeRecognizerTests.swift
//  NativeModelConverterTests
//
//  Hermetic (no fixture download, no Core ML compile) proofs of the anchor-free recognition audit:
//  the coordinate-space classification reads a constant's value, labels never come from a channel
//  count, and a graph that only *looks* like a detector is refused. The end-to-end numeric proof on
//  the real model lives in ONNXConversionIntegrationTests.
//

import Foundation
import XCTest
@testable import NativeModelConverter

final class NativeModelAnchorFreeRecognizerTests: XCTestCase {

	// MARK: - Coordinate classification (the value-based audit)

	func testClassify_uniformInputReciprocal_isNormalizedByGraph() {
		// A `÷640` folded into the box path presents as a uniform 1/640 constant.
		let values = [Float](repeating: 1.0 / 640, count: 4 * 3)
		XCTAssertEqual(
			NativeModelAnchorFreeRecognizer.classify(boxScale: values, boxCount: 3, width: 640, height: 640),
			.normalizedByGraph
		)
	}

	func testClassify_perAxisReciprocalForNonSquareInput_isNormalized() {
		// cx,w take 1/width; cy,h take 1/height — uniform within each channel but different across.
		let width = 640, height = 320, boxCount = 3
		var values: [Float] = []
		for channel in 0 ..< 4 {
			let reciprocal = channel % 2 == 0 ? 1.0 / Float(width) : 1.0 / Float(height)
			values += [Float](repeating: reciprocal, count: boxCount)
		}
		XCTAssertEqual(
			NativeModelAnchorFreeRecognizer.classify(boxScale: values, boxCount: boxCount, width: width, height: height),
			.normalizedByGraph
		)
	}

	func testClassify_perPositionStride_isPixelsOfInput() {
		// A `×stride` presents as a per-position (non-uniform) constant — the boxes are in pixels.
		let strides: [Float] = [8, 16, 32]
		let values = Array(repeating: strides, count: 4).flatMap { $0 }
		XCTAssertEqual(
			NativeModelAnchorFreeRecognizer.classify(boxScale: values, boxCount: 3, width: 640, height: 640),
			.pixelsOfInput(width: 640, height: 640)
		)
	}

	func testClassify_uniformButNotInputReciprocal_isRefused() {
		// A uniform 0.5 scale is neither the input reciprocal nor a stride — an unknown convention.
		let values = [Float](repeating: 0.5, count: 4 * 3)
		XCTAssertNil(NativeModelAnchorFreeRecognizer.classify(boxScale: values, boxCount: 3, width: 640, height: 640))
	}

	// MARK: - Label resolution

	func testResolveLabels_matchingNames_areMetadata() {
		let (labels, provenance) = NativeModelAnchorFreeRecognizer.resolveLabels(
			hints: UltralyticsDetectorHints(names: ["person", "bicycle", "car"]), classCount: 3
		)
		XCTAssertEqual(labels, ["person", "bicycle", "car"])
		XCTAssertEqual(provenance, .metadata)
	}

	func testResolveLabels_countMismatch_fallsBackToGeneric() {
		let (labels, provenance) = NativeModelAnchorFreeRecognizer.resolveLabels(
			hints: UltralyticsDetectorHints(names: ["person", "bicycle"]), classCount: 3
		)
		XCTAssertEqual(labels, ["class_0", "class_1", "class_2"])
		XCTAssertEqual(provenance, .unnamed)
	}

	func testResolveLabels_noNames_areUnnamed() {
		let (labels, provenance) = NativeModelAnchorFreeRecognizer.resolveLabels(
			hints: UltralyticsDetectorHints(), classCount: 2
		)
		XCTAssertEqual(labels, ["class_0", "class_1"])
		XCTAssertEqual(provenance, .unnamed)
	}

	// MARK: - Catalog invariant

	func testAnchorBasedChannelCountsAreUnique() {
		// Anchor-based selection keys on channel count, so two entries sharing one would be ambiguous.
		let counts = NativeModelDetectorCatalog.entries.map(\.channelCount)
		XCTAssertEqual(counts.count, Set(counts).count, "anchor-based entries must have unique channel counts")
	}

	// MARK: - Structural recognition & rejection

	func testRecognizes_normalizedAnchorFreeHead_asAnUnnamedDetector() throws {
		let input = makeAnchorFreeInput(boxScale: [Float](repeating: 1.0 / 640, count: 4 * 8), boxCount: 8, classCount: 80)
		let conversion = try NativeModelDetectorCatalog.detectionConversion(of: input)
		let detector = try XCTUnwrap(conversion, "a normalized anchor-free head must convert as a detector")
		XCTAssertEqual(detector.labelProvenance, .unnamed)
		XCTAssertEqual(detector.coordinateMode, .normalizedByGraph)
		XCTAssertEqual(detector.interface.labels.count, 80)
		XCTAssertEqual(detector.interface.boxCount, 8)
	}

	func testRecognizes_withMatchingMetadataNames_asAMetadataDetector() throws {
		let names = (0 ..< 80).map { "thing\($0)" }
		let input = makeAnchorFreeInput(
			boxScale: [Float](repeating: 1.0 / 640, count: 4 * 8), boxCount: 8, classCount: 80,
			hints: UltralyticsDetectorHints(names: names)
		)
		let detector = try XCTUnwrap(try NativeModelDetectorCatalog.detectionConversion(of: input))
		XCTAssertEqual(detector.labelProvenance, .metadata)
		XCTAssertEqual(detector.interface.labels, names)
	}

	func testRejects_whenScoreBranchIsNotSigmoid() throws {
		let input = makeAnchorFreeInput(
			boxScale: [Float](repeating: 1.0 / 640, count: 4 * 8), boxCount: 8, classCount: 80, scoreKind: .add
		)
		XCTAssertNil(try NativeModelDetectorCatalog.detectionConversion(of: input), "a non-sigmoid score branch is not a detector")
	}

	func testRejects_whenOutputIsNotAConcat() throws {
		let input = makeAnchorFreeInput(
			boxScale: [Float](repeating: 1.0 / 640, count: 4 * 8), boxCount: 8, classCount: 80, outputIsConcat: false
		)
		XCTAssertNil(try NativeModelDetectorCatalog.detectionConversion(of: input), "an output not assembled by a channel concat is not a detector")
	}

	func testRejects_whenBoxScaleIsAmbiguous() throws {
		let input = makeAnchorFreeInput(boxScale: [Float](repeating: 0.5, count: 4 * 8), boxCount: 8, classCount: 80)
		XCTAssertNil(try NativeModelDetectorCatalog.detectionConversion(of: input), "an unknown box scale must be refused")
	}

	func testRejects_whenBoxCountExceedsTheCeiling() throws {
		// An oversized box axis is refused at the shape guard, before the scale constant is ever read.
		let input = makeAnchorFreeInput(
			boxScale: [1.0 / 640], boxCount: NativeModelAnchorFreeHead.maximumBoxCount + 1, classCount: 80
		)
		XCTAssertNil(try NativeModelDetectorCatalog.detectionConversion(of: input), "an oversized box axis must be refused")
	}

	func testRejects_whenBoxChannelsAreNotACentreSizeAssembly() throws {
		// The four box channels reach the concat directly, not via a centre⊕size join — not a cxcywh head.
		let input = makeAnchorFreeInput(
			boxScale: [Float](repeating: 1.0 / 640, count: 4 * 8), boxCount: 8, classCount: 80, boxAssembly: false
		)
		XCTAssertNil(try NativeModelDetectorCatalog.detectionConversion(of: input), "a box branch that is not centre⊕size is not a cxcywh detector")
	}

	// MARK: - Synthetic graph builder

	/// Builds a minimal lowered graph shaped like an anchor-free head: an image input, a box branch
	/// that ends in a multiply-by-constant, a score branch, and a channel concat producing `output0`.
	/// Only the structure the recognizer inspects is present — it never validates or compiles.
	private func makeAnchorFreeInput(
		boxScale: [Float],
		boxCount: Int,
		classCount: Int,
		scoreKind: NativeModelOperationKind = .sigmoid,
		outputIsConcat: Bool = true,
		boxAssembly: Bool = true,
		hints: UltralyticsDetectorHints = UltralyticsDetectorHints()
	) -> ONNXConversionInput {
		func tensor(_ name: String, _ shape: [Int]) -> NativeModelTensor {
			NativeModelTensor(name: name, dataType: .float32, shape: shape)
		}
		func operation(_ name: String, _ kind: NativeModelOperationKind, _ inputs: [String], _ shape: [Int], _ attributes: [String: NativeModelAttribute] = [:]) -> NativeModelOperation {
			NativeModelOperation(name: name, kind: kind, inputs: inputs, outputs: [tensor(name, shape)], attributes: attributes)
		}
		let channels = 4 + classCount
		let weights = boxScale.withUnsafeBytes { Data($0) }
		let boxScaleWeight = NativeModelWeight(
			name: "box_scale_w", dataType: .float32, shape: [4, boxCount, 1], offset: 0, byteCount: UInt64(weights.count)
		)
		var operations: [NativeModelOperation] = [
			operation("box_scale", .constant, ["box_scale_w"], [4, boxCount, 1]),
			operation("scores", scoreKind, ["images"], [1, classCount, boxCount])
		]
		if boxAssembly {
			// The ultralytics centre⊕size assembly the recognizer requires: two 2-channel tensors joined.
			operations.append(operation("centre", .identity, ["images"], [1, 2, boxCount]))
			operations.append(operation("size", .identity, ["images"], [1, 2, boxCount]))
			operations.append(operation("box_assembled", .concatenate, ["centre", "size"], [1, 4, boxCount], ["axis": .integer(1)]))
			operations.append(operation("box", .multiply, ["box_assembled", "box_scale"], [1, 4, boxCount]))
		} else {
			// A box branch whose four channels are not a centre⊕size concat (a direct source).
			operations.append(operation("box_src", .identity, ["images"], [1, 4, boxCount]))
			operations.append(operation("box", .multiply, ["box_src", "box_scale"], [1, 4, boxCount]))
		}
		if outputIsConcat {
			operations.append(operation("output0", .concatenate, ["box", "scores"], [1, channels, boxCount], ["axis": .integer(1)]))
		} else {
			operations.append(operation("output0", .sigmoid, ["box"], [1, channels, boxCount]))
		}
		let graph = NativeModelGraph(
			formatVersion: NativeModelGraph.currentFormatVersion,
			producer: NativeModelGraphProducer(name: "test", version: "1"),
			inputs: [tensor("images", [1, 3, 640, 640])],
			weights: [boxScaleWeight],
			operations: operations,
			outputs: ["output0"]
		)
		return ONNXConversionInput(graph: graph, weights: weights, detectorHints: hints)
	}
}
