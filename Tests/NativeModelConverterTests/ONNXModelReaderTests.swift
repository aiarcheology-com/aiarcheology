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

	private func onnxNode(op: String, inputs: [String], outputs: [String], name: String, attributes: [Data] = []) -> Data {
		CoreMLProtobufEncoder.message { node in
			for input in inputs { CoreMLProtobufEncoder.appendStringField(1, value: input, to: &node) }
			for output in outputs { CoreMLProtobufEncoder.appendStringField(2, value: output, to: &node) }
			CoreMLProtobufEncoder.appendStringField(3, value: name, to: &node)
			CoreMLProtobufEncoder.appendStringField(4, value: op, to: &node)
			for attribute in attributes { CoreMLProtobufEncoder.appendMessageField(5, value: attribute, to: &node) }
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

	private func onnxModel(nodes: [Data], initializers: [Data], inputs: [Data], outputs: [Data]) -> Data {
		let graph = CoreMLProtobufEncoder.message { graph in
			for node in nodes { CoreMLProtobufEncoder.appendMessageField(1, value: node, to: &graph) }
			for initializer in initializers { CoreMLProtobufEncoder.appendMessageField(5, value: initializer, to: &graph) }
			for input in inputs { CoreMLProtobufEncoder.appendMessageField(11, value: input, to: &graph) }
			for output in outputs { CoreMLProtobufEncoder.appendMessageField(12, value: output, to: &graph) }
		}
		return CoreMLProtobufEncoder.message { model in
			CoreMLProtobufEncoder.appendMessageField(7, value: graph, to: &model)
		}
	}

	private func cpuOnly() -> MLModelConfiguration {
		let configuration = MLModelConfiguration()
		configuration.computeUnits = .cpuOnly
		return configuration
	}
}
