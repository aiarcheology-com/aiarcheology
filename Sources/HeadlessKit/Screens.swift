//
//  Screens.swift
//  HeadlessKit
//
//  AIA-0970.
//

import Foundation

/// A screen's identity, e.g. `home` or `settings.account`.
public struct Route: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral,
	CustomStringConvertible {

	public let rawValue: String

	public init(rawValue: String) {
		self.rawValue = rawValue
	}

	public init(_ rawValue: String) {
		self.rawValue = rawValue
	}

	public init(stringLiteral value: String) {
		self.rawValue = value
	}

	public var description: String { rawValue }
}

/// One parameter of an action or a wait condition.
public struct ParameterSpec: Codable, Hashable, Sendable {

	public enum Kind: String, Codable, Hashable, Sendable {
		case string
		case integer
		case number
		case boolean
	}

	public let name: String
	public let kind: Kind
	public let isRequired: Bool
	public let summary: String

	public init(_ name: String, _ kind: Kind, required isRequired: Bool = true, summary: String = "") {
		self.name = name
		self.kind = kind
		self.isRequired = isRequired
		self.summary = summary
	}

	private enum CodingKeys: String, CodingKey {
		case name
		case kind = "type"
		case isRequired = "required"
		case summary
	}
}

/// What a client sees of an action: enough to decide to call it, never how it works.
public struct ActionSpec: Codable, Hashable, Sendable {

	public let name: String
	public let summary: String
	public let parameters: [ParameterSpec]
	/// The route the app shows once the action succeeds, when the action is a transition.
	///
	/// This is what makes `goto` honest: it can only ever take a transition the current screen
	/// offers, so a client cannot reach a screen a user could not have reached from here.
	public let navigatesTo: Route?

	public init(name: String, summary: String, parameters: [ParameterSpec] = [], navigatesTo: Route? = nil) {
		self.name = name
		self.summary = summary
		self.parameters = parameters
		self.navigatesTo = navigatesTo
	}
}

/// A user action the current screen offers, with the code that performs it.
///
/// The handler must call the same model methods the UI calls for this action; the package cannot
/// check that, the adopter's review can. It returns once the action's own effect has completed —
/// awaiting a readiness signal, never a duration — so the state in the response is the state
/// after the action, not a guess at it.
public struct HeadlessAction: Sendable {

	public typealias Handler = @MainActor @Sendable (Arguments) async throws -> JSONValue?

	public let spec: ActionSpec
	public let handler: Handler

	public init(
		_ name: String,
		summary: String,
		parameters: [ParameterSpec] = [],
		navigatesTo: Route? = nil,
		handler: @escaping Handler
	) {
		self.spec = ActionSpec(name: name, summary: summary, parameters: parameters, navigatesTo: navigatesTo)
		self.handler = handler
	}
}

/// What a client sees of a wait condition.
public struct WaitConditionSpec: Codable, Hashable, Sendable {
	public let name: String
	public let summary: String
	public let parameters: [ParameterSpec]
}

/// A named state a client can wait for, such as "the model finished loading".
///
/// Waiting is always on a condition the app defines, with a timeout only as an upper bound — a
/// test that sleeps for a duration encodes a guess about timing and fails on a slow machine.
public struct WaitCondition: Sendable {

	public typealias Predicate = @MainActor @Sendable (Arguments) throws -> Bool

	public let spec: WaitConditionSpec
	public let isSatisfied: Predicate

	public init(_ name: String, summary: String, parameters: [ParameterSpec] = [], isSatisfied: @escaping Predicate) {
		self.spec = WaitConditionSpec(name: name, summary: summary, parameters: parameters)
		self.isSatisfied = isSatisfied
	}
}

/// A screen of the app as a headless client sees it.
@MainActor
public protocol HeadlessScreen {
	var route: Route { get }
	/// The screen's content, redacted of anything that must not leave the app (images, secrets),
	/// with a stable shape so scenarios can address it by JSON pointer.
	func state() -> JSONValue
	/// The actions a user could take here **right now**. Context-sensitive: an action that the UI
	/// would disable is absent, not present-and-failing.
	func actions() -> [HeadlessAction]
}

extension HeadlessScreen {
	public func state() -> JSONValue { .object([:]) }
}

/// The adopter's app, as the session drives it.
@MainActor
public protocol HeadlessApplication: AnyObject {
	/// Facts about this process, sent once in the handshake — build, environment, launch options.
	var metadata: [String: JSONValue] { get }
	/// The screen the app shows now, **derived from the app's own state** on every call. Keeping a
	/// separate navigation stack here would let the headless view of the app drift from the app.
	func currentScreen() -> any HeadlessScreen
	/// App-wide state that belongs to no single screen, returned with every response.
	func context() -> JSONValue
	/// The conditions `wait` accepts, in addition to the built-in `route` condition.
	func waitConditions() -> [WaitCondition]
}

extension HeadlessApplication {
	public var metadata: [String: JSONValue] { [:] }
	public func context() -> JSONValue { .object([:]) }
	public func waitConditions() -> [WaitCondition] { [] }
}
