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
		XCTAssertEqual(template.interface.boxCount, 100)
		XCTAssertEqual(template.interface.suppressionOwnership, .graph)
		XCTAssertEqual(template.targetInfo.classCount, 1)
		XCTAssertEqual(template.targetInfo.coordinateMode, .normalizedByGraph)
		XCTAssertEqual(template.targetSemanticsIntent.preprocessingProfile, .imageNetRGB)
		XCTAssertEqual(template.sourceWeightByteCount, 86_630_834)
		XCTAssertEqual(template.graph.weights.count, 341, "339 checkpoint weights, anchor corners, and the centre conversion constant")
		XCTAssertEqual(template.synthesizedWeightData.count, 7_222_288)
		XCTAssertTrue(NativeModelGraphValidator().validate(template.graph).isConvertible)

		let kinds = template.graph.operations.map(\.kind)
		for kind in [
			.convolution2D, .batchNormalization, .relu, .maxPool2D, .upsample2D,
			.reshapeND, .constantND, .sigmoid, .concatenateND, .splitND, .subtract, .multiply,
			.topK, .gather, .nonMaximumSuppression
		] as [NativeModelOperationKind] {
			XCTAssertTrue(kinds.contains(kind), "missing \(kind.serializedValue)")
		}

		let suppression = template.graph.operations.filter { $0.kind == .nonMaximumSuppression }
		XCTAssertEqual(suppression.map(\.name), [
			"frcnn.postprocess.torchvision_nms",
			"frcnn.postprocess.adaf_nms"
		])
		XCTAssertEqual(suppression.map { $0.attributes["iouThreshold"] }, [.floatingPoint(0.5), .floatingPoint(0.2)])
		XCTAssertEqual(suppression.map { $0.attributes["scoreThreshold"] }, [.floatingPoint(0.05), .floatingPoint(0)])
		XCTAssertEqual(suppression.map { $0.attributes["maxBoxes"] }, [.integer(100), .integer(100)])

		let firstNMS = try XCTUnwrap(template.graph.operations.firstIndex { $0.name == "frcnn.postprocess.torchvision_nms" })
		let conversion = template.graph.operations[firstNMS - 1]
		XCTAssertEqual(conversion.name, "frcnn.postprocess.centre_size")
		XCTAssertEqual(conversion.kind, .concatenateND)
		XCTAssertEqual(suppression.first?.inputs.first, conversion.outputs.first?.name)
	}

	func test_terminalNMSDecision_matchesTheCommittedM3aMeasurement() throws {
		let url = try XCTUnwrap(Bundle.module.url(forResource: "M3aTerminalNMSMeasurements", withExtension: "json"))
		let measurements = try JSONDecoder().decode(TerminalNMSMeasurements.self, from: Data(contentsOf: url))

		XCTAssertEqual(measurements.trials, 200)
		XCTAssertEqual(measurements.trialsWhereOutputsDiffer, 200)
		XCTAssertEqual(measurements.meanBoxesTwoPass, 73.89, accuracy: 0.000_001)
		XCTAssertEqual(measurements.meanBoxesSinglePassAt0_2, 153.07, accuracy: 0.000_001)
		XCTAssertGreaterThan(measurements.meanBoxesSinglePassAt0_2, measurements.meanBoxesTwoPass)
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

	private struct TerminalNMSMeasurements: Decodable {
		let trials: Int
		let trialsWhereOutputsDiffer: Int
		let meanBoxesTwoPass: Double
		let meanBoxesSinglePassAt0_2: Double

		private enum CodingKeys: String, CodingKey {
			case trials
			case trialsWhereOutputsDiffer = "trials_where_outputs_differ"
			case meanBoxesTwoPass = "mean_boxes_two_pass"
			case meanBoxesSinglePassAt0_2 = "mean_boxes_single_pass_at_0_2"
		}
	}
}
