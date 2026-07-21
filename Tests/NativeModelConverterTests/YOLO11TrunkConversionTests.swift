//
//  YOLO11TrunkConversionTests.swift
//  NativeModelConverterTests
//
//  Exact-ND regression test for the real YOLO11n attention graph. The samples exercise its rank-4
//  batched MatMuls, axis-2 `[32,32,64]` Split, rank-N shape operations, and SoftmaxND axis -1.
//

import CoreML
import CryptoKit
import Foundation
import XCTest
@testable import NativeModelConverter

final class YOLO11TrunkConversionTests: XCTestCase {

	private struct Oracle: Decodable {
		struct Sample: Decodable {
			let index: Int
			let value: Float
		}

		let fileName: String
		let sha256: String
		let inputName: String
		let outputName: String
		let outputShape: [Int]
		let coordinateAbsoluteTolerance: Float
		let scoreAbsoluteTolerance: Float
		let samples: [Sample]
	}

	func testConvertYOLO11nTrunk_matchesTheONNXRuntimeOracle() async throws {
		guard let directoryPath = ProcessInfo.processInfo.environment["NATIVE_MODEL_ONNX_DIRECTORY"] else {
			throw XCTSkip("Set NATIVE_MODEL_ONNX_DIRECTORY to fixtures from scripts/fetch_native_test_models.sh.")
		}
		let oracleURL = try XCTUnwrap(Bundle.module.url(forResource: "YOLO11TrunkOracle", withExtension: "json"))
		let oracle = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: oracleURL))
		let modelURL = URL(fileURLWithPath: directoryPath, isDirectory: true).appendingPathComponent(oracle.fileName)
		guard FileManager.default.fileExists(atPath: modelURL.path) else {
			throw XCTSkip("\(oracle.fileName) is not present in \(directoryPath); fetch it with scripts/fetch_native_test_models.sh.")
		}
		let digest = SHA256.hash(data: try Data(contentsOf: modelURL, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
		XCTAssertEqual(digest, oracle.sha256, "Pinned YOLO11 fixture bytes drifted.")

		let conversion = try ONNXModelReader().read(from: modelURL)
		XCTAssertEqual(conversion.graph.formatVersion, NativeModelGraph.exactNDFormatVersion)
		XCTAssertTrue(conversion.graph.operations.contains { $0.kind == .batchedMatrixMultiplicationND })
		XCTAssertTrue(
			conversion.graph.operations.contains {
				$0.kind == .splitND && $0.attributes["axis"]?.integerValue == 2
					&& $0.attributes["splitSizes"]?.integerArrayValue == [32, 32, 64]
			},
			"YOLO11 attention must preserve the Q/K/V axis-2 Split([32,32,64])."
		)
		XCTAssertTrue(conversion.graph.operations.contains { $0.kind == .softmax && $0.attributes["axis"]?.integerValue == 3 })
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
		let input = try MLMultiArray(shape: [1, 3, 640, 640], dataType: .float32)
		let pointer = input.dataPointer.bindMemory(to: Float.self, capacity: input.count)
		for index in 0 ..< input.count {
			pointer[index] = Float((index * 17 + 11) % 256) / 255
		}
		let prediction = try await model.prediction(
			from: MLDictionaryFeatureProvider(dictionary: [oracle.inputName: MLFeatureValue(multiArray: input)])
		)
		let output = try XCTUnwrap(prediction.featureValue(for: oracle.outputName)?.multiArrayValue)
		XCTAssertEqual(output.shape.map(\.intValue), oracle.outputShape)
		XCTAssertEqual(output.dataType, .float32)
		for sample in oracle.samples {
			guard sample.index >= 0, sample.index < output.count else {
				XCTFail("oracle sample index \(sample.index) is outside the output")
				continue
			}
			let channel = sample.index / 8_400
			let tolerance = channel < 4 ? oracle.coordinateAbsoluteTolerance : oracle.scoreAbsoluteTolerance
			XCTAssertEqual(output[sample.index].floatValue, sample.value, accuracy: tolerance, "YOLO11 output drifted at \(sample.index)")
		}
	}
}
