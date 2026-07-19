//
//  ONNXMetadataConversionTests.swift
//  NativeModelConverterTests
//
//  End-to-end attribution check (AIA-0473): convert a real .onnx model, compile it, and read back
//  the Core ML metadata the app will display — the exact acceptance criteria. Reads through
//  `MLModel.modelDescription.metadata` rather than trusting the emitter's intermediate values, so a
//  regression anywhere in reader -> mapping -> emitter -> protobuf surfaces here.
//
//  Fixtures are not committed. The test finds them in $NATIVE_MODEL_ONNX_DIRECTORY, else in the
//  repo's `.native-model-fixtures/`, and skips cleanly when they are absent (as in CI). The
//  deterministic mapping + field-number coverage lives in ONNXMetadataMappingTests, which always
//  runs.
//

import CoreML
import Foundation
import XCTest
@testable import NativeModelConverter

final class ONNXMetadataConversionTests: XCTestCase {

	/// tinyyolov2 carries its description in `doc_string` (no "description" prop) and names its
	/// authors and license in `metadata_props` — the mixed case.
	func testTinyYOLOv2CarriesDocStringDescriptionAuthorAndLicense() async throws {
		let metadata = try await convertAndReadMetadata(fixture: "tinyyolov2-8.onnx")
		let description = try XCTUnwrap(metadata[.description] as? String)
		XCTAssertTrue(
			description.contains("Tiny YOLO network from the paper"),
			"description should carry the source doc_string; was: \(description)"
		)
		XCTAssertTrue(description.hasPrefix("Converted Core ML"), "description should state it is a conversion")
		XCTAssertEqual(metadata[.author] as? String, "Original paper: Joseph Redmon, Ali Farhadi")
		XCTAssertEqual(metadata[.license] as? String, "Public Domain")
	}

	/// A genuine Ultralytics export: description/author/version/license all in `metadata_props`,
	/// plus many extra keys that must survive as provenance.
	///
	/// yolo11n uses `Split`, which the converter cannot lower yet (that is #469 PR 3), so this reads
	/// the metadata straight from the real file's bytes through the reader's parsing + mapping — the
	/// layer AIA-0473 actually changes — rather than a full conversion that would fail before emit.
	func testYOLO11nRealFileParsesUltralyticsAttributionAndExtraKeys() throws {
		guard let onnxURL = fixtureURL("yolo11n-aaurelions.onnx") else {
			throw XCTSkip("yolo11n-aaurelions.onnx not found.")
		}
		let data = try Data(contentsOf: onnxURL, options: .mappedIfSafe)
		let fields = try ProtobufReader.fields(in: data)
		let raw = ONNXModelReader().rawMetadata(from: fields)
		let metadata = try XCTUnwrap(ONNXMetadataMapping.metadata(from: raw))

		XCTAssertEqual(metadata.author, "Ultralytics")
		XCTAssertEqual(metadata.versionString, "8.3.168")
		XCTAssertTrue(try XCTUnwrap(metadata.license).contains("AGPL-3.0"))
		XCTAssertTrue(try XCTUnwrap(metadata.shortDescription).contains("Ultralytics"))
		// Keys the typed fields do not capture survive in the provenance mirror.
		XCTAssertEqual(metadata.userDefined["docs"], "https://docs.ultralytics.com")
		XCTAssertEqual(metadata.userDefined["task"], "detect")
		XCTAssertEqual(metadata.userDefined["stride"], "32")
	}

	/// A model with no attribution still converts, records converter provenance (so it is known to
	/// be a conversion), and writes NO real typed fields — the display then keeps its filename.
	func testMetadataFreeModelConvertsWithProvenanceButNoRealFields() async throws {
		let metadata = try await convertAndReadMetadata(fixture: "resnet50-v1-7.onnx")
		// Core ML always REPORTS the four standard keys, defaulting to "" when unset — so the check
		// is "blank", not "nil". Blank is exactly what triggers the app's filename fallback.
		XCTAssertTrue(((metadata[.author] as? String) ?? "").isEmpty, "a source-less model must not invent an author")
		XCTAssertTrue(((metadata[.license] as? String) ?? "").isEmpty)
		XCTAssertTrue(((metadata[.description] as? String) ?? "").isEmpty, "no source description → filename fallback")

		let userDefined = try XCTUnwrap(metadata[.creatorDefinedKey] as? [String: String])
		// Converter provenance is still recorded — the model is known to be a conversion.
		XCTAssertNotNil(userDefined["com.aiarcheology.native.conversion.weights-sha256"])
		XCTAssertEqual(
			userDefined["com.aiarcheology.native.converter.package-version"],
			NativeModelConverterVersion.packageVersion
		)
		// But nothing sourced from an (absent) source metadata block — no empty-string noise.
		XCTAssertFalse(
			userDefined.keys.contains { $0.hasPrefix("com.aiarcheology.native.source.") },
			"a source-less model must not carry any source.* provenance keys"
		)
	}

	// MARK: - Helpers

	private func convertAndReadMetadata(fixture: String) async throws -> [MLModelMetadataKey: Any] {
		guard let onnxURL = fixtureURL(fixture) else {
			throw XCTSkip("\(fixture) not found; set NATIVE_MODEL_ONNX_DIRECTORY or populate .native-model-fixtures/.")
		}
		let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mlmodel")
		addTeardownBlock { try? FileManager.default.removeItem(at: outputURL) }
		_ = try await NativeModelConverter().convert(onnx: onnxURL, to: outputURL)

		let compiledURL = try await MLModel.compileModel(at: outputURL)
		addTeardownBlock { try? FileManager.default.removeItem(at: compiledURL) }
		let configuration = MLModelConfiguration()
		configuration.computeUnits = .cpuOnly
		// Reading the compiled model's own description returns the OUTER model's metadata — the
		// pipeline description for a detector, the network description for a classifier.
		return try MLModel(contentsOf: compiledURL, configuration: configuration).modelDescription.metadata
	}

	/// Prefers `$NATIVE_MODEL_ONNX_DIRECTORY`, else the repo's `.native-model-fixtures/` located
	/// relative to this source file, so the test runs locally without an env var and skips in CI.
	private func fixtureURL(_ name: String) -> URL? {
		if let dir = ProcessInfo.processInfo.environment["NATIVE_MODEL_ONNX_DIRECTORY"] {
			let candidate = URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent(name)
			if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
		}
		// Tests/NativeModelConverterTests/<file> -> repo root -> .native-model-fixtures
		let repoRoot = URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
		let candidate = repoRoot.appendingPathComponent(".native-model-fixtures").appendingPathComponent(name)
		return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
	}
}
