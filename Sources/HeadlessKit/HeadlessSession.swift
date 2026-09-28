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
	/// Whether an action may also land one move on the app's own past what it declares (AIA-0994).
	public let appMoves: AppMoves

	/// The last command accepted, which the next one waits for.
	///
	/// Commands are serialized because an action's handler suspends while its effect completes. Two
	/// interleaved commands would each see — and report — the other's half-finished state. The
	/// transport admits one controlling client at a time (AIA-0992); a client that has just given up
	/// the slot may still have a command running here, and the next client's commands wait behind it.
	private var tail: Task<Void, Never>?

	public init(
		application: any HeadlessApplication,
		defaultWaitTimeout: Duration = .seconds(30),
		pollInterval: Duration = .milliseconds(50),
		appMoves: AppMoves = .oneHop
	) {
		self.application = application
		self.defaultWaitTimeout = defaultWaitTimeout
		self.pollInterval = pollInterval
		self.appMoves = appMoves
	}

	/// The handshake reply for this app.
	public var serverHello: ServerHello {
		let map = application.navigationMap
		return ServerHello(metadata: application.metadata, routes: map.isEmpty ? nil : map.routeNames)
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
		case .map:
			return map()
		case .perform(let name, let raw):
			let screen = application.currentScreen()
			guard let action = screen.actions().first(where: { $0.spec.name == name }) else {
				throw HeadlessError(
					.unknownAction,
					"'\(name)' is not available on '\(screen.route)' (available: \(Self.names(screen.actions())))"
				)
			}
			let arguments = try Arguments.validated(raw, against: action.spec.parameters, subject: "'\(name)'")
			return try await perform(action, on: screen.route, arguments: arguments)
		case .goto(let route):
			return try await goto(route)
		case .wait(let name, let raw, let timeout):
			try await wait(for: name, raw: raw, timeout: timeout)
			return nil
		}
	}

	private func goto(_ route: Route) async throws -> JSONValue? {
		try requireDeclared(route)
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
		return try await perform(transition, on: screen.route, arguments: Arguments())
	}

	/// Runs an action and holds it to where it declares it leads (AIA-0994; `AcceptedLandings`).
	///
	/// Landing anywhere else means the adapter and the app disagree about navigation — exactly the
	/// drift this layer exists to expose — so it fails with `undeclaredTransition` instead of reporting
	/// success. A handler that throws is not checked: its own failure is the answer.
	private func perform(_ action: HeadlessAction, on origin: Route, arguments: Arguments) async throws -> JSONValue? {
		let result = try await action.handler(arguments)
		let map = application.navigationMap
		guard let landings = AcceptedLandings(action: action.spec, origin: origin, map: map, appMoves: appMoves) else {
			return result
		}
		let arrived = application.currentScreen().route
		guard landings.accepted.contains(arrived) else {
			throw HeadlessError(.undeclaredTransition, Self.undeclared(
				action.spec.name, from: origin, landedOn: arrived, landings: landings, map: map, appMoves: appMoves
			))
		}
		return result
	}

	/// `'close' on 'drawer' landed on 'drawer'; declared: home; accepted after the app's own moves: paywall, consent`
	static func undeclared(
		_ action: String,
		from origin: Route,
		landedOn arrived: Route,
		landings: AcceptedLandings,
		map: NavigationMap,
		appMoves: AppMoves
	) -> String {
		let declared = landings.staysOn.map { "none (stays on '\($0)')" }
			?? landings.declared.map(\.rawValue).joined(separator: ", ")
		let moves: String
		if map.isEmpty {
			moves = "none (no navigation map)"
		} else if appMoves == .off {
			moves = "none (app moves off)"
		} else {
			moves = landings.appMoves.isEmpty ? "none" : landings.appMoves.map(\.rawValue).joined(separator: ", ")
		}
		return "'\(action)' on '\(origin)' landed on '\(arrived)'; declared: \(declared); accepted after the app's own moves: \(moves)"
	}

	private func wait(for name: String, raw: [String: JSONValue], timeout seconds: Double?) async throws {
		let timeout = try Self.timeout(seconds, default: defaultWaitTimeout)
		let predicate: WaitCondition.Predicate
		let arguments: Arguments
		if name == Self.routeCondition {
			arguments = try Arguments.validated(raw, against: [Self.routeParameter], subject: "condition 'route'")
			let target = Route(try arguments.string("route"))
			// Rejected before polling: a misspelt route would otherwise wait out the whole timeout.
			try requireDeclared(target)
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
				"map",
				"perform <action> [name=value …]",
				"goto <route>",
				"wait <condition> [name=value …] [timeout=<seconds>]"
			],
			"conditions": conditionsValue ?? .array([])
		]
	}

	/// The declared routes and transitions, marked against the current screen.
	///
	/// A declared transition is possible under its condition; only `open` (offered now, leading
	/// there) and `available` (offered now, destination decided when it runs) describe the present.
	/// `undeclared` lists the current screen's transitions the map lacks — drift in the declaration.
	/// An app that declares no map has no declaration to drift from, so it lists none.
	private func map() -> JSONValue {
		let map = application.navigationMap
		let screen = application.currentScreen()
		let live = screen.actions().map(\.spec)
		let routes: [JSONValue] = map.routes.map { declaration in
			let isCurrent = declaration.route == screen.route
			let transitions: [JSONValue] = declaration.transitions.map { transition in
				var entry: [String: JSONValue] = [
					"to": .string(transition.to.rawValue),
					"condition": .string(transition.condition)
				]
				if let action = transition.action {
					entry["action"] = .string(action)
					if isCurrent, let offered = live.first(where: { $0.name == action }) {
						if offered.navigatesTo == transition.to {
							entry["open"] = true
						} else if offered.navigatesTo == nil {
							entry["available"] = true
						}
					}
				}
				return .object(entry)
			}
			return [
				"route": .string(declaration.route.rawValue),
				"summary": .string(declaration.summary),
				"current": .bool(isCurrent),
				"transitions": .array(transitions)
			]
		}
		let undeclared: [JSONValue] = map.isEmpty ? [] : live.compactMap { spec in
			guard let target = spec.navigatesTo,
				  map.declares(action: spec.name, from: screen.route, to: target) == false else { return nil }
			return ["action": .string(spec.name), "to": .string(target.rawValue)]
		}
		return [
			"guarantee": "possible",
			"note": "A declared transition can happen when its condition holds; only 'open' and 'available' describe what the current screen offers now.",
			"current": .string(screen.route.rawValue),
			"routes": .array(routes),
			"undeclared": .array(undeclared)
		]
	}

	// MARK: - Helpers

	/// Rejects a route the app's navigation map does not declare. An app that declares no map
	/// accepts any route, as before maps existed.
	private func requireDeclared(_ route: Route) throws {
		let map = application.navigationMap
		guard map.isEmpty == false, map.routeNames.contains(route) == false else { return }
		throw HeadlessError(.invalidArgument, map.unknownRouteMessage(route.rawValue))
	}

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
