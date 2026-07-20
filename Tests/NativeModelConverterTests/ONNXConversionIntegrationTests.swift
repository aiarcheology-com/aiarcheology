//
//  ONNXConversionIntegrationTests.swift
//  NativeModelConverterTests
//
//  End-to-end conversion check that runs entirely outside the app (macOS `swift test`, no
//  simulator): convert a real .onnx model to Core ML, run it on probe images, and assert the
//  predicted class label against an independent oracle (onnxruntime, baked into the manifest).
//
//  Real model files are not committed. Point NATIVE_MODEL_ONNX_DIRECTORY at a directory holding the
//  manifest's .onnx files (populate it with `scripts/fetch_native_test_models.sh`, or reuse an
//  existing download folder). Models listed in the manifest but absent from the directory are
//  reported and skipped, so a partial directory still validates whatever is present.
//

import CoreML
import CoreVideo
import CryptoKit
import Foundation
import XCTest
@testable import NativeModelConverter

final class ONNXConversionIntegrationTests: XCTestCase {

	func testConvertedModels_reproduceTheOnnxRuntimeProbeLabels() async throws {
		guard let directoryPath = ProcessInfo.processInfo.environment["NATIVE_MODEL_ONNX_DIRECTORY"] else {
			throw XCTSkip("Set NATIVE_MODEL_ONNX_DIRECTORY to a folder of .onnx fixtures to run ONNX conversion integration tests.")
		}
		let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
		let manifest = try loadManifest()

		var testedModelCount = 0
		for model in manifest.models {
			let onnxURL = directory.appendingPathComponent(model.fileName)
			guard FileManager.default.fileExists(atPath: onnxURL.path) else {
				// A missing fixture is not a failure: it lets a partial directory validate the rest.
				print("SKIP \(model.id): \(model.fileName) not found in \(directory.path)")
				continue
			}
			testedModelCount += 1
			XCTAssertEqual(try checksum(of: onnxURL), model.sha256, "Unexpected bytes for \(model.fileName).")

			let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mlmodel")
			defer { try? FileManager.default.removeItem(at: outputURL) }
			let metrics = try await NativeModelConverter().convert(onnx: onnxURL, to: outputURL)
			XCTAssertGreaterThan(metrics.emission.operationCount, 0, "\(model.id) produced no operations.")

			let compiledURL = try await MLModel.compileModel(at: outputURL)
			let coreMLModel = try MLModel(contentsOf: compiledURL, configuration: cpuOnlyConfiguration())

			// The interface is a property of the model, not of a probe: assert it once, before the
			// probes, so a wrong interface fails even for a fixture that declares no probes.
			if model.solidColorProbes != nil {
				try assertImageClassifierInterface(of: coreMLModel, matches: model)
			}
			if model.detectionProbes != nil {
				try assertDetectorInterface(of: coreMLModel)
			}
			XCTAssertTrue(
				model.solidColorProbes != nil || model.detectionProbes != nil,
				"\(model.id) declares no probes; a manifest entry must assert something."
			)

			for probe in model.solidColorProbes ?? [] {
				let top = try topClassification(of: coreMLModel, input: model.convertedInput, probe: probe)
				XCTAssertEqual(
					top?.label, probe.expectedClassLabel,
					"\(model.id): solid (\(probe.red),\(probe.green),\(probe.blue)) expected '\(probe.expectedClassLabel)', got '\(top?.label ?? "nil")'."
				)
				// Some models (SqueezeNet) collapse every solid color onto one label, so the manifest can
				// additionally pin the oracle's top-1 probability — a converted model must reproduce it.
				if let expectedProbability = probe.expectedTopProbability {
					XCTAssertEqual(
						top?.probability ?? -1, expectedProbability, accuracy: 0.005,
						"\(model.id): solid (\(probe.red),\(probe.green),\(probe.blue)) top-1 probability drifted from the onnxruntime oracle."
					)
				}
			}

			for probe in model.detectionProbes ?? [] {
				try assertDetections(of: coreMLModel, model: model, probe: probe)
			}
		}

		if testedModelCount == 0 {
			throw XCTSkip("No manifest models were present in \(directory.path); nothing to validate.")
		}
	}

	// MARK: - Helpers

	private func loadManifest() throws -> ONNXConversionManifest {
		let resourceURL = try XCTUnwrap(
			Bundle.module.url(forResource: "ONNXConversionModels", withExtension: "json")
		)
		return try JSONDecoder().decode(ONNXConversionManifest.self, from: Data(contentsOf: resourceURL))
	}

	private func checksum(of url: URL) throws -> String {
		let data = try Data(contentsOf: url, options: .mappedIfSafe)
		return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
	}

	private func assertImageClassifierInterface(of model: MLModel, matches expected: ONNXConversionModel) throws {
		let input = try XCTUnwrap(model.modelDescription.inputDescriptionsByName[expected.convertedInput.name])
		XCTAssertEqual(input.type, .image)
		let constraint = try XCTUnwrap(input.imageConstraint)
		XCTAssertEqual(constraint.pixelsWide, expected.convertedInput.width)
		XCTAssertEqual(constraint.pixelsHigh, expected.convertedInput.height)
		XCTAssertEqual(model.modelDescription.predictedFeatureName, "classLabel")
	}

	private func topClassification(
		of model: MLModel, input: ProbeInput, probe: SolidColorProbe
	) throws -> (label: String, probability: Double)? {
		let pixelBuffer = try solidColorPixelBuffer(
			width: input.width, height: input.height,
			red: probe.red, green: probe.green, blue: probe.blue
		)
		let provider = try MLDictionaryFeatureProvider(dictionary: [input.name: MLFeatureValue(pixelBuffer: pixelBuffer)])
		let prediction = try model.prediction(from: provider)
		guard let label = prediction.featureValue(for: "classLabel")?.stringValue else { return nil }
		let probability = prediction.featureValue(for: "classLabelProbs")?.dictionaryValue[label]?.doubleValue ?? -1
		return (label, probability)
	}

	private func solidColorPixelBuffer(width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8) throws -> CVPixelBuffer {
		var buffer: CVPixelBuffer?
		let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
		let pixelBuffer = try XCTUnwrap(status == kCVReturnSuccess ? buffer : nil)
		CVPixelBufferLockBaseAddress(pixelBuffer, [])
		defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
		let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer)).assumingMemoryBound(to: UInt8.self)
		let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
		for y in 0 ..< height {
			for x in 0 ..< width {
				let offset = y * rowBytes + x * 4
				base[offset] = blue
				base[offset + 1] = green
				base[offset + 2] = red
				base[offset + 3] = 255
			}
		}
		return pixelBuffer
	}

	private func cpuOnlyConfiguration() -> MLModelConfiguration {
		let configuration = MLModelConfiguration()
		configuration.computeUnits = .cpuOnly
		return configuration
	}

	// MARK: - Detection

	private func assertDetectorInterface(of model: MLModel) throws {
		let outputs = model.modelDescription.outputDescriptionsByName
		// These names are exactly what the app's ModelLoadingService.inferType keys a detector on.
		XCTAssertNotNil(outputs["coordinates"], "A converted detector must publish 'coordinates'.")
		XCTAssertNotNil(outputs["confidence"], "A converted detector must publish 'confidence'.")
		XCTAssertTrue(model.modelDescription.predictedFeatureName?.isEmpty ?? true, "A detector must not read as a classifier.")
	}

	private func assertDetections(of model: MLModel, model manifestModel: ONNXConversionModel, probe: DetectionProbe) throws {
		let pixelBuffer: CVPixelBuffer
		if let seedText = probe.noiseSeed {
			// Require the prefix rather than assuming it: a manifest entry written without `0x` would
			// otherwise silently lose its first two digits and probe a different image than the oracle.
			XCTAssertTrue(seedText.hasPrefix("0x"), "noiseSeed '\(seedText)' must be a 0x-prefixed hex literal.")
			let seed = try XCTUnwrap(
				seedText.hasPrefix("0x") ? UInt64(seedText.dropFirst(2), radix: 16) : nil,
				"noiseSeed '\(seedText)' is not a valid 0x-prefixed hex literal."
			)
			pixelBuffer = try noisePixelBuffer(width: manifestModel.convertedInput.width, height: manifestModel.convertedInput.height, seed: seed)
		} else {
			let color = try XCTUnwrap(probe.solidColor, "A detection probe needs a noiseSeed or a solidColor.")
			pixelBuffer = try solidColorPixelBuffer(
				width: manifestModel.convertedInput.width, height: manifestModel.convertedInput.height,
				red: color.red, green: color.green, blue: color.blue
			)
		}
		let provider = try MLDictionaryFeatureProvider(dictionary: [
			manifestModel.convertedInput.name: MLFeatureValue(pixelBuffer: pixelBuffer),
			"confidenceThreshold": MLFeatureValue(double: probe.confidenceThreshold)
		])
		let prediction = try model.prediction(from: provider)
		let coordinates = try XCTUnwrap(prediction.featureValue(for: "coordinates")?.multiArrayValue)
		let confidence = try XCTUnwrap(prediction.featureValue(for: "confidence")?.multiArrayValue)
		// Read the geometry from the declared shapes rather than dividing element counts: if Core ML
		// ever returns a different rank or column count, this fails loudly instead of silently
		// re-slicing the buffer into plausible-looking boxes.
		let coordinatesShape = coordinates.shape.map(\.intValue)
		let confidenceShape = confidence.shape.map(\.intValue)
		XCTAssertEqual(coordinatesShape.count, 2, "coordinates must be [boxes, 4], got \(coordinatesShape).")
		XCTAssertEqual(confidenceShape.count, 2, "confidence must be [boxes, classes], got \(confidenceShape).")
		guard coordinatesShape.count == 2, confidenceShape.count == 2 else { return }
		XCTAssertEqual(coordinatesShape[1], 4, "coordinates must have 4 columns, got \(coordinatesShape[1]).")
		XCTAssertEqual(coordinatesShape[0], confidenceShape[0], "coordinates and confidence must agree on the box count.")
		guard coordinatesShape[1] == 4, coordinatesShape[0] == confidenceShape[0] else { return }
		let rowCount: Int = coordinatesShape[0]
		let classCount: Int = confidenceShape[1]
		var boxes: [DetectedBox] = []
		for row in 0 ..< rowCount {
			var scores: [Double] = []
			for classIndex in 0 ..< classCount {
				scores.append(confidence[row * classCount + classIndex].doubleValue)
			}
			boxes.append(DetectedBox(
				x: coordinates[row * 4].doubleValue,
				y: coordinates[row * 4 + 1].doubleValue,
				width: coordinates[row * 4 + 2].doubleValue,
				height: coordinates[row * 4 + 3].doubleValue,
				scores: scores
			))
		}

		let context = "\(manifestModel.id) probe \(probe.noiseSeed ?? "solid")"
		if let expectedClassCount = manifestModel.expectedClassCount {
			XCTAssertEqual(classCount, expectedClassCount, "\(context): detector class count diverged from the manifest.")
		}
		XCTAssertEqual(boxes.count, probe.expectedBoxes.count, "\(context): box count diverged from the oracle.")
		// Suppression order is confidence-based and could legally tie-break differently, so each
		// expected box is matched by geometry rather than position — and consumed, so two expected
		// boxes can never claim the same returned one.
		var unmatched = boxes
		for expected in probe.expectedBoxes {
			guard let matchIndex = unmatched.indices.max(by: { iou(unmatched[$0], expected) < iou(unmatched[$1], expected) }),
				iou(unmatched[matchIndex], expected) >= 0.9
			else {
				XCTFail("\(context): no returned box overlaps expected \(expected.label) at IoU >= 0.9.")
				continue
			}
			let match = unmatched.remove(at: matchIndex)
			let topClass: Int = try XCTUnwrap(match.scores.indices.max { match.scores[$0] < match.scores[$1] })
			// Prefer an index assertion; fall back to the catalogued VOC label only for the anchor-based
			// fixture that supplies one. This keeps the general path free of a hardcoded label list.
			if let classIndex = expected.classIndex {
				XCTAssertEqual(topClass, classIndex, "\(context): the matched box has the wrong class index.")
			} else if let label = expected.label, topClass < NativeModelDetectorCatalog.pascalVOCLabels.count {
				XCTAssertEqual(
					NativeModelDetectorCatalog.pascalVOCLabels[topClass], label,
					"\(context): the matched box wears the wrong class."
				)
			} else {
				XCTFail("\(context): an expected box needs a classIndex or a Pascal-VOC label.")
			}
			XCTAssertEqual(
				match.scores[topClass], expected.confidence, accuracy: 0.015,
				"\(context): confidence drifted from the onnxruntime oracle."
			)
		}
	}

	private struct DetectedBox {
		let x: Double
		let y: Double
		let width: Double
		let height: Double
		let scores: [Double]
	}

	private func iou(_ box: DetectedBox, _ expected: ExpectedBox) -> Double {
		let overlapWidth = max(0, min(box.x + box.width / 2, expected.x + expected.width / 2) - max(box.x - box.width / 2, expected.x - expected.width / 2))
		let overlapHeight = max(0, min(box.y + box.height / 2, expected.y + expected.height / 2) - max(box.y - box.height / 2, expected.y - expected.height / 2))
		let intersection = overlapWidth * overlapHeight
		let union = box.width * box.height + expected.width * expected.height - intersection
		return union > 0 ? intersection / union : 0
	}

	/// A deterministic noise image from the same LCG the oracle uses: per pixel, three sequential
	/// draws fill r, g, b in row-major order. Byte-for-byte agreement with the Python side is what
	/// makes the baked expectations valid.
	private func noisePixelBuffer(width: Int, height: Int, seed: UInt64) throws -> CVPixelBuffer {
		var buffer: CVPixelBuffer?
		let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
		let pixelBuffer = try XCTUnwrap(status == kCVReturnSuccess ? buffer : nil)
		CVPixelBufferLockBaseAddress(pixelBuffer, [])
		defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
		let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer)).assumingMemoryBound(to: UInt8.self)
		let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
		var state = seed
		func next() -> UInt8 {
			state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
			return UInt8((state >> 33) & 0xFF)
		}
		for y in 0 ..< height {
			for x in 0 ..< width {
				let offset = y * rowBytes + x * 4
				let red = next(), green = next(), blue = next()
				base[offset] = blue
				base[offset + 1] = green
				base[offset + 2] = red
				base[offset + 3] = 255
			}
		}
		return pixelBuffer
	}
}

private struct ONNXConversionManifest: Decodable {
	let formatVersion: Int
	let models: [ONNXConversionModel]
}

private struct ONNXConversionModel: Decodable {
	let id: String
	let fileName: String
	let url: URL
	let sha256: String
	let convertedInput: ProbeInput
	/// Present on classifier fixtures.
	let solidColorProbes: [SolidColorProbe]?
	/// Present on detector fixtures.
	let detectionProbes: [DetectionProbe]?
	/// Expected number of confidence columns (classes). Guards against a label/class-count regression
	/// that an index-only box assertion would miss.
	let expectedClassCount: Int?
}

private struct DetectionProbe: Decodable {
	/// A `0x…` seed for the deterministic noise image; mutually exclusive with `solidColor`.
	let noiseSeed: String?
	let solidColor: SolidColor?
	let confidenceThreshold: Double
	let expectedBoxes: [ExpectedBox]
}

private struct SolidColor: Decodable {
	let red: UInt8
	let green: UInt8
	let blue: UInt8
}

private struct ExpectedBox: Decodable {
	/// A catalogued-convention label (tiny-yolov2's Pascal VOC). Mutually exclusive with `classIndex`.
	let label: String?
	/// The expected top class *index*. Preferred for heads whose labels are file-supplied or generic
	/// `class_<i>` placeholders, where a label-string assertion would couple the test to a naming that
	/// is not the property under test.
	let classIndex: Int?
	let confidence: Double
	let x: Double
	let y: Double
	let width: Double
	let height: Double
}

private struct ProbeInput: Decodable {
	let name: String
	let width: Int
	let height: Int
}

private struct SolidColorProbe: Decodable {
	let red: UInt8
	let green: UInt8
	let blue: UInt8
	let expectedClassLabel: String
	/// Optional: the oracle's top-1 probability, for models whose probes share a single label.
	let expectedTopProbability: Double?
}
