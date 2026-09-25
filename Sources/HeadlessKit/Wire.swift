//
//  Wire.swift
//  HeadlessKit
//
//  AIA-0970.
//

import Foundation

/// Version of the request/response protocol. Bump it only for a change an older peer would
/// misread; adding an optional field is not one.
public enum HeadlessProtocol {
	public static let version = 1
}

/// Coders every peer uses, so the same value always produces the same bytes.
public enum HeadlessCoding {

	public static func makeEncoder() -> JSONEncoder {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
		return encoder
	}

	public static func makeDecoder() -> JSONDecoder {
		JSONDecoder()
	}
}

/// A failure a client can act on, by code.
public struct HeadlessError: Error, Codable, Hashable, Sendable, CustomStringConvertible {

	/// An open set: a newer peer may send a code this build does not know, and it must still decode.
	public struct Code: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
		public let rawValue: String
		public init(rawValue: String) { self.rawValue = rawValue }
		public var description: String { rawValue }

		/// The request could not be read.
		public static let malformedRequest = Code(rawValue: "malformedRequest")
		public static let unknownCommand = Code(rawValue: "unknownCommand")
		/// The current screen offers no action of that name.
		public static let unknownAction = Code(rawValue: "unknownAction")
		public static let unknownCondition = Code(rawValue: "unknownCondition")
		/// No single transition from the current screen leads to the requested route.
		public static let unreachable = Code(rawValue: "unreachable")
		public static let invalidArgument = Code(rawValue: "invalidArgument")
		/// The action ran and failed.
		public static let actionFailed = Code(rawValue: "actionFailed")
		public static let timeout = Code(rawValue: "timeout")
		public static let unauthorized = Code(rawValue: "unauthorized")
		public static let protocolMismatch = Code(rawValue: "protocolMismatch")
	}

	public let code: Code
	public let message: String

	public init(_ code: Code, _ message: String) {
		self.code = code
		self.message = message
	}

	public var description: String { "\(code): \(message)" }
}

/// What a client asks for.
public enum Command: Sendable, Equatable {
	/// The built-in commands, the current actions and the wait conditions.
	case help
	/// The current screen, unchanged.
	case state
	/// The current screen, unchanged; kept distinct from `state` for clients that only list.
	case actions
	case perform(action: String, arguments: [String: JSONValue])
	/// Take the one transition from the current screen that leads to `route`.
	case goto(Route)
	/// Wait until a named condition holds. `timeout` is in seconds; `nil` uses the session default.
	case wait(condition: String, arguments: [String: JSONValue], timeout: Double?)

	/// The command's wire name.
	public var name: String {
		switch self {
		case .help: "help"
		case .state: "state"
		case .actions: "actions"
		case .perform: "perform"
		case .goto: "goto"
		case .wait: "wait"
		}
	}
}

/// One request: `{"id": "7", "command": "perform", "action": "enable", "arguments": {"id": "…"}}`.
///
/// Flat rather than nested so a person or an agent can type it by hand.
public struct Request: Codable, Sendable, Equatable {

	public let id: String
	public let command: Command

	public init(id: String, command: Command) {
		self.id = id
		self.command = command
	}

	private enum CodingKeys: String, CodingKey {
		case id, command, action, arguments, route, condition, timeout
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		id = try container.decode(String.self, forKey: .id)
		let name = try container.decode(String.self, forKey: .command)
		let arguments = try container.decodeIfPresent([String: JSONValue].self, forKey: .arguments) ?? [:]
		switch name {
		case "help":
			command = .help
		case "state":
			command = .state
		case "actions":
			command = .actions
		case "perform":
			command = .perform(action: try container.decode(String.self, forKey: .action), arguments: arguments)
		case "goto":
			command = .goto(try container.decode(Route.self, forKey: .route))
		case "wait":
			command = .wait(
				condition: try container.decode(String.self, forKey: .condition),
				arguments: arguments,
				timeout: try container.decodeIfPresent(Double.self, forKey: .timeout)
			)
		default:
			throw DecodingError.dataCorruptedError(
				forKey: .command,
				in: container,
				debugDescription: "Unknown command '\(name)'"
			)
		}
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(id, forKey: .id)
		try container.encode(command.name, forKey: .command)
		switch command {
		case .help, .state, .actions:
			break
		case .perform(let action, let arguments):
			try container.encode(action, forKey: .action)
			if arguments.isEmpty == false {
				try container.encode(arguments, forKey: .arguments)
			}
		case .goto(let route):
			try container.encode(route, forKey: .route)
		case .wait(let condition, let arguments, let timeout):
			try container.encode(condition, forKey: .condition)
			if arguments.isEmpty == false {
				try container.encode(arguments, forKey: .arguments)
			}
			try container.encodeIfPresent(timeout, forKey: .timeout)
		}
	}
}

/// Every response carries the whole current screen, so a client never needs a second round trip
/// to learn where an action left it — which is what lets an agent loop on "look, act, look".
public struct Response: Codable, Sendable, Equatable {

	public let id: String
	public let ok: Bool
	public let route: Route
	public let state: JSONValue
	public let actions: [ActionSpec]
	public let context: JSONValue
	public let result: JSONValue?
	public let error: HeadlessError?

	public init(
		id: String,
		route: Route,
		state: JSONValue,
		actions: [ActionSpec],
		context: JSONValue,
		result: JSONValue? = nil,
		error: HeadlessError? = nil
	) {
		self.id = id
		self.ok = error == nil
		self.route = route
		self.state = state
		self.actions = actions
		self.context = context
		self.result = result
		self.error = error
	}

	/// The response exactly as it travels, as one JSON document — so a JSON pointer written against
	/// the wire format (`/state/models/0/id`, `/error/code`) addresses the same thing here.
	public var document: JSONValue {
		do {
			let data = try HeadlessCoding.makeEncoder().encode(self)
			return try HeadlessCoding.makeDecoder().decode(JSONValue.self, from: data)
		} catch {
			// Unreachable for values this type can hold; `null` makes any pointer miss loudly
			// rather than match something stale.
			return .null
		}
	}
}

/// The first line a client sends.
public struct ClientHello: Codable, Sendable, Equatable {
	public let protocolVersion: Int
	public let token: String

	public init(protocolVersion: Int = HeadlessProtocol.version, token: String) {
		self.protocolVersion = protocolVersion
		self.token = token
	}
}

/// The server's answer to a valid `ClientHello`.
public struct ServerHello: Codable, Sendable, Equatable {
	public let protocolVersion: Int
	public let metadata: [String: JSONValue]

	public init(protocolVersion: Int = HeadlessProtocol.version, metadata: [String: JSONValue]) {
		self.protocolVersion = protocolVersion
		self.metadata = metadata
	}
}
