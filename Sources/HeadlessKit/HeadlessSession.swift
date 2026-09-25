//
//  HeadlessSession.swift
//  HeadlessKit
//
//  AIA-0970.
//

import Foundation

/// Executes commands against a `HeadlessApplication`, one at a time.
///
/// Transport-independent: a socket server, an in-process test driver and anything else feed it
/// `Request`s and send back the `Response`s it returns.
@MainActor
public final class HeadlessSession {

	/// The built-in condition every app has: `wait route route=<name>`.
	public nonisolated static let routeCondition = "route"
	/// An upper bound on any single wait, so a typo in a scenario cannot hang a run for hours.
	public nonisolated static let maximumWaitTimeout: Duration = .seconds(600)

	public let application: any HeadlessApplication
	public let defaultWaitTimeout: Duration
	public let pollInterval: Duration

	/// The last command accepted, which the next one waits for.
	///
	/// Commands are serialized because an action's handler suspends while its effect completes. Two
	/// interleaved commands would each see — and report — the other's half-finished state, and two
	/// clients (a scenario and an agent) could otherwise drive the same app at once.
	private var tail: Task<Void, Never>?

	public init(
		application: any HeadlessApplication,
		defaultWaitTimeout: Duration = .seconds(30),
		pollInterval: Duration = .milliseconds(50)
	) {
		self.application = application
		self.defaultWaitTimeout = defaultWaitTimeout
		self.pollInterval = pollInterval
	}

	/// The handshake reply for this app.
	public var serverHello: ServerHello {
		ServerHello(metadata: application.metadata)
	}

	/// Runs `request` after every earlier request has finished, and describes the app afterwards.
	public func handle(_ request: Request) async -> Response {
		let previous = tail
		let current = Task { @MainActor in
			await previous?.value
			return await self.execute(request)
		}
		tail = Task { _ = await current.value }
		return await current.value
	}

	/// A failure response that still carries the current screen — for a request the transport could
	/// not even decode.
	public func reject(id: String, error: HeadlessError) -> Response {
		snapshot(id: id, result: nil, error: error)
	}

	// MARK: - Execution

	private func execute(_ request: Request) async -> Response {
		do {
			let result = try await run(request.command)
			return snapshot(id: request.id, result: result, error: nil)
		} catch let error as HeadlessError {
			return snapshot(id: request.id, result: nil, error: error)
		} catch {
			return snapshot(id: request.id, result: nil, error: HeadlessError(.actionFailed, String(describing: error)))
		}
	}

	private func run(_ command: Command) async throws -> JSONValue? {
		switch command {
		case .state, .actions:
			return nil
		case .help:
			return help()
		case .perform(let name, let raw):
			let screen = application.currentScreen()
			guard let action = screen.actions().first(where: { $0.spec.name == name }) else {
				throw HeadlessError(
					.unknownAction,
					"'\(name)' is not available on '\(screen.route)' (available: \(Self.names(screen.actions())))"
				)
			}
			let arguments = try Arguments.validated(raw, against: action.spec.parameters, subject: "'\(name)'")
			return try await perform(action, arguments: arguments)
		case .goto(let route):
			return try await goto(route)
		case .wait(let name, let raw, let timeout):
			try await wait(for: name, raw: raw, timeout: timeout)
			return nil
		}
	}

	private func goto(_ route: Route) async throws -> JSONValue? {
		let screen = application.currentScreen()
		guard screen.route != route else { return nil }
		let transitions = screen.actions().filter { $0.spec.navigatesTo == route }
		guard transitions.count == 1, let transition = transitions.first else {
			let reason = transitions.isEmpty
				? "no action on '\(screen.route)' leads there"
				: "several actions on '\(screen.route)' lead there (\(Self.names(transitions))); use perform"
			throw HeadlessError(.unreachable, "Cannot go to '\(route)': \(reason)")
		}
		guard transition.spec.parameters.allSatisfy({ $0.isRequired == false }) else {
			throw HeadlessError(
				.unreachable,
				"Cannot go to '\(route)': '\(transition.spec.name)' needs arguments; use perform"
			)
		}
		return try await perform(transition, arguments: Arguments())
	}

	/// Runs an action and holds a declared transition to its word.
	private func perform(_ action: HeadlessAction, arguments: Arguments) async throws -> JSONValue? {
		let result = try await action.handler(arguments)
		// A transition that did not arrive means the adapter and the app disagree about navigation —
		// exactly the drift this layer exists to expose, so it fails instead of reporting success.
		if let target = action.spec.navigatesTo {
			let arrived = application.currentScreen().route
			guard arrived == target else {
				throw HeadlessError(
					.actionFailed,
					"'\(action.spec.name)' declares a transition to '\(target)' but the app shows '\(arrived)'"
				)
			}
		}
		return result
	}

	private func wait(for name: String, raw: [String: JSONValue], timeout seconds: Double?) async throws {
		let timeout = try Self.timeout(seconds, default: defaultWaitTimeout)
		let predicate: WaitCondition.Predicate
		let arguments: Arguments
		if name == Self.routeCondition {
			arguments = try Arguments.validated(raw, against: [Self.routeParameter], subject: "condition 'route'")
			let target = Route(try arguments.string("route"))
			predicate = { [application] _ in application.currentScreen().route == target }
		} else {
			let conditions = application.waitConditions()
			guard let condition = conditions.first(where: { $0.spec.name == name }) else {
				let known = ([Self.routeCondition] + conditions.map(\.spec.name)).joined(separator: ", ")
				throw HeadlessError(.unknownCondition, "Unknown condition '\(name)' (known: \(known))")
			}
			arguments = try Arguments.validated(raw, against: condition.spec.parameters, subject: "condition '\(name)'")
			predicate = condition.isSatisfied
		}
		let satisfied = try await HeadlessWait.until(timeout: timeout, pollInterval: pollInterval) {
			try predicate(arguments)
		}
		guard satisfied else {
			throw HeadlessError(.timeout, "Condition '\(name)' did not hold within \(timeout)")
		}
	}

	// MARK: - Describing the app

	private func snapshot(id: String, result: JSONValue?, error: HeadlessError?) -> Response {
		let screen = application.currentScreen()
		return Response(
			id: id,
			route: screen.route,
			state: screen.state(),
			actions: screen.actions().map(\.spec),
			context: application.context(),
			result: result,
			error: error
		)
	}

	private func help() -> JSONValue {
		let encoder = HeadlessCoding.makeEncoder()
		let decoder = HeadlessCoding.makeDecoder()
		let conditions = [WaitConditionSpec(
			name: Self.routeCondition,
			summary: "The app shows the given route.",
			parameters: [Self.routeParameter]
		)] + application.waitConditions().map(\.spec)
		let conditionsValue = (try? encoder.encode(conditions)).flatMap { try? decoder.decode(JSONValue.self, from: $0) }
		return [
			"protocolVersion": .number(Double(HeadlessProtocol.version)),
			"commands": [
				"help",
				"state",
				"actions",
				"perform <action> [name=value …]",
				"goto <route>",
				"wait <condition> [name=value …] [timeout=<seconds>]"
			],
			"conditions": conditionsValue ?? .array([])
		]
	}

	// MARK: - Helpers

	private static let routeParameter = ParameterSpec("route", .string, summary: "The route to wait for.")

	private static func names(_ actions: [HeadlessAction]) -> String {
		let names = actions.map(\.spec.name)
		return names.isEmpty ? "none" : names.joined(separator: ", ")
	}

	private static func timeout(_ seconds: Double?, default fallback: Duration) throws -> Duration {
		guard let seconds else { return fallback }
		guard seconds.isFinite, seconds > 0 else {
			throw HeadlessError(.invalidArgument, "timeout must be a positive number of seconds")
		}
		// Compared in seconds, before any integer conversion: `Int64(1e30 * 1000)` traps, and a
		// client must not be able to crash the app by sending a large number.
		guard seconds <= Double(maximumWaitTimeout.components.seconds) else {
			throw HeadlessError(.invalidArgument, "timeout must not exceed \(maximumWaitTimeout)")
		}
		return .milliseconds(Int64((seconds * 1000).rounded(.up)))
	}
}
