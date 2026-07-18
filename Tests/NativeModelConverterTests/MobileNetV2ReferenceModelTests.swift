//
//  MobileNetV2ReferenceModelTests.swift
//  NativeModelConverterTests
//

import CoreML
import CoreVideo
import CryptoKit
import Foundation
import XCTest

final class MobileNetV2ReferenceModelTests: XCTestCase {

	func testSuppliedReferenceModels_compileAndMatchTheirDeclaredContract() throws {
		guard let directoryPath = ProcessInfo.processInfo.environment["NATIVE_MODEL_REFERENCE_DIRECTORY"] else {
			throw XCTSkip("Set NATIVE_MODEL_REFERENCE_DIRECTORY to run external MobileNetV2 reference tests.")
		}
		let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
		let manifest = try loadManifest()

		for reference in manifest.models {
			let modelURL = directory.appendingPathComponent(reference.fileName)
			XCTAssertTrue(FileManager.default.fileExists(atPath: modelURL.path), "Missing \(reference.fileName).")
			XCTAssertEqual(try checksum(of: modelURL), reference.sha256, "Unexpected bytes for \(reference.fileName).")

			let compiledURL = try MLModel.compileModel(at: modelURL)
			let model = try MLModel(contentsOf: compiledURL, configuration: cpuOnlyConfiguration())
			try assertInterface(of: model, matches: reference)
			try assertSolidRedProbe(of: model, reference: reference)
		}
	}

	private func loadManifest() throws -> ReferenceManifest {
		let resourceURL = try XCTUnwrap(
			Bundle.module.url(forResource: "MobileNetV2ReferenceModels", withExtension: "json")
		)
		return try JSONDecoder().decode(ReferenceManifest.self, from: Data(contentsOf: resourceURL))
	}

	private func checksum(of url: URL) throws -> String {
		let data = try Data(contentsOf: url, options: .mappedIfSafe)
		return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
	}

	private func assertInterface(of model: MLModel, matches reference: ReferenceModel) throws {
		let input = try XCTUnwrap(model.modelDescription.inputDescriptionsByName[reference.input.name])
		XCTAssertEqual(input.type, .image)
		let imageConstraint = try XCTUnwrap(input.imageConstraint)
		XCTAssertEqual(imageConstraint.pixelsWide, reference.input.width)
		XCTAssertEqual(imageConstraint.pixelsHigh, reference.input.height)
		XCTAssertEqual(model.modelDescription.outputDescriptionsByName["classLabel"]?.type, .string)
		XCTAssertEqual(model.modelDescription.outputDescriptionsByName["classLabelProbs"]?.type, .dictionary)
	}

	private func assertSolidRedProbe(of model: MLModel, reference: ReferenceModel) throws {
		let pixelBuffer = try solidRedPixelBuffer(width: reference.input.width, height: reference.input.height)
		let input = try MLDictionaryFeatureProvider(
			dictionary: [reference.input.name: MLFeatureValue(pixelBuffer: pixelBuffer)]
		)
		let output = try model.prediction(from: input)

		XCTAssertEqual(
			output.featureValue(for: "classLabel")?.stringValue,
			reference.expectedClassLabelForSolidRedProbe
		)
	}

	private func solidRedPixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
		var pixelBuffer: CVPixelBuffer?
		let status = CVPixelBufferCreate(
			kCFAllocatorDefault,
			width,
			height,
			kCVPixelFormatType_32BGRA,
			nil,
			&pixelBuffer
		)
		guard status == kCVReturnSuccess, let pixelBuffer else {
			throw ReferenceModelTestError.pixelBufferCreationFailed(status)
		}

		CVPixelBufferLockBaseAddress(pixelBuffer, [])
		defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
		let pixels = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer)).assumingMemoryBound(to: UInt8.self)
		let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
		for y in 0..<height {
			for x in 0..<width {
				let offset = y * rowBytes + x * 4
				pixels[offset] = 0
				pixels[offset + 1] = 0
				pixels[offset + 2] = 255
				pixels[offset + 3] = 255
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

private struct ReferenceManifest: Decodable {
	let formatVersion: Int
	let models: [ReferenceModel]
}

private struct ReferenceModel: Decodable {
	let id: String
	let fileName: String
	let url: URL
	let sha256: String
	let input: ReferenceInput
	let expectedClassLabelForSolidRedProbe: String
}

private struct ReferenceInput: Decodable {
	let name: String
	let width: Int
	let height: Int
}

private enum ReferenceModelTestError: Error {
	case pixelBufferCreationFailed(CVReturn)
}
