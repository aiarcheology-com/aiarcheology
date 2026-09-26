//
//  Scenario.swift
//  HeadlessScenario
//
//  AIA-0970.
//

import Foundation
import HeadlessKit

/// A declarative end-to-end test: installations of the app, the steps a user takes in them, and
/// what must be true after each step.
///
/// ```json
/// {
///   "schemaVersion": 1,
///   "name": "enable-a-model",
///   "installations": { "a": { "launch": { "mockSubscription": "subscribed" } } },
///   "steps": [
///     { "on": "a", "wait": { "condition": "route", "arguments": { "route": "home" } } },
///     { "on": "a", "goto": "drawer", "capture": { "model": "/state/models/0/id" } },
///     { "on": "a", "perform": { "action": "enable", "arguments": { "id": "${model}" } },
///       "expect": [ { "equals": { "pointer": "/state/models/0/enabled", "value": true } } ] }
///   ],
///   "teardown": []
/// }
/// ```
///
/// Decoding is strict: an unknown key anywhere is an error, so a misspelt `expect` fails the
/// scenario instead of silently asserting nothing.
public struct Scenario: Codable, Sendable, Equatable {

	/// The only schema this build reads.
	public static let supportedSchemaVersion = 1

	public let schemaVersion: Int
	public let name: String
	/// Independent installations of the app, by name. Each has its own data and its own launch.
	public let installations: [String: Installation]
	public let steps: [Step]
	/// Runs after `steps` whatever happened in them — to clean up anything a run created outside the
	/// installations, such as server-side data. Only these steps may be `bestEffort`.
	public let teardown: [Step]

	public init(
		schemaVersion: Int = Scenario.supportedSchemaVersion,
		name: String,
		installations: [String: Installation],
		steps: [Step],
		teardown: [Step] = []
	) {
		self.schemaVersion = schemaVersion
		self.name = name
		self.installations = installations
		self.steps = steps
		self.teardown = teardown
	}

	private enum CodingKeys: String, CodingKey, CaseIterable {
		case schemaVersion, name, installations, steps, teardown
	}

	public init(from decoder: Decoder) throws {
		try StrictKeys.check(decoder, allowed: CodingKeys.allCases)
		let container = try decoder.container(keyedBy: CodingKeys.self)
		schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
		name = try container.decode(String.self, forKey: .name)
		installations = try container.decode([String: Installation].self, forKey: .installations)
		steps = try container.decode([Step].self, forKey: .steps)
		teardown = try container.decodeIfPresent([Step].self, forKey: .teardown) ?? []
		// Rejected while reading, not only by `validate()`: a best-effort *step* would be an assertion
		// that cannot fail, which is exactly what strict decoding exists to prevent.
		if let index = steps.firstIndex(where: \.bestEffort) {
			throw DecodingError.dataCorrupted(.init(
				codingPath: container.codingPath + [CodingKeys.steps],
				debugDescription: "steps[\(index)]: bestEffort is only allowed in teardown"
			))
		}
	}

	/// Reads and validates a scenario file.
	public static func load(contentsOf url: URL) throws -> Scenario {
		let scenario = try HeadlessCoding.makeDecoder().decode(Scenario.self, from: Data(contentsOf: url))
		try scenario.validate()
		return scenario
	}

	/// Checks what decoding cannot: the version, and that every step names a real installation and
	/// does at most one thing.
	public func validate() throws {
		guard schemaVersion == Self.supportedSchemaVersion else {
			throw ScenarioError("'\(name)': schemaVersion \(schemaVersion) is not supported (expected \(Self.supportedSchemaVersion))")
		}
		guard installations.isEmpty == false else {
			throw ScenarioError("'\(name)': declares no installations")
		}
		for (phase, list) in [("steps", steps), ("teardown", teardown)] {
			for (index, step) in list.enumerated() {
				let label = "'\(name)' \(phase)[\(index)]"
				guard step.actionCount <= 1 else {
					throw ScenarioError("\(label): a step does at most one of goto, perform, wait, relaunch")
				}
				guard step.bestEffort == false || phase == "teardown" else {
					throw ScenarioError("\(label): bestEffort is only allowed in teardown")
				}
				_ = try installation(for: step, label: label)
				for (variable, pointer) in step.capture {
					guard pointer.isEmpty || pointer.hasPrefix("/") else {
						throw ScenarioError("\(label): capture '\(variable)' is not a JSON pointer: \(pointer)")
					}
				}
				for expectation in step.expect {
					try Self.validate(expectation, label: label)
				}
			}
		}
	}

	private static func validate(_ expectation: Expectation, label: String) throws {
		let pointer: String
		switch expectation {
		case .route, .error:
			return
		case .equals(let target, _), .exists(let target), .absent(let target):
			pointer = target
		case .matches(let target, let pattern):
			pointer = target
			// Placeholders are filled at run time, with the value matched literally, so the pattern
			// is checked with each one standing in as a plain literal.
			let checked = Substitution.placeholder.stringByReplacingMatches(
				in: pattern,
				range: NSRange(pattern.startIndex..., in: pattern),
				withTemplate: "x"
			)
			do {
				_ = try NSRegularExpression(pattern: checked)
			} catch {
				throw ScenarioError("\(label): invalid regular expression \(pattern)")
			}
		}
		// A pointer without the leading slash addresses nothing, so `absent` would always pass and
		// the others would always fail with a misleading "found nothing".
		guard pointer.isEmpty || pointer.hasPrefix("/") else {
			throw ScenarioError("\(label): '\(pointer)' is not a JSON pointer (it must start with /)")
		}
	}

	/// The installation a step runs on: the one it names, or the only one there is.
	func installation(for step: Step, label: String) throws -> String {
		if let name = step.on {
			guard installations[name] != nil else {
				throw ScenarioError("\(label): unknown installation '\(name)'")
			}
			return name
		}
		guard installations.count == 1, let only = installations.keys.first else {
			throw ScenarioError("\(label): 'on' is required when there is more than one installation")
		}
		return only
	}
}

/// How to launch one installation. `launch` is interpreted by the adopter's launcher only.
public struct Installation: Codable, Sendable, Equatable {

	public let launch: JSONValue

	public init(launch: JSONValue = .object([:])) {
		self.launch = launch
	}

	private enum CodingKeys: String, CodingKey, CaseIterable {
		case launch
	}

	public init(from decoder: Decoder) throws {
		try StrictKeys.check(decoder, allowed: CodingKeys.allCases)
		let container = try decoder.container(keyedBy: CodingKeys.self)
		launch = try container.decodeIfPresent(JSONValue.self, forKey: .launch) ?? .object([:])
	}
}

/// One step: at most one command, then expectations on the response, then captures from it.
///
/// A step with no command observes the current screen. Every string in a command or an
/// expectation may use `${variable}` (captured earlier) and `${env:NAME}` (from the runner's
/// environment) — credentials belong in the environment, never in a scenario file. In a `matches`
/// pattern a substituted value is matched literally, never as regex syntax.
public struct Step: Codable, Sendable, Equatable {

	public let name: String?
	public let on: String?
	public let goto: Route?
	public let perform: Perform?
	public let wait: Wait?
	/// Quit the installation and launch it again with the same data, as a user reopening the app.
	public let relaunch: Bool
	public let expect: [Expectation]
	/// Variable name → JSON pointer into this step's response document.
	public let capture: [String: String]
	/// Teardown only: a failure is reported as a warning instead of failing the run.
	///
	/// For cleanup that must be attempted from wherever a failed run stopped, where the same step
	/// has nothing to do after a successful one — signing out, say, when the steps already did.
	public let bestEffort: Bool

	public init(
		name: String? = nil,
		on: String? = nil,
		goto: Route? = nil,
		perform: Perform? = nil,
		wait: Wait? = nil,
		relaunch: Bool = false,
		expect: [Expectation] = [],
		capture: [String: String] = [:],
		bestEffort: Bool = false
	) {
		self.name = name
		self.on = on
		self.goto = goto
		self.perform = perform
		self.wait = wait
		self.relaunch = relaunch
		self.expect = expect
		self.capture = capture
		self.bestEffort = bestEffort
	}

	var actionCount: Int {
		[goto != nil, perform != nil, wait != nil, relaunch].filter { $0 }.count
	}

	private enum CodingKeys: String, CodingKey, CaseIterable {
		case name, on, goto, perform, wait, relaunch, expect, capture, bestEffort
	}

	public init(from decoder: Decoder) throws {
		try StrictKeys.check(decoder, allowed: CodingKeys.allCases)
		let container = try decoder.container(keyedBy: CodingKeys.self)
		name = try container.decodeIfPresent(String.self, forKey: .name)
		on = try container.decodeIfPresent(String.self, forKey: .on)
		goto = try container.decodeIfPresent(Route.self, forKey: .goto)
		perform = try container.decodeIfPresent(Perform.self, forKey: .perform)
		wait = try container.decodeIfPresent(Wait.self, forKey: .wait)
		relaunch = try container.decodeIfPresent(Bool.self, forKey: .relaunch) ?? false
		expect = try container.decodeIfPresent([Expectation].self, forKey: .expect) ?? []
		capture = try container.decodeIfPresent([String: String].self, forKey: .capture) ?? [:]
		bestEffort = try container.decodeIfPresent(Bool.self, forKey: .bestEffort) ?? false
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encodeIfPresent(name, forKey: .name)
		try container.encodeIfPresent(on, forKey: .on)
		try container.encodeIfPresent(goto, forKey: .goto)
		try container.encodeIfPresent(perform, forKey: .perform)
		try container.encodeIfPresent(wait, forKey: .wait)
		if relaunch { try container.encode(true, forKey: .relaunch) }
		if expect.isEmpty == false { try container.encode(expect, forKey: .expect) }
		if capture.isEmpty == false { try container.encode(capture, forKey: .capture) }
		if bestEffort { try container.encode(true, forKey: .bestEffort) }
	}
}

public struct Perform: Codable, Sendable, Equatable {

	public let action: String
	public let arguments: [String: JSONValue]

	public init(action: String, arguments: [String: JSONValue] = [:]) {
		self.action = action
		self.arguments = arguments
	}

	private enum CodingKeys: String, CodingKey, CaseIterable {
		case action, arguments
	}

	public init(from decoder: Decoder) throws {
		try StrictKeys.check(decoder, allowed: CodingKeys.allCases)
		let container = try decoder.container(keyedBy: CodingKeys.self)
		action = try container.decode(String.self, forKey: .action)
		arguments = try container.decodeIfPresent([String: JSONValue].self, forKey: .arguments) ?? [:]
	}
}

public struct Wait: Codable, Sendable, Equatable {

	public let condition: String
	public let arguments: [String: JSONValue]
	/// Seconds; `nil` uses the app's default.
	public let timeout: Double?

	public init(condition: String, arguments: [String: JSONValue] = [:], timeout: Double? = nil) {
		self.condition = condition
		self.arguments = arguments
		self.timeout = timeout
	}

	private enum CodingKeys: String, CodingKey, CaseIterable {
		case condition, arguments, timeout
	}

	public init(from decoder: Decoder) throws {
		try StrictKeys.check(decoder, allowed: CodingKeys.allCases)
		let container = try decoder.container(keyedBy: CodingKeys.self)
		condition = try container.decode(String.self, forKey: .condition)
		arguments = try container.decodeIfPresent([String: JSONValue].self, forKey: .arguments) ?? [:]
		timeout = try container.decodeIfPresent(Double.self, forKey: .timeout)
	}
}

/// What must hold for the step's response. Pointers address the response document
/// (`/route`, `/state/…`, `/context/…`, `/result/…`, `/error/code`).
public enum Expectation: Codable, Sendable, Equatable {
	/// `{"route": "drawer"}`
	case route(Route)
	/// `{"equals": {"pointer": "/state/count", "value": 3}}`
	case equals(pointer: String, value: JSONValue)
	/// `{"exists": "/state/models/0"}`
	case exists(pointer: String)
	/// `{"absent": "/state/error"}`
	case absent(pointer: String)
	/// `{"matches": {"pointer": "/state/name", "regex": "^Hrouda"}}` — the value must be a string.
	case matches(pointer: String, regex: String)
	/// `{"error": "unreachable"}` — the command must fail with this code. Without it, any error
	/// response fails the step.
	case error(HeadlessError.Code)

	private enum CodingKeys: String, CodingKey, CaseIterable {
		case route, equals, exists, absent, matches, error
	}

	private struct PointerValue: Codable {
		let pointer: String
		let value: JSONValue

		private enum CodingKeys: String, CodingKey, CaseIterable {
			case pointer, value
		}

		init(pointer: String, value: JSONValue) {
			self.pointer = pointer
			self.value = value
		}

		init(from decoder: Decoder) throws {
			try StrictKeys.check(decoder, allowed: CodingKeys.allCases)
			let container = try decoder.container(keyedBy: CodingKeys.self)
			pointer = try container.decode(String.self, forKey: .pointer)
			value = try container.decode(JSONValue.self, forKey: .value)
		}
	}

	private struct PointerRegex: Codable {
		let pointer: String
		let regex: String

		private enum CodingKeys: String, CodingKey, CaseIterable {
			case pointer, regex
		}

		init(pointer: String, regex: String) {
			self.pointer = pointer
			self.regex = regex
		}

		init(from decoder: Decoder) throws {
			try StrictKeys.check(decoder, allowed: CodingKeys.allCases)
			let container = try decoder.container(keyedBy: CodingKeys.self)
			pointer = try container.decode(String.self, forKey: .pointer)
			regex = try container.decode(String.self, forKey: .regex)
		}
	}

	public init(from decoder: Decoder) throws {
		try StrictKeys.check(decoder, allowed: CodingKeys.allCases)
		let container = try decoder.container(keyedBy: CodingKeys.self)
		guard container.allKeys.count == 1, let key = container.allKeys.first else {
			throw DecodingError.dataCorrupted(.init(
				codingPath: decoder.codingPath,
				debugDescription: "An expectation has exactly one of: \(CodingKeys.allCases.map(\.rawValue).joined(separator: ", "))"
			))
		}
		switch key {
		case .route:
			self = .route(try container.decode(Route.self, forKey: .route))
		case .equals:
			let body = try container.decode(PointerValue.self, forKey: .equals)
			self = .equals(pointer: body.pointer, value: body.value)
		case .exists:
			self = .exists(pointer: try container.decode(String.self, forKey: .exists))
		case .absent:
			self = .absent(pointer: try container.decode(String.self, forKey: .absent))
		case .matches:
			let body = try container.decode(PointerRegex.self, forKey: .matches)
			self = .matches(pointer: body.pointer, regex: body.regex)
		case .error:
			self = .error(try container.decode(HeadlessError.Code.self, forKey: .error))
		}
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		switch self {
		case .route(let route):
			try container.encode(route, forKey: .route)
		case .equals(let pointer, let value):
			try container.encode(PointerValue(pointer: pointer, value: value), forKey: .equals)
		case .exists(let pointer):
			try container.encode(pointer, forKey: .exists)
		case .absent(let pointer):
			try container.encode(pointer, forKey: .absent)
		case .matches(let pointer, let regex):
			try container.encode(PointerRegex(pointer: pointer, regex: regex), forKey: .matches)
		case .error(let code):
			try container.encode(code, forKey: .error)
		}
	}
}

/// A scenario that cannot be run as written.
public struct ScenarioError: Error, Hashable, Sendable, CustomStringConvertible {
	public let message: String

	public init(_ message: String) {
		self.message = message
	}

	public var description: String { message }
}

/// Rejects keys a type does not declare.
enum StrictKeys {

	private struct AnyKey: CodingKey {
		let stringValue: String
		let intValue: Int? = nil
		init(stringValue: String) { self.stringValue = stringValue }
		init?(intValue: Int) { nil }
	}

	static func check<Key: CodingKey & RawRepresentable>(_ decoder: Decoder, allowed: [Key]) throws where Key.RawValue == String {
		let container = try decoder.container(keyedBy: AnyKey.self)
		let known = Set(allowed.map(\.rawValue))
		let unknown = container.allKeys.map(\.stringValue).filter { known.contains($0) == false }.sorted()
		guard unknown.isEmpty else {
			throw DecodingError.dataCorrupted(.init(
				codingPath: decoder.codingPath,
				debugDescription: "Unknown key(s) \(unknown.joined(separator: ", ")); expected \(known.sorted().joined(separator: ", "))"
			))
		}
	}
}
