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
			try assertImageClassifierInterface(of: coreMLModel, matches: model)

			for probe in model.solidColorProbes {
				let label = try classLabel(of: coreMLModel, input: model.convertedInput, probe: probe)
				XCTAssertEqual(
					label, probe.expectedClassLabel,
					"\(model.id): solid (\(probe.red),\(probe.green),\(probe.blue)) expected '\(probe.expectedClassLabel)', got '\(label ?? "nil")'."
				)
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

	private func classLabel(of model: MLModel, input: ProbeInput, probe: SolidColorProbe) throws -> String? {
		let pixelBuffer = try solidColorPixelBuffer(
			width: input.width, height: input.height,
			red: probe.red, green: probe.green, blue: probe.blue
		)
		let provider = try MLDictionaryFeatureProvider(dictionary: [input.name: MLFeatureValue(pixelBuffer: pixelBuffer)])
		let prediction = try model.prediction(from: provider)
		return prediction.featureValue(for: "classLabel")?.stringValue
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
	let solidColorProbes: [SolidColorProbe]
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
}
