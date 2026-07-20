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

	func testRead_channelSplitV1_decomposesToChannelSlices() throws {
		let split = onnxNode(
			op: "Split", inputs: ["x", "sizes"], outputs: ["first", "second"], name: "split",
			attributes: [onnxIntAttr(name: "axis", value: 1)]
		)
		let model = onnxModel(
			nodes: [split], initializers: [onnxInt64Tensor(name: "sizes", dims: [2], ints: [2, 4])],
			inputs: [onnxValueInfo(name: "x", shape: [1, 6, 3])],
			outputs: [onnxValueInfo(name: "second", shape: [1, 4, 3])], opsetVersion: 13
		)

		let conversion = try ONNXModelReader().read(data: model)
		XCTAssertEqual(conversion.graph.formatVersion, NativeModelGraph.legacyFormatVersion)
		XCTAssertEqual(conversion.graph.operations.map(\.kind), [.sliceChannels, .sliceChannels])
		XCTAssertEqual(conversion.graph.operations.map(\.name), ["split__split0", "split__split1"])
		XCTAssertEqual(conversion.graph.operations.map { $0.attributes["startChannel"]?.integerValue }, [0, 2])
		XCTAssertEqual(conversion.graph.operations.map { $0.attributes["endChannel"]?.integerValue }, [2, 6])
		XCTAssertEqual(conversion.graph.operations.map { $0.outputs[0].shape }, [[1, 2, 3], [1, 4, 3]])
		XCTAssertTrue(NativeModelGraphValidator().validate(conversion.graph).isConvertible)
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

	func testRead_addWithSpatialConstant_isStaticallyExpanded() throws {
		// A full-extent constant used to be rejected; it is now statically expanded to the activation's
		// canonical [C, H, W] and added same-shape. A [1, 3, 2, 2] bias over a [1, 3, 2, 2] activation
		// expands 1:1, so the constant weight carries the bias verbatim in [3, 2, 2] layout.
		let biasValues: [Float] = (0 ..< 12).map(Float.init)
		let bias = onnxTensor(name: "b", dims: [1, 3, 2, 2], floats: biasValues)
		let add = onnxNode(op: "Add", inputs: ["x", "b"], outputs: ["y"], name: "shift")
		let model = onnxModel(
			nodes: [add], initializers: [bias],
			inputs: [onnxValueInfo(name: "x", shape: [1, 3, 2, 2])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 3, 2, 2])]
		)
		let conversion = try ONNXModelReader().read(data: model)
		XCTAssertEqual(conversion.graph.operations.map(\.kind), [.constant, .add])
		XCTAssertEqual(conversion.graph.weights.map(\.shape), [[3, 2, 2]])
		XCTAssertEqual(floats(of: conversion.graph.weights[0], in: conversion.weights), biasValues)
		XCTAssertTrue(NativeModelGraphValidator().validate(conversion.graph).isConvertible)
	}

	func testRead_mulWithSpatialTableConstant_expandsAndTiles() throws {
		// The YOLOv8 stride-table shape: a per-position [1, N] constant against a [1, C, N] activation.
		// It has no channel broadcast, so it is tiled across the C channels into a full [C, N, 1]
		// constant — the table repeated once per channel — then multiplied same-shape.
		let table = onnxTensor(name: "t", dims: [1, 3], floats: [1, 2, 3])
		let mul = onnxNode(op: "Mul", inputs: ["x", "t"], outputs: ["y"], name: "scale")
		let model = onnxModel(
			nodes: [mul], initializers: [table],
			inputs: [onnxValueInfo(name: "x", shape: [1, 2, 3])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 2, 3])]
		)
		let conversion = try ONNXModelReader().read(data: model)
		XCTAssertEqual(conversion.graph.operations.map(\.kind), [.constant, .multiply])
		XCTAssertEqual(conversion.graph.weights.map(\.shape), [[2, 3, 1]])
		XCTAssertEqual(floats(of: conversion.graph.weights[0], in: conversion.weights), [1, 2, 3, 1, 2, 3])
		XCTAssertTrue(NativeModelGraphValidator().validate(conversion.graph).isConvertible)
	}

	func testRead_mulWithConstantThatBroadcastsTheActivation_isRejected() throws {
		// A constant larger than the activation on some axis would broadcast the *activation*, changing
		// its shape — no classic elementwise layer does that, so it is rejected, not expanded.
		let table = onnxTensor(name: "t", dims: [1, 5], floats: [1, 2, 3, 4, 5])
		let mul = onnxNode(op: "Mul", inputs: ["x", "t"], outputs: ["y"], name: "scale")
		let model = onnxModel(
			nodes: [mul], initializers: [table],
			inputs: [onnxValueInfo(name: "x", shape: [1, 2, 3])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 2, 3])]
		)
		XCTAssertThrowsError(try ONNXModelReader().read(data: model)) { error in
			guard case ONNXModelReaderError.unsupportedAttribute = error else {
				return XCTFail("Expected unsupportedAttribute, got \(error)")
			}
		}
	}

	func testRead_mulWithOversizedExpansion_isRejected() throws {
		// The expansion is bounded so a crafted shape cannot exhaust memory: a per-position constant over
		// a [1, 4, 2000, 2000] activation would expand to 16M elements, past the 8M cap.
		let table = onnxTensor(name: "t", dims: [1, 1, 1, 2000], floats: Array(repeating: 1, count: 2000))
		let mul = onnxNode(op: "Mul", inputs: ["x", "t"], outputs: ["y"], name: "scale")
		let model = onnxModel(
			nodes: [mul], initializers: [table],
			inputs: [onnxValueInfo(name: "x", shape: [1, 4, 2000, 2000])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 4, 2000, 2000])]
		)
		XCTAssertThrowsError(try ONNXModelReader().read(data: model)) { error in
			guard case ONNXModelReaderError.unsupportedAttribute = error else {
				return XCTFail("Expected unsupportedAttribute, got \(error)")
			}
		}
	}

	// MARK: - Sub / Div lowering

	func testRead_subByScalarInitializer_negatesAndAdds() throws {
		// Core ML has no subtract layer, so `x − 2` becomes `x + (−2)`: the constant is negated at read
		// time and lowered as an add. The negated value must land in the emitted weight.
		let bias = onnxTensor(name: "s", dims: [1], floats: [2])
		let sub = onnxNode(op: "Sub", inputs: ["x", "s"], outputs: ["y"], name: "shift")
		let model = onnxModel(
			nodes: [sub], initializers: [bias],
			inputs: [onnxValueInfo(name: "x", shape: [1, 3, 4, 4])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 3, 4, 4])]
		)
		let conversion = try ONNXModelReader().read(data: model)
		XCTAssertEqual(conversion.graph.operations.map(\.kind), [.constant, .add])
		XCTAssertEqual(conversion.graph.weights.map(\.shape), [[1, 1, 1]])
		XCTAssertEqual(floats(of: conversion.graph.weights[0], in: conversion.weights), [-2])
		XCTAssertTrue(NativeModelGraphValidator().validate(conversion.graph).isConvertible)
	}

	func testRead_subActivationMinusActivation_lowersToNegateMultiplyAdd() throws {
		// Two same-shape activations (here the one input used twice): multiply the subtrahend by a
		// synthesized scalar −1, then add. The synthesized constant, the multiply and the add appear in
		// that order.
		let sub = onnxNode(op: "Sub", inputs: ["x", "x"], outputs: ["y"], name: "diff")
		let model = onnxModel(
			nodes: [sub], initializers: [],
			inputs: [onnxValueInfo(name: "x", shape: [1, 3, 1, 1])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 3, 1, 1])]
		)
		let conversion = try ONNXModelReader().read(data: model)
		XCTAssertEqual(conversion.graph.operations.map(\.kind), [.constant, .multiply, .add])
		XCTAssertEqual(floats(of: conversion.graph.weights[0], in: conversion.weights), [-1])
		XCTAssertTrue(NativeModelGraphValidator().validate(conversion.graph).isConvertible)
	}

	func testRead_subConstantMinusActivation_negatesTheActivationAndAdds() throws {
		// `constant − activation` — YOLOv8's `anchors − lt` box decode. The rewrite must negate the
		// ACTIVATION (`c − a = a·(−1) + c`), never the constant: negating the constant would compute
		// `activation − constant` with silently swapped operands. Proven numerically: 5 − x, not x − 5.
		let base = onnxTensor(name: "c", dims: [1], floats: [5])
		let sub = onnxNode(op: "Sub", inputs: ["c", "x"], outputs: ["y"], name: "diff")
		let model = onnxModel(
			nodes: [sub], initializers: [base],
			inputs: [onnxValueInfo(name: "x", shape: [1, 3, 1, 1])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 3, 1, 1])]
		)
		let conversion = try ONNXModelReader().read(data: model)
		XCTAssertEqual(conversion.graph.operations.map(\.kind), [.constant, .multiply, .constant, .add])
		XCTAssertTrue(NativeModelGraphValidator().validate(conversion.graph).isConvertible)
		let output = try predictSingleInput(model: model, inputShape: [1, 3, 1, 1], values: [1, 2, 10], outputName: "y")
		XCTAssertEqual(output, [4, 3, -5])
	}

	func testRead_tensorNameCollidingWithSynthesizedName_isRejected() throws {
		// ONNX places no constraints on tensor names, so a crafted file can pre-claim a name the
		// reader synthesizes (here `b__negConst`, what Sub generates for its negated constant).
		// Silently adopting that activation would compute with the wrong operand — reject instead.
		let squatter = onnxNode(op: "Relu", inputs: ["x"], outputs: ["b__negConst"], name: "squatter")
		let bias = onnxTensor(name: "b", dims: [1], floats: [3])
		let sub = onnxNode(op: "Sub", inputs: ["b__negConst", "b"], outputs: ["y"], name: "diff")
		let model = onnxModel(
			nodes: [squatter, sub], initializers: [bias],
			inputs: [onnxValueInfo(name: "x", shape: [1, 3, 1, 1])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 3, 1, 1])]
		)
		XCTAssertThrowsError(try ONNXModelReader().read(data: model)) { error in
			guard case ONNXModelReaderError.invalidModel = error else {
				return XCTFail("Expected invalidModel, got \(error)")
			}
		}
	}

	func testRead_initializerNameCollidingWithSynthesizedName_isRejected() throws {
		// An *initializer* carries no `shapes` entry, so checking `shapes` alone would let it squat a
		// synthesized name and be reinterpreted as an activation later. Same for alias targets and
		// folded shape tensors — every namespace a model tensor can occupy must be checked.
		let squatter = onnxTensor(name: "b__negConst", dims: [1], floats: [7])
		let bias = onnxTensor(name: "b", dims: [1], floats: [3])
		let sub = onnxNode(op: "Sub", inputs: ["x", "b"], outputs: ["y"], name: "diff")
		let model = onnxModel(
			nodes: [sub], initializers: [bias, squatter],
			inputs: [onnxValueInfo(name: "x", shape: [1, 3, 1, 1])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 3, 1, 1])]
		)
		XCTAssertThrowsError(try ONNXModelReader().read(data: model)) { error in
			guard case ONNXModelReaderError.invalidModel = error else {
				return XCTFail("Expected invalidModel, got \(error)")
			}
		}
	}

	func testRead_divBySubnormalConstant_isRejected() throws {
		// Not zero, but its reciprocal overflows to +∞ — `0 / d` is 0 in ONNX while the lowered
		// `0 · ∞` would be NaN, so the non-finite reciprocal is rejected like the zero divisor.
		let divisor = onnxTensor(name: "d", dims: [1], floats: [Float.leastNonzeroMagnitude])
		let div = onnxNode(op: "Div", inputs: ["x", "d"], outputs: ["y"], name: "scale")
		let model = onnxModel(
			nodes: [div], initializers: [divisor],
			inputs: [onnxValueInfo(name: "x", shape: [1, 2, 1, 1])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 2, 1, 1])]
		)
		XCTAssertThrowsError(try ONNXModelReader().read(data: model)) { error in
			guard case ONNXModelReaderError.unsupportedAttribute = error else {
				return XCTFail("Expected unsupportedAttribute, got \(error)")
			}
		}
	}

	func testRead_resizeWithHugeScale_isRejectedNotTrapped() throws {
		// 2^62 is a finite integral Double; an unchecked Int conversion or output-shape multiply
		// would trap instead of failing as an unsupported model.
		let scales = onnxTensor(name: "s", dims: [4], floats: [1, 1, Float(pow(2.0, 62.0)), 2])
		let resize = onnxNode(op: "Resize", inputs: ["x", "", "s"], outputs: ["y"], name: "up", attributes: [
			onnxStringAttr(name: "mode", value: "nearest"),
			onnxStringAttr(name: "coordinate_transformation_mode", value: "asymmetric"),
			onnxStringAttr(name: "nearest_mode", value: "floor")
		])
		let model = onnxModel(
			nodes: [resize], initializers: [scales],
			inputs: [onnxValueInfo(name: "x", shape: [1, 2, 4, 4])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 2, 8, 8])]
		)
		XCTAssertThrowsError(try ONNXModelReader().read(data: model)) { error in
			guard case ONNXModelReaderError.unsupportedAttribute = error else {
				return XCTFail("Expected unsupportedAttribute, got \(error)")
			}
		}
	}

	func testRead_divByScalarInitializer_lowersToReciprocalMultiply() throws {
		// `x / 2` becomes `x · 0.5`: the divisor's reciprocal is computed at read time and multiplied.
		let divisor = onnxTensor(name: "d", dims: [1], floats: [2])
		let div = onnxNode(op: "Div", inputs: ["x", "d"], outputs: ["y"], name: "scale")
		let model = onnxModel(
			nodes: [div], initializers: [divisor],
			inputs: [onnxValueInfo(name: "x", shape: [1, 2, 1, 1])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 2, 1, 1])]
		)
		let conversion = try ONNXModelReader().read(data: model)
		XCTAssertEqual(conversion.graph.operations.map(\.kind), [.constant, .multiply])

		let modelURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mlmodel")
		defer { try? FileManager.default.removeItem(at: modelURL) }
		try NativeModelCoreMLEmitter().emit(graph: conversion.graph, weights: conversion.weights, to: modelURL)
		let compiled = try MLModel.compileModel(at: modelURL)
		let coreMLModel = try MLModel(contentsOf: compiled, configuration: cpuOnly())
		let input = try MLMultiArray(shape: [1, 2, 1, 1], dataType: .float32)
		input[0] = 4
		input[1] = 6
		let provider = try MLDictionaryFeatureProvider(dictionary: ["x": MLFeatureValue(multiArray: input)])
		let prediction = try coreMLModel.prediction(from: provider)
		let output = try XCTUnwrap(prediction.featureValue(for: "y")?.multiArrayValue)
		XCTAssertEqual((0 ..< 2).map { output[$0].floatValue }, [2, 3])
	}

	func testRead_divByZeroConstant_isRejected() throws {
		// Dividing by a zero element must not silently become a multiply by infinity.
		let divisor = onnxTensor(name: "d", dims: [1], floats: [0])
		let div = onnxNode(op: "Div", inputs: ["x", "d"], outputs: ["y"], name: "scale")
		let model = onnxModel(
			nodes: [div], initializers: [divisor],
			inputs: [onnxValueInfo(name: "x", shape: [1, 2, 1, 1])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 2, 1, 1])]
		)
		XCTAssertThrowsError(try ONNXModelReader().read(data: model)) { error in
			guard case ONNXModelReaderError.unsupportedAttribute = error else {
				return XCTFail("Expected unsupportedAttribute, got \(error)")
			}
		}
	}

	func testRead_divOfTwoActivations_isRejected() throws {
		// No classic Core ML layer divides two activations (here the one input used as both operands).
		let div = onnxNode(op: "Div", inputs: ["x", "x"], outputs: ["y"], name: "scale")
		let model = onnxModel(
			nodes: [div], initializers: [],
			inputs: [onnxValueInfo(name: "x", shape: [1, 3, 1, 1])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 3, 1, 1])]
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

	// MARK: - Resize lowering (nearest/asymmetric upsample)

	func testRead_resizeNearestAsymmetric2x_lowersToUpsample() throws {
		// The FPN upsample YOLOv8 exports: nearest + asymmetric + floor, scales [1, 1, 2, 2].
		let scales = onnxTensor(name: "scales", dims: [4], floats: [1, 1, 2, 2])
		let resize = onnxNode(op: "Resize", inputs: ["x", "", "scales"], outputs: ["y"], name: "resize", attributes: [
			onnxStringAttr(name: "mode", value: "nearest"),
			onnxStringAttr(name: "coordinate_transformation_mode", value: "asymmetric"),
			onnxStringAttr(name: "nearest_mode", value: "floor")
		])
		let model = onnxModel(
			nodes: [resize], initializers: [scales],
			inputs: [onnxValueInfo(name: "x", shape: [1, 3, 8, 10])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 3, 16, 20])]
		)
		let conversion = try ONNXModelReader().read(data: model)
		XCTAssertEqual(conversion.graph.operations.map(\.kind), [.upsample2D])
		XCTAssertEqual(conversion.graph.operations[0].attributes["scalingFactor"]?.integerArrayValue, [2, 2])
		XCTAssertEqual(conversion.graph.operations[0].outputs[0].shape, [1, 3, 16, 20])
		XCTAssertTrue(NativeModelGraphValidator().validate(conversion.graph).isConvertible)
	}

	func testRead_resizeLinearMode_isRejected() throws {
		let model = resizeModel(mode: "linear", coordinateTransform: "asymmetric", nearestMode: "floor")
		assertResizeRejected(model)
	}

	func testRead_resizeHalfPixel_isRejected() throws {
		// half_pixel samples at coordinates the nearest upsample layer does not reproduce.
		let model = resizeModel(mode: "nearest", coordinateTransform: "half_pixel", nearestMode: "floor")
		assertResizeRejected(model)
	}

	func testRead_resizeNonIntegerScale_isRejected() throws {
		let scales = onnxTensor(name: "scales", dims: [4], floats: [1, 1, 1.5, 1.5])
		let resize = onnxNode(op: "Resize", inputs: ["x", "", "scales"], outputs: ["y"], name: "resize", attributes: [
			onnxStringAttr(name: "mode", value: "nearest"),
			onnxStringAttr(name: "coordinate_transformation_mode", value: "asymmetric"),
			onnxStringAttr(name: "nearest_mode", value: "floor")
		])
		let model = onnxModel(
			nodes: [resize], initializers: [scales],
			inputs: [onnxValueInfo(name: "x", shape: [1, 3, 8, 8])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 3, 12, 12])]
		)
		assertResizeRejected(model)
	}

	func testRead_resizeSizesForm_lowersWhenItDividesExactly() throws {
		// The `sizes` input (4 → 8) form: the implied integer factor is 2.
		let sizes = onnxInt64Tensor(name: "sizes", dims: [4], ints: [1, 3, 8, 8])
		let resize = onnxNode(op: "Resize", inputs: ["x", "", "", "sizes"], outputs: ["y"], name: "resize", attributes: [
			onnxStringAttr(name: "mode", value: "nearest"),
			onnxStringAttr(name: "coordinate_transformation_mode", value: "asymmetric"),
			onnxStringAttr(name: "nearest_mode", value: "floor")
		])
		let model = onnxModel(
			nodes: [resize], initializers: [sizes],
			inputs: [onnxValueInfo(name: "x", shape: [1, 3, 4, 4])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 3, 8, 8])]
		)
		let conversion = try ONNXModelReader().read(data: model)
		XCTAssertEqual(conversion.graph.operations.map(\.kind), [.upsample2D])
		XCTAssertEqual(conversion.graph.operations[0].attributes["scalingFactor"]?.integerArrayValue, [2, 2])
		XCTAssertEqual(conversion.graph.operations[0].outputs[0].shape, [1, 3, 8, 8])
	}

	func testRead_resizeSizesForm_isRejectedWhenItDoesNotDivide() throws {
		// 4 → 7 is not an integer multiple, so the nearest upsample cannot reproduce it.
		let sizes = onnxInt64Tensor(name: "sizes", dims: [4], ints: [1, 3, 7, 7])
		let resize = onnxNode(op: "Resize", inputs: ["x", "", "", "sizes"], outputs: ["y"], name: "resize", attributes: [
			onnxStringAttr(name: "mode", value: "nearest"),
			onnxStringAttr(name: "coordinate_transformation_mode", value: "asymmetric"),
			onnxStringAttr(name: "nearest_mode", value: "floor")
		])
		let model = onnxModel(
			nodes: [resize], initializers: [sizes],
			inputs: [onnxValueInfo(name: "x", shape: [1, 3, 4, 4])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 3, 7, 7])]
		)
		assertResizeRejected(model)
	}

	/// A `[1, 3, 8, 8]` → `[1, 3, 16, 16]` (scales [1, 1, 2, 2]) Resize with the given string attributes.
	private func resizeModel(mode: String, coordinateTransform: String, nearestMode: String) -> Data {
		let scales = onnxTensor(name: "scales", dims: [4], floats: [1, 1, 2, 2])
		let resize = onnxNode(op: "Resize", inputs: ["x", "", "scales"], outputs: ["y"], name: "resize", attributes: [
			onnxStringAttr(name: "mode", value: mode),
			onnxStringAttr(name: "coordinate_transformation_mode", value: coordinateTransform),
			onnxStringAttr(name: "nearest_mode", value: nearestMode)
		])
		return onnxModel(
			nodes: [resize], initializers: [scales],
			inputs: [onnxValueInfo(name: "x", shape: [1, 3, 8, 8])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 3, 16, 16])]
		)
	}

	private func assertResizeRejected(_ model: Data, file: StaticString = #filePath, line: UInt = #line) {
		XCTAssertThrowsError(try ONNXModelReader().read(data: model), file: file, line: line) { error in
			guard case ONNXModelReaderError.unsupportedAttribute = error else {
				return XCTFail("Expected unsupportedAttribute, got \(error)", file: file, line: line)
			}
		}
	}

	// MARK: - Concat lowering (rank-3, and the axis-2 transpose-wrap)

	func testRead_concatRank3ChannelAxis_sumsChannels() throws {
		let concat = onnxNode(op: "Concat", inputs: ["x", "x"], outputs: ["y"], name: "concat", attributes: [
			onnxSignedIntAttr(name: "axis", value: 1)
		])
		let model = onnxModel(
			nodes: [concat], initializers: [],
			inputs: [onnxValueInfo(name: "x", shape: [1, 2, 5])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 4, 5])]
		)
		let conversion = try ONNXModelReader().read(data: model)
		XCTAssertEqual(conversion.graph.operations.map(\.kind), [.concatenate])
		XCTAssertEqual(conversion.graph.operations[0].outputs[0].shape, [1, 4, 5])
		XCTAssertTrue(NativeModelGraphValidator().validate(conversion.graph).isConvertible)
	}

	func testRead_concatRank3Axis2_rewritesAsTransposeWrappedChannelConcat() throws {
		// The YOLOv8 stride merge: [1, C, N₀] ⧺₂ [1, C, N₁] → [1, C, N₀+N₁]. Classic Core ML concat
		// joins channels only, so the lowering must transpose each input, channel-concat, and
		// transpose back — the op sequence and the final shape are the contract.
		let concat = onnxNode(op: "Concat", inputs: ["x", "x"], outputs: ["y"], name: "concat", attributes: [
			onnxSignedIntAttr(name: "axis", value: 2)
		])
		let model = onnxModel(
			nodes: [concat], initializers: [],
			inputs: [onnxValueInfo(name: "x", shape: [1, 2, 5])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 2, 10])]
		)
		let conversion = try ONNXModelReader().read(data: model)
		// One synthesized transpose per input occurrence (the same tensor twice still gets two, under
		// distinct generated names), one channel concat, one transpose back.
		XCTAssertEqual(conversion.graph.operations.map(\.kind), [.transpose, .transpose, .concatenate, .transpose])
		XCTAssertEqual(conversion.graph.operations.last?.outputs[0].shape, [1, 2, 10])
		XCTAssertTrue(NativeModelGraphValidator().validate(conversion.graph).isConvertible)
	}

	func testRead_concatRank4SpatialAxis_isStillRejected() throws {
		let model = concatModel(inputShape: [1, 3, 4, 4], count: 2, axis: 2)
		XCTAssertThrowsError(try ONNXModelReader().read(data: model)) { error in
			guard case ONNXModelReaderError.unsupportedAttribute = error else {
				return XCTFail("Expected unsupportedAttribute, got \(error)")
			}
		}
	}

	func testRead_concatRank3Axis2_convertsAndPredictsInDocumentOrder() throws {
		// End-to-end numeric proof of the transpose-wrap: rank-4 input reshaped to [1, 2, 3], concat
		// with itself on axis 2, reshaped back to rank 4 so the declared output maps cleanly under the
		// legacy rank-5 layout. Axis-2 concat repeats each CHANNEL'S row — [a b c a b c | d e f d e f]
		// — while a channel concat would repeat whole channel blocks; the expectation distinguishes them.
		let toRank3 = onnxNode(op: "Reshape", inputs: ["x", "t3"], outputs: ["r3"], name: "toRank3")
		let concat = onnxNode(op: "Concat", inputs: ["r3", "r3"], outputs: ["cat"], name: "concat", attributes: [
			onnxSignedIntAttr(name: "axis", value: 2)
		])
		let toRank4 = onnxNode(op: "Reshape", inputs: ["cat", "t4"], outputs: ["y"], name: "toRank4")
		let model = onnxModel(
			nodes: [toRank3, concat, toRank4],
			initializers: [
				onnxInt64Tensor(name: "t3", dims: [3], ints: [1, 2, 3]),
				onnxInt64Tensor(name: "t4", dims: [4], ints: [1, 2, 6, 1])
			],
			inputs: [onnxValueInfo(name: "x", shape: [1, 2, 3, 1])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 2, 6, 1])]
		)
		// Under the legacy mapping the emitter declares rank-4 unit-batch features as [C, H, W].
		let output = try predictSingleInput(model: model, inputShape: [2, 3, 1], values: [1, 2, 3, 4, 5, 6], outputName: "y")
		XCTAssertEqual(output, [1, 2, 3, 1, 2, 3, 4, 5, 6, 4, 5, 6])
	}

	func testRead_softmaxUnderLegacyMapping_normalizesTheChannelAxis() throws {
		// A reshape in the graph flips the whole network to the legacy rank-5 mapping, under which
		// softmaxND's axis numbering would be wrong — the emitter must switch to the classic channel
		// softmax. Channel pairs (1,3) and (2,4) must each normalize to (0.1192, 0.8808); a softmax
		// over the wrong axis would normalize (1,2) and (3,4) instead.
		let toRank3 = onnxNode(op: "Reshape", inputs: ["x", "t3"], outputs: ["r3"], name: "toRank3")
		let softmax = onnxNode(op: "Softmax", inputs: ["r3"], outputs: ["s"], name: "softmax", attributes: [
			onnxSignedIntAttr(name: "axis", value: 1)
		])
		let toRank4 = onnxNode(op: "Reshape", inputs: ["s", "t4"], outputs: ["y"], name: "toRank4")
		let model = onnxModel(
			nodes: [toRank3, softmax, toRank4],
			initializers: [
				onnxInt64Tensor(name: "t3", dims: [3], ints: [1, 2, 2]),
				onnxInt64Tensor(name: "t4", dims: [4], ints: [1, 2, 2, 1])
			],
			inputs: [onnxValueInfo(name: "x", shape: [1, 2, 2, 1])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 2, 2, 1])],
			opsetVersion: 13
		)
		let output = try predictSingleInput(model: model, inputShape: [2, 2, 1], values: [1, 2, 3, 4], outputName: "y")
		XCTAssertEqual(output.count, 4)
		for (index, expected) in [0.11920292, 0.11920292, 0.88079708, 0.88079708].enumerated() {
			XCTAssertEqual(output[index], Float(expected), accuracy: 0.0005, "element \(index)")
		}
	}

	/// Reads `model`, emits it, compiles it, and predicts over one input, returning the flat output.
	private func predictSingleInput(model: Data, inputShape: [Int], values: [Float], outputName: String) throws -> [Float] {
		let conversion = try ONNXModelReader().read(data: model)
		XCTAssertTrue(NativeModelGraphValidator().validate(conversion.graph).isConvertible)
		let modelURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mlmodel")
		defer { try? FileManager.default.removeItem(at: modelURL) }
		try NativeModelCoreMLEmitter().emit(graph: conversion.graph, weights: conversion.weights, to: modelURL)
		let compiled = try MLModel.compileModel(at: modelURL)
		defer { try? FileManager.default.removeItem(at: compiled) }
		let coreMLModel = try MLModel(contentsOf: compiled, configuration: cpuOnly())
		let input = try MLMultiArray(shape: inputShape.map { NSNumber(value: $0) }, dataType: .float32)
		for (index, value) in values.enumerated() { input[index] = NSNumber(value: value) }
		let provider = try MLDictionaryFeatureProvider(dictionary: ["x": MLFeatureValue(multiArray: input)])
		let prediction = try coreMLModel.prediction(from: provider)
		let output = try XCTUnwrap(prediction.featureValue(for: outputName)?.multiArrayValue)
		return (0 ..< output.count).map { output[$0].floatValue }
	}

	// MARK: - Reshape lowering (static targets vs the classifier flatten fast-path)

	func testRead_reshapeStaticRank4Target_lowersToGeneralReshape() throws {
		let model = reshapeModel(inputShape: [1, 4, 4, 1], target: [1, 2, 2, 4])
		let conversion = try ONNXModelReader().read(data: model)
		XCTAssertEqual(conversion.graph.operations.map(\.kind), [.reshape])
		XCTAssertEqual(conversion.graph.operations[0].attributes["shape"]?.integerArrayValue, [1, 2, 2, 4])
		XCTAssertEqual(conversion.graph.operations[0].outputs[0].shape, [1, 2, 2, 4])
		XCTAssertTrue(NativeModelGraphValidator().validate(conversion.graph).isConvertible)
	}

	func testRead_reshapeRank3TargetWithInferredDim_canonicalizesToRank4() throws {
		// The YOLOv8 head's stride flatten: [1, 144, 80, 80] -> [1, 144, -1]. The -1 resolves to 6400
		// and the emitted attribute gains the trailing unit axis the classic reshape layer requires.
		let model = reshapeModel(inputShape: [1, 144, 80, 80], target: [1, 144, -1])
		let conversion = try ONNXModelReader().read(data: model)
		XCTAssertEqual(conversion.graph.operations.map(\.kind), [.reshape])
		XCTAssertEqual(conversion.graph.operations[0].attributes["shape"]?.integerArrayValue, [1, 144, 6400, 1])
		XCTAssertEqual(conversion.graph.operations[0].outputs[0].shape, [1, 144, 6400])
	}

	func testRead_reshapeBatchVectorTarget_staysOnTheFlattenFastPath() throws {
		// MobileNetV2/ResNet50 ship a [1, -1] classifier reshape. It must remain a .flatten: a .reshape
		// op would flip the network to the legacy rank-5 mapping, which the emitter rejects for
		// classifier interfaces — i.e. this test is the shipped-classifier regression guard.
		let model = reshapeModel(inputShape: [1, 1280, 1, 1], target: [1, -1])
		let conversion = try ONNXModelReader().read(data: model)
		XCTAssertEqual(conversion.graph.operations.map(\.kind), [.flatten])
		XCTAssertEqual(conversion.graph.operations[0].outputs[0].shape, [1, 1280])
	}

	func testRead_reshapeNonDivisibleInferredDim_isRejected() throws {
		let model = reshapeModel(inputShape: [1, 4, 4, 1], target: [1, 7, -1])
		XCTAssertThrowsError(try ONNXModelReader().read(data: model)) { error in
			guard case ONNXModelReaderError.shapeInferenceFailed = error else {
				return XCTFail("Expected shapeInferenceFailed, got \(error)")
			}
		}
	}

	func testRead_reshapeElementCountMismatch_isRejected() throws {
		let model = reshapeModel(inputShape: [1, 4, 4, 1], target: [1, 3, 5])
		XCTAssertThrowsError(try ONNXModelReader().read(data: model)) { error in
			guard case ONNXModelReaderError.shapeInferenceFailed = error else {
				return XCTFail("Expected shapeInferenceFailed, got \(error)")
			}
		}
	}

	func testRead_reshapeZeroCopyDimension_isRejected() throws {
		let model = reshapeModel(inputShape: [1, 4, 4, 1], target: [0, 16])
		XCTAssertThrowsError(try ONNXModelReader().read(data: model)) { error in
			guard case ONNXModelReaderError.unsupportedAttribute = error else {
				return XCTFail("Expected unsupportedAttribute, got \(error)")
			}
		}
	}

	func testRead_reshapeRank5Target_isRejected() throws {
		let model = reshapeModel(inputShape: [1, 4, 4, 1], target: [1, 1, 2, 2, 4])
		XCTAssertThrowsError(try ONNXModelReader().read(data: model)) { error in
			guard case ONNXModelReaderError.unsupportedAttribute = error else {
				return XCTFail("Expected unsupportedAttribute, got \(error)")
			}
		}
	}

	// MARK: - Sigmoid and Transpose lowering

	func testRead_sigmoid_lowersPreservingShape() throws {
		let model = onnxModel(
			nodes: [onnxNode(op: "Sigmoid", inputs: ["x"], outputs: ["y"], name: "sig")],
			initializers: [],
			inputs: [onnxValueInfo(name: "x", shape: [1, 4, 8])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 4, 8])]
		)

		let conversion = try ONNXModelReader().read(data: model)

		XCTAssertEqual(conversion.graph.operations.map(\.kind), [.sigmoid])
		XCTAssertEqual(conversion.graph.operations[0].outputs[0].shape, [1, 4, 8])
		XCTAssertTrue(NativeModelGraphValidator().validate(conversion.graph).isConvertible)
	}

	func testRead_transposeRank4_lowersWithPermutedShape() throws {
		let transpose = onnxNode(op: "Transpose", inputs: ["x"], outputs: ["y"], name: "t", attributes: [
			onnxIntsAttr(name: "perm", ints: [0, 2, 1, 3])
		])
		let model = onnxModel(
			nodes: [transpose],
			initializers: [],
			inputs: [onnxValueInfo(name: "x", shape: [1, 4, 8, 2])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 8, 4, 2])]
		)

		let conversion = try ONNXModelReader().read(data: model)

		XCTAssertEqual(conversion.graph.operations.map(\.kind), [.transpose])
		XCTAssertEqual(conversion.graph.operations[0].attributes["permutation"]?.integerArrayValue, [0, 2, 1, 3])
		XCTAssertEqual(conversion.graph.operations[0].outputs[0].shape, [1, 8, 4, 2])
		XCTAssertTrue(NativeModelGraphValidator().validate(conversion.graph).isConvertible)
	}

	func testRead_transposeRank3_canonicalizesPermToRank4() throws {
		// A rank-3 [1, C, N] input canonicalizes to four axes: perm [0, 2, 1] gains the trailing axis 3,
		// while the recorded output shape stays the ONNX rank-3 result [1, N, C].
		let transpose = onnxNode(op: "Transpose", inputs: ["x"], outputs: ["y"], name: "t", attributes: [
			onnxIntsAttr(name: "perm", ints: [0, 2, 1])
		])
		let model = onnxModel(
			nodes: [transpose],
			initializers: [],
			inputs: [onnxValueInfo(name: "x", shape: [1, 4, 8])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 8, 4])]
		)

		let conversion = try ONNXModelReader().read(data: model)

		XCTAssertEqual(conversion.graph.operations.map(\.kind), [.transpose])
		XCTAssertEqual(conversion.graph.operations[0].attributes["permutation"]?.integerArrayValue, [0, 2, 1, 3])
		XCTAssertEqual(conversion.graph.operations[0].outputs[0].shape, [1, 8, 4])
		XCTAssertTrue(NativeModelGraphValidator().validate(conversion.graph).isConvertible)
	}

	func testRead_transposeWithoutPerm_isRejected() throws {
		let transpose = onnxNode(op: "Transpose", inputs: ["x"], outputs: ["y"], name: "t")
		let model = onnxModel(
			nodes: [transpose],
			initializers: [],
			inputs: [onnxValueInfo(name: "x", shape: [1, 4, 8, 2])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 4, 8, 2])]
		)
		XCTAssertThrowsError(try ONNXModelReader().read(data: model)) { error in
			guard case ONNXModelReaderError.unsupportedAttribute = error else {
				return XCTFail("Expected unsupportedAttribute, got \(error)")
			}
		}
	}

	func testRead_transposeWithInvalidPerm_isRejected() throws {
		let transpose = onnxNode(op: "Transpose", inputs: ["x"], outputs: ["y"], name: "t", attributes: [
			onnxIntsAttr(name: "perm", ints: [0, 0, 1, 2])
		])
		let model = onnxModel(
			nodes: [transpose],
			initializers: [],
			inputs: [onnxValueInfo(name: "x", shape: [1, 4, 8, 2])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 4, 8, 2])]
		)
		XCTAssertThrowsError(try ONNXModelReader().read(data: model)) { error in
			guard case ONNXModelReaderError.unsupportedAttribute = error else {
				return XCTFail("Expected unsupportedAttribute, got \(error)")
			}
		}
	}

	// MARK: - Slice lowering (channel-axis only)

	func testRead_sliceChannelRangeRank3_lowersToSliceChannels() throws {
		let model = sliceModel(inputShape: [1, 144, 20], starts: [0], ends: [64], axes: [1], outputShape: [1, 64, 20])
		let conversion = try ONNXModelReader().read(data: model)
		XCTAssertEqual(conversion.graph.operations.map(\.kind), [.sliceChannels])
		XCTAssertEqual(conversion.graph.operations[0].attributes["startChannel"]?.integerValue, 0)
		XCTAssertEqual(conversion.graph.operations[0].attributes["endChannel"]?.integerValue, 64)
		XCTAssertEqual(conversion.graph.operations[0].outputs[0].shape, [1, 64, 20])
		XCTAssertTrue(NativeModelGraphValidator().validate(conversion.graph).isConvertible)
	}

	func testRead_sliceNegativeStart_normalizesAgainstChannelCount() throws {
		// -80 on 144 channels counts back from the dim to 64; the slice keeps the trailing 80 channels.
		let model = sliceModel(inputShape: [1, 144, 20], starts: [-80], ends: [144], axes: [1], outputShape: [1, 80, 20])
		let conversion = try ONNXModelReader().read(data: model)
		XCTAssertEqual(conversion.graph.operations.map(\.kind), [.sliceChannels])
		XCTAssertEqual(conversion.graph.operations[0].attributes["startChannel"]?.integerValue, 64)
		XCTAssertEqual(conversion.graph.operations[0].attributes["endChannel"]?.integerValue, 144)
		XCTAssertEqual(conversion.graph.operations[0].outputs[0].shape, [1, 80, 20])
		XCTAssertTrue(NativeModelGraphValidator().validate(conversion.graph).isConvertible)
	}

	func testRead_sliceEndAtInt64Max_clampsToChannelCount() throws {
		// YOLO exports write an INT64_MAX "to the end" sentinel; it truncates to Int.max and must clamp.
		let model = sliceModel(inputShape: [1, 144, 20], starts: [64], ends: [Int(Int64.max)], axes: [1], outputShape: [1, 80, 20])
		let conversion = try ONNXModelReader().read(data: model)
		XCTAssertEqual(conversion.graph.operations.map(\.kind), [.sliceChannels])
		XCTAssertEqual(conversion.graph.operations[0].attributes["startChannel"]?.integerValue, 64)
		XCTAssertEqual(conversion.graph.operations[0].attributes["endChannel"]?.integerValue, 144)
		XCTAssertEqual(conversion.graph.operations[0].outputs[0].shape, [1, 80, 20])
	}

	func testRead_sliceOnSpatialAxis_isRejected() throws {
		let model = sliceModel(inputShape: [1, 144, 20], starts: [0], ends: [10], axes: [2], outputShape: [1, 144, 10])
		XCTAssertThrowsError(try ONNXModelReader().read(data: model)) { error in
			guard case ONNXModelReaderError.unsupportedAttribute = error else {
				return XCTFail("Expected unsupportedAttribute, got \(error)")
			}
		}
	}

	func testRead_sliceWithNonUnitStep_isRejected() throws {
		let model = sliceModel(inputShape: [1, 144, 20], starts: [0], ends: [64], axes: [1], steps: [2], outputShape: [1, 32, 20])
		XCTAssertThrowsError(try ONNXModelReader().read(data: model)) { error in
			guard case ONNXModelReaderError.unsupportedAttribute = error else {
				return XCTFail("Expected unsupportedAttribute, got \(error)")
			}
		}
	}

	func testRead_sliceOverMultipleAxes_isRejected() throws {
		let model = sliceModel(inputShape: [1, 144, 20], starts: [0, 0], ends: [64, 10], axes: [1, 2], outputShape: [1, 64, 10])
		XCTAssertThrowsError(try ONNXModelReader().read(data: model)) { error in
			guard case ONNXModelReaderError.unsupportedAttribute = error else {
				return XCTFail("Expected unsupportedAttribute, got \(error)")
			}
		}
	}

	func testRead_sliceWithNonConstantStarts_isRejected() throws {
		// `starts` is a float initializer, not the int64/int32 `constantInts` accepts, so the bound cannot
		// be read at compile time and the slice is unrepresentable.
		let slice = onnxNode(op: "Slice", inputs: ["x", "starts", "ends"], outputs: ["y"], name: "slice")
		let model = onnxModel(
			nodes: [slice],
			initializers: [
				onnxTensor(name: "starts", dims: [1], floats: [0]),
				onnxInt64Tensor(name: "ends", dims: [1], ints: [64])
			],
			inputs: [onnxValueInfo(name: "x", shape: [1, 144, 20])],
			outputs: [onnxValueInfo(name: "y", shape: [1, 64, 20])]
		)
		XCTAssertThrowsError(try ONNXModelReader().read(data: model)) { error in
			guard case ONNXModelReaderError.unsupportedAttribute = error else {
				return XCTFail("Expected unsupportedAttribute, got \(error)")
			}
		}
	}

	/// Builds a Slice model in the opset-≥10 tensor-input form. `axes`/`steps` become extra initializer
	/// inputs when present; an absent `axes` beneath a present `steps` fills the positional slot with the
	/// empty-string optional-input marker ONNX uses.
	private func sliceModel(inputShape: [Int], starts: [Int], ends: [Int], axes: [Int]? = nil, steps: [Int]? = nil, outputShape: [Int]) -> Data {
		var inputNames = ["x", "starts", "ends"]
		var initializers = [
			onnxInt64Tensor(name: "starts", dims: [starts.count], ints: starts),
			onnxInt64Tensor(name: "ends", dims: [ends.count], ints: ends)
		]
		if let axes {
			inputNames.append("axes")
			initializers.append(onnxInt64Tensor(name: "axes", dims: [axes.count], ints: axes))
		}
		if let steps {
			if axes == nil { inputNames.append("") }
			inputNames.append("steps")
			initializers.append(onnxInt64Tensor(name: "steps", dims: [steps.count], ints: steps))
		}
		return onnxModel(
			nodes: [onnxNode(op: "Slice", inputs: inputNames, outputs: ["y"], name: "slice")],
			initializers: initializers,
			inputs: [onnxValueInfo(name: "x", shape: inputShape)],
			outputs: [onnxValueInfo(name: "y", shape: outputShape)]
		)
	}

	private func reshapeModel(inputShape: [Int], target: [Int]) -> Data {
		let reshape = onnxNode(op: "Reshape", inputs: ["x", "target"], outputs: ["y"], name: "reshape")
		var resolvedOutput = target.map { $0 == -1 ? 1 : $0 } // declared output shape is cosmetic here
		if resolvedOutput.isEmpty { resolvedOutput = [1] }
		return onnxModel(
			nodes: [reshape],
			initializers: [onnxInt64Tensor(name: "target", dims: [target.count], ints: target)],
			inputs: [onnxValueInfo(name: "x", shape: inputShape)],
			outputs: [onnxValueInfo(name: "y", shape: resolvedOutput)]
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

	private func onnxInt64Tensor(name: String, dims: [Int], ints: [Int]) -> Data {
		var raw = Data()
		for value in ints {
			withUnsafeBytes(of: Int64(value).littleEndian) { raw.append(contentsOf: $0) }
		}
		return CoreMLProtobufEncoder.message { tensor in
			for dimension in dims { CoreMLProtobufEncoder.appendVarintField(1, value: UInt64(dimension), to: &tensor) }
			CoreMLProtobufEncoder.appendVarintField(2, value: 7, to: &tensor) // data_type = INT64
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

	/// Reads a weight's float32 values out of the conversion's packed weight blob.
	private func floats(of weight: NativeModelWeight, in blob: Data) -> [Float] {
		let start = Int(weight.offset)
		let slice = blob.subdata(in: start ..< start + Int(weight.byteCount))
		return slice.withUnsafeBytes { raw in
			(0 ..< slice.count / 4).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
		}
	}

	private func cpuOnly() -> MLModelConfiguration {
		let configuration = MLModelConfiguration()
		configuration.computeUnits = .cpuOnly
		return configuration
	}
}
