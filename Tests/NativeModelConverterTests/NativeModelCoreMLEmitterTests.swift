//
//  NativeModelCoreMLEmitterTests.swift
//  NativeModelConverterTests
//

import CoreML
import CoreVideo
import XCTest
@testable import NativeModelConverter

final class NativeModelCoreMLEmitterTests: XCTestCase {

	func testEmit_imageClassifier_appliesImageNetPreprocessingAndLabels() throws {
		// A 3-channel image classifier: global-average-pool + flatten yields one value per channel, so
		// a uniform image reduces to the three preprocessed channel values, which softmax turns into
		// class probabilities. This isolates the image input + per-channel normalization + labels.
		let graph = NativeModelGraph(
			formatVersion: 1,
			producer: NativeModelGraphProducer(name: "tests", version: "1.0.0"),
			inputs: [NativeModelTensor(name: "input", dataType: .float32, shape: [1, 3, 2, 2])],
			weights: [],
			operations: [
				NativeModelOperation(
					name: "pool",
					kind: .globalAveragePool2D,
					inputs: ["input"],
					outputs: [tensor("pooled", shape: [1, 3, 1, 1])],
					attributes: [:]
				),
				NativeModelOperation(
					name: "flatten",
					kind: .flatten,
					inputs: ["pooled"],
					outputs: [tensor("output", shape: [1, 3])],
					attributes: ["axis": .integer(1)]
				)
			],
			outputs: ["output"]
		)
		let modelURL = try temporaryDirectory().appendingPathComponent("image-classifier.mlmodel")
		try NativeModelCoreMLEmitter().emit(
			graph: graph,
			weights: Data(),
			to: modelURL,
			classifierLabels: ["red", "green", "blue"],
			imagePreprocessing: .imageNetRGB
		)

		let compiledURL = try MLModel.compileModel(at: modelURL)
		let model = try MLModel(contentsOf: compiledURL, configuration: cpuOnlyConfiguration())

		// The input must be an image feature, not a multi-array.
		let inputDescription = try XCTUnwrap(model.modelDescription.inputDescriptionsByName["image"])
		XCTAssertEqual(inputDescription.type, .image)
		XCTAssertEqual(model.modelDescription.predictedFeatureName, "classLabel")

		let pixelBuffer = try uniformBGRAPixelBuffer(width: 2, height: 2, red: 100, green: 150, blue: 200)
		let provider = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: pixelBuffer)])
		let prediction = try model.prediction(from: provider)
		let probabilities = try XCTUnwrap(prediction.featureValue(for: "classLabelProbs")?.dictionaryValue as? [String: Double])

		// Expected: normalize each channel with ImageNet, then softmax over the three values.
		let mean = [0.485, 0.456, 0.406], std = [0.229, 0.224, 0.225]
		let pixels = [100.0, 150.0, 200.0]
		let normalized = (0 ..< 3).map { (pixels[$0] / 255 - mean[$0]) / std[$0] }
		let exponentials = normalized.map { exp($0) }
		let sum = exponentials.reduce(0, +)
		let expected = exponentials.map { $0 / sum }

		XCTAssertEqual(prediction.featureValue(for: "classLabel")?.stringValue, "blue")
		XCTAssertEqual(probabilities["red"] ?? -1, expected[0], accuracy: 1e-4)
		XCTAssertEqual(probabilities["green"] ?? -1, expected[1], accuracy: 1e-4)
		XCTAssertEqual(probabilities["blue"] ?? -1, expected[2], accuracy: 1e-4)
	}

	private func uniformBGRAPixelBuffer(width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8) throws -> CVPixelBuffer {
		var buffer: CVPixelBuffer?
		let status = CVPixelBufferCreate(
			kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
			[kCVPixelBufferCGImageCompatibilityKey as String: true] as CFDictionary, &buffer
		)
		let pixelBuffer = try XCTUnwrap(status == kCVReturnSuccess ? buffer : nil)
		CVPixelBufferLockBaseAddress(pixelBuffer, [])
		defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
		let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer)).assumingMemoryBound(to: UInt8.self)
		let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
		for y in 0 ..< height {
			for x in 0 ..< width {
				let offset = y * bytesPerRow + x * 4
				base[offset + 0] = blue
				base[offset + 1] = green
				base[offset + 2] = red
				base[offset + 3] = 255
			}
		}
		return pixelBuffer
	}

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

	func testEmit_maxPoolGraph_compilesAndPredictsOnMacOS() throws {
		// 2x2/2 max pooling over a 4x4 ramp: blocks (1,2,5,6) (3,4,7,8) (9,10,13,14) (11,12,15,16)
		// reduce to their maxima [6, 8, 14, 16].
		let graph = NativeModelGraph(
			formatVersion: 1,
			producer: NativeModelGraphProducer(name: "tests", version: "1.0.0"),
			inputs: [tensor("input", shape: [1, 1, 4, 4])],
			weights: [],
			operations: [
				NativeModelOperation(
					name: "pool",
					kind: .maxPool2D,
					inputs: ["input"],
					outputs: [tensor("output", shape: [1, 1, 2, 2])],
					attributes: [
						"kernelSize": .integers([2, 2]),
						"strides": .integers([2, 2]),
						"padding": .integers([0, 0])
					]
				)
			],
			outputs: ["output"]
		)
		let modelURL = try temporaryDirectory().appendingPathComponent("maxpool.mlmodel")
		try NativeModelCoreMLEmitter().emit(graph: graph, to: modelURL)

		let compiledURL = try MLModel.compileModel(at: modelURL)
		let model = try MLModel(contentsOf: compiledURL, configuration: cpuOnlyConfiguration())
		let input = try MLMultiArray(shape: [1, 1, 4, 4], dataType: .float32)
		for index in 0 ..< 16 { input[index] = NSNumber(value: index + 1) }
		let provider = try MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(multiArray: input)])

		let output = try XCTUnwrap(model.prediction(from: provider).featureValue(for: "output")?.multiArrayValue)
		XCTAssertEqual((0 ..< 4).map { output[$0].floatValue }, [6, 8, 14, 16])
	}

	func testEmit_concatGraph_joinsChannelsInOrder() throws {
		// Two ReLU branches of the same input concatenate on the channel axis; the negated branch is
		// distinguishable from the plain one, proving both order and axis.
		let graph = NativeModelGraph(
			formatVersion: 1,
			producer: NativeModelGraphProducer(name: "tests", version: "1.0.0"),
			inputs: [tensor("input", shape: [1, 1, 2, 2])],
			weights: [],
			operations: [
				NativeModelOperation(
					name: "branchA", kind: .relu, inputs: ["input"],
					outputs: [tensor("a", shape: [1, 1, 2, 2])], attributes: [:]
				),
				NativeModelOperation(
					name: "branchB", kind: .relu6, inputs: ["input"],
					outputs: [tensor("b", shape: [1, 1, 2, 2])], attributes: [:]
				),
				NativeModelOperation(
					name: "join", kind: .concatenate, inputs: ["a", "b"],
					outputs: [tensor("output", shape: [1, 2, 2, 2])], attributes: ["axis": .integer(1)]
				)
			],
			outputs: ["output"]
		)
		let modelURL = try temporaryDirectory().appendingPathComponent("concat.mlmodel")
		try NativeModelCoreMLEmitter().emit(graph: graph, to: modelURL)

		let compiledURL = try MLModel.compileModel(at: modelURL)
		let model = try MLModel(contentsOf: compiledURL, configuration: cpuOnlyConfiguration())
		let input = try MLMultiArray(shape: [1, 1, 2, 2], dataType: .float32)
		for (index, value) in [-1, 2, 7, 9].enumerated() { input[index] = NSNumber(value: value) }
		let provider = try MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(multiArray: input)])

		let output = try XCTUnwrap(model.prediction(from: provider).featureValue(for: "output")?.multiArrayValue)
		// Channel 0 = relu([-1,2,7,9]) = [0,2,7,9]; channel 1 = relu6 caps at 6 = [0,2,6,6].
		XCTAssertEqual((0 ..< 8).map { output[$0].floatValue }, [0, 2, 7, 9, 0, 2, 6, 6])
	}

	func testEmit_softmaxGraph_normalizesTheChannelAxis() throws {
		// The SqueezeNet head shape [1, C, 1, 1]: softmax at axis 1 over logits ln(1), ln(2), ln(4)
		// must produce exactly 1/7, 2/7, 4/7.
		let graph = NativeModelGraph(
			formatVersion: 1,
			producer: NativeModelGraphProducer(name: "tests", version: "1.0.0"),
			inputs: [tensor("input", shape: [1, 3, 1, 1])],
			weights: [],
			operations: [
				NativeModelOperation(
					name: "softmax",
					kind: .softmax,
					inputs: ["input"],
					outputs: [tensor("output", shape: [1, 3, 1, 1])],
					attributes: ["axis": .integer(1)]
				)
			],
			outputs: ["output"]
		)
		let modelURL = try temporaryDirectory().appendingPathComponent("softmax.mlmodel")
		try NativeModelCoreMLEmitter().emit(graph: graph, to: modelURL)

		let compiledURL = try MLModel.compileModel(at: modelURL)
		let model = try MLModel(contentsOf: compiledURL, configuration: cpuOnlyConfiguration())
		let input = try MLMultiArray(shape: [1, 3, 1, 1], dataType: .float32)
		for (index, value) in [Float(0), log(2), log(4)].enumerated() { input[index] = NSNumber(value: value) }
		let provider = try MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(multiArray: input)])

		let output = try XCTUnwrap(model.prediction(from: provider).featureValue(for: "output")?.multiArrayValue)
		XCTAssertEqual(output[0].floatValue, 1.0 / 7, accuracy: 0.000_01)
		XCTAssertEqual(output[1].floatValue, 2.0 / 7, accuracy: 0.000_01)
		XCTAssertEqual(output[2].floatValue, 4.0 / 7, accuracy: 0.000_01)
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
