//
//  ADAFCheckpointDirectoryTests.swift
//  NativeModelConverterTests
//
//  The gated suite: every published ADAF checkpoint, fetched rather than committed (AIA-0666).
//

import CoreML
import CryptoKit
import XCTest
@testable import NativeModelConverter

/// Runs the reader against files this repository does not contain.
///
/// The always-on suite covers the reader's whole read set from committed byte ranges, so this is the
/// redundant check rather than the only one — but it is redundant in the useful direction: it opens
/// files fetched fresh from Zenodo, including the three published detection models whose bytes are
/// not committed here, and (with `--full`) files whose middle is real weight data instead of a hole.
///
/// Gated on `ADAF_CHECKPOINT_DIRECTORY`. A gate that skips silently is the hazard `ios/AGENTS.md`
/// §13 records for the other two fixture gates, so `scripts/test_adaf_checkpoints.sh` is the way to
/// run this: it fails when the fixtures are absent or when any test skipped, which `swift test`
/// alone will not.
final class ADAFCheckpointDirectoryTests: XCTestCase {

	/// Every model in the manifest, opened from the fetched directory and identified.
	func test_everyPublishedCheckpoint_isReadAndIdentified() throws {
		let directory = try requireDirectory()
		let manifest = try ADAFFixtures.manifest()
		XCTAssertFalse(manifest.models.isEmpty)

		for model in manifest.models {
			let url = directory.appendingPathComponent(model.fileName)
			guard FileManager.default.fileExists(atPath: url.path) else {
				XCTFail("\(model.fileName) is not in \(directory.path) — run scripts/fetch_adaf_checkpoints.sh")
				continue
			}

			let source = try FileBytes(url: url)
			XCTAssertEqual(source.totalLength, model.totalLength, model.fileName)

			let counting = CountingBytes(source)
			let checkpoint = try PyTorchCheckpointReader.read(counting)

			if let tensorCount = model.tensorCount {
				XCTAssertEqual(checkpoint.tensors.count, tensorCount, model.fileName)
			}
			XCTAssertEqual(checkpoint.formatVersion, 3, model.fileName)

			// The read-set guarantee, asserted here too. Against a whole file every byte is available,
			// so without this the budget would be proven only by the sparse fixture and would vanish
			// with it.
			XCTAssertLessThan(counting.bytesRead, 2 * 1_024 * 1_024,
							  "\(model.fileName): read \(counting.bytesRead) of \(model.totalLength) bytes")

			switch (ADAFCheckpointCatalog.identity(of: checkpoint), model.expects) {
			case (.objectDetection(let detector), "objectDetection"):
				XCTAssertEqual(detector.predictorLogitCount, 2, model.fileName)
				XCTAssertEqual(detector.detectableClassCount, 1, model.fileName)
				XCTAssertEqual(detector.classLabel?.displayName, model.classLabel, model.fileName)
				XCTAssertEqual(detector.labelProvenance, .checkpointIdentifier, model.fileName)
			case (.segmentation, "segmentation"):
				break
			case (let identity, let expected):
				XCTFail("\(model.fileName): expected \(expected ?? "nothing"), got \(identity)")
			}
		}
	}

	/// All four detection checkpoints must share one tensor table — the fact the pinned digest rests
	/// on, and the reason the class label has to come from the training `id`.
	/// Every weight in a whole checkpoint, extracted to fp16 and accounted for (AIA-0675).
	///
	/// This is the only place the extractor meets a real file end to end. The always-on suite reaches
	/// five storages out of 339, because that is all the committed head can hold; a sparse fetched
	/// copy reaches barely more, since its middle is a hole of zeros that would fail the first
	/// checksum it touched. So a **whole** copy is required here and a sparse one is skipped by name
	/// rather than quietly passing on a prefix — `--full` is the only way this test means anything.
	func test_wholeDetectionCheckpoints_extractEveryWeightToFloat16() throws {
		let directory = try requireDirectory()
		let manifest = try ADAFFixtures.manifest()
		var examined = 0
		var sparse: [String] = []

		for model in manifest.models where model.expects == "objectDetection" {
			let url = directory.appendingPathComponent(model.fileName)
			guard FileManager.default.fileExists(atPath: url.path) else { continue }
			let marker = directory.appendingPathComponent(".\(model.fileName).sparse")
			if FileManager.default.fileExists(atPath: marker.path) {
				sparse.append(model.fileName)
				continue
			}

			let checkpoint = try PyTorchCheckpointReader.read(contentsOf: url)
			let destination = FileManager.default.temporaryDirectory
				.appendingPathComponent("\(model.id)-weights-\(UUID().uuidString).bin", isDirectory: false)
			let started = Date()
			let extraction = try PyTorchWeightExtractor.extract(checkpoint, from: url, to: destination)
			let elapsed = Date().timeIntervalSince(started)
			defer { try? FileManager.default.removeItem(at: destination) }

			// Nothing may simply disappear between the state_dict and the blob.
			XCTAssertEqual(
				extraction.weights.count + extraction.skippedCounterTensors.count,
				checkpoint.tensors.count, model.fileName
			)
			XCTAssertEqual(extraction.weights.count, 339, model.fileName)
			XCTAssertEqual(extraction.skippedCounterTensors.count, 65, model.fileName)
			XCTAssertTrue(
				extraction.skippedCounterTensors.allSatisfy { $0.hasSuffix(".num_batches_tracked") },
				"\(model.fileName): something other than a BatchNorm counter was skipped"
			)
			XCTAssertEqual(extraction.sourceByteCount, 173_261_668, model.fileName)
			XCTAssertEqual(extraction.byteCount, 86_630_834, model.fileName)
			XCTAssertEqual(
				UInt64(try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int ?? -1),
				extraction.byteCount, model.fileName
			)

			// The reason this milestone can store fp16 at all: measured on the real file, the largest
			// weight magnitude in `OD_ringfort` is 5.24, four orders of magnitude under fp16's 65,504
			// ceiling. If a published checkpoint ever did carry one that overflows, extraction refuses
			// it by name rather than writing an infinity — this asserts that has not happened.
			let footprint = extraction.memory?.observedPeakIncreaseByteCount
			print("""
				[AIA-0675] \(model.fileName): \(extraction.weights.count) weights, \
				\(extraction.byteCount) bytes, sha256 \(extraction.sha256), \
				peak increase \(footprint.map(String.init) ?? "unavailable") bytes, \
				\(String(format: "%.1f", elapsed)) s
				""")
			if let footprint {
				// Bounded by the chunk, not by the checkpoint. Generous because this is a *process*
				// figure that includes whatever the test host already held; the claim being defended is
				// that it does not scale with the 165 MiB being read.
				XCTAssertLessThan(footprint, 64 * 1_024 * 1_024, "\(model.fileName): extraction is not streaming")
			}
			examined += 1
		}

		XCTAssertGreaterThan(examined, 0, "no whole detection checkpoint was available — fetch with --full")
		// Without this the test passes on one whole detector beside three sparse ones, while claiming
		// end-to-end coverage for every detector present.
		XCTAssertEqual(
			sparse, [],
			"these detectors are present but sparse, so their weights were never extracted: \(sparse)"
		)
	}

	/// The same attack as the built-archive test, with the files that make it plausible (AIA-0675).
	///
	/// `test_theFourDetectionCheckpoints_shareOneTensorTable` is the reason this matters: the four
	/// published detectors are indistinguishable by tensor table, so extracting one model's weights
	/// against another's description passes every structural check there is. Only the pickle's
	/// checksum differs, because only the `id` string does.
	func test_oneDetectorsDescriptionAgainstAnothersBytes_isRefused() throws {
		let directory = try requireDirectory()
		let first = directory.appendingPathComponent("OD_ringfort.tar")
		let second = directory.appendingPathComponent("OD_barrow.tar")
		guard FileManager.default.fileExists(atPath: first.path),
			FileManager.default.fileExists(atPath: second.path)
		else {
			throw XCTSkip("needs both OD_ringfort and OD_barrow")
		}

		let ringfort = try PyTorchCheckpointReader.read(contentsOf: first)
		let barrow = try PyTorchCheckpointReader.read(contentsOf: second)
		XCTAssertEqual(
			ringfort.tensors, barrow.tensors,
			"if these ever differ, this test is no longer testing the case it was written for"
		)

		let destination = FileManager.default.temporaryDirectory
			.appendingPathComponent("swap-\(UUID().uuidString).bin", isDirectory: false)
		XCTAssertThrowsError(try PyTorchWeightExtractor.extract(ringfort, from: second, to: destination)) {
			XCTAssertEqual($0 as? PyTorchWeightExtractionError, .checkpointDescribesAnotherArchive)
		}
		XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
	}

	func test_theFourDetectionCheckpoints_shareOneTensorTable() throws {
		let directory = try requireDirectory()
		let detection = try ADAFFixtures.manifest().models.filter { $0.expects == "objectDetection" }
		XCTAssertEqual(detection.count, 4, "the record publishes four OD_* models")

		var digests: Set<UInt64> = []
		var labels: Set<String> = []
		for model in detection {
			let url = directory.appendingPathComponent(model.fileName)
			guard FileManager.default.fileExists(atPath: url.path) else {
				XCTFail("\(model.fileName) is missing — run scripts/fetch_adaf_checkpoints.sh")
				continue
			}
			let checkpoint = try PyTorchCheckpointReader.read(try FileBytes(url: url))
			digests.insert(ADAFCheckpointCatalog.tableDigest(of: checkpoint.tensors))
			if case .objectDetection(let detector) = ADAFCheckpointCatalog.identity(of: checkpoint),
				let label = detector.classLabel?.displayName {
				labels.insert(label)
			}
		}
		XCTAssertEqual(digests, [ADAFCheckpointCatalog.objectDetectionDigest],
					   "the four detection checkpoints must digest identically")
		XCTAssertEqual(labels, ["All archaeology", "Barrow", "Enclosure", "Ringfort"],
					   "each one must still resolve to its own class")
	}

	/// The actual detector artifact must compile and load as the Vision-facing detector pipeline.
	/// This is intentionally gated with the real checkpoints: the committed sparse fixture contains
	/// the tensor table but not the 82 MiB of values the emitted model needs.
	func test_realDetector_emitsALoadableVisionPipeline() async throws {
		let directory = try requireDirectory()
		let checkpointURL = directory.appendingPathComponent("OD_ringfort.tar")
		let weightURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("OD_ringfort-weights-\(UUID().uuidString).bin", isDirectory: false)
		let modelURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("OD_ringfort-\(UUID().uuidString).mlmodel", isDirectory: false)
		defer {
			try? FileManager.default.removeItem(at: weightURL)
			try? FileManager.default.removeItem(at: modelURL)
		}

		let checkpoint = try PyTorchCheckpointReader.read(contentsOf: checkpointURL)
		let extraction = try PyTorchWeightExtractor.extract(checkpoint, from: checkpointURL, to: weightURL)
		let conversion = try NativeModelFasterRCNNRegistry.conversion(
			checkpoint: checkpoint,
			extraction: extraction,
			weightData: try Data(contentsOf: weightURL)
		)
		let convertedWeights = Dictionary(uniqueKeysWithValues: conversion.graph.weights.map { ($0.name, $0) })
		for sourceWeight in extraction.weights {
			let emitted = try XCTUnwrap(convertedWeights[sourceWeight.name])
			XCTAssertEqual(emitted.dataType, .float32, "\(sourceWeight.name) must retain Float32 CPU accumulation")
			XCTAssertEqual(emitted.byteCount, sourceWeight.byteCount * 2)
		}
		let firstSource = try XCTUnwrap(extraction.weights.first)
		let firstEmitted = try XCTUnwrap(convertedWeights[firstSource.name])
		let sourceBytes = try Data(contentsOf: weightURL)
		let halfBits = sourceBytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: Int(firstSource.offset), as: UInt16.self) }
		let emittedValue = conversion.weights.withUnsafeBytes {
			$0.loadUnaligned(fromByteOffset: Int(firstEmitted.offset), as: Float.self)
		}
		XCTAssertEqual(emittedValue, Float(Float16(bitPattern: UInt16(littleEndian: halfBits))))
		do {
			try NativeModelCoreMLEmitter().emit(
				graph: conversion.graph,
				weights: conversion.weights,
				to: modelURL,
				detection: conversion.interface,
				detectionTarget: conversion.targetInfo,
				imagePreprocessing: .imageNetRGB,
				imageSizingContract: .adafFasterRCNN,
				targetSemanticsIntent: conversion.targetSemanticsIntent,
				parityEvidence: .structurallyMatched
			)
		} catch {
			return XCTFail("detector emission failed before Core ML compilation: \(error)")
		}
		XCTAssertTrue(FileManager.default.fileExists(atPath: modelURL.path), "emitter did not publish the model")
		try assertSerializedFullPredictionPath(in: modelURL)

		let compiledURL = try await MLModel.compileModel(at: modelURL)
		defer { try? FileManager.default.removeItem(at: compiledURL) }
		let model = try MLModel(contentsOf: compiledURL)
		let image = try XCTUnwrap(model.modelDescription.inputDescriptionsByName["image_input"])
		XCTAssertEqual(image.imageConstraint?.pixelsWide, 1_344)
		XCTAssertEqual(image.imageConstraint?.pixelsHigh, 1_344)
		XCTAssertNotNil(model.modelDescription.outputDescriptionsByName["coordinates"])
		XCTAssertNotNil(model.modelDescription.outputDescriptionsByName["confidence"])
		let metadata = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
		XCTAssertTrue(metadata[NativeModelParityProvenance.userDefinedKey]?.contains("structurally-matched") == true)
		XCTAssertFalse(metadata[NativeModelParityProvenance.userDefinedKey]?.contains("verified") == true)
		XCTAssertEqual(
			NativeModelImageSizingContract(userDefined: metadata),
			.adafFasterRCNN,
			"the emitted detector must declare the input transform its runtime requires"
		)
		XCTAssertEqual(
			NativeModelRuntimePolicy.computeUnitPolicy(from: metadata),
			.cpuOnly,
			"The converted ADAF detector must require CPU placement: every accelerator measured on device "
				+ "moves a box past the 1 px budget, the GPU furthest of all."
		)
	}

	/// The app imports through `NativeModelConverter.convert(adafDetector:to:)`; the parity runner's
	/// former explicit registry/emitter sequence is retained below as the CLI reference. Comparing the
	/// written bytes (not just a loadable model) locks the interface, parity provenance and stamped
	/// CPU runtime policy together.
	func test_appADAFConversion_matchesTheCLIReferenceArtifactAndReportsProgress() async throws {
		let directory = try requireDirectory()
		let checkpointURL = directory.appendingPathComponent("OD_ringfort.tar")
		let sparseMarker = directory.appendingPathComponent(".OD_ringfort.tar.sparse")
		try XCTSkipIf(
			FileManager.default.fileExists(atPath: sparseMarker.path),
			"OD_ringfort is sparse; fetch with scripts/fetch_adaf_checkpoints.sh --full."
		)
		let appModelURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("OD_ringfort-app-\(UUID().uuidString).mlmodel", isDirectory: false)
		let cliModelURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("OD_ringfort-cli-\(UUID().uuidString).mlmodel", isDirectory: false)
		let weightURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("OD_ringfort-cli-weights-\(UUID().uuidString).bin", isDirectory: false)
		defer {
			try? FileManager.default.removeItem(at: appModelURL)
			try? FileManager.default.removeItem(at: cliModelURL)
			try? FileManager.default.removeItem(at: weightURL)
		}

		let progress = ADAFProgressCollector()
		let appMetrics = try await NativeModelConverter().convert(
			adafDetector: checkpointURL,
			to: appModelURL,
			reporting: progress.append
		)

		let checkpoint = try PyTorchCheckpointReader.read(contentsOf: checkpointURL)
		let extraction = try PyTorchWeightExtractor.extract(checkpoint, from: checkpointURL, to: weightURL)
		let conversion = try NativeModelFasterRCNNRegistry.conversion(
			checkpoint: checkpoint,
			extraction: extraction,
			weightData: try Data(contentsOf: weightURL)
		)
		try NativeModelCoreMLEmitter().emit(
			graph: conversion.graph,
			weights: conversion.weights,
			to: cliModelURL,
			detection: conversion.interface,
			detectionTarget: conversion.targetInfo,
			imagePreprocessing: .imageNetRGB,
			imageSizingContract: .adafFasterRCNN,
			targetSemanticsIntent: conversion.targetSemanticsIntent,
			parityEvidence: .structurallyMatched
		)

		XCTAssertEqual(
			SHA256.hash(data: try Data(contentsOf: appModelURL, options: .mappedIfSafe)),
			SHA256.hash(data: try Data(contentsOf: cliModelURL, options: .mappedIfSafe)),
			"the app route must emit the exact artifact already checked through the CLI"
		)
		XCTAssertEqual(appMetrics.sourceFootprint.weightsByteCount, extraction.sourceByteCount)
		let phases = progress.values.map(\.phase)
		XCTAssertTrue(phases.contains(.readingWeights), "ADAF extraction must report progress to the import UI")
		XCTAssertTrue(phases.contains(.emittingModel), "ADAF emission must report progress to the import UI")
		XCTAssertEqual(phases.last, .completed)
	}

	/// Inspection is deliberately against the emitted real detector, not its graph IR: an unused ROI
	/// branch can look complete in the builder yet be pruned or disconnected by serialization. The path
	/// asserted here reaches the checkpoint's box head and foreground predictor before terminal NMS.
	private func assertSerializedFullPredictionPath(in detectorURL: URL) throws {
		let outer = try ProtobufReader.fields(in: Data(contentsOf: detectorURL, options: .mappedIfSafe))
		let pipeline = try ProtobufReader.fields(
			in: try XCTUnwrap(outer.firstBytes(NativeModelDetectorPipelineBuilder.pipelineModelField))
		)
		let stages = pipeline.allBytes(1)
		XCTAssertEqual(stages.count, 2, "the detector must retain its network and Vision NMS adapter stages")
		let networkModel = try ProtobufReader.fields(in: try XCTUnwrap(stages.first))
		let network = try ProtobufReader.fields(in: try XCTUnwrap(networkModel.firstBytes(500)))
		let layers = try network.allBytes(1).map { layer -> (name: String, inputs: [String], outputs: [String]) in
			let fields = try ProtobufReader.fields(in: layer)
			return (
				try XCTUnwrap(fields.firstString(1)),
				try fields.allBytes(2).map { try XCTUnwrap(String(data: $0, encoding: .utf8)) },
				try fields.allBytes(3).map { try XCTUnwrap(String(data: $0, encoding: .utf8)) }
			)
		}

		for level in 2 ... 5 {
			let prefix = "frcnn.roi.p\(level)"
			let expectedNames = [
				"\(prefix).features_rank5", "\(prefix).ring_left", "\(prefix).ring_right",
				"\(prefix).ring_columns", "\(prefix).ring_top", "\(prefix).ring_bottom",
				"\(prefix).replicate_ring", "\(prefix).feature_pixel_shift", "\(prefix).shifted_boxes",
				"\(prefix).crop_resize", "\(prefix).roi_align", "\(prefix).selected_roi_align"
			]
			let first = try XCTUnwrap(layers.firstIndex { $0.name == expectedNames[0] })
			guard first + expectedNames.count <= layers.count else {
				return XCTFail("\(prefix) serialized only a partial ROI edge branch")
			}
			XCTAssertEqual(layers[first..<(first + expectedNames.count)].map(\.name), expectedNames)

			let byName = Dictionary(uniqueKeysWithValues: layers.map { ($0.name, $0) })
			XCTAssertEqual(byName["\(prefix).ring_columns"]?.inputs, [
				"\(prefix).ring_left", "\(prefix).features_rank5", "\(prefix).ring_right"
			])
			XCTAssertEqual(byName["\(prefix).replicate_ring"]?.inputs, [
				"\(prefix).ring_top", "\(prefix).ring_columns", "\(prefix).ring_bottom"
			])
			XCTAssertEqual(byName["\(prefix).crop_resize"]?.inputs, [
				"\(prefix).replicate_ring", "\(prefix).shifted_boxes"
			])
			XCTAssertEqual(byName["\(prefix).roi_align"]?.inputs, ["\(prefix).crop_resize"])
			XCTAssertEqual(byName["\(prefix).selected_roi_align"]?.inputs, [
				"\(prefix).roi_align", "\(prefix).level_weight"
			])
		}

		let names = Set(layers.map(\.name))
		for name in [
			"frcnn.roi.boxes", "frcnn.roi.selected_pool_3", "frcnn.roi.box_head.fc",
			"frcnn.roi.predictor.class_scores", "frcnn.roi.predictor.foreground_scores",
			"frcnn.roi.decode.corners", "frcnn.postprocess.torchvision_nms"
		] {
			XCTAssertTrue(names.contains(name), "serialized detector omitted \(name)")
		}
		let boxHead = try XCTUnwrap(layers.first { $0.name == "frcnn.roi.box_head.0.conv" })
		XCTAssertEqual(boxHead.inputs.first, "frcnn.roi.selected_pool_3")
		let terminal = try XCTUnwrap(layers.first { $0.name == "frcnn.postprocess.torchvision_nms" })
		XCTAssertEqual(terminal.inputs.first, "frcnn.postprocess.centre_size")
	}

	private func requireDirectory() throws -> URL {
		try XCTSkipIf(
			ADAFFixtures.gatedDirectory == nil,
			"""
			ADAF_CHECKPOINT_DIRECTORY is not set, so this suite did nothing. That is a coverage hole, \
			not a pass: run scripts/test_adaf_checkpoints.sh, which fails instead of skipping.
			"""
		)
		return try XCTUnwrap(ADAFFixtures.gatedDirectory)
	}
}

private final class ADAFProgressCollector: @unchecked Sendable {
	private let lock = NSLock()
	private var storage: [NativeModelConversionProgress] = []

	func append(_ update: NativeModelConversionProgress) {
		lock.lock()
		defer { lock.unlock() }
		storage.append(update)
	}

	var values: [NativeModelConversionProgress] {
		lock.lock()
		defer { lock.unlock() }
		return storage
	}
}
