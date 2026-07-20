//
//  UltralyticsDetectorHints.swift
//  NativeModelConverter
//
//  Strict parser for the detector semantics an Ultralytics export carries in ONNX `metadata_props`
//  (`task` / `names` / `imgsz` / `args.nms`). This reads the SAME untrusted `[key, value]` bag as
//  ONNXMetadataMapping, but with a harder trust posture: ONNXMetadataMapping is display-only, whereas
//  these values DRIVE conversion semantics — `names` becomes the label list a detector reports. A
//  shifted or half-parsed label map confidently mislabels every detection (the #471 / #473
//  silent-wrongness class), so parsing is ALL-OR-NOTHING per field: any deviation from the exact
//  expected shape yields `nil` ("absent"), never a guessed or partial result. "Absent" is always
//  safer than "approximately parsed" — the caller falls back to honest generic labels.
//
//  Nothing here decides a model IS a detector or trusts these values over the graph. The graph's
//  op set and output shape remain authoritative; `names` is only consulted once the structural audit
//  has already recognised an anchor-free head, and only when its count matches the graph output.
//

import Foundation

/// Detector semantics recovered from an Ultralytics ONNX export's `metadata_props`. Every field is
/// independently optional: a stripped re-export (e.g. yolov8n-s1777) parses to an all-`nil` value.
struct UltralyticsDetectorHints: Equatable {
	/// `task` verbatim (e.g. "detect"). Confirms an anchor-free head is a detector; never gates it.
	var task: String?
	/// `names` as an ordered label list — populated ONLY when the map is exactly a dense `0..<N`.
	var names: [String]?
	/// `imgsz` as positive integer dimensions (used only to cross-check the graph input, never to
	/// set geometry — the graph input tensor is authoritative for that).
	var imgsz: [Int]?
	/// `args.nms`. Purely confirmatory: a raw export (the only kind we convert) has `nms == false`,
	/// but the graph output shape already proves that, so this only corroborates.
	var nms: Bool?

	var isEmpty: Bool { task == nil && names == nil && imgsz == nil && nms == nil }
}

extension UltralyticsDetectorHints {

	/// A generous ceiling on class count; a real detector has ≤ a few thousand. Bounds a hostile file
	/// that lists a huge `names` map.
	static let maximumClassCount = 4096
	/// A per-value byte cap applied before any scanning, so a corrupt file cannot make the parser
	/// walk megabytes of text. `names` for thousands of classes stays well under this.
	static let maximumValueByteCount = 64 * 1024

	/// Builds the hints from the raw ONNX attribution bag. Never throws and never partially trusts a
	/// field: each of `task`/`names`/`imgsz`/`nms` is present only when it parses exactly.
	static func parse(from raw: ONNXRawMetadata) -> UltralyticsDetectorHints {
		// Last-occurrence-wins with exact (untrimmed) keys and a size cap — the same discipline
		// ONNXMetadataMapping uses so both readers see the same value for a key.
		var props: [String: String] = [:]
		for (key, value) in raw.props {
			guard key == key.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { continue }
			guard value.utf8.count <= maximumValueByteCount else { continue }
			props[key] = value
		}
		func prop(_ name: String) -> String? {
			guard let value = props[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
				return nil
			}
			return value
		}
		return UltralyticsDetectorHints(
			task: prop("task"),
			names: prop("names").flatMap(parseNames),
			imgsz: prop("imgsz").flatMap(parseIntList),
			nms: prop("args").flatMap(parseNMS)
		)
	}

	/// Parses `{0: 'person', 1: 'bicycle', …}` (Python-dict repr) into a label list ordered by key,
	/// but ONLY when the keys are exactly the dense set `0..<N`. Any gap, duplicate, negative key,
	/// non-integer key, malformed quoting, or trailing garbage → `nil`. Handles single- and
	/// double-quoted values with backslash escapes and labels that contain spaces ("traffic light").
	static func parseNames(_ raw: String) -> [String]? {
		var scanner = Scanner(raw)
		scanner.skipWhitespace()
		guard scanner.consume("{") else { return nil }
		scanner.skipWhitespace()
		// An empty map carries no labels — treat as absent rather than "zero classes".
		if scanner.consume("}") {
			scanner.skipWhitespace()
			return nil
		}
		var byKey: [Int: String] = [:]
		var count = 0
		while true {
			scanner.skipWhitespace()
			guard let key = scanner.scanNonNegativeInt() else { return nil }
			scanner.skipWhitespace()
			guard scanner.consume(":") else { return nil }
			scanner.skipWhitespace()
			guard let value = scanner.scanQuotedString() else { return nil }
			// A duplicate key means the map is not a clean dense enumeration — reject the whole field.
			guard byKey[key] == nil else { return nil }
			byKey[key] = value
			count += 1
			guard count <= maximumClassCount else { return nil }
			scanner.skipWhitespace()
			if scanner.consume(",") { continue }
			if scanner.consume("}") { break }
			return nil  // neither a separator nor the closing brace → malformed
		}
		scanner.skipWhitespace()
		guard scanner.atEnd else { return nil }  // trailing garbage after the closing brace
		// Require exactly the dense keys 0..<count; a gap would make label i ambiguous.
		var ordered: [String] = []
		ordered.reserveCapacity(count)
		for index in 0..<count {
			guard let label = byKey[index] else { return nil }
			ordered.append(label)
		}
		return ordered
	}

	/// Parses `[640, 640]` into positive integers. Any non-integer, non-positive, empty list, or
	/// trailing garbage → `nil`.
	static func parseIntList(_ raw: String) -> [Int]? {
		var scanner = Scanner(raw)
		scanner.skipWhitespace()
		guard scanner.consume("[") else { return nil }
		scanner.skipWhitespace()
		if scanner.consume("]") { return nil }  // empty list → absent
		var values: [Int] = []
		while true {
			scanner.skipWhitespace()
			guard let value = scanner.scanNonNegativeInt(), value > 0 else { return nil }
			values.append(value)
			guard values.count <= 8 else { return nil }  // a dimension list is short
			scanner.skipWhitespace()
			if scanner.consume(",") { continue }
			if scanner.consume("]") { break }
			return nil
		}
		scanner.skipWhitespace()
		guard scanner.atEnd else { return nil }
		return values
	}

	/// Reads `args.nms` from the `args` dict-repr string. Confirmatory only, so it is deliberately a
	/// narrow exact-token match (both quote styles); anything ambiguous → `nil`.
	static func parseNMS(_ argsValue: String) -> Bool? {
		for quote in ["'", "\""] {
			if argsValue.contains("\(quote)nms\(quote): True") { return true }
			if argsValue.contains("\(quote)nms\(quote): False") { return false }
		}
		return nil
	}
}

// MARK: - Character scanner

/// A minimal forward character scanner. Hand-written (not a regex) because `names` is structured
/// markup whose quoting and escaping a regex cannot parse correctly — a real tokenizer is the only
/// correct tool.
private struct Scanner {
	private let chars: [Character]
	private var index = 0

	init(_ string: String) { chars = Array(string) }

	var atEnd: Bool { index >= chars.count }

	mutating func skipWhitespace() {
		while index < chars.count, chars[index].isWhitespace { index += 1 }
	}

	mutating func consume(_ character: Character) -> Bool {
		guard index < chars.count, chars[index] == character else { return false }
		index += 1
		return true
	}

	/// Scans a run of ASCII digits into a non-negative `Int`. Non-ASCII "digits" are not accepted,
	/// and a run too large for `Int` returns `nil` (rejecting the field rather than wrapping).
	mutating func scanNonNegativeInt() -> Int? {
		let start = index
		while index < chars.count, chars[index] >= "0", chars[index] <= "9" { index += 1 }
		guard index > start else { return nil }
		return Int(String(chars[start..<index]))
	}

	/// Scans a single- or double-quoted string with backslash escapes. Unknown escape sequences,
	/// dangling escapes, and unterminated strings all fail (return `nil`) rather than guess.
	mutating func scanQuotedString() -> String? {
		guard index < chars.count else { return nil }
		let quote = chars[index]
		guard quote == "'" || quote == "\"" else { return nil }
		index += 1
		var output = ""
		while index < chars.count {
			let character = chars[index]
			if character == "\\" {
				index += 1
				guard index < chars.count else { return nil }  // dangling escape
				let escaped = chars[index]
				switch escaped {
				case "\\", "'", "\"": output.append(escaped)
				case "n": output.append("\n")
				case "t": output.append("\t")
				default: return nil  // unknown escape → reject the whole field
				}
				index += 1
			} else if character == quote {
				index += 1
				return output
			} else {
				output.append(character)
				index += 1
			}
		}
		return nil  // unterminated string
	}
}
