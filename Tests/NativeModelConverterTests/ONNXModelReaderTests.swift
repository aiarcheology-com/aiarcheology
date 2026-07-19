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

	func testRead_convWithSameUpperAutoPad_resolvesTheOddPixelToTheEndEdges() throws {
		// SAME on a 2x2 kernel over 3x3 needs 1 pad pixel per axis; SAME_UPPER puts it on the
		// bottom/right, so the resolved padding is the asymmetric [0, 0, 1, 1] and the output keeps
		// the input's spatial size. Caffe-era detector exports (tiny-yolov2) write this on every node.
		let kernel = onnxTensor(name: "w", dims: [1, 1, 2, 2], floats: [1, 1, 1, 1])
		let conv = onnxNode(op: "Conv", inputs: ["x", "w"], outputs: ["y"], name: "conv", attributes: [
			onnxStringAttr(name: "auto_pad", value: "SAME_UPPER")
		])
		let model = onnxModel(
			nodes: [conv], initializers: [kernel],
			inputs: [onnxValueInfo(name: "x", shape: [1, 1, 3, 3]), onnxValueInfo(name: "w", shape: [1, 1, 2, 2])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 1, 3, 3])]
		)
		let conversion = try ONNXModelReader().read(data: model)
		XCTAssertEqual(conversion.graph.operations.map(\.kind), [.convolution2D])
		XCTAssertEqual(conversion.graph.operations[0].attributes["padding"]?.integerArrayValue, [0, 0, 1, 1])
		XCTAssertEqual(conversion.graph.operations[0].outputs[0].shape, [1, 1, 3, 3])
		XCTAssertTrue(NativeModelGraphValidator().validate(conversion.graph).isConvertible)
	}

	func testRead_sameUpperWithHugeStride_isRejectedNotTrapped() throws {
		// The SAME_UPPER resolution multiplies file-supplied strides; a crafted near-Int.max stride
		// must produce a typed rejection, never an arithmetic-overflow trap.
		let maxPool = onnxNode(op: "MaxPool", inputs: ["x"], outputs: ["y"], name: "pool", attributes: [
			onnxIntsAttr(name: "kernel_shape", ints: [2, 2]),
			onnxIntsAttr(name: "strides", ints: [1 << 61, 1 << 61]),
			onnxStringAttr(name: "auto_pad", value: "SAME_UPPER")
		])
		let model = onnxModel(
			nodes: [maxPool], initializers: [],
			inputs: [onnxValueInfo(name: "x", shape: [1, 8, 13, 13])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 8, 13, 13])]
		)
		XCTAssertThrowsError(try ONNXModelReader().read(data: model)) { error in
			guard case ONNXModelReaderError.unsupportedAttribute = error else {
				return XCTFail("Expected unsupportedAttribute, got \(error)")
			}
		}
	}

	func testRead_convWithSameLowerAutoPad_isRejected() throws {
		let kernel = onnxTensor(name: "w", dims: [1, 1, 2, 2], floats: [1, 1, 1, 1])
		let conv = onnxNode(op: "Conv", inputs: ["x", "w"], outputs: ["y"], name: "conv", attributes: [
			onnxStringAttr(name: "auto_pad", value: "SAME_LOWER")
		])
		let model = onnxModel(
			nodes: [conv], initializers: [kernel],
			inputs: [onnxValueInfo(name: "x", shape: [1, 1, 3, 3]), onnxValueInfo(name: "w", shape: [1, 1, 2, 2])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 1, 3, 3])]
		)
		XCTAssertThrowsError(try ONNXModelReader().read(data: model)) { error in
			guard case ONNXModelReaderError.unsupportedAttribute = error else {
				return XCTFail("Expected unsupportedAttribute, got \(error)")
			}
		}
	}

	// MARK: - Detection-backbone lowering

	func testRead_leakyRelu_lowersWithItsAlpha() throws {
		let node = onnxNode(op: "LeakyRelu", inputs: ["x"], outputs: ["y"], name: "act", attributes: [
			onnxFloatAttr(name: "alpha", value: 0.1)
		])
		let model = onnxModel(
			nodes: [node], initializers: [],
			inputs: [onnxValueInfo(name: "x", shape: [1, 3, 4, 4])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 3, 4, 4])]
		)
		let conversion = try ONNXModelReader().read(data: model)
		XCTAssertEqual(conversion.graph.operations.map(\.kind), [.leakyReLU])
		XCTAssertEqual(conversion.graph.operations[0].attributes["alpha"]?.floatingPointValue ?? 0, 0.1, accuracy: 0.0001)
		XCTAssertTrue(NativeModelGraphValidator().validate(conversion.graph).isConvertible)
	}

	func testRead_leakyReluWithoutAlpha_usesTheONNXDefault() throws {
		let node = onnxNode(op: "LeakyRelu", inputs: ["x"], outputs: ["y"], name: "act")
		let model = onnxModel(
			nodes: [node], initializers: [],
			inputs: [onnxValueInfo(name: "x", shape: [1, 3, 4, 4])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 3, 4, 4])]
		)
		let conversion = try ONNXModelReader().read(data: model)
		XCTAssertEqual(conversion.graph.operations[0].attributes["alpha"]?.floatingPointValue ?? 0, 0.01, accuracy: 0.0001)
	}

	func testRead_mulByScalarInitializer_lowersToAConstantAndBroadcastMultiply() throws {
		// tiny-yolov2's embedded pixel normalization: Mul(image, [1]-scalar), then Add(bias, x) with
		// the constant on the FIRST input. Both must produce a load-constant plus the elementwise op.
		let scale = onnxTensor(name: "s", dims: [1], floats: [0.00392157])
		let bias = onnxTensor(name: "b", dims: [3, 1, 1], floats: [0, 0, 0])
		let mul = onnxNode(op: "Mul", inputs: ["x", "s"], outputs: ["scaled"], name: "scale")
		let add = onnxNode(op: "Add", inputs: ["b", "scaled"], outputs: ["y"], name: "shift")
		let model = onnxModel(
			nodes: [mul, add], initializers: [scale, bias],
			inputs: [onnxValueInfo(name: "x", shape: [1, 3, 4, 4])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 3, 4, 4])]
		)
		let conversion = try ONNXModelReader().read(data: model)
		XCTAssertEqual(conversion.graph.operations.map(\.kind), [.constant, .multiply, .constant, .add])
		// Constants are normalized to the [C, 1, 1] layout the load-constant layer takes.
		XCTAssertEqual(conversion.graph.weights.map(\.shape), [[1, 1, 1], [3, 1, 1]])
		XCTAssertTrue(NativeModelGraphValidator().validate(conversion.graph).isConvertible)
	}

	func testRead_addWithSpatialConstant_isRejected() throws {
		// A constant with spatial extent has no classic channel-wise broadcast; converting it would
		// silently mis-add.
		let bias = onnxTensor(name: "b", dims: [1, 3, 4, 4], floats: Array(repeating: 0, count: 48))
		let add = onnxNode(op: "Add", inputs: ["x", "b"], outputs: ["y"], name: "shift")
		let model = onnxModel(
			nodes: [add], initializers: [bias],
			inputs: [onnxValueInfo(name: "x", shape: [1, 3, 4, 4])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 3, 4, 4])]
		)
		XCTAssertThrowsError(try ONNXModelReader().read(data: model)) { error in
			guard case ONNXModelReaderError.unsupportedAttribute = error else {
				return XCTFail("Expected unsupportedAttribute, got \(error)")
			}
		}
	}

	func testRead_addWithLegacyBroadcastAttribute_isRejected() throws {
		// Pre-opset-7 Add/Mul broadcast is LEFT-aligned at `axis` — the opposite of the numpy
		// alignment the lowering assumes — so the legacy attributes must reject, not misconvert.
		let bias = onnxTensor(name: "b", dims: [3, 1, 1], floats: [0, 0, 0])
		let add = onnxNode(op: "Add", inputs: ["x", "b"], outputs: ["y"], name: "shift", attributes: [
			onnxIntAttr(name: "broadcast", value: 1),
			onnxIntAttr(name: "axis", value: 1)
		])
		let model = onnxModel(
			nodes: [add], initializers: [bias],
			inputs: [onnxValueInfo(name: "x", shape: [1, 3, 4, 4])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 3, 4, 4])]
		)
		XCTAssertThrowsError(try ONNXModelReader().read(data: model)) { error in
			guard case ONNXModelReaderError.unsupportedAttribute = error else {
				return XCTFail("Expected unsupportedAttribute, got \(error)")
			}
		}
	}

	func testRead_convKernelLargerThanPaddedInput_isRejected() throws {
		// (1 + 0 - 2)/2 + 1 truncates to 1 in Swift while ONNX floor-divides to 0 — the same trap
		// the MaxPool lowering guards; Conv must reject before the division.
		let kernel = onnxTensor(name: "w", dims: [1, 1, 2, 2], floats: [1, 1, 1, 1])
		let conv = onnxNode(op: "Conv", inputs: ["x", "w"], outputs: ["y"], name: "conv", attributes: [
			onnxIntsAttr(name: "kernel_shape", ints: [2, 2]),
			onnxIntsAttr(name: "strides", ints: [2, 2])
		])
		let model = onnxModel(
			nodes: [conv], initializers: [kernel],
			inputs: [onnxValueInfo(name: "x", shape: [1, 1, 1, 1]), onnxValueInfo(name: "w", shape: [1, 1, 2, 2])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 1, 1, 1])]
		)
		XCTAssertThrowsError(try ONNXModelReader().read(data: model)) { error in
			guard case ONNXModelReaderError.shapeInferenceFailed = error else {
				return XCTFail("Expected shapeInferenceFailed, got \(error)")
			}
		}
	}

	func testRead_mulWithRankOneVectorConstant_isRejected() throws {
		// ONNX broadcasting is right-aligned: a rank-1 [3] against [1, 3, 4, 4] pairs with the WIDTH
		// axis, not channels. Converting it channel-wise would be silently wrong, so it is rejected
		// even though the extent happens to match the channel count.
		let scale = onnxTensor(name: "s", dims: [3], floats: [1, 2, 3])
		let mul = onnxNode(op: "Mul", inputs: ["x", "s"], outputs: ["y"], name: "scale")
		let model = onnxModel(
			nodes: [mul], initializers: [scale],
			inputs: [onnxValueInfo(name: "x", shape: [1, 3, 4, 4])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 3, 4, 4])]
		)
		XCTAssertThrowsError(try ONNXModelReader().read(data: model)) { error in
			guard case ONNXModelReaderError.unsupportedAttribute = error else {
				return XCTFail("Expected unsupportedAttribute, got \(error)")
			}
		}
	}

	func testRead_mulWithMismatchedChannelConstant_isRejected() throws {
		let scale = onnxTensor(name: "s", dims: [4, 1, 1], floats: [1, 1, 1, 1])
		let mul = onnxNode(op: "Mul", inputs: ["x", "s"], outputs: ["y"], name: "scale")
		let model = onnxModel(
			nodes: [mul], initializers: [scale],
			inputs: [onnxValueInfo(name: "x", shape: [1, 3, 4, 4])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 3, 4, 4])]
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

	func testRead_maxPoolWithBothAutoPadAndExplicitPads_isRejected() throws {
		// auto_pad and non-zero pads together are contradictory: guessing which one the exporter
		// meant would silently change the feature maps.
		let model = maxPoolModel(inputShape: [1, 64, 112, 112], kernel: [3, 3], strides: [2, 2], pads: [1, 1, 1, 1],
			extraAttributes: [onnxStringAttr(name: "auto_pad", value: "SAME_UPPER")])
		XCTAssertThrowsError(try ONNXModelReader().read(data: model)) { error in
			guard case ONNXModelReaderError.unsupportedAttribute = error else {
				return XCTFail("Expected unsupportedAttribute, got \(error)")
			}
		}
	}

	func testRead_maxPoolStrideOneSameUpper_padsTheEndAndKeepsTheGridSize() throws {
		// tiny-yolov2's final pool: 13x13, kernel 2, stride 1, SAME_UPPER -> pads [0, 0, 1, 1] and a
		// 13x13 output.
		let maxPool = onnxNode(op: "MaxPool", inputs: ["x"], outputs: ["y"], name: "pool", attributes: [
			onnxIntsAttr(name: "kernel_shape", ints: [2, 2]),
			onnxIntsAttr(name: "strides", ints: [1, 1]),
			onnxStringAttr(name: "auto_pad", value: "SAME_UPPER")
		])
		let model = onnxModel(
			nodes: [maxPool], initializers: [],
			inputs: [onnxValueInfo(name: "x", shape: [1, 512, 13, 13])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 512, 13, 13])]
		)
		let conversion = try ONNXModelReader().read(data: model)
		XCTAssertEqual(conversion.graph.operations.map(\.kind), [.maxPool2D])
		XCTAssertEqual(conversion.graph.operations[0].attributes["padding"]?.integerArrayValue, [0, 0, 1, 1])
		XCTAssertEqual(conversion.graph.operations[0].outputs[0].shape, [1, 512, 13, 13])
		XCTAssertTrue(NativeModelGraphValidator().validate(conversion.graph).isConvertible)
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

	func testRead_maxPoolWithAsymmetricPads_lowersPerEdge() throws {
		// Explicit per-edge pads [top 1, left 0, bottom 2, right 0]: padded height 115 -> 57 rows,
		// unpadded width 112 -> 55 columns.
		let model = maxPoolModel(inputShape: [1, 64, 112, 112], kernel: [3, 3], strides: [2, 2], pads: [1, 0, 2, 0])
		let conversion = try ONNXModelReader().read(data: model)
		XCTAssertEqual(conversion.graph.operations.map(\.kind), [.maxPool2D])
		XCTAssertEqual(conversion.graph.operations[0].attributes["padding"]?.integerArrayValue, [1, 0, 2, 0])
		XCTAssertEqual(conversion.graph.operations[0].outputs[0].shape, [1, 64, 57, 55])
		XCTAssertTrue(NativeModelGraphValidator().validate(conversion.graph).isConvertible)
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

	// MARK: - Concat lowering (channel-axis join)

	func testRead_concatTwoInputs_sumsChannels() throws {
		// Two [1,64,55,55] branches join on the channel axis -> [1,128,55,55].
		let model = concatModel(inputShape: [1, 64, 55, 55], count: 2, axis: 1)
		let conversion = try ONNXModelReader().read(data: model)
		XCTAssertEqual(conversion.graph.operations.map(\.kind), [.concatenate])
		XCTAssertEqual(conversion.graph.operations[0].outputs[0].shape, [1, 128, 55, 55])
		XCTAssertEqual(conversion.graph.operations[0].inputs, ["x", "x"])
		XCTAssertTrue(NativeModelGraphValidator().validate(conversion.graph).isConvertible)
	}

	func testRead_concatThreeInputs_sumsChannels() throws {
		// Three [1,3,8,8] branches -> [1,9,8,8]; the channel dim is the sum of all inputs.
		let model = concatModel(inputShape: [1, 3, 8, 8], count: 3, axis: 1)
		let conversion = try ONNXModelReader().read(data: model)
		XCTAssertEqual(conversion.graph.operations.map(\.kind), [.concatenate])
		XCTAssertEqual(conversion.graph.operations[0].outputs[0].shape, [1, 9, 8, 8])
		XCTAssertEqual(conversion.graph.operations[0].inputs.count, 3)
		XCTAssertTrue(NativeModelGraphValidator().validate(conversion.graph).isConvertible)
	}

	func testRead_concatNegativeAxis_normalizesToChannel() throws {
		// axis -3 on a rank-4 tensor is the channel axis; accept it and record the normalized axis 1.
		let model = concatModel(inputShape: [1, 64, 55, 55], count: 2, axis: -3)
		let conversion = try ONNXModelReader().read(data: model)
		XCTAssertEqual(conversion.graph.operations.map(\.kind), [.concatenate])
		XCTAssertEqual(conversion.graph.operations[0].attributes["axis"], .integer(1))
	}

	func testRead_concatBatchAxis_isRejected() throws {
		// axis 0 is the batch axis; the native op only joins channels.
		let model = concatModel(inputShape: [1, 64, 55, 55], count: 2, axis: 0)
		XCTAssertThrowsError(try ONNXModelReader().read(data: model)) { error in
			guard case ONNXModelReaderError.unsupportedAttribute = error else {
				return XCTFail("Expected unsupportedAttribute, got \(error)")
			}
		}
	}

	func testRead_concatSpatialAxis_isRejected() throws {
		// axis 2 is a spatial axis; the native op only joins channels.
		let model = concatModel(inputShape: [1, 64, 55, 55], count: 2, axis: 2)
		XCTAssertThrowsError(try ONNXModelReader().read(data: model)) { error in
			guard case ONNXModelReaderError.unsupportedAttribute = error else {
				return XCTFail("Expected unsupportedAttribute, got \(error)")
			}
		}
	}

	func testRead_concatMissingAxis_isRejected() throws {
		// ONNX Concat has no default axis, so a missing one is unconvertible rather than assumed.
		let model = concatModel(inputShape: [1, 64, 55, 55], count: 2, axis: nil)
		XCTAssertThrowsError(try ONNXModelReader().read(data: model)) { error in
			guard case ONNXModelReaderError.unsupportedAttribute = error else {
				return XCTFail("Expected unsupportedAttribute, got \(error)")
			}
		}
	}

	func testRead_concatSpatialMismatch_isRejected() throws {
		// [1,64,55,55] + [1,64,54,55] disagree on a spatial dim; channel concat requires equal H/W.
		// A MaxPool k[2,1] s[1,1] p0 turns 55x55 -> 54x55, giving the mismatched second branch.
		let pool = onnxNode(op: "MaxPool", inputs: ["x"], outputs: ["p"], name: "pool", attributes: [
			onnxIntsAttr(name: "kernel_shape", ints: [2, 1]),
			onnxIntsAttr(name: "strides", ints: [1, 1]),
			onnxIntsAttr(name: "pads", ints: [0, 0, 0, 0])
		])
		let concat = onnxNode(op: "Concat", inputs: ["x", "p"], outputs: ["y"], name: "concat", attributes: [
			onnxSignedIntAttr(name: "axis", value: 1)
		])
		let model = onnxModel(
			nodes: [pool, concat], initializers: [],
			inputs: [onnxValueInfo(name: "x", shape: [1, 64, 55, 55])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 128, 54, 55])]
		)
		XCTAssertThrowsError(try ONNXModelReader().read(data: model)) { error in
			guard case ONNXModelReaderError.shapeInferenceFailed = error else {
				return XCTFail("Expected shapeInferenceFailed, got \(error)")
			}
		}
	}

	func testRead_concatWithUnknownInput_isRejected() throws {
		// "ghost" is never produced and is not the model input, so its shape is unknown — this is also
		// how concat over an initializer or shape tensor (neither has a recorded activation shape) fails.
		let concat = onnxNode(op: "Concat", inputs: ["x", "ghost"], outputs: ["y"], name: "concat", attributes: [
			onnxSignedIntAttr(name: "axis", value: 1)
		])
		let model = onnxModel(
			nodes: [concat], initializers: [],
			inputs: [onnxValueInfo(name: "x", shape: [1, 64, 55, 55])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 128, 55, 55])]
		)
		XCTAssertThrowsError(try ONNXModelReader().read(data: model)) { error in
			guard case ONNXModelReaderError.shapeInferenceFailed = error else {
				return XCTFail("Expected shapeInferenceFailed, got \(error)")
			}
		}
	}

	/// Joins the single model input `count` times so the concat is the only emitted op (the reader
	/// requires exactly one model input). Pass `axis: nil` to omit the attribute entirely.
	private func concatModel(inputShape: [Int], count: Int, axis: Int?) -> Data {
		var attributes: [Data] = []
		if let axis { attributes.append(onnxSignedIntAttr(name: "axis", value: axis)) }
		let concat = onnxNode(op: "Concat", inputs: Array(repeating: "x", count: count), outputs: ["y"], name: "concat", attributes: attributes)
		let outputShape = [inputShape[0], inputShape[1] * count, inputShape[2], inputShape[3]]
		return onnxModel(
			nodes: [concat], initializers: [],
			inputs: [onnxValueInfo(name: "x", shape: inputShape)],
			outputs: [onnxValueInfo(name: "y", shape: outputShape)]
		)
	}

	// MARK: - Softmax lowering (opset-aware axis semantics)

	func testRead_softmaxOpset12ClassifierHead_defaultsToAxis1() throws {
		// SqueezeNet's shape: pre-13 default axis 1 over [1,1000,1,1] — trailing dims are 1, so the
		// coerce-to-2D and per-axis semantics coincide and the op is accepted.
		let model = softmaxModel(inputShape: [1, 1000, 1, 1], axis: nil, opsetVersion: 12)
		let conversion = try ONNXModelReader().read(data: model)
		XCTAssertEqual(conversion.graph.operations.map(\.kind), [.softmax])
		XCTAssertEqual(conversion.graph.operations[0].attributes["axis"]?.integerValue, 1)
		XCTAssertEqual(conversion.graph.operations[0].outputs[0].shape, [1, 1000, 1, 1])
		XCTAssertTrue(NativeModelGraphValidator().validate(conversion.graph).isConvertible)
	}

	func testRead_softmaxOpset12WithSpatialDims_isRejected() throws {
		// Pre-13, axis 1 over [1,3,4,4] normalizes across C*H*W jointly — softmaxND cannot express that.
		let model = softmaxModel(inputShape: [1, 3, 4, 4], axis: 1, opsetVersion: 12)
		XCTAssertThrowsError(try ONNXModelReader().read(data: model)) { error in
			guard case ONNXModelReaderError.unsupportedAttribute = error else {
				return XCTFail("Expected unsupportedAttribute, got \(error)")
			}
		}
	}

	func testRead_softmaxOpset13_defaultsToLastAxis() throws {
		// From opset 13 the default axis is −1 and the per-axis semantics match softmaxND for any shape.
		let model = softmaxModel(inputShape: [1, 3, 4, 4], axis: nil, opsetVersion: 13)
		let conversion = try ONNXModelReader().read(data: model)
		XCTAssertEqual(conversion.graph.operations[0].attributes["axis"]?.integerValue, 3)
	}

	func testRead_softmaxNegativeAxis_isNormalized() throws {
		let model = softmaxModel(inputShape: [1, 1000, 1, 1], axis: -3, opsetVersion: 12)
		let conversion = try ONNXModelReader().read(data: model)
		XCTAssertEqual(conversion.graph.operations[0].attributes["axis"]?.integerValue, 1)
	}

	func testRead_softmaxAxisOutOfRange_isRejected() throws {
		for axis in [4, -5] {
			let model = softmaxModel(inputShape: [1, 1000, 1, 1], axis: axis, opsetVersion: 13)
			XCTAssertThrowsError(try ONNXModelReader().read(data: model), "axis \(axis)") { error in
				guard case ONNXModelReaderError.unsupportedAttribute = error else {
					return XCTFail("Expected unsupportedAttribute for axis \(axis), got \(error)")
				}
			}
		}
	}

	func testRead_softmaxOpset13Rank2_defaultsToClassAxis() throws {
		// A [1,N] head at opset 13: default −1 lands on the class axis.
		let model = softmaxModel(inputShape: [1, 10], axis: nil, opsetVersion: 13)
		let conversion = try ONNXModelReader().read(data: model)
		XCTAssertEqual(conversion.graph.operations[0].attributes["axis"]?.integerValue, 1)
	}

	private func softmaxModel(inputShape: [Int], axis: Int?, opsetVersion: Int) -> Data {
		var attributes: [Data] = []
		if let axis { attributes.append(onnxSignedIntAttr(name: "axis", value: axis)) }
		let softmax = onnxNode(op: "Softmax", inputs: ["x"], outputs: ["y"], name: "softmax", attributes: attributes)
		return onnxModel(
			nodes: [softmax], initializers: [],
			inputs: [onnxValueInfo(name: "x", shape: inputShape)],
			outputs: [onnxValueInfo(name: "y", shape: inputShape)],
			opsetVersion: opsetVersion
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

	func testRead_nodeWithoutOutputs_isRejectedNotCrashed() throws {
		// A malformed node with no declared outputs must throw from the central `record` guard, for
		// every operator kind, instead of trapping on outputs[0].
		for op in ["Softmax", "Concat", "Relu"] {
			let inputs = op == "Concat" ? ["x", "x"] : ["x"]
			let attributes = op == "Concat" ? [onnxSignedIntAttr(name: "axis", value: 1)] : []
			let node = onnxNode(op: op, inputs: inputs, outputs: [], name: "broken", attributes: attributes)
			let model = onnxModel(
				nodes: [node], initializers: [],
				inputs: [onnxValueInfo(name: "x", shape: [1, 3, 4, 4])],
				outputs: [onnxValueInfo(name: "y", shape: [1, 3, 4, 4])]
			)
			XCTAssertThrowsError(try ONNXModelReader().read(data: model), op) { error in
				guard error is ONNXModelReaderError else {
					return XCTFail("Expected a reader error for \(op), got \(error)")
				}
			}
		}
	}

	func testRead_maxPoolOversizeKernelWithStride2_isRejected() throws {
		// Swift's truncating division would turn (2 − 3)/2 + 1 into a bogus 1-wide output; the
		// padded-input >= kernel guard must reject before the division.
		let model = maxPoolModel(inputShape: [1, 1, 2, 2], kernel: [3, 3], strides: [2, 2], pads: [0, 0, 0, 0])
		XCTAssertThrowsError(try ONNXModelReader().read(data: model)) { error in
			guard case ONNXModelReaderError.shapeInferenceFailed = error else {
				return XCTFail("Expected shapeInferenceFailed, got \(error)")
			}
		}
	}

	func testRead_preOpset7DropoutWithoutIsTest_isRejected() throws {
		// Opsets 1–6 default `is_test` to 0 (training): only an explicit is_test=1 makes dropout the
		// identity, so the default must be rejected rather than silently aliased away.
		let dropout = onnxNode(op: "Dropout", inputs: ["x"], outputs: ["y"], name: "drop")
		let model = onnxModel(
			nodes: [dropout], initializers: [],
			inputs: [onnxValueInfo(name: "x", shape: [1, 3])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 3])],
			opsetVersion: 6
		)
		XCTAssertThrowsError(try ONNXModelReader().read(data: model)) { error in
			guard case ONNXModelReaderError.unsupportedAttribute = error else {
				return XCTFail("Expected unsupportedAttribute, got \(error)")
			}
		}
	}

	func testRead_preOpset7DropoutWithIsTest_isAliased() throws {
		let dropout = onnxNode(op: "Dropout", inputs: ["x"], outputs: ["y"], name: "drop", attributes: [
			onnxIntAttr(name: "is_test", value: 1)
		])
		let relu = onnxNode(op: "Relu", inputs: ["y"], outputs: ["z"], name: "relu")
		let model = onnxModel(
			nodes: [dropout, relu], initializers: [],
			inputs: [onnxValueInfo(name: "x", shape: [1, 3])],
			outputs: [onnxValueInfo(name: "z", shape: [1, 3])],
			opsetVersion: 6
		)
		let conversion = try ONNXModelReader().read(data: model)
		XCTAssertEqual(conversion.graph.operations.map(\.kind), [.relu])
		XCTAssertEqual(conversion.graph.operations[0].inputs, ["x"])
	}

	func testRead_zeroOpsetVersion_isRejected() throws {
		let model = onnxModel(
			nodes: [onnxNode(op: "Relu", inputs: ["x"], outputs: ["y"], name: "relu")],
			initializers: [],
			inputs: [onnxValueInfo(name: "x", shape: [1, 3])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 3])],
			opsetVersion: 0
		)
		XCTAssertThrowsError(try ONNXModelReader().read(data: model)) { error in
			guard case ONNXModelReaderError.invalidModel(let reason) = error else {
				return XCTFail("Expected invalidModel, got \(error)")
			}
			XCTAssertTrue(reason.contains("version"), reason)
		}
	}

	func testRead_emptyNodeName_fallsBackToOutputName() throws {
		// Caffe-era exporters (the zoo's SqueezeNet) write an empty node name, which the graph
		// validator would reject; the reader must substitute the output name for empty, not just
		// absent, names.
		let relu = onnxNode(op: "Relu", inputs: ["x"], outputs: ["y"], name: "")
		let model = onnxModel(
			nodes: [relu], initializers: [],
			inputs: [onnxValueInfo(name: "x", shape: [1, 3])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 3])]
		)

		let conversion = try ONNXModelReader().read(data: model)

		XCTAssertEqual(conversion.graph.operations.map(\.name), ["y"])
		XCTAssertTrue(NativeModelGraphValidator().validate(conversion.graph).isConvertible)
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

	/// Like `onnxIntAttr` but encodes the value as a two's-complement varint so negative axes (which
	/// `onnxIntAttr`'s `UInt64(value)` would trap on) round-trip through the reader's `Int(bitPattern:)`.
	private func onnxSignedIntAttr(name: String, value: Int) -> Data {
		CoreMLProtobufEncoder.message { attribute in
			CoreMLProtobufEncoder.appendStringField(1, value: name, to: &attribute)
			CoreMLProtobufEncoder.appendVarintField(3, value: UInt64(bitPattern: Int64(value)), to: &attribute)
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
