//
//  UltralyticsDetectorHintsTests.swift
//  NativeModelConverterTests
//
//  Hermetic (no fixture download) proofs of the strict metadata parser. The contract under test is
//  all-or-nothing: a field is either parsed exactly or reported absent (`nil`) — never guessed.
//

import XCTest
@testable import NativeModelConverter

final class UltralyticsDetectorHintsTests: XCTestCase {

	// MARK: - names: the happy path (real Ultralytics format)

	func testNames_denseSingleQuotedWithSpaces_parsesInKeyOrder() {
		// Exact shape a genuine export writes: single quotes, "key: value", a label with a space.
		let value = "{0: 'person', 1: 'bicycle', 2: 'car', 3: 'motorcycle', 4: 'traffic light'}"
		XCTAssertEqual(
			UltralyticsDetectorHints.parseNames(value),
			["person", "bicycle", "car", "motorcycle", "traffic light"]
		)
	}

	func testNames_keysOutOfOrderButDense_reordersByKey() {
		let value = "{2: 'c', 0: 'a', 1: 'b'}"
		XCTAssertEqual(UltralyticsDetectorHints.parseNames(value), ["a", "b", "c"])
	}

	func testNames_doubleQuotedValues_parse() {
		XCTAssertEqual(UltralyticsDetectorHints.parseNames("{0: \"a\", 1: \"b\"}"), ["a", "b"])
	}

	func testNames_backslashEscapedQuoteInLabel_unescapes() {
		// {0: 'it\'s'} -> "it's"
		XCTAssertEqual(UltralyticsDetectorHints.parseNames("{0: 'it\\'s'}"), ["it's"])
	}

	func testNames_singleEntry_parses() {
		XCTAssertEqual(UltralyticsDetectorHints.parseNames("{0: 'only'}"), ["only"])
	}

	// MARK: - names: rejections (must be nil, never a partial guess)

	func testNames_sparseKeys_rejected() {
		// Missing key 1 -> label 1 would be ambiguous -> reject the whole map.
		XCTAssertNil(UltralyticsDetectorHints.parseNames("{0: 'a', 2: 'c'}"))
	}

	func testNames_duplicateKey_rejected() {
		XCTAssertNil(UltralyticsDetectorHints.parseNames("{0: 'a', 0: 'b'}"))
	}

	func testNames_keysNotStartingAtZero_rejected() {
		XCTAssertNil(UltralyticsDetectorHints.parseNames("{1: 'a', 2: 'b'}"))
	}

	func testNames_negativeKey_rejected() {
		XCTAssertNil(UltralyticsDetectorHints.parseNames("{-1: 'a'}"))
	}

	func testNames_nonIntegerKey_rejected() {
		XCTAssertNil(UltralyticsDetectorHints.parseNames("{'a': 'b'}"))
	}

	func testNames_unterminatedString_rejected() {
		XCTAssertNil(UltralyticsDetectorHints.parseNames("{0: 'perso"))
	}

	func testNames_missingClosingBrace_rejected() {
		XCTAssertNil(UltralyticsDetectorHints.parseNames("{0: 'a'"))
	}

	func testNames_emptyMap_reportedAbsent() {
		XCTAssertNil(UltralyticsDetectorHints.parseNames("{}"))
	}

	func testNames_trailingGarbageAfterBrace_rejected() {
		XCTAssertNil(UltralyticsDetectorHints.parseNames("{0: 'a'} extra"))
	}

	func testNames_trailingComma_rejected() {
		XCTAssertNil(UltralyticsDetectorHints.parseNames("{0: 'a',}"))
	}

	func testNames_unknownEscape_rejected() {
		// \x is not a Python string escape Ultralytics emits; reject rather than silently drop it.
		XCTAssertNil(UltralyticsDetectorHints.parseNames("{0: 'a\\xb'}"))
	}

	func testNames_notADict_rejected() {
		XCTAssertNil(UltralyticsDetectorHints.parseNames("person, bicycle"))
		XCTAssertNil(UltralyticsDetectorHints.parseNames(""))
	}

	func testNames_overClassCountCap_rejected() {
		var parts: [String] = []
		for index in 0...UltralyticsDetectorHints.maximumClassCount {  // one past the cap
			parts.append("\(index): 'c\(index)'")
		}
		let value = "{" + parts.joined(separator: ", ") + "}"
		XCTAssertNil(UltralyticsDetectorHints.parseNames(value))
	}

	// MARK: - imgsz

	func testIMGSZ_pair_parses() {
		XCTAssertEqual(UltralyticsDetectorHints.parseIntList("[640, 640]"), [640, 640])
	}

	func testIMGSZ_nonPositive_rejected() {
		XCTAssertNil(UltralyticsDetectorHints.parseIntList("[640, 0]"))
	}

	func testIMGSZ_empty_reportedAbsent() {
		XCTAssertNil(UltralyticsDetectorHints.parseIntList("[]"))
	}

	func testIMGSZ_nonInteger_rejected() {
		XCTAssertNil(UltralyticsDetectorHints.parseIntList("[abc]"))
		XCTAssertNil(UltralyticsDetectorHints.parseIntList("[640.0, 640.0]"))
	}

	// MARK: - nms (confirmatory only)

	func testNMS_falseInArgs_parses() {
		XCTAssertEqual(UltralyticsDetectorHints.parseNMS("{'batch': 1, 'nms': False}"), false)
	}

	func testNMS_trueInArgs_parses() {
		XCTAssertEqual(UltralyticsDetectorHints.parseNMS("{'nms': True}"), true)
	}

	func testNMS_doubleQuoted_parses() {
		XCTAssertEqual(UltralyticsDetectorHints.parseNMS("{\"nms\": False}"), false)
	}

	func testNMS_absent_isNil() {
		XCTAssertNil(UltralyticsDetectorHints.parseNMS("{'batch': 1}"))
	}

	// MARK: - value byte cap (bounded before scanning)

	func testNames_oversizeValue_reportedAbsentFromParse() {
		let huge = String(repeating: "x", count: UltralyticsDetectorHints.maximumValueByteCount + 1)
		let raw = ONNXRawMetadata(props: [("names", "{0: '\(huge)'}")])
		XCTAssertNil(UltralyticsDetectorHints.parse(from: raw).names)
	}

	// MARK: - parse(from:) integration

	func testParse_fullUltralyticsBag_populatesEveryField() {
		let raw = ONNXRawMetadata(props: [
			("task", "detect"),
			("names", "{0: 'person', 1: 'bicycle', 2: 'car'}"),
			("imgsz", "[640, 640]"),
			("args", "{'batch': 1, 'half': False, 'nms': False}")
		])
		let hints = UltralyticsDetectorHints.parse(from: raw)
		XCTAssertEqual(hints.task, "detect")
		XCTAssertEqual(hints.names, ["person", "bicycle", "car"])
		XCTAssertEqual(hints.imgsz, [640, 640])
		XCTAssertEqual(hints.nms, false)
		XCTAssertFalse(hints.isEmpty)
	}

	func testParse_strippedExport_isEmpty() {
		// yolov8n-s1777: no metadata_props at all.
		let hints = UltralyticsDetectorHints.parse(from: ONNXRawMetadata())
		XCTAssertTrue(hints.isEmpty)
		XCTAssertNil(hints.names)
	}

	func testParse_lastOccurrenceWinsForDuplicateKey() {
		let raw = ONNXRawMetadata(props: [("task", "classify"), ("task", "detect")])
		XCTAssertEqual(UltralyticsDetectorHints.parse(from: raw).task, "detect")
	}

	func testParse_whitespaceDecoratedKeyIgnored() {
		// A " task " key must not shadow the exact "task" — matches ONNXMetadataMapping's key rule.
		let raw = ONNXRawMetadata(props: [(" task ", "classify"), ("task", "detect")])
		XCTAssertEqual(UltralyticsDetectorHints.parse(from: raw).task, "detect")
	}

	// MARK: - Review hardening: last-occurrence, leading-zero keys, control characters

	func testParse_lastNamesOccurrenceWins() {
		let raw = ONNXRawMetadata(props: [("names", "{0: 'a'}"), ("names", "{0: 'z'}")])
		XCTAssertEqual(UltralyticsDetectorHints.parse(from: raw).names, ["z"])
	}

	func testParse_oversizeLastNames_isAbsentNotStaleEarlier() {
		// An oversized FINAL occurrence must make names absent — never fall back to an earlier valid map.
		let oversize = "{0: '" + String(repeating: "x", count: UltralyticsDetectorHints.maximumValueByteCount) + "'}"
		let raw = ONNXRawMetadata(props: [("names", "{0: 'a', 1: 'b'}"), ("names", oversize)])
		XCTAssertNil(UltralyticsDetectorHints.parse(from: raw).names)
	}

	func testNames_leadingZeroKey_rejected() {
		XCTAssertNil(UltralyticsDetectorHints.parseNames("{00: 'a'}"))
		XCTAssertNil(UltralyticsDetectorHints.parseNames("{0: 'a', 01: 'b'}"))
	}

	func testNames_rawControlCharInLabel_rejected() {
		XCTAssertNil(UltralyticsDetectorHints.parseNames("{0: 'a\nb'}"))
		XCTAssertNil(UltralyticsDetectorHints.parseNames("{0: 'a\tb'}"))
	}

	func testNames_escapedNewlineStillDecodes() {
		// The escaped form is preserved even though a raw newline is rejected.
		XCTAssertEqual(UltralyticsDetectorHints.parseNames("{0: 'a\\nb'}"), ["a\nb"])
	}
}
