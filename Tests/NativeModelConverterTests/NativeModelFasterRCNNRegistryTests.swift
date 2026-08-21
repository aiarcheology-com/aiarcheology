//
//  NativeModelFasterRCNNRegistryTests.swift
//  NativeModelConverterTests
//
//  The pinned architecture contract for the ADAF Faster R-CNN checkpoints (AIA-0685).
//

import XCTest
@testable import NativeModelConverter

final class NativeModelFasterRCNNRegistryTests: XCTestCase {

	func test_realDetectorTable_buildsThePinnedGraphTemplate() throws {
		let checkpoint = try PyTorchCheckpointReader.read(try ADAFFixtures.sparseBytes("OD_ringfort"))
		guard case let .objectDetection(model) = ADAFCheckpointCatalog.identity(of: checkpoint) else {
			return XCTFail("the committed fixture must remain the pinned ADAF detector")
		}

		let template = try NativeModelFasterRCNNRegistry.template(for: model, weights: extractedWeights(for: checkpoint))

		XCTAssertEqual(NativeModelFasterRCNNRegistry.architecture.identifier, "fasterrcnn_resnet50_fpn_v2")
		XCTAssertEqual(template.graph.formatVersion, NativeModelGraph.exactNDFormatVersion)
		XCTAssertEqual(template.graph.inputs, [
			NativeModelTensor(name: "image", dataType: .float32, shape: [1, 3, 1_344, 1_344])
		])
		XCTAssertEqual(template.graph.outputs, ["frcnn_raw_coordinates", "frcnn_raw_confidence"])
		XCTAssertEqual(template.interface.labels, ["Ringfort"])
		XCTAssertEqual(template.interface.boxCount, 1_000)
		XCTAssertEqual(template.targetInfo.classCount, 1)
		XCTAssertEqual(template.targetInfo.coordinateMode, .normalizedByGraph)
		XCTAssertEqual(template.targetSemanticsIntent.preprocessingProfile, .imageNetRGB)
		XCTAssertEqual(template.sourceWeightByteCount, 86_630_834)
		XCTAssertEqual(template.graph.weights.count, 340, "339 checkpoint weights plus one anchor tensor")
		XCTAssertEqual(template.synthesizedWeightData.count, 7_218_288)
		XCTAssertTrue(NativeModelGraphValidator().validate(template.graph).isConvertible)

		let kinds = template.graph.operations.map(\.kind)
		for kind in [
			.convolution2D, .batchNormalization, .relu, .maxPool2D, .upsample2D,
			.reshapeND, .constantND, .sigmoid, .concatenateND, .topK, .gather
		] as [NativeModelOperationKind] {
			XCTAssertTrue(kinds.contains(kind), "missing \(kind.serializedValue)")
		}
	}

	func test_duplicateSourceWeightName_isRefusedWithoutTrapping() throws {
		let checkpoint = try PyTorchCheckpointReader.read(try ADAFFixtures.sparseBytes("OD_ringfort"))
		guard case let .objectDetection(model) = ADAFCheckpointCatalog.identity(of: checkpoint) else {
			return XCTFail("the committed fixture must remain the pinned ADAF detector")
		}
		var weights = extractedWeights(for: checkpoint)
		weights.append(try XCTUnwrap(weights.first))

		XCTAssertThrowsError(try NativeModelFasterRCNNRegistry.template(for: model, weights: weights)) {
			XCTAssertEqual($0 as? NativeModelFasterRCNNRegistryError, .duplicateWeightName)
		}
	}

	private func extractedWeights(for checkpoint: PyTorchCheckpoint) -> [NativeModelWeight] {
		var offset: UInt64 = 0
		return checkpoint.tensors.compactMap { tensor in
			guard tensor.dataType == .float32 else { return nil }
			let byteCount = UInt64(tensor.shape.reduce(1, *)) * 2
			defer { offset += byteCount }
			return NativeModelWeight(
				name: tensor.name, dataType: .float16, shape: tensor.shape,
				offset: offset, byteCount: byteCount
			)
		}
	}
}
