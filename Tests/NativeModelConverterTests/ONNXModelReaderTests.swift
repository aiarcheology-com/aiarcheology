//
//  ONNXModelReaderTests.swift
//  NativeModelConverterTests
//

import CoreML
import XCTest
@testable import NativeModelConverter

final class ONNXModelReaderTests: XCTestCase {

	func testRead_reluModel_lowersToNativeGraph() throws {
		let model = onnxModel(
			nodes: [onnxNode(op: "Relu", inputs: ["x"], outputs: ["y"], name: "relu")],
			initializers: [],
			inputs: [onnxValueInfo(name: "x", shape: [1, 3])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 3])]
		)

		let conversion = try ONNXModelReader().read(data: model)

		XCTAssertEqual(conversion.graph.inputs.map(\.name), ["x"])
		XCTAssertEqual(conversion.graph.inputs[0].shape, [1, 3])
		XCTAssertEqual(conversion.graph.outputs, ["y"])
		XCTAssertEqual(conversion.graph.operations.map(\.kind), [.relu])
		XCTAssertEqual(conversion.graph.operations[0].outputs[0].shape, [1, 3])
		XCTAssertTrue(NativeModelGraphValidator().validate(conversion.graph).isConvertible)
	}

	func testRead_convModel_convertsAndPredicts() throws {
		// input [1,1,3,3] --conv(2x2 sum kernel)--> [1,1,2,2]. Verifies weight extraction, shape
		// inference, and that the lowered graph compiles + predicts through Core ML.
		let kernel = onnxTensor(name: "w", dims: [1, 1, 2, 2], floats: [1, 1, 1, 1])
		let conv = onnxNode(op: "Conv", inputs: ["x", "w"], outputs: ["y"], name: "conv", attributes: [
			onnxIntsAttr(name: "kernel_shape", ints: [2, 2]),
			onnxIntsAttr(name: "strides", ints: [1, 1]),
			onnxIntsAttr(name: "pads", ints: [0, 0, 0, 0]),
			onnxIntsAttr(name: "dilations", ints: [1, 1]),
			onnxIntAttr(name: "group", value: 1)
		])
		let model = onnxModel(
			nodes: [conv],
			initializers: [kernel],
			inputs: [onnxValueInfo(name: "x", shape: [1, 1, 3, 3]), onnxValueInfo(name: "w", shape: [1, 1, 2, 2])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 1, 2, 2])]
		)

		let conversion = try ONNXModelReader().read(data: model)
		XCTAssertEqual(conversion.graph.operations.map(\.kind), [.convolution2D])
		XCTAssertEqual(conversion.graph.operations[0].outputs[0].shape, [1, 1, 2, 2])
		XCTAssertEqual(conversion.graph.weights.map(\.name), ["w"])

		let modelURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mlmodel")
		defer { try? FileManager.default.removeItem(at: modelURL) }
		try NativeModelCoreMLEmitter().emit(graph: conversion.graph, weights: conversion.weights, to: modelURL)

		let compiled = try MLModel.compileModel(at: modelURL)
		let coreMLModel = try MLModel(contentsOf: compiled, configuration: cpuOnly())
		let input = try MLMultiArray(shape: [1, 1, 3, 3], dataType: .float32)
		for index in 0 ..< 9 { input[index] = NSNumber(value: index + 1) }
		let provider = try MLDictionaryFeatureProvider(dictionary: ["x": MLFeatureValue(multiArray: input)])
		let prediction = try coreMLModel.prediction(from: provider)
		let output = try XCTUnwrap(prediction.featureValue(for: "y")?.multiArrayValue)

		// 2x2 sum over the 3x3 ramp: [1+2+4+5, 2+3+5+6, 4+5+7+8, 5+6+8+9] = [12, 16, 24, 28].
		XCTAssertEqual((0 ..< 4).map { output[$0].floatValue }, [12, 16, 24, 28])
	}

	func testRead_gemmModel_lowersToLinear() throws {
		let weight = onnxTensor(name: "w", dims: [3, 4], floats: Array(repeating: 0, count: 12))
		let bias = onnxTensor(name: "b", dims: [3], floats: [0, 0, 0])
		let gemm = onnxNode(op: "Gemm", inputs: ["x", "w", "b"], outputs: ["y"], name: "fc", attributes: [
			onnxIntAttr(name: "transB", value: 1)
		])
		let model = onnxModel(
			nodes: [gemm],
			initializers: [weight, bias],
			inputs: [onnxValueInfo(name: "x", shape: [1, 4]), onnxValueInfo(name: "w", shape: [3, 4]), onnxValueInfo(name: "b", shape: [3])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 3])]
		)

		let conversion = try ONNXModelReader().read(data: model)

		XCTAssertEqual(conversion.graph.operations.map(\.kind), [.linear])
		XCTAssertEqual(conversion.graph.operations[0].outputs[0].shape, [1, 3])
		XCTAssertEqual(conversion.graph.weights.map(\.name), ["w", "b"])
	}

	func testConvertONNX_endToEnd_producesLoadableModel() async throws {
		// Exercises the high-level `convert(onnx:to:)` orchestration (file read, FIFO gate, metrics,
		// atomic model write) rather than the reader in isolation.
		let kernel = onnxTensor(name: "w", dims: [1, 1, 2, 2], floats: [1, 1, 1, 1])
		let conv = onnxNode(op: "Conv", inputs: ["x", "w"], outputs: ["y"], name: "conv", attributes: [
			onnxIntsAttr(name: "kernel_shape", ints: [2, 2]),
			onnxIntsAttr(name: "strides", ints: [1, 1]),
			onnxIntsAttr(name: "pads", ints: [0, 0, 0, 0]),
			onnxIntsAttr(name: "dilations", ints: [1, 1]),
			onnxIntAttr(name: "group", value: 1)
		])
		let model = onnxModel(
			nodes: [conv],
			initializers: [kernel],
			inputs: [onnxValueInfo(name: "x", shape: [1, 1, 3, 3]), onnxValueInfo(name: "w", shape: [1, 1, 2, 2])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 1, 2, 2])]
		)

		let onnxURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).onnx")
		let modelURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mlmodel")
		defer {
			try? FileManager.default.removeItem(at: onnxURL)
			try? FileManager.default.removeItem(at: modelURL)
		}
		try model.write(to: onnxURL)

		let metrics = try await NativeModelConverter().convert(onnx: onnxURL, to: modelURL)
		XCTAssertEqual(metrics.emission.operationCount, 1)
		XCTAssertGreaterThan(metrics.emission.outputModelByteCount, 0)
		XCTAssertTrue(FileManager.default.fileExists(atPath: modelURL.path))

		// The emitted model must compile and load through Core ML.
		let compiled = try await MLModel.compileModel(at: modelURL)
		_ = try MLModel(contentsOf: compiled, configuration: cpuOnly())
	}

	func testConvertONNX_unsupportedOperator_surfacesReaderMessage() async throws {
		let node = onnxNode(op: "TotallyMadeUpOp", inputs: ["x"], outputs: ["y"], name: "n")
		let model = onnxModel(
			nodes: [node],
			initializers: [],
			inputs: [onnxValueInfo(name: "x", shape: [1, 3])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 3])]
		)
		let onnxURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).onnx")
		let modelURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mlmodel")
		defer {
			try? FileManager.default.removeItem(at: onnxURL)
			try? FileManager.default.removeItem(at: modelURL)
		}
		try model.write(to: onnxURL)

		do {
			_ = try await NativeModelConverter().convert(onnx: onnxURL, to: modelURL)
			XCTFail("Expected conversion to fail for an unsupported operator")
		} catch let error as NativeModelConversionError {
			// The reader's operator-naming message is preserved (it is path-free), not masked.
			XCTAssertTrue(error.localizedDescription.contains("TotallyMadeUpOp"), error.localizedDescription)
		}
	}

	// MARK: - Hardening: reject unsupported attributes instead of silently misconverting

	func testRead_clipZeroToSix_lowersToRelu6() throws {
		let model = clipModel(min: 0, max: 6)
		let conversion = try ONNXModelReader().read(data: model)
		XCTAssertEqual(conversion.graph.operations.map(\.kind), [.relu6])
	}

	func testRead_clipWithNonRelu6Bounds_isRejected() throws {
		let model = clipModel(min: -1, max: 1)
		XCTAssertThrowsError(try ONNXModelReader().read(data: model)) { error in
			guard case ONNXModelReaderError.unsupportedAttribute = error else {
				return XCTFail("Expected unsupportedAttribute, got \(error)")
			}
		}
	}

	func testRead_gemmWithNonDefaultAlpha_isRejected() throws {
		let weight = onnxTensor(name: "w", dims: [3, 4], floats: Array(repeating: 0, count: 12))
		let gemm = onnxNode(op: "Gemm", inputs: ["x", "w"], outputs: ["y"], name: "fc", attributes: [
			onnxIntAttr(name: "transB", value: 1),
			onnxFloatAttr(name: "alpha", value: 2)
		])
		let model = onnxModel(
			nodes: [gemm], initializers: [weight],
			inputs: [onnxValueInfo(name: "x", shape: [1, 4]), onnxValueInfo(name: "w", shape: [3, 4])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 3])]
		)
		XCTAssertThrowsError(try ONNXModelReader().read(data: model)) { error in
			guard case ONNXModelReaderError.unsupportedAttribute = error else {
				return XCTFail("Expected unsupportedAttribute, got \(error)")
			}
		}
	}

	func testRead_convWithAutoPad_isRejected() throws {
		let kernel = onnxTensor(name: "w", dims: [1, 1, 2, 2], floats: [1, 1, 1, 1])
		let conv = onnxNode(op: "Conv", inputs: ["x", "w"], outputs: ["y"], name: "conv", attributes: [
			onnxStringAttr(name: "auto_pad", value: "SAME_UPPER")
		])
		let model = onnxModel(
			nodes: [conv], initializers: [kernel],
			inputs: [onnxValueInfo(name: "x", shape: [1, 1, 3, 3]), onnxValueInfo(name: "w", shape: [1, 1, 2, 2])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 1, 2, 2])]
		)
		XCTAssertThrowsError(try ONNXModelReader().read(data: model)) { error in
			guard case ONNXModelReaderError.unsupportedAttribute = error else {
				return XCTFail("Expected unsupportedAttribute, got \(error)")
			}
		}
	}

	// MARK: - MaxPool lowering

	func testRead_maxPoolResNetStem_lowersAndValidates() throws {
		// ResNet stem: [1,64,112,112] --MaxPool k3 s2 p1--> [1,64,56,56].
		let model = maxPoolModel(inputShape: [1, 64, 112, 112], kernel: [3, 3], strides: [2, 2], pads: [1, 1, 1, 1])
		let conversion = try ONNXModelReader().read(data: model)
		XCTAssertEqual(conversion.graph.operations.map(\.kind), [.maxPool2D])
		XCTAssertEqual(conversion.graph.operations[0].outputs[0].shape, [1, 64, 56, 56])
		XCTAssertTrue(NativeModelGraphValidator().validate(conversion.graph).isConvertible)
	}

	func testRead_maxPoolSqueezeNetStem_lowersAndValidates() throws {
		// SqueezeNet stem: [1,64,224,224] --MaxPool k3 s2 p0--> 224 -> (224-3)/2+1 = 111.
		let model = maxPoolModel(inputShape: [1, 64, 224, 224], kernel: [3, 3], strides: [2, 2], pads: [0, 0, 0, 0])
		let conversion = try ONNXModelReader().read(data: model)
		XCTAssertEqual(conversion.graph.operations.map(\.kind), [.maxPool2D])
		XCTAssertEqual(conversion.graph.operations[0].outputs[0].shape, [1, 64, 111, 111])
		XCTAssertTrue(NativeModelGraphValidator().validate(conversion.graph).isConvertible)
	}

	func testRead_maxPoolWithCeilMode_isRejected() throws {
		let model = maxPoolModel(inputShape: [1, 64, 112, 112], kernel: [3, 3], strides: [2, 2], pads: [1, 1, 1, 1],
			extraAttributes: [onnxIntAttr(name: "ceil_mode", value: 1)])
		XCTAssertThrowsError(try ONNXModelReader().read(data: model)) { error in
			guard case ONNXModelReaderError.unsupportedAttribute = error else {
				return XCTFail("Expected unsupportedAttribute, got \(error)")
			}
		}
	}

	func testRead_maxPoolWithAutoPad_isRejected() throws {
		let model = maxPoolModel(inputShape: [1, 64, 112, 112], kernel: [3, 3], strides: [2, 2], pads: [1, 1, 1, 1],
			extraAttributes: [onnxStringAttr(name: "auto_pad", value: "SAME_UPPER")])
		XCTAssertThrowsError(try ONNXModelReader().read(data: model)) { error in
			guard case ONNXModelReaderError.unsupportedAttribute = error else {
				return XCTFail("Expected unsupportedAttribute, got \(error)")
			}
		}
	}

	func testRead_maxPoolWithDilations_isRejected() throws {
		let model = maxPoolModel(inputShape: [1, 64, 112, 112], kernel: [3, 3], strides: [2, 2], pads: [1, 1, 1, 1],
			extraAttributes: [onnxIntsAttr(name: "dilations", ints: [2, 2])])
		XCTAssertThrowsError(try ONNXModelReader().read(data: model)) { error in
			guard case ONNXModelReaderError.unsupportedAttribute = error else {
				return XCTFail("Expected unsupportedAttribute, got \(error)")
			}
		}
	}

	func testRead_maxPoolWithAsymmetricPads_isRejected() throws {
		let model = maxPoolModel(inputShape: [1, 64, 112, 112], kernel: [3, 3], strides: [2, 2], pads: [1, 0, 2, 0])
		XCTAssertThrowsError(try ONNXModelReader().read(data: model)) { error in
			guard case ONNXModelReaderError.unsupportedAttribute = error else {
				return XCTFail("Expected unsupportedAttribute, got \(error)")
			}
		}
	}

	func testRead_maxPoolWithIndicesOutput_isRejected() throws {
		// A declared second (Indices) output can't be reproduced by Core ML pooling, so it is rejected.
		let maxPool = onnxNode(op: "MaxPool", inputs: ["x"], outputs: ["y", "indices"], name: "pool", attributes: [
			onnxIntsAttr(name: "kernel_shape", ints: [3, 3]),
			onnxIntsAttr(name: "strides", ints: [2, 2]),
			onnxIntsAttr(name: "pads", ints: [1, 1, 1, 1])
		])
		let model = onnxModel(
			nodes: [maxPool], initializers: [],
			inputs: [onnxValueInfo(name: "x", shape: [1, 64, 112, 112])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 64, 56, 56])]
		)
		XCTAssertThrowsError(try ONNXModelReader().read(data: model)) { error in
			guard case ONNXModelReaderError.unsupportedAttribute = error else {
				return XCTFail("Expected unsupportedAttribute, got \(error)")
			}
		}
	}

	func testRead_maxPoolWithoutKernelShape_isRejected() throws {
		// MaxPool has no kernel initializer to fall back on, so a missing kernel_shape is rejected.
		let maxPool = onnxNode(op: "MaxPool", inputs: ["x"], outputs: ["y"], name: "pool", attributes: [
			onnxIntsAttr(name: "strides", ints: [2, 2]),
			onnxIntsAttr(name: "pads", ints: [1, 1, 1, 1])
		])
		let model = onnxModel(
			nodes: [maxPool], initializers: [],
			inputs: [onnxValueInfo(name: "x", shape: [1, 64, 112, 112])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 64, 56, 56])]
		)
		XCTAssertThrowsError(try ONNXModelReader().read(data: model)) { error in
			guard case ONNXModelReaderError.unsupportedAttribute = error else {
				return XCTFail("Expected unsupportedAttribute, got \(error)")
			}
		}
	}

	func testRead_maxPoolKernelLargerThanInput_isRejected() throws {
		// [1,1,2,2] with a 5x5 kernel and no padding gives (2-5)/1+1 = -2 <= 0; reject rather than trap.
		let model = maxPoolModel(inputShape: [1, 1, 2, 2], kernel: [5, 5], strides: [1, 1], pads: [0, 0, 0, 0])
		XCTAssertThrowsError(try ONNXModelReader().read(data: model)) { error in
			guard case ONNXModelReaderError.shapeInferenceFailed = error else {
				return XCTFail("Expected shapeInferenceFailed, got \(error)")
			}
		}
	}

	private func maxPoolModel(inputShape: [Int], kernel: [Int], strides: [Int], pads: [Int], extraAttributes: [Data] = []) -> Data {
		let outputShape = [
			inputShape[0], inputShape[1],
			max((inputShape[2] + 2 * pads[0] - kernel[0]) / strides[0] + 1, 1),
			max((inputShape[3] + 2 * pads[1] - kernel[1]) / strides[1] + 1, 1)
		]
		let maxPool = onnxNode(op: "MaxPool", inputs: ["x"], outputs: ["y"], name: "pool", attributes: [
			onnxIntsAttr(name: "kernel_shape", ints: kernel),
			onnxIntsAttr(name: "strides", ints: strides),
			onnxIntsAttr(name: "pads", ints: pads)
		] + extraAttributes)
		return onnxModel(
			nodes: [maxPool], initializers: [],
			inputs: [onnxValueInfo(name: "x", shape: inputShape)],
			outputs: [onnxValueInfo(name: "y", shape: outputShape)]
		)
	}

	// MARK: - Opset, node domain, and pass-through (Identity/Dropout) aliasing

	func testRead_dropoutBetweenConvAndRelu_isAliasedAway() throws {
		// input --Conv--> c --Dropout(data + mask)--> d --Relu--> y. Inference-mode Dropout is the
		// identity, so both its outputs fold away and Relu must read the conv output directly.
		let kernel = onnxTensor(name: "w", dims: [1, 1, 2, 2], floats: [1, 1, 1, 1])
		let conv = onnxNode(op: "Conv", inputs: ["x", "w"], outputs: ["c"], name: "conv", attributes: [
			onnxIntsAttr(name: "kernel_shape", ints: [2, 2]),
			onnxIntsAttr(name: "strides", ints: [1, 1]),
			onnxIntsAttr(name: "pads", ints: [0, 0, 0, 0]),
			onnxIntsAttr(name: "dilations", ints: [1, 1]),
			onnxIntAttr(name: "group", value: 1)
		])
		let dropout = onnxNode(op: "Dropout", inputs: ["c"], outputs: ["d", "mask"], name: "drop")
		let relu = onnxNode(op: "Relu", inputs: ["d"], outputs: ["y"], name: "relu")
		let model = onnxModel(
			nodes: [conv, dropout, relu], initializers: [kernel],
			inputs: [onnxValueInfo(name: "x", shape: [1, 1, 3, 3]), onnxValueInfo(name: "w", shape: [1, 1, 2, 2])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 1, 2, 2])]
		)

		let conversion = try ONNXModelReader().read(data: model)

		XCTAssertEqual(conversion.graph.operations.map(\.kind), [.convolution2D, .relu])
		XCTAssertEqual(conversion.graph.operations[1].inputs.first, conversion.graph.operations[0].outputs[0].name)
		XCTAssertTrue(NativeModelGraphValidator().validate(conversion.graph).isConvertible)
	}

	func testRead_identityChain_resolvesThroughBothHops() throws {
		let id1 = onnxNode(op: "Identity", inputs: ["x"], outputs: ["a"], name: "id1")
		let id2 = onnxNode(op: "Identity", inputs: ["a"], outputs: ["b"], name: "id2")
		let relu = onnxNode(op: "Relu", inputs: ["b"], outputs: ["y"], name: "relu")
		let model = onnxModel(
			nodes: [id1, id2, relu], initializers: [],
			inputs: [onnxValueInfo(name: "x", shape: [1, 3])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 3])]
		)

		let conversion = try ONNXModelReader().read(data: model)

		XCTAssertEqual(conversion.graph.operations.map(\.kind), [.relu])
		// Both Identity hops collapse: Relu reads the model input directly.
		XCTAssertEqual(conversion.graph.operations[0].inputs, ["x"])
		XCTAssertEqual(conversion.graph.outputs, ["y"])
		XCTAssertTrue(NativeModelGraphValidator().validate(conversion.graph).isConvertible)
	}

	func testRead_trailingIdentityOutput_resolvesToUpstreamTensor() throws {
		let relu = onnxNode(op: "Relu", inputs: ["x"], outputs: ["r"], name: "relu")
		let identity = onnxNode(op: "Identity", inputs: ["r"], outputs: ["y"], name: "id")
		let model = onnxModel(
			nodes: [relu, identity], initializers: [],
			inputs: [onnxValueInfo(name: "x", shape: [1, 3])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 3])]
		)

		let conversion = try ONNXModelReader().read(data: model)

		XCTAssertEqual(conversion.graph.operations.map(\.kind), [.relu])
		// The declared output "y" is the trailing Identity's output; it must resolve to Relu's tensor "r".
		XCTAssertEqual(conversion.graph.outputs, ["r"])
		XCTAssertEqual(conversion.graph.outputs, [conversion.graph.operations[0].outputs[0].name])
		XCTAssertTrue(NativeModelGraphValidator().validate(conversion.graph).isConvertible)
	}

	func testRead_dropoutWithTrainingModeInput_isRejected() throws {
		// A third `training_mode` input means dropout is active — not the identity — so it is rejected.
		let dropout = onnxNode(op: "Dropout", inputs: ["x", "ratio", "training_mode"], outputs: ["y"], name: "drop")
		let model = onnxModel(
			nodes: [dropout], initializers: [],
			inputs: [onnxValueInfo(name: "x", shape: [1, 3])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 3])]
		)
		XCTAssertThrowsError(try ONNXModelReader().read(data: model)) { error in
			guard case ONNXModelReaderError.unsupportedAttribute = error else {
				return XCTFail("Expected unsupportedAttribute, got \(error)")
			}
		}
	}

	func testRead_customDomainNode_isRejectedAsUnsupportedOperation() throws {
		// A "Relu" in a custom domain is a different op; standard ReLU semantics must not be assumed.
		let node = onnxNode(op: "Relu", inputs: ["x"], outputs: ["y"], name: "custom", domain: "com.example")
		let model = onnxModel(
			nodes: [node], initializers: [],
			inputs: [onnxValueInfo(name: "x", shape: [1, 3])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 3])]
		)
		XCTAssertThrowsError(try ONNXModelReader().read(data: model)) { error in
			guard case ONNXModelReaderError.unsupportedOperation(let name) = error else {
				return XCTFail("Expected unsupportedOperation, got \(error)")
			}
			XCTAssertTrue(name.contains("com.example"), name)
		}
	}

	func testRead_oversizedOpsetVersion_doesNotTrap() throws {
		// An opset version beyond Int.max must clamp (newest semantics), not trap on conversion.
		let opset = CoreMLProtobufEncoder.message { opset in
			CoreMLProtobufEncoder.appendVarintField(2, value: UInt64.max, to: &opset)
		}
		let graph = CoreMLProtobufEncoder.message { graph in
			CoreMLProtobufEncoder.appendMessageField(1, value: onnxNode(op: "Relu", inputs: ["x"], outputs: ["y"], name: "relu"), to: &graph)
			CoreMLProtobufEncoder.appendMessageField(11, value: onnxValueInfo(name: "x", shape: [1, 3]), to: &graph)
			CoreMLProtobufEncoder.appendMessageField(12, value: onnxValueInfo(name: "y", shape: [1, 3]), to: &graph)
		}
		let model = CoreMLProtobufEncoder.message { model in
			CoreMLProtobufEncoder.appendMessageField(7, value: graph, to: &model)
			CoreMLProtobufEncoder.appendMessageField(8, value: opset, to: &model)
		}

		let conversion = try ONNXModelReader().read(data: model)
		XCTAssertEqual(conversion.graph.operations.map(\.kind), [.relu])
	}

	func testRead_missingOpsetImport_isRejected() throws {
		let model = onnxModel(
			nodes: [onnxNode(op: "Relu", inputs: ["x"], outputs: ["y"], name: "relu")],
			initializers: [],
			inputs: [onnxValueInfo(name: "x", shape: [1, 3])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 3])],
			opsetVersion: nil
		)
		XCTAssertThrowsError(try ONNXModelReader().read(data: model)) { error in
			guard case ONNXModelReaderError.invalidModel(let reason) = error else {
				return XCTFail("Expected invalidModel, got \(error)")
			}
			XCTAssertTrue(reason.contains("opset_import"), reason)
		}
	}

	private func clipModel(min: Float, max: Float) -> Data {
		let clip = onnxNode(op: "Clip", inputs: ["x"], outputs: ["y"], name: "clip", attributes: [
			onnxFloatAttr(name: "min", value: min),
			onnxFloatAttr(name: "max", value: max)
		])
		return onnxModel(
			nodes: [clip], initializers: [],
			inputs: [onnxValueInfo(name: "x", shape: [1, 3])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 3])]
		)
	}

	// MARK: - Minimal ONNX protobuf builders (reuse the encoder to write ONNX-shaped messages)

	private func onnxValueInfo(name: String, shape: [Int]) -> Data {
		let shapeMessage = CoreMLProtobufEncoder.message { shapeMessage in
			for dimension in shape {
				let dimensionMessage = CoreMLProtobufEncoder.message { dim in
					CoreMLProtobufEncoder.appendVarintField(1, value: UInt64(dimension), to: &dim)
				}
				CoreMLProtobufEncoder.appendMessageField(1, value: dimensionMessage, to: &shapeMessage)
			}
		}
		let tensorType = CoreMLProtobufEncoder.message { tensorType in
			CoreMLProtobufEncoder.appendVarintField(1, value: 1, to: &tensorType) // elem_type = FLOAT
			CoreMLProtobufEncoder.appendMessageField(2, value: shapeMessage, to: &tensorType)
		}
		let typeProto = CoreMLProtobufEncoder.message { typeProto in
			CoreMLProtobufEncoder.appendMessageField(1, value: tensorType, to: &typeProto)
		}
		return CoreMLProtobufEncoder.message { valueInfo in
			CoreMLProtobufEncoder.appendStringField(1, value: name, to: &valueInfo)
			CoreMLProtobufEncoder.appendMessageField(2, value: typeProto, to: &valueInfo)
		}
	}

	private func onnxTensor(name: String, dims: [Int], floats: [Float]) -> Data {
		let raw = floats.withUnsafeBytes { Data($0) }
		return CoreMLProtobufEncoder.message { tensor in
			for dimension in dims { CoreMLProtobufEncoder.appendVarintField(1, value: UInt64(dimension), to: &tensor) }
			CoreMLProtobufEncoder.appendVarintField(2, value: 1, to: &tensor) // data_type = FLOAT
			CoreMLProtobufEncoder.appendStringField(8, value: name, to: &tensor)
			CoreMLProtobufEncoder.appendMessageField(9, value: raw, to: &tensor) // raw_data
		}
	}

	private func onnxNode(op: String, inputs: [String], outputs: [String], name: String, attributes: [Data] = [], domain: String = "") -> Data {
		CoreMLProtobufEncoder.message { node in
			for input in inputs { CoreMLProtobufEncoder.appendStringField(1, value: input, to: &node) }
			for output in outputs { CoreMLProtobufEncoder.appendStringField(2, value: output, to: &node) }
			CoreMLProtobufEncoder.appendStringField(3, value: name, to: &node)
			CoreMLProtobufEncoder.appendStringField(4, value: op, to: &node)
			for attribute in attributes { CoreMLProtobufEncoder.appendMessageField(5, value: attribute, to: &node) }
			if !domain.isEmpty { CoreMLProtobufEncoder.appendStringField(7, value: domain, to: &node) } // NodeProto.domain
		}
	}

	private func onnxIntsAttr(name: String, ints: [Int]) -> Data {
		CoreMLProtobufEncoder.message { attribute in
			CoreMLProtobufEncoder.appendStringField(1, value: name, to: &attribute)
			for value in ints { CoreMLProtobufEncoder.appendVarintField(8, value: UInt64(value), to: &attribute) }
		}
	}

	private func onnxIntAttr(name: String, value: Int) -> Data {
		CoreMLProtobufEncoder.message { attribute in
			CoreMLProtobufEncoder.appendStringField(1, value: name, to: &attribute)
			CoreMLProtobufEncoder.appendVarintField(3, value: UInt64(value), to: &attribute)
		}
	}

	private func onnxFloatAttr(name: String, value: Float) -> Data {
		CoreMLProtobufEncoder.message { attribute in
			CoreMLProtobufEncoder.appendStringField(1, value: name, to: &attribute)
			CoreMLProtobufEncoder.appendFloatField(2, value: value, to: &attribute) // AttributeProto.f
		}
	}

	private func onnxStringAttr(name: String, value: String) -> Data {
		CoreMLProtobufEncoder.message { attribute in
			CoreMLProtobufEncoder.appendStringField(1, value: name, to: &attribute)
			CoreMLProtobufEncoder.appendStringField(4, value: value, to: &attribute) // AttributeProto.s
		}
	}

	private func onnxModel(nodes: [Data], initializers: [Data], inputs: [Data], outputs: [Data], opsetVersion: Int? = 12) -> Data {
		let graph = CoreMLProtobufEncoder.message { graph in
			for node in nodes { CoreMLProtobufEncoder.appendMessageField(1, value: node, to: &graph) }
			for initializer in initializers { CoreMLProtobufEncoder.appendMessageField(5, value: initializer, to: &graph) }
			for input in inputs { CoreMLProtobufEncoder.appendMessageField(11, value: input, to: &graph) }
			for output in outputs { CoreMLProtobufEncoder.appendMessageField(12, value: output, to: &graph) }
		}
		return CoreMLProtobufEncoder.message { model in
			CoreMLProtobufEncoder.appendMessageField(7, value: graph, to: &model)
			// ModelProto.opset_import is repeated field 8; the reader requires a default-domain entry. Pass
			// opsetVersion: nil to build a model deliberately missing it.
			if let opsetVersion {
				let opset = CoreMLProtobufEncoder.message { opset in
					CoreMLProtobufEncoder.appendVarintField(2, value: UInt64(opsetVersion), to: &opset) // version; domain omitted = default
				}
				CoreMLProtobufEncoder.appendMessageField(8, value: opset, to: &model)
			}
		}
	}

	private func cpuOnly() -> MLModelConfiguration {
		let configuration = MLModelConfiguration()
		configuration.computeUnits = .cpuOnly
		return configuration
	}
}
