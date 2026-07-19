//
//  YOLOv8TrunkConversionTests.swift
//  NativeModelConverterTests
//
//  End-to-end trunk oracle for the YOLOv8n raw-output export (AIA-0469, PR 1): the real
//  yolov8n-s1777.onnx is lowered, emitted, compiled, and predicted, and the Core ML output is
//  compared against onnxruntime's answers at 507 pre-sampled positions
//  (Fixtures/YOLOv8TrunkOracle.json). The input is a deterministic integer pattern
//  (((c·31 + y·7 + x·13) mod 256) / 255) that is exact in float32 on both sides, so any drift
//  beyond the tolerance is a conversion bug, not noise.
//
//  Real model files are not committed. Point NATIVE_MODEL_ONNX_DIRECTORY at a directory holding
//  yolov8n-s1777.onnx (see scripts/fetch_native_test_models.sh); the test skips when absent.
//

import CoreML
import Foundation
import XCTest
@testable import NativeModelConverter

final class YOLOv8TrunkConversionTests: XCTestCase {

	private struct Oracle: Decodable {
		struct Sample: Decodable {
			let index: Int
			let value: Float
		}

		let fileName: String
		let inputName: String
		let outputName: String
		let outputShape: [Int]
		let absoluteTolerance: Float
		let samples: [Sample]
	}

	func testConvertYOLOv8nTrunk_matchesTheONNXRuntimeOracle() async throws {
		guard let directoryPath = ProcessInfo.processInfo.environment["NATIVE_MODEL_ONNX_DIRECTORY"] else {
			throw XCTSkip("Set NATIVE_MODEL_ONNX_DIRECTORY to a folder of .onnx fixtures to run the YOLOv8 trunk oracle.")
		}
		let oracleURL = try XCTUnwrap(Bundle.module.url(forResource: "YOLOv8TrunkOracle", withExtension: "json"))
		let oracle = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: oracleURL))
		let modelURL = URL(fileURLWithPath: directoryPath).appendingPathComponent(oracle.fileName)
		guard FileManager.default.fileExists(atPath: modelURL.path) else {
			throw XCTSkip("\(oracle.fileName) is not present in \(directoryPath); fetch it with scripts/fetch_native_test_models.sh.")
		}

		// Lower and emit. The trunk has no catalog entry yet, so this is a plain neural network with a
		// multi-array interface; reshape/transpose in the graph force the legacy rank-5 mapping, under
		// which the emitter declares the unit-batch features as [C, H, W] / the output as its blob shape.
		let conversion = try ONNXModelReader().read(from: modelURL)
		let validation = NativeModelGraphValidator().validate(conversion.graph)
		XCTAssertTrue(validation.isConvertible, "graph validation failed: \(validation.issues)")

		let emittedURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mlmodel")
		addTeardownBlock { try? FileManager.default.removeItem(at: emittedURL) }
		try NativeModelCoreMLEmitter().emit(graph: conversion.graph, weights: conversion.weights, to: emittedURL)

		let compiled = try await MLModel.compileModel(at: emittedURL)
		addTeardownBlock { try? FileManager.default.removeItem(at: compiled) }
		let configuration = MLModelConfiguration()
		configuration.computeUnits = .cpuOnly
		let model = try MLModel(contentsOf: compiled, configuration: configuration)

		// The oracle's deterministic input: ((c·31 + y·7 + x·13) mod 256) / 255 over [3, 640, 640].
		let input = try MLMultiArray(shape: [3, 640, 640], dataType: .float32)
		let pointer = input.dataPointer.bindMemory(to: Float.self, capacity: input.count)
		var offset = 0
		for channel in 0 ..< 3 {
			for row in 0 ..< 640 {
				for column in 0 ..< 640 {
					pointer[offset] = Float((channel * 31 + row * 7 + column * 13) % 256) / 255.0
					offset += 1
				}
			}
		}

		let provider = try MLDictionaryFeatureProvider(dictionary: [oracle.inputName: MLFeatureValue(multiArray: input)])
		let prediction = try await model.prediction(from: provider)
		let output = try XCTUnwrap(prediction.featureValue(for: oracle.outputName)?.multiArrayValue)

		let expectedCount = oracle.outputShape.reduce(1, *)
		XCTAssertEqual(output.count, expectedCount, "output element count drifted from \(oracle.outputShape)")

		// Compare at every sampled position. Report the worst offender rather than stopping at the
		// first, so a systematic axis error (which shifts *every* sample) is distinguishable from a
		// localized numeric one.
		var worstDifference: Float = 0
		var worstIndex = -1
		var failures = 0
		// Read through MLMultiArray's own accessor rather than binding the buffer to Float: a future
		// output type change would then fail this assertion cleanly instead of reinterpreting bytes.
		XCTAssertEqual(output.dataType, .float32, "oracle comparison assumes a float32 output")
		for sample in oracle.samples {
			// A corrupt fixture index must fail the test, not trap on an out-of-bounds read.
			guard sample.index >= 0, sample.index < output.count else {
				XCTFail("oracle sample index \(sample.index) is outside the output's \(output.count) elements")
				continue
			}
			let actual = output[sample.index].floatValue
			let difference = abs(actual - sample.value)
			if difference > worstDifference {
				worstDifference = difference
				worstIndex = sample.index
			}
			if difference > oracle.absoluteTolerance {
				failures += 1
			}
		}
		XCTAssertEqual(
			failures, 0,
			"\(failures)/\(oracle.samples.count) oracle samples exceed tolerance \(oracle.absoluteTolerance); worst |Δ| = \(worstDifference) at flat index \(worstIndex)"
		)
	}
}
