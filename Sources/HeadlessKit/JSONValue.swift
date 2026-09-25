//
//  JSONValue.swift
//  HeadlessKit
//
//  AIA-0970.
//

import Foundation

/// A JSON document as a value: the currency of every screen state, action result and scenario
/// assertion.
///
/// Screens describe themselves with this rather than with their own `Codable` types so that a
/// client — an AI agent, a scenario runner, another language — can read any adopter's state
/// without that adopter's Swift types, and so that assertions can address any part of a response
/// by JSON pointer.
public enum JSONValue: Hashable, Sendable {
	case null
	case bool(Bool)
	case number(Double)
	case string(String)
	case array([JSONValue])
	case object([String: JSONValue])
}

// MARK: - Codable

extension JSONValue: Codable {

	public init(from decoder: Decoder) throws {
		let container = try decoder.singleValueContainer()
		if container.decodeNil() {
			self = .null
		// `Bool` is tried before `Double`: JSON `true` must never become `1`.
		} else if let value = try? container.decode(Bool.self) {
			self = .bool(value)
		} else if let value = try? container.decode(Double.self) {
			self = .number(value)
		} else if let value = try? container.decode(String.self) {
			self = .string(value)
		} else if let value = try? container.decode([JSONValue].self) {
			self = .array(value)
		} else if let value = try? container.decode([String: JSONValue].self) {
			self = .object(value)
		} else {
			throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a JSON value")
		}
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.singleValueContainer()
		switch self {
		case .null:
			try container.encodeNil()
		case .bool(let value):
			try container.encode(value)
		case .number(let value):
			// Integral values are written as integers so an id or a count reads `3`, not `3.0`,
			// whichever way the platform's encoder formats a `Double`.
			if let integer = Self.exactInteger(value) {
				try container.encode(integer)
			} else {
				try container.encode(value)
			}
		case .string(let value):
			try container.encode(value)
		case .array(let value):
			try container.encode(value)
		case .object(let value):
			try container.encode(value)
		}
	}

	/// The value as an `Int` when it is integral and exactly representable, otherwise `nil`.
	static func exactInteger(_ value: Double) -> Int? {
		// 2^53: beyond it a `Double` no longer holds every integer, so "integral" stops meaning "exact".
		guard value.isFinite, value.rounded() == value, abs(value) <= 9_007_199_254_740_992 else { return nil }
		return Int(value)
	}
}

// MARK: - Literals

// Deliberately not `ExpressibleByNilLiteral`: in a `JSONValue?` context a bare `nil` would then be
// ambiguous, and in a ternary it silently becomes `.null` rather than "no value" — a bug this
// package's own argument conversion hit. Write `.null`.
extension JSONValue: ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
	ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
	ExpressibleByDictionaryLiteral {

	public init(booleanLiteral value: Bool) { self = .bool(value) }
	public init(integerLiteral value: Int) { self = .number(Double(value)) }
	public init(floatLiteral value: Double) { self = .number(value) }
	public init(stringLiteral value: String) { self = .string(value) }
	public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }

	public init(dictionaryLiteral elements: (String, JSONValue)...) {
		self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
	}
}

// MARK: - Accessors

extension JSONValue {

	public var stringValue: String? {
		if case .string(let value) = self { return value }
		return nil
	}

	public var boolValue: Bool? {
		if case .bool(let value) = self { return value }
		return nil
	}

	public var numberValue: Double? {
		if case .number(let value) = self { return value }
		return nil
	}

	/// The number as an `Int`, only when it is integral.
	public var intValue: Int? {
		numberValue.flatMap(Self.exactInteger)
	}

	public var arrayValue: [JSONValue]? {
		if case .array(let value) = self { return value }
		return nil
	}

	public var objectValue: [String: JSONValue]? {
		if case .object(let value) = self { return value }
		return nil
	}

	/// The value a JSON Pointer (RFC 6901) addresses, or `nil` when it addresses nothing.
	///
	/// The empty pointer is the whole document. Array indices must be canonical (`"01"` addresses
	/// nothing), as the RFC requires, so a pointer cannot match by accident.
	public func value(at pointer: String) -> JSONValue? {
		guard pointer.isEmpty == false else { return self }
		guard pointer.hasPrefix("/") else { return nil }
		var current = self
		for rawToken in pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
			// `~1` before `~0`, per the RFC: `~01` must decode to `~1`, not to `/`.
			let token = rawToken.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
			switch current {
			case .object(let members):
				guard let next = members[token] else { return nil }
				current = next
			case .array(let elements):
				guard let index = Int(token), index >= 0, index < elements.count, String(index) == token else {
					return nil
				}
				current = elements[index]
			default:
				return nil
			}
		}
		return current
	}

	/// Compact JSON with sorted keys: stable across runs, so it can be compared and diffed.
	public var jsonString: String {
		// A non-finite number is the only value that cannot encode, and JSON cannot carry it, so the
		// honest rendering of that failure is `null`.
		guard let data = try? HeadlessCoding.makeEncoder().encode(self),
			  let text = String(bytes: data, encoding: .utf8) else {
			return "null"
		}
		return text
	}
}
