//
//  ONNXMetadataMappingTests.swift
//  NativeModelConverterTests
//
//  Deterministic tests for ONNX attribution mapping (AIA-0473). These run everywhere — no fixture
//  files, no simulator — and cover the parts an adversarial review flagged as easy to get wrong:
//  empty-string values beating the doc_string fallback, model_version's 0 default, untrusted-input
//  bounds, and duplicate keys. The field-number parsing (fields 2/5/6/14, StringStringEntryProto
//  key=1/value=2) is checked against hand-built protobuf bytes so a wrong field number fails here
//  rather than only against an uncommitted fixture.
//

import Foundation
import XCTest
@testable import NativeModelConverter

final class ONNXMetadataMappingTests: XCTestCase {

	// MARK: - Mapping (pure)

	func testTypedFieldsFromMetadataProps() throws {
		let metadata = try XCTUnwrap(ONNXMetadataMapping.metadata(from: ONNXRawMetadata(
			props: [
				("description", "Ultralytics YOLO11n"),
				("author", "Ultralytics"),
				("version", "8.3.168"),
				("license", "AGPL-3.0")
			]
		)))
		XCTAssertEqual(metadata.shortDescription, "Ultralytics YOLO11n")
		XCTAssertEqual(metadata.author, "Ultralytics")
		XCTAssertEqual(metadata.versionString, "8.3.168")
		XCTAssertEqual(metadata.license, "AGPL-3.0")
	}

	func testDescriptionFallsBackToDocStringWhenNoDescriptionProp() throws {
		// tinyyolov2 carries its description in doc_string and has no "description" metadata prop.
		let metadata = try XCTUnwrap(ONNXMetadataMapping.metadata(from: ONNXRawMetadata(
			props: [("author", "Original paper: Joseph Redmon, Ali Farhadi"), ("license", "Public Domain")],
			docString: "The Tiny YOLO network from the paper 'YOLO9000'"
		)))
		XCTAssertEqual(metadata.shortDescription, "The Tiny YOLO network from the paper 'YOLO9000'")
		XCTAssertEqual(metadata.author, "Original paper: Joseph Redmon, Ali Farhadi")
		XCTAssertEqual(metadata.license, "Public Domain")
	}

	func testEmptyDescriptionPropDoesNotSuppressDocStringFallback() throws {
		// firstString returns "" for a present-but-empty protobuf value; the empty prop must be
		// treated as absent so the real doc_string still wins, not left as blank noise.
		let metadata = try XCTUnwrap(ONNXMetadataMapping.metadata(from: ONNXRawMetadata(
			props: [("description", "   ")],
			docString: "Real description"
		)))
		XCTAssertEqual(metadata.shortDescription, "Real description")
	}

	func testModelVersionZeroIsTreatedAsAbsent() {
		// ONNX model_version defaults to 0; a "0" version string would be noise on most zoo models.
		let metadata = ONNXMetadataMapping.metadata(from: ONNXRawMetadata(modelVersion: 0))
		XCTAssertNil(metadata, "a model whose only 'metadata' is model_version=0 records nothing")
	}

	func testModelVersionUsedOnlyWhenNoVersionProp() throws {
		let withProp = try XCTUnwrap(ONNXMetadataMapping.metadata(from: ONNXRawMetadata(
			props: [("version", "2.0")], modelVersion: 5)))
		XCTAssertEqual(withProp.versionString, "2.0", "an explicit version prop wins over model_version")

		let withoutProp = try XCTUnwrap(ONNXMetadataMapping.metadata(from: ONNXRawMetadata(
			props: [("author", "x")], modelVersion: 5)))
		XCTAssertEqual(withoutProp.versionString, "5")
	}

	func testProducerNameIsNeverUsedAsAuthor() {
		// producer_name identifies the exporting tool, not the model's author. A model with only a
		// producer name (no author prop) must not present that tool as the author.
		let metadata = ONNXMetadataMapping.metadata(from: ONNXRawMetadata(producerName: "OnnxMLTools"))
		XCTAssertNil(metadata?.author)
	}

	func testEveryNonEmptyPropIsMirroredIntoUserDefined() throws {
		let metadata = try XCTUnwrap(ONNXMetadataMapping.metadata(from: ONNXRawMetadata(
			props: [("docs", "https://docs.ultralytics.com"), ("stride", "32"), ("imgsz", "[640, 640]")]
		)))
		XCTAssertEqual(metadata.userDefined["docs"], "https://docs.ultralytics.com")
		XCTAssertEqual(metadata.userDefined["stride"], "32")
		XCTAssertEqual(metadata.userDefined["imgsz"], "[640, 640]")
	}

	func testEmptyKeysAndValuesAreDroppedFromTheMirror() throws {
		let metadata = try XCTUnwrap(ONNXMetadataMapping.metadata(from: ONNXRawMetadata(
			props: [("author", "A"), ("", "orphan value"), ("orphan key", "  ")]
		)))
		XCTAssertNil(metadata.userDefined[""])
		XCTAssertNil(metadata.userDefined["orphan key"])
		XCTAssertEqual(metadata.userDefined.count, 1, "only the non-empty pair survives")
	}

	func testDuplicateKeysKeepLastOccurrence() throws {
		// ONNX does not require unique metadata_props keys.
		let metadata = try XCTUnwrap(ONNXMetadataMapping.metadata(from: ONNXRawMetadata(
			props: [("author", "first"), ("author", "second")]
		)))
		XCTAssertEqual(metadata.author, "second")
	}

	func testOversizedValueIsDroppedWithoutSuppressingOthers() throws {
		let huge = String(repeating: "x", count: ONNXMetadataMapping.maximumValueByteCount + 1)
		let metadata = try XCTUnwrap(ONNXMetadataMapping.metadata(from: ONNXRawMetadata(
			props: [("author", "Legit"), ("blob", huge)]
		)))
		XCTAssertEqual(metadata.author, "Legit", "a hostile oversized value must not nuke a legit field")
		XCTAssertNil(metadata.userDefined["blob"])
	}

	func testMirroredPairCountIsBounded() throws {
		let props = (0 ..< (ONNXMetadataMapping.maximumMirroredPairCount + 50)).map { index in
			(key: "k\(String(format: "%04d", index))", value: "v")
		}
		let metadata = try XCTUnwrap(ONNXMetadataMapping.metadata(from: ONNXRawMetadata(props: props)))
		XCTAssertLessThanOrEqual(metadata.userDefined.count, ONNXMetadataMapping.maximumMirroredPairCount)
	}

	func testMetadataFreeModelMapsToNil() {
		XCTAssertNil(ONNXMetadataMapping.metadata(from: ONNXRawMetadata()),
			"a bare model records nothing, so it keeps its filename fallback rather than an empty block")
	}

	// MARK: - Proto field parsing (deterministic, against hand-built bytes)

	func testRawMetadataParsesModelProtoFieldNumbers() throws {
		// Build a minimal ModelProto carrying only the attribution fields, so a regression in the
		// field numbers (producer_name=2, model_version=5, doc_string=6, metadata_props=14) or in the
		// StringStringEntryProto layout (key=1, value=2) fails deterministically, without a fixture.
		var model = Data()
		appendStringField(2, "pytorch", to: &model)               // producer_name
		appendVarintField(5, 7, to: &model)                       // model_version
		appendStringField(6, "a doc string", to: &model)          // doc_string
		appendStringField(14, stringStringEntry("author", "Ultralytics"), to: &model)
		appendStringField(14, stringStringEntry("task", "detect"), to: &model)

		let fields = try ProtobufReader.fields(in: model)
		let raw = ONNXModelReader().rawMetadata(from: fields)

		XCTAssertEqual(raw.producerName, "pytorch")
		XCTAssertEqual(raw.modelVersion, 7)
		XCTAssertEqual(raw.docString, "a doc string")
		XCTAssertEqual(raw.props.count, 2)
		XCTAssertEqual(raw.props.first { $0.key == "author" }?.value, "Ultralytics")
		XCTAssertEqual(raw.props.first { $0.key == "task" }?.value, "detect")
	}

	// MARK: - Minimal protobuf writer (test-local)

	private func appendVarint(_ value: UInt64, to data: inout Data) {
		var remaining = value
		repeat {
			var byte = UInt8(remaining & 0x7f)
			remaining >>= 7
			if remaining != 0 { byte |= 0x80 }
			data.append(byte)
		} while remaining != 0
	}

	private func appendVarintField(_ field: Int, _ value: UInt64, to data: inout Data) {
		appendVarint(UInt64(field) << 3 | 0, to: &data)  // wire type 0
		appendVarint(value, to: &data)
	}

	private func appendStringField(_ field: Int, _ value: String, to data: inout Data) {
		appendStringField(field, Data(value.utf8), to: &data)
	}

	private func appendStringField(_ field: Int, _ value: Data, to data: inout Data) {
		appendVarint(UInt64(field) << 3 | 2, to: &data)  // wire type 2 (length-delimited)
		appendVarint(UInt64(value.count), to: &data)
		data.append(value)
	}

	private func stringStringEntry(_ key: String, _ value: String) -> Data {
		var entry = Data()
		appendStringField(1, key, to: &entry)
		appendStringField(2, value, to: &entry)
		return entry
	}
}
