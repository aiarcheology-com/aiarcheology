//
//  Arguments.swift
//  HeadlessKit
//
//  AIA-0970.
//

import Foundation

/// The arguments of one action or wait, already validated against its parameters.
///
/// The session validates before any handler runs: unknown names, missing required values and
/// values of the wrong type never reach adopter code. Typed accessors still throw, so a handler
/// that asks for a parameter it did not declare fails loudly instead of reading nothing.
public struct Arguments: Sendable, Equatable {

	public let values: [String: JSONValue]

	public init(_ values: [String: JSONValue] = [:]) {
		self.values = values
	}

	public subscript(name: String) -> JSONValue? {
		values[name]
	}

	public func string(_ name: String) throws -> String {
		guard let value = values[name]?.stringValue else { throw Self.missing(name, "a string") }
		return value
	}

	public func integer(_ name: String) throws -> Int {
		guard let value = values[name]?.intValue else { throw Self.missing(name, "an integer") }
		return value
	}

	public func number(_ name: String) throws -> Double {
		guard let value = values[name]?.numberValue else { throw Self.missing(name, "a number") }
		return value
	}

	public func boolean(_ name: String) throws -> Bool {
		guard let value = values[name]?.boolValue else { throw Self.missing(name, "a boolean") }
		return value
	}

	private static func missing(_ name: String, _ kind: String) -> HeadlessError {
		HeadlessError(.invalidArgument, "'\(name)' must be \(kind)")
	}

	/// Validates raw client arguments against `parameters`. Types are strict (AIA-0992): each value
	/// must already be the declared JSON type — a string for `string`, an integral number for
	/// `integer`, a finite number for `number`, a boolean for `boolean`. Converting command-line text
	/// is the command line's job (ProjectTool's `exec` reads the declared types first), not the
	/// protocol's: `"3"` for an integer is rejected, as is `7` for a string.
	///
	/// - Parameter subject: names the action or condition in error messages.
	static func validated(
		_ raw: [String: JSONValue],
		against parameters: [ParameterSpec],
		subject: String
	) throws -> Arguments {
		let declared = Dictionary(parameters.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
		// Rejected rather than ignored: a misspelt optional argument would otherwise be dropped and
		// the action would run with its default, which is the wrong action, silently.
		let unknown = raw.keys.filter { declared[$0] == nil }.sorted()
		guard unknown.isEmpty else {
			let expected = parameters.map(\.name).joined(separator: ", ")
			throw HeadlessError(
				.invalidArgument,
				"\(subject) does not take \(unknown.joined(separator: ", ")) (parameters: \(expected.isEmpty ? "none" : expected))"
			)
		}
		var result: [String: JSONValue] = [:]
		for parameter in parameters {
			guard let value = raw[parameter.name], value != .null else {
				if parameter.isRequired {
					throw HeadlessError(.invalidArgument, "\(subject) requires '\(parameter.name)'")
				}
				continue
			}
			guard let converted = convert(value, to: parameter.kind) else {
				throw HeadlessError(
					.invalidArgument,
					"\(subject): '\(parameter.name)' must be \(parameter.kind.rawValue), got \(value.jsonString)"
				)
			}
			result[parameter.name] = converted
		}
		return Arguments(result)
	}

	/// `value` when it is of `kind`, or `nil` when it is not. Written with explicit branches: every
	/// `nil` here must mean "the wrong type", never a JSON null.
	private static func convert(_ value: JSONValue, to kind: ParameterSpec.Kind) -> JSONValue? {
		switch kind {
		case .string: convertToString(value)
		case .integer: convertToInteger(value)
		case .number: convertToNumber(value)
		case .boolean: convertToBoolean(value)
		}
	}

	private static func convertToString(_ value: JSONValue) -> JSONValue? {
		switch value {
		case .string:
			return value
		case .null, .number, .bool, .array, .object:
			return nil
		}
	}

	private static func convertToInteger(_ value: JSONValue) -> JSONValue? {
		switch value {
		case .number(let number):
			guard JSONValue.exactInteger(number) != nil else { return nil }
			return value
		case .null, .bool, .string, .array, .object:
			return nil
		}
	}

	private static func convertToNumber(_ value: JSONValue) -> JSONValue? {
		switch value {
		case .number(let number):
			return number.isFinite ? value : nil
		case .null, .bool, .string, .array, .object:
			return nil
		}
	}

	private static func convertToBoolean(_ value: JSONValue) -> JSONValue? {
		switch value {
		case .bool:
			return value
		case .null, .number, .string, .array, .object:
			return nil
		}
	}
}
