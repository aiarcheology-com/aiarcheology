//
//  NativeModelCoreMLEmitterTests.swift
//  NativeModelConverterTests
//

import CoreML
import XCTest
@testable import NativeModelConverter

final class NativeModelCoreMLEmitterTests: XCTestCase {

	func testEmit_reluGraph_compilesAndPredictsOnMacOS() throws {
		let graph = NativeModelGraph(
			formatVersion: 1,
			producer: NativeModelGraphProducer(name: "tests", version: "1.0.0"),
			inputs: [tensor("input")],
			weights: [],
			operations: [
				NativeModelOperation(
					name: "relu",
					kind: .relu,
					inputs: ["input"],
					outputs: [tensor("output")],
					attributes: [:]
				)
			],
			outputs: ["output"]
		)
		let modelURL = try temporaryDirectory().appendingPathComponent("relu.mlmodel")

		try NativeModelCoreMLEmitter().emit(graph: graph, to: modelURL)

		let compiledURL = try MLModel.compileModel(at: modelURL)
		let model = try MLModel(contentsOf: compiledURL, configuration: cpuOnlyConfiguration())
		let input = try MLMultiArray(shape: [1, 1, 2, 2], dataType: .float32)
		input[0] = -2
		input[1] = -0.5
		input[2] = 0.25
		input[3] = 3
		let provider = try MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(multiArray: input)])

		let prediction = try model.prediction(from: provider)
		let output = try XCTUnwrap(prediction.featureValue(for: "output")?.multiArrayValue)

		XCTAssertEqual(output[0].floatValue, 0, accuracy: 0.000_001)
		XCTAssertEqual(output[1].floatValue, 0, accuracy: 0.000_001)
		XCTAssertEqual(output[2].floatValue, 0.25, accuracy: 0.000_001)
		XCTAssertEqual(output[3].floatValue, 3, accuracy: 0.000_001)
	}

	func testEmit_weightBearingGraph_withoutWeightData_reportsBoundsFailure() {
		let graph = NativeModelGraph(
			formatVersion: 1,
			producer: NativeModelGraphProducer(name: "tests", version: "1.0.0"),
			inputs: [tensor("input")],
			weights: [NativeModelWeight(name: "unused", dataType: .float32, shape: [1], offset: 0, byteCount: 4)],
			operations: [
				NativeModelOperation(
					name: "relu",
					kind: .relu,
					inputs: ["input"],
					outputs: [tensor("output")],
					attributes: [:]
				)
			],
			outputs: ["output"]
		)

		XCTAssertThrowsError(try NativeModelCoreMLEmitter().emit(graph: graph, to: temporaryDirectory())) { error in
			XCTAssertEqual(
				error as? NativeModelCoreMLEmissionError,
				.weightDataOutOfBounds(name: "unused", offset: 0, byteCount: 4, availableByteCount: 0)
			)
		}
	}

	func testWeightDataOutOfBoundsDescription_withOverflowingRange_doesNotTrap() {
		// Rendering this diagnostic previously computed `offset + byteCount` and trapped on overflow.
		let error = NativeModelCoreMLEmissionError.weightDataOutOfBounds(
			name: "w",
			offset: .max - 3,
			byteCount: 4,
			availableByteCount: 4
		)

		let description = error.localizedDescription

		XCTAssertTrue(description.contains("w"))
		XCTAssertTrue(description.contains("\(UInt64.max - 3)"))
	}

	func testEmit_float16ReluGraph_compiles() throws {
		let graph = NativeModelGraph(
			formatVersion: 1,
			producer: NativeModelGraphProducer(name: "tests", version: "1.0.0"),
			inputs: [tensor("input", dataType: .float16)],
			weights: [],
			operations: [
				NativeModelOperation(
					name: "relu",
					kind: .relu,
					inputs: ["input"],
					outputs: [tensor("output", dataType: .float16)],
					attributes: [:]
				)
			],
			outputs: ["output"]
		)

		let modelURL = try temporaryDirectory().appendingPathComponent("relu-float16.mlmodel")

		try NativeModelCoreMLEmitter().emit(graph: graph, to: modelURL)

		XCTAssertNoThrow(try MLModel.compileModel(at: modelURL))
	}

	func testEmit_float32Convolution_compilesAndPredictsOnMacOS() throws {
		let graph = NativeModelGraph(
			formatVersion: 1,
			producer: NativeModelGraphProducer(name: "tests", version: "1.0.0"),
			inputs: [NativeModelTensor(name: "input", dataType: .float32, shape: [1, 1, 3, 3])],
			weights: [
				NativeModelWeight(name: "kernel", dataType: .float32, shape: [1, 1, 2, 2], offset: 0, byteCount: 16),
				NativeModelWeight(name: "bias", dataType: .float32, shape: [1], offset: 16, byteCount: 4)
			],
			operations: [
				NativeModelOperation(
					name: "conv",
					kind: .convolution2D,
					inputs: ["input", "kernel", "bias"],
					outputs: [NativeModelTensor(name: "output", dataType: .float32, shape: [1, 1, 2, 2])],
					attributes: [
						"kernelSize": .integers([2, 2]),
						"strides": .integers([1, 1]),
						"padding": .integers([0, 0]),
						"dilations": .integers([1, 1]),
						"groups": .integer(1)
					]
				)
			],
			outputs: ["output"]
		)
		let weights = float32Data([1, 0, 0, -1, 0.5])
		let modelURL = try temporaryDirectory().appendingPathComponent("conv.mlmodel")

		try NativeModelCoreMLEmitter().emit(graph: graph, weights: weights, to: modelURL)

		let compiledURL = try MLModel.compileModel(at: modelURL)
		let model = try MLModel(contentsOf: compiledURL, configuration: cpuOnlyConfiguration())
		let input = try MLMultiArray(shape: [1, 1, 3, 3], dataType: .float32)
		for index in 0..<9 {
			input[index] = NSNumber(value: index + 1)
		}
		let provider = try MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(multiArray: input)])

		let prediction = try model.prediction(from: provider)
		let output = try XCTUnwrap(prediction.featureValue(for: "output")?.multiArrayValue)

		for index in 0..<4 {
			XCTAssertEqual(output[index].floatValue, -3.5, accuracy: 0.000_001)
		}
	}

	func testEmit_float16ConvolutionWeights_compileAndPredictOnMacOS() throws {
		let graph = NativeModelGraph(
			formatVersion: 1,
			producer: NativeModelGraphProducer(name: "tests", version: "1.0.0"),
			inputs: [NativeModelTensor(name: "input", dataType: .float32, shape: [1, 1, 3, 3])],
			weights: [
				NativeModelWeight(name: "kernel", dataType: .float16, shape: [1, 1, 2, 2], offset: 0, byteCount: 8),
				NativeModelWeight(name: "bias", dataType: .float16, shape: [1], offset: 8, byteCount: 2)
			],
			operations: [
				NativeModelOperation(
					name: "conv",
					kind: .convolution2D,
					inputs: ["input", "kernel", "bias"],
					outputs: [NativeModelTensor(name: "output", dataType: .float32, shape: [1, 1, 2, 2])],
					attributes: [
						"kernelSize": .integers([2, 2]),
						"strides": .integers([1, 1]),
						"padding": .integers([0, 0]),
						"dilations": .integers([1, 1]),
						"groups": .integer(1)
					]
				)
			],
			outputs: ["output"]
		)
		let weights = float16Data([1, 0, 0, -1, 0.5])
		let modelURL = try temporaryDirectory().appendingPathComponent("conv-float16-weights.mlmodel")

		try NativeModelCoreMLEmitter().emit(graph: graph, weights: weights, to: modelURL)

		let compiledURL = try MLModel.compileModel(at: modelURL)
		let model = try MLModel(contentsOf: compiledURL, configuration: cpuOnlyConfiguration())
		let input = try MLMultiArray(shape: [1, 1, 3, 3], dataType: .float32)
		for index in 0..<9 {
			input[index] = NSNumber(value: index + 1)
		}
		let provider = try MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(multiArray: input)])

		let prediction = try model.prediction(from: provider)
		let output = try XCTUnwrap(prediction.featureValue(for: "output")?.multiArrayValue)

		for index in 0..<4 {
			XCTAssertEqual(output[index].floatValue, -3.5, accuracy: 0.000_001)
		}
	}

	func testEmit_depthwiseConvolution_compilesAndPredictsOnMacOS() throws {
		let graph = NativeModelGraph(
			formatVersion: 1,
			producer: NativeModelGraphProducer(name: "tests", version: "1.0.0"),
			inputs: [NativeModelTensor(name: "input", dataType: .float32, shape: [1, 2, 2, 2])],
			weights: [NativeModelWeight(name: "kernel", dataType: .float32, shape: [2, 1, 1, 1], offset: 0, byteCount: 8)],
			operations: [
				NativeModelOperation(
					name: "depthwise",
					kind: .convolution2D,
					inputs: ["input", "kernel"],
					outputs: [NativeModelTensor(name: "output", dataType: .float32, shape: [1, 2, 2, 2])],
					attributes: [
						"kernelSize": .integers([1, 1]),
						"strides": .integers([1, 1]),
						"padding": .integers([0, 0]),
						"dilations": .integers([1, 1]),
						"groups": .integer(2)
					]
				)
			],
			outputs: ["output"]
		)
		let modelURL = try temporaryDirectory().appendingPathComponent("depthwise.mlmodel")

		try NativeModelCoreMLEmitter().emit(graph: graph, weights: float32Data([2, 3]), to: modelURL)

		let compiledURL = try MLModel.compileModel(at: modelURL)
		let model = try MLModel(contentsOf: compiledURL, configuration: cpuOnlyConfiguration())
		let input = try MLMultiArray(shape: [1, 2, 2, 2], dataType: .float32)
		for (index, value) in [1, 2, 3, 4, 10, 20, 30, 40].enumerated() {
			input[index] = NSNumber(value: value)
		}
		let provider = try MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(multiArray: input)])

		let prediction = try model.prediction(from: provider)
		let output = try XCTUnwrap(prediction.featureValue(for: "output")?.multiArrayValue)

		for (index, expected) in [2, 4, 6, 8, 30, 60, 90, 120].enumerated() {
			XCTAssertEqual(output[index].floatValue, Float(expected), accuracy: 0.000_001)
		}
	}

	func testEmit_mobileNetStyleClassifierSpine_compilesAndPredictsOnMacOS() throws {
		let graph = NativeModelGraph(
			formatVersion: 1,
			producer: NativeModelGraphProducer(name: "tests", version: "1.0.0"),
			inputs: [NativeModelTensor(name: "input", dataType: .float32, shape: [1, 1, 2, 2])],
			weights: [
				weight("conv.weight", [1, 1, 1, 1], offset: 0),
				weight("bn.gamma", [1], offset: 4),
				weight("bn.beta", [1], offset: 8),
				weight("bn.mean", [1], offset: 12),
				weight("bn.variance", [1], offset: 16),
				weight("classifier.weight", [1, 1], offset: 20),
				weight("classifier.bias", [1], offset: 24)
			],
			operations: [
				NativeModelOperation(
					name: "conv",
					kind: .convolution2D,
					inputs: ["input", "conv.weight"],
					outputs: [tensor("conv", shape: [1, 1, 2, 2])],
					attributes: convolutionAttributes(kernelSize: [1, 1])
				),
				NativeModelOperation(
					name: "batchNorm",
					kind: .batchNormalization,
					inputs: ["conv", "bn.gamma", "bn.beta", "bn.mean", "bn.variance"],
					outputs: [tensor("normalized", shape: [1, 1, 2, 2])],
					attributes: ["epsilon": .floatingPoint(1)]
				),
				NativeModelOperation(
					name: "relu6",
					kind: .relu6,
					inputs: ["normalized"],
					outputs: [tensor("activated", shape: [1, 1, 2, 2])],
					attributes: [:]
				),
				NativeModelOperation(
					name: "residual",
					kind: .add,
					inputs: ["activated", "activated"],
					outputs: [tensor("residual", shape: [1, 1, 2, 2])],
					attributes: [:]
				),
				NativeModelOperation(
					name: "pool",
					kind: .globalAveragePool2D,
					inputs: ["residual"],
					outputs: [tensor("pooled", shape: [1, 1, 1, 1])],
					attributes: [:]
				),
				NativeModelOperation(
					name: "flatten",
					kind: .flatten,
					inputs: ["pooled"],
					outputs: [tensor("features", shape: [1, 1])],
					attributes: ["axis": .integer(1)]
				),
				NativeModelOperation(
					name: "classifier",
					kind: .linear,
					inputs: ["features", "classifier.weight", "classifier.bias"],
					outputs: [tensor("output", shape: [1, 1])],
					attributes: [:]
				)
			],
			outputs: ["output"]
		)
		let weights = float32Data([2, 2, 0, 0, 1, 3, 1])
		let modelURL = try temporaryDirectory().appendingPathComponent("mobilenet-style.mlmodel")

		try NativeModelCoreMLEmitter().emit(graph: graph, weights: weights, to: modelURL)

		let compiledURL = try MLModel.compileModel(at: modelURL)
		let model = try MLModel(contentsOf: compiledURL, configuration: cpuOnlyConfiguration())
		let input = try MLMultiArray(shape: [1, 1, 2, 2], dataType: .float32)
		for index in 0..<4 {
			input[index] = NSNumber(value: index + 1)
		}
		let provider = try MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(multiArray: input)])

		let prediction = try model.prediction(from: provider)
		let output = try XCTUnwrap(prediction.featureValue(for: "output")?.multiArrayValue)

		XCTAssertEqual(output[0].floatValue, 31.727_92, accuracy: 0.000_1)
	}

	private func tensor(
		_ name: String,
		dataType: NativeModelDataType = .float32,
		shape: [Int] = [1, 1, 2, 2]
	) -> NativeModelTensor {
		NativeModelTensor(name: name, dataType: dataType, shape: shape)
	}

	private func weight(_ name: String, _ shape: [Int], offset: UInt64) -> NativeModelWeight {
		NativeModelWeight(
			name: name,
			dataType: .float32,
			shape: shape,
			offset: offset,
			byteCount: UInt64(shape.reduce(1, *)) * 4
		)
	}

	private func convolutionAttributes(kernelSize: [Int]) -> [String: NativeModelAttribute] {
		[
			"kernelSize": .integers(kernelSize),
			"strides": .integers([1, 1]),
			"padding": .integers([0, 0]),
			"dilations": .integers([1, 1]),
			"groups": .integer(1)
		]
	}

	private func temporaryDirectory() throws -> URL {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		return directory
	}

	private func cpuOnlyConfiguration() -> MLModelConfiguration {
		let configuration = MLModelConfiguration()
		configuration.computeUnits = .cpuOnly
		return configuration
	}

	private func float32Data(_ values: [Float]) -> Data {
		values.withUnsafeBytes { Data($0) }
	}

	private func float16Data(_ values: [Float16]) -> Data {
		values.withUnsafeBytes { Data($0) }
	}
}
