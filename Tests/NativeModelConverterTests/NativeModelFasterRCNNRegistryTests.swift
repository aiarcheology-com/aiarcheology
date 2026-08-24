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
		XCTAssertGreaterThan(template.graph.weights.count, 339, "the graph must add anchors and decode constants to the checkpoint weights")
		XCTAssertGreaterThan(template.synthesizedWeightData.count, 7_000_000, "the full fixed-K path must retain its anchor table")
		XCTAssertTrue(NativeModelGraphValidator().validate(template.graph).isConvertible)

		let kinds = template.graph.operations.map(\.kind)
		for kind in [
			.convolution2D, .batchNormalization, .relu, .maxPool2D, .upsample2D,
			.reshapeND, .transposeND, .constantND, .sigmoid, .softmax, .concatenateND, .sliceND, .splitND,
			.subtract, .multiply, .minimumND, .maximumND, .naturalLogarithm, .floor, .exponential,
			.cropResize, .averagePool2D,
			.linear, .topK, .gather, .nonMaximumSuppression
		] as [NativeModelOperationKind] {
			XCTAssertTrue(kinds.contains(kind), "missing \(kind.serializedValue)")
		}

		let suppression = template.graph.operations.filter { $0.kind == .nonMaximumSuppression }
		let rpnSuppression = suppression.filter { $0.name.hasPrefix("frcnn.rpn.p") }
		XCTAssertEqual(rpnSuppression.map(\.name), [
			"frcnn.rpn.p2.nms", "frcnn.rpn.p3.nms", "frcnn.rpn.p4.nms", "frcnn.rpn.p5.nms", "frcnn.rpn.p6.nms"
		])
		XCTAssertEqual(rpnSuppression.map { $0.attributes["iouThreshold"] }, Array(repeating: .floatingPoint(0.7), count: 5))
		XCTAssertEqual(rpnSuppression.map { $0.attributes["maxBoxes"] }, Array(repeating: .integer(1_000), count: 5))
		let terminalSuppression = suppression.filter { $0.name.hasPrefix("frcnn.postprocess.") }
		XCTAssertEqual(terminalSuppression.map(\.name), [
			"frcnn.postprocess.torchvision_nms",
			"frcnn.postprocess.adaf_nms"
		])
		XCTAssertEqual(terminalSuppression.map { $0.attributes["iouThreshold"] }, [.floatingPoint(0.5), .floatingPoint(0.2)])
		XCTAssertEqual(terminalSuppression.map { $0.attributes["scoreThreshold"] }, [.floatingPoint(Double(Float(0.05).nextUp)), .floatingPoint(0)])
		XCTAssertEqual(terminalSuppression.map { $0.attributes["maxBoxes"] }, [.integer(100), .integer(100)])

		let mask = template.graph.operations.filter { $0.name.hasPrefix("frcnn.postprocess.") }
		XCTAssertEqual(mask.suffix(4).map(\.name), [
			"frcnn.postprocess.survivors",
			"frcnn.postprocess.masked_scores",
			"frcnn.postprocess.box_mask",
			"frcnn.postprocess.masked_boxes"
		])
		XCTAssertEqual(mask.suffix(4).first?.attributes["threshold"], .floatingPoint(Double(Float(0.05).nextUp)))
		XCTAssertEqual(template.graph.outputs, ["frcnn_raw_coordinates", "frcnn_raw_confidence"])
		let coordinates = try XCTUnwrap(template.graph.operations.last { $0.name == "frcnn_raw_coordinates" })
		let confidence = try XCTUnwrap(template.graph.operations.last { $0.name == "frcnn_raw_confidence" })
		XCTAssertEqual(coordinates.inputs, ["frcnn.postprocess.masked_boxes"])
		XCTAssertEqual(confidence.inputs, ["frcnn.postprocess.masked_scores"])

		let firstNMS = try XCTUnwrap(template.graph.operations.firstIndex { $0.name == "frcnn.postprocess.torchvision_nms" })
		let conversion = template.graph.operations[firstNMS - 1]
		XCTAssertEqual(conversion.name, "frcnn.postprocess.centre_size")
		XCTAssertEqual(conversion.kind, .concatenateND)
		XCTAssertEqual(terminalSuppression.first?.inputs.first, conversion.outputs.first?.name)

		let edgeLevels: [(level: Int, scale: Double)] = [(2, 0.25), (3, 0.125), (4, 0.0625), (5, 0.03125)]
		for edge in edgeLevels {
			let prefix = "frcnn.roi.p\(edge.level)"
			let side = Int(Double(NativeModelFasterRCNNRegistry.architecture.canvas.width) * edge.scale)
			let channels = NativeModelFasterRCNNRegistry.architecture.fpnChannels
			assertSlice(
				named: "\(prefix).ring_left", in: template.graph,
				input: "\(prefix).features_rank5",
				begin: [0, 0, 0, 0, 0], end: [1, 1, channels, side, 1]
			)
			assertSlice(
				named: "\(prefix).ring_right", in: template.graph,
				input: "\(prefix).features_rank5",
				begin: [0, 0, 0, 0, side - 1], end: [1, 1, channels, side, side]
			)
			assertSlice(
				named: "\(prefix).ring_top", in: template.graph,
				input: "\(prefix).ring_columns",
				begin: [0, 0, 0, 0, 0], end: [1, 1, channels, 1, side + 2]
			)
			assertSlice(
				named: "\(prefix).ring_bottom", in: template.graph,
				input: "\(prefix).ring_columns",
				begin: [0, 0, 0, side - 1, 0], end: [1, 1, channels, side, side + 2]
			)
			let columns = try XCTUnwrap(template.graph.operations.last { $0.name == "\(prefix).ring_columns" })
			XCTAssertEqual(columns.kind, .concatenateND)
			XCTAssertEqual(columns.inputs, ["\(prefix).ring_left", "\(prefix).features_rank5", "\(prefix).ring_right"])
			let ring = try XCTUnwrap(template.graph.operations.last { $0.name == "\(prefix).replicate_ring" })
			XCTAssertEqual(ring.kind, .concatenateND)
			XCTAssertEqual(ring.inputs, ["\(prefix).ring_top", "\(prefix).ring_columns", "\(prefix).ring_bottom"])

			let shift = try XCTUnwrap(template.graph.operations.last { $0.name == "\(prefix).feature_pixel_shift" })
			XCTAssertEqual(shift.kind, .constantND)
			let shiftWeight = try XCTUnwrap(template.graph.weights.first { $0.name == "\(prefix).feature_pixel_shift.values" })
			XCTAssertEqual(
				floatValues(for: shiftWeight, in: template),
				[Float](repeating: Float(1 / edge.scale), count: 4)
			)
			let shiftedBoxes = try XCTUnwrap(template.graph.operations.last { $0.name == "\(prefix).shifted_boxes" })
			XCTAssertEqual(shiftedBoxes.kind, .add)
			XCTAssertEqual(shiftedBoxes.inputs, ["frcnn.roi.boxes", "\(prefix).feature_pixel_shift"])

			let crop = try XCTUnwrap(template.graph.operations.last { $0.name == "\(prefix).crop_resize" })
			XCTAssertEqual(crop.kind, .cropResize)
			XCTAssertEqual(crop.inputs, ["\(prefix).replicate_ring", "\(prefix).shifted_boxes"])
			XCTAssertEqual(crop.attributes["spatialScale"], .floatingPoint(edge.scale))
			let pooled = try XCTUnwrap(template.graph.operations.last { $0.name == "\(prefix).roi_align" })
			XCTAssertEqual(pooled.kind, .averagePool2D)
			XCTAssertEqual(pooled.inputs, ["\(prefix).crop_resize"])
			XCTAssertEqual(pooled.outputs.first?.shape, [1_000, 1, channels, 7, 7])
			let selected = try XCTUnwrap(template.graph.operations.last { $0.name == "\(prefix).selected_roi_align" })
			XCTAssertEqual(selected.inputs, ["\(prefix).roi_align", "\(prefix).level_weight"])
		}

		let cropCorners = try XCTUnwrap(template.graph.operations.last { $0.name == "frcnn.roi.crop_corners" })
		XCTAssertEqual(cropCorners.inputs, [
			"frcnn.roi.corner_y0", "frcnn.roi.corner_x0", "frcnn.roi.corner_y1", "frcnn.roi.corner_x1"
		])
		XCTAssertEqual(
			template.graph.operations.filter { $0.name.hasSuffix(".level_mask") }.map(\.name),
			["frcnn.roi.p2.level_mask", "frcnn.roi.p3.level_mask", "frcnn.roi.p4.level_mask"]
		)
		for index in 0..<4 {
			XCTAssertNotNil(template.graph.operations.last { $0.name == "frcnn.roi.box_head.\(index).conv" })
			XCTAssertNotNil(template.graph.operations.last { $0.name == "frcnn.roi.box_head.\(index).bn" })
		}
		let fc = try XCTUnwrap(template.graph.operations.last { $0.name == "frcnn.roi.box_head.fc" })
		XCTAssertEqual(fc.kind, .linear)
		XCTAssertEqual(fc.inputs, ["frcnn.roi.box_head.flatten", "roi_heads.box_head.5.weight", "roi_heads.box_head.5.bias"])
		let foreground = try XCTUnwrap(template.graph.operations.last { $0.name == "frcnn.roi.predictor.foreground_scores" })
		XCTAssertEqual(foreground.inputs, ["frcnn.roi.predictor.class_scores"])
		let decoded = try XCTUnwrap(template.graph.operations.last { $0.name == "frcnn.roi.decode.corners" })
		XCTAssertEqual(decoded.kind, .concatenateND)
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

	func testPromotedWeightsDigest_usesLogicalWeightOrderWhenEmissionOrderDiffers() throws {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let sourceURL = directory.appendingPathComponent("weights.bin")
		try Data([0x00, 0x00, 0x00, 0x3C]).write(to: sourceURL)
		let promotedWeights = try makePromotedWeights(sourceURL: sourceURL, byteCount: 4, weightCount: 2)
		let digest = NativeModelADAFPromotedWeightsDigest(logicalWeights: promotedWeights.graph.weights)

		var segments = CoreMLProtobufSegments()
		for weight in promotedWeights.graph.weights.reversed() {
			CoreMLProtobufStreamingEncoder.appendDeferredPayloadField(
				1,
				payload: try promotedWeights.payload(for: weight, checkingCancellation: nil, digest: digest),
				to: &segments
			)
		}
		let outputURL = directory.appendingPathComponent("model.mlmodel")
		var actualDigest = ""
		try NativeModelAtomicFilePublisher.writeAtomically(
			to: outputURL,
			writing: { handle in try segments.write(to: handle, reporting: nil) },
			beforePublish: { temporaryURL in
				actualDigest = try digest.sha256(of: temporaryURL, checkingCancellation: nil)
			}
		)

		var expectedBytes = Data()
		for value in [Float(0), Float(1)] {
			var bits = value.bitPattern.littleEndian
			withUnsafeBytes(of: &bits) { expectedBytes.append(contentsOf: $0) }
		}
		XCTAssertEqual(actualDigest, NativeModelConversionChecksums.sha256Hex(of: expectedBytes))
	}

	func testPromotedWeights_shortReadReportsPerWeightCounts() throws {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let sourceURL = directory.appendingPathComponent("weights.bin")
		try Data([0x00, 0x00, 0x00, 0x3C]).write(to: sourceURL)
		let promotedWeights = try makePromotedWeights(sourceURL: sourceURL, byteCount: 4, weightCount: 1)
		try Data([0x00]).write(to: sourceURL)
		let outputURL = directory.appendingPathComponent("output.bin")
		FileManager.default.createFile(atPath: outputURL.path, contents: nil)
		let handle = try FileHandle(forWritingTo: outputURL)
		defer { try? handle.close() }
		let weight = try XCTUnwrap(promotedWeights.graph.weights.first)
		let payload = try promotedWeights.payload(for: weight, checkingCancellation: nil)

		XCTAssertThrowsError(try payload.write(handle)) { error in
			XCTAssertEqual(
				error as? NativeModelFasterRCNNRegistryError,
				.weightDataLengthMismatch(expected: 2, actual: 1)
			)
		}
	}

	func testStreamingNetworkLayers_cancelsBeforeWeightlessOperation() throws {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let sourceURL = directory.appendingPathComponent("empty.bin")
		try Data().write(to: sourceURL)
		let promotedWeights = try makePromotedWeights(sourceURL: sourceURL, byteCount: 0, weightCount: 0)
		let operation = NativeModelOperation(
			name: "weightless.relu",
			kind: .relu,
			inputs: ["input"],
			outputs: [NativeModelTensor(name: "output", dataType: .float32, shape: [1, 1, 1, 1])],
			attributes: [:]
		)

		XCTAssertThrowsError(
			try NativeModelCoreMLEmitter().streamingNetworkLayers(
				operations: [operation],
				weightsByName: [:],
				promotedWeights: promotedWeights,
				weightsDigest: NativeModelADAFPromotedWeightsDigest(logicalWeights: []),
				imagePlan: nil,
				usesLegacyShapeMapping: false,
				cancellationCheck: { throw CancellationError() }
			)
		) { error in
			XCTAssertTrue(error is CancellationError)
		}
	}

	private func makePromotedWeights(
		sourceURL: URL,
		byteCount: UInt64,
		weightCount: Int
	) throws -> NativeModelADAFPromotedWeights {
		let weights = (0..<weightCount).map { index in
			NativeModelWeight(
				name: "weight.\(index)",
				dataType: .float16,
				shape: [1],
				offset: UInt64(index * 2),
				byteCount: 2
			)
		}
		let graph = NativeModelGraph(
			formatVersion: NativeModelGraph.exactNDFormatVersion,
			producer: NativeModelGraphProducer(name: "test", version: "1"),
			inputs: [],
			weights: weights,
			operations: [],
			outputs: []
		)
		return try NativeModelADAFPromotedWeights(
			graph: graph,
			sourceWeightByteCount: byteCount,
			synthesizedWeightData: Data(),
			weightURL: sourceURL,
			checkingCancellation: nil
		)
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

	private func floatValues(
		for weight: NativeModelWeight,
		in template: NativeModelFasterRCNNRegistry.Template
	) -> [Float] {
		guard weight.offset >= template.sourceWeightByteCount else {
			XCTFail("weight \(weight.name) starts before synthesized weights")
			return []
		}
		let sourceOffset = weight.offset - template.sourceWeightByteCount
		let synthesizedByteCount = UInt64(template.synthesizedWeightData.count)
		guard sourceOffset <= synthesizedByteCount,
			weight.byteCount <= synthesizedByteCount - sourceOffset else {
			XCTFail("weight \(weight.name) exceeds synthesized weights")
			return []
		}
		let start = Int(sourceOffset)
		let end = start + Int(weight.byteCount)
		let bytes = template.synthesizedWeightData[start..<end]
		return stride(from: 0, to: bytes.count, by: MemoryLayout<Float>.size).map { byteOffset in
			bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: byteOffset, as: Float.self) }
		}
	}

	private func assertSlice(
		named name: String,
		in graph: NativeModelGraph,
		input: String,
		begin: [Int],
		end: [Int],
		file: StaticString = #filePath,
		line: UInt = #line
	) {
		let operation = graph.operations.last { $0.name == name }
		XCTAssertEqual(operation?.kind, .sliceND, name, file: file, line: line)
		XCTAssertEqual(operation?.inputs, [input], name, file: file, line: line)
		XCTAssertEqual(operation?.attributes["beginIds"], .integers(begin), name, file: file, line: line)
		XCTAssertEqual(operation?.attributes["endIds"], .integers(end), name, file: file, line: line)
		XCTAssertEqual(operation?.attributes["strides"], .integers([1, 1, 1, 1, 1]), name, file: file, line: line)
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
