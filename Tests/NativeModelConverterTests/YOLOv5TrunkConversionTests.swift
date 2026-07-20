//
//  YOLOv5TrunkConversionTests.swift
//  NativeModelConverterTests
//
//  End-to-end exact-ND oracle for the pinned YOLOv5-L export (AIA-0469 PR 3). The real graph uses
//  rank-5 reshape/transpose and axis-4 Split, plus the constant-square Pow lowering. It is not a
//  detector catalog entry: its `[1, N, 5 + C]` raw tensor still needs a separately audited adapter.
//

import CoreML
import CryptoKit
import Foundation
import XCTest
@testable import NativeModelConverter

final class YOLOv5TrunkConversionTests: XCTestCase {

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

	func testConvertPinnedYOLOv5LTrunk_matchesTheONNXRuntimeOracle() async throws {
		guard let directoryPath = ProcessInfo.processInfo.environment["NATIVE_MODEL_ONNX_DIRECTORY"] else {
			throw XCTSkip("Set NATIVE_MODEL_ONNX_DIRECTORY to fixtures from scripts/fetch_native_test_models.sh.")
		}
		let oracleURL = try XCTUnwrap(Bundle.module.url(forResource: "YOLOv5TrunkOracle", withExtension: "json"))
		let oracle = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: oracleURL))
		let modelURL = URL(fileURLWithPath: directoryPath, isDirectory: true).appendingPathComponent(oracle.fileName)
		guard FileManager.default.fileExists(atPath: modelURL.path) else {
			throw XCTSkip("\(oracle.fileName) is not present in \(directoryPath); fetch it with scripts/fetch_native_test_models.sh.")
		}
		let digest = SHA256.hash(data: try Data(contentsOf: modelURL, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
		XCTAssertEqual(digest, oracle.sha256, "Pinned YOLOv5 fixture bytes drifted.")

		let conversion = try ONNXModelReader().read(from: modelURL)
		XCTAssertEqual(conversion.graph.formatVersion, NativeModelGraph.exactNDFormatVersion)
		XCTAssertTrue(conversion.graph.operations.contains { $0.kind == .splitND }, "YOLOv5 must exercise exact-ND Split.")
		XCTAssertTrue(
			conversion.graph.operations.contains { $0.outputs.contains(where: { $0.name == "pow_1" }) && $0.kind == .multiply },
			"A constant square Pow must lower to multiply(x, x)."
		)
		let validation = NativeModelGraphValidator().validate(conversion.graph)
		XCTAssertTrue(validation.isConvertible, "graph validation failed: \(validation.issues)")

		let emittedURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mlmodel")
		addTeardownBlock { try? FileManager.default.removeItem(at: emittedURL) }
		_ = try await NativeModelConverter().convert(onnx: modelURL, to: emittedURL)
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
		var worstDifference: Float = 0
		var worstIndex = -1
		var failures = 0
		var mismatchDetails: [String] = []
		for sample in oracle.samples {
			guard sample.index >= 0, sample.index < output.count else {
				XCTFail("oracle sample index \(sample.index) is outside the output")
				continue
			}
			let difference = abs(output[sample.index].floatValue - sample.value)
			if difference > worstDifference {
				worstDifference = difference
				worstIndex = sample.index
			}
			let tolerance = sample.index % 6 < 4 ? oracle.coordinateAbsoluteTolerance : oracle.scoreAbsoluteTolerance
			if difference > tolerance {
				failures += 1
				mismatchDetails.append("\(sample.index): expected \(sample.value), got \(output[sample.index].floatValue), |Δ| \(difference) > \(tolerance)")
			}
		}
		XCTAssertEqual(
			failures, 0,
			"\(failures)/\(oracle.samples.count) YOLOv5 samples exceed their coordinate/score tolerances; worst |Δ| = \(worstDifference) at \(worstIndex): \(mismatchDetails.joined(separator: "; "))"
		)
	}
}
