//
//  ScenarioRunner.swift
//  HeadlessScenario
//
//  AIA-0970.
//

import Foundation
import HeadlessKit

/// Starts and stops installations of the adopter's app. The runner knows nothing about simulators,
/// processes or builds; this is where an adopter puts that knowledge.
public protocol InstallationLauncher: Sendable {
	/// Launches `installation` with its scenario `options` and returns a connected driver. A fresh
	/// run gets a fresh installation; a relaunch keeps its data.
	func launch(installation: String, options: JSONValue, relaunch: Bool) async throws -> any HeadlessDriving
	/// Quits the running app of `installation`, keeping its data.
	func terminate(installation: String) async throws
}

/// Runs scenarios: launches the installations, performs the steps in order, stops at the first
/// failure, always runs the teardown, always terminates what it launched.
public struct ScenarioRunner: Sendable {

	public let launcher: any InstallationLauncher
	public let environment: [String: String]

	public init(launcher: any InstallationLauncher, environment: [String: String] = ProcessInfo.processInfo.environment) {
		self.launcher = launcher
		self.environment = environment
	}

	public func run(_ scenario: Scenario) async -> ScenarioReport {
		let clock = ContinuousClock()
		let started = clock.now
		var run = Run(scenario: scenario)
		do {
			try scenario.validate()
		} catch {
			return run.report(setupFailure: "\(error)", duration: clock.now - started)
		}

		var setupFailure: String?
		for name in scenario.installations.keys.sorted() {
			do {
				let driver = try await launcher.launch(
					installation: name,
					options: scenario.installations[name]?.launch ?? .object([:]),
					relaunch: false
				)
				run.drivers[name] = driver
				run.declaredRoutes[name] = await driver.declaredRoutes()
			} catch {
				setupFailure = "launching '\(name)' failed: \(error)"
				break
			}
		}
		// Every route the scenario names is checked against what its installation declares before
		// any step is sent: a typo then fails at once, not after the steps before it and a timeout.
		// An installation that declares no routes is not checked, as before declarations existed.
		if setupFailure == nil {
			let undeclared = RouteCheck.failures(in: scenario, declared: run.declaredRoutes)
			if undeclared.isEmpty == false {
				setupFailure = "the scenario names routes the app does not declare:\n" + undeclared.joined(separator: "\n")
			}
		}

		if setupFailure == nil {
			for (index, step) in scenario.steps.enumerated() {
				let report = await execute(step, index: index, phase: "steps", run: &run)
				run.steps.append(report)
				if report.passed == false { break }
			}
		}
		// Teardown runs even after a failure — that is its purpose — and continues past its own
		// failures, so one broken cleanup does not leave the rest undone. A `bestEffort` step's
		// failure is reported as a warning rather than failing the run.
		for (index, step) in scenario.teardown.enumerated() {
			let installation = try? scenario.installation(for: step, label: "")
			if let installation, run.drivers[installation] == nil { continue }
			run.teardown.append(await execute(step, index: index, phase: "teardown", run: &run))
		}
		for name in run.drivers.keys.sorted() {
			do {
				try await launcher.terminate(installation: name)
			} catch {
				run.teardown.append(StepReport(
					phase: "teardown",
					index: run.teardown.count,
					name: "terminate",
					installation: name,
					command: "terminate",
					route: nil,
					failures: ["terminating '\(name)' failed: \(error)"]
				))
			}
		}
		return run.report(setupFailure: setupFailure, duration: clock.now - started)
	}

	// MARK: - Steps

	private func execute(_ step: Step, index: Int, phase: String, run: inout Run) async -> StepReport {
		let label = "\(phase)[\(index)]"
		var failures: [String] = []
		var response: Response?
		var installationName: String?
		let command = Self.commandName(step)
		do {
			let installation = try run.scenario.installation(for: step, label: label)
			installationName = installation
			if step.relaunch {
				try await launcher.terminate(installation: installation)
				run.drivers[installation] = nil
				run.declaredRoutes[installation] = nil
				let relaunched = try await launcher.launch(
					installation: installation,
					options: run.scenario.installations[installation]?.launch ?? .object([:]),
					relaunch: true
				)
				run.drivers[installation] = relaunched
				// The new process may be a different build: its own handshake decides.
				run.declaredRoutes[installation] = await relaunched.declaredRoutes()
			}
			guard let driver = run.drivers[installation] else {
				throw ScenarioError("\(label): '\(installation)' is not running")
			}
			let substitution = Substitution(variables: run.variables, environment: environment)
			let command = try Self.command(for: step, substitution: substitution)
			// Resolved values — `${…}` included — are checked here, before anything is sent. An
			// `expect route` is compared locally and would otherwise never reach the app's check.
			let undeclared = try Self.undeclaredRoutes(
				in: step,
				phase: phase,
				index: index,
				known: run.declaredRoutes[installation],
				substitution: substitution
			)
			guard undeclared.isEmpty else { throw UndeclaredRoutes(failures: undeclared) }
			let sent = try await driver.send(command)
			response = sent
			failures = try Self.check(step.expect, against: sent, substitution: substitution)
			if failures.isEmpty {
				let document = sent.document
				for (variable, pointer) in step.capture.sorted(by: { $0.key < $1.key }) {
					guard let value = document.value(at: pointer) else {
						failures.append("capture '\(variable)': nothing at \(pointer)")
						continue
					}
					run.variables[variable] = value
				}
			}
		} catch let error as UndeclaredRoutes {
			failures.append(contentsOf: error.failures)
		} catch {
			failures.append("\(error)")
		}
		return StepReport(
			phase: phase,
			index: index,
			name: step.name,
			installation: installationName,
			command: command,
			route: response?.route,
			failures: failures,
			response: failures.isEmpty ? nil : response?.document,
			bestEffort: step.bestEffort
		)
	}

	private static func commandName(_ step: Step) -> String {
		if step.goto != nil { return "goto" }
		if step.perform != nil { return "perform" }
		if step.wait != nil { return "wait" }
		if step.relaunch { return "relaunch" }
		return "state"
	}

	private static func command(for step: Step, substitution: Substitution) throws -> Command {
		if let route = step.goto {
			return .goto(Route(try substitution.apply(to: route.rawValue)))
		}
		if let perform = step.perform {
			return .perform(
				action: try substitution.apply(to: perform.action),
				arguments: try substitution.apply(to: perform.arguments)
			)
		}
		if let wait = step.wait {
			return .wait(
				condition: try substitution.apply(to: wait.condition),
				arguments: try substitution.apply(to: wait.arguments),
				timeout: wait.timeout
			)
		}
		// A relaunch or a bare observation: report the screen as it now is.
		return .state
	}

	/// The routes `step` names — `RouteCheck`'s references, each resolved as the command sending it
	/// is — that `known` does not contain; none when the installation declared no routes.
	private static func undeclaredRoutes(
		in step: Step,
		phase: String,
		index: Int,
		known: [Route]?,
		substitution: Substitution
	) throws -> [String] {
		guard let known, known.isEmpty == false else { return [] }
		let references = try RouteCheck.references(in: step, phase: phase, index: index) { try substitution.apply(to: $0) }
		return try references.compactMap { reference in
			let resolved: String?
			switch reference.kind {
			case .goto, .expect:
				resolved = try substitution.apply(to: reference.route)
			case .wait:
				// As the command's arguments are resolved: a whole `${name}` keeps its captured type,
				// and a route that is not a string is left to the app to reject.
				resolved = try substitution.apply(to: JSONValue.string(reference.route)).stringValue
			}
			return resolved.flatMap { RouteCheck.problem(kind: reference.kind, route: $0, known: known) }
		}
	}

	/// Every failed expectation, not just the first: one run shows everything that is wrong.
	private static func check(_ expectations: [Expectation], against response: Response, substitution: Substitution) throws -> [String] {
		let document = response.document
		var failures: [String] = []
		let expectsError = expectations.contains { if case .error = $0 { true } else { false } }
		if let error = response.error, expectsError == false {
			failures.append("the app answered with an error: \(error)")
			return failures
		}
		for expectation in expectations {
			if let failure = try failure(of: expectation, response: response, document: document, substitution: substitution) {
				failures.append(failure)
			}
		}
		return failures
	}

	/// Why `expectation` does not hold, or `nil` when it does.
	private static func failure(
		of expectation: Expectation,
		response: Response,
		document: JSONValue,
		substitution: Substitution
	) throws -> String? {
		switch expectation {
		case .route(let route):
			let expected = Route(try substitution.apply(to: route.rawValue))
			return response.route == expected ? nil : "expected route '\(expected)', got '\(response.route)'"
		case .equals(let pointer, let value):
			let expected = try substitution.apply(to: value)
			let actual = document.value(at: pointer)
			return actual == expected ? nil : "\(pointer): expected \(expected.jsonString), got \(actual?.jsonString ?? "nothing")"
		case .exists(let pointer):
			return document.value(at: pointer) == nil ? "\(pointer): expected a value, found nothing" : nil
		case .absent(let pointer):
			return document.value(at: pointer).map { "\(pointer): expected nothing, found \($0.jsonString)" }
		case .matches(let pointer, let pattern):
			let regex = try NSRegularExpression(pattern: try substitution.apply(toPattern: pattern))
			guard let text = document.value(at: pointer)?.stringValue else {
				let found = document.value(at: pointer)?.jsonString ?? "nothing"
				return "\(pointer): expected a string matching /\(pattern)/, found \(found)"
			}
			let matched = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
			return matched ? nil : "\(pointer): \(JSONValue.string(text).jsonString) does not match /\(pattern)/"
		case .error(let code):
			guard response.error?.code != code else { return nil }
			return "expected error '\(code)', got \(response.error.map { "'\($0.code)'" } ?? "success")"
		}
	}
}

/// The mutable state of one scenario run.
private struct Run {
	let scenario: Scenario
	var drivers: [String: any HeadlessDriving] = [:]
	/// The routes each running installation declared; absent when it declared none.
	var declaredRoutes: [String: [Route]] = [:]
	var variables: [String: JSONValue] = [:]
	var steps: [StepReport] = []
	var teardown: [StepReport] = []

	init(scenario: Scenario) {
		self.scenario = scenario
	}

	func report(setupFailure: String?, duration: Duration) -> ScenarioReport {
		ScenarioReport(
			scenario: scenario.name,
			setupFailure: setupFailure,
			steps: steps,
			teardown: teardown,
			completedAllSteps: setupFailure == nil && steps.count == scenario.steps.count,
			durationSeconds: Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
		)
	}
}

/// A step that names routes its installation does not declare; it is never sent.
private struct UndeclaredRoutes: Error {
	let failures: [String]
}

/// `${name}` and `${env:NAME}` in scenario strings.
struct Substitution {

	let variables: [String: JSONValue]
	let environment: [String: String]

	/// A `${…}` placeholder; group 1 is the name.
	static let placeholder: NSRegularExpression = {
		do {
			return try NSRegularExpression(pattern: #"\$\{([^}]+)\}"#)
		} catch {
			preconditionFailure("The substitution pattern is a constant: \(error)")
		}
	}()

	/// Substitutes inside every string of `value`. A string that is exactly one `${variable}`
	/// takes the variable's JSON value as is, so a captured `true` or `3` stays typed.
	func apply(to value: JSONValue) throws -> JSONValue {
		switch value {
		case .string(let text):
			if let whole = try wholeVariable(text) { return whole }
			return .string(try apply(to: text))
		case .array(let elements):
			return .array(try elements.map { try apply(to: $0) })
		case .object(let members):
			return .object(try members.mapValues { try apply(to: $0) })
		case .null, .bool, .number:
			return value
		}
	}

	func apply(to arguments: [String: JSONValue]) throws -> [String: JSONValue] {
		try arguments.mapValues { try apply(to: $0) }
	}

	func apply(to text: String) throws -> String {
		try replacingPlaceholders(in: text) { Self.text(of: $0) }
	}

	/// Substitutes into a regular expression, escaping each value so it matches literally: a
	/// captured `a.b` must match `a.b`, not `axb`.
	func apply(toPattern pattern: String) throws -> String {
		try replacingPlaceholders(in: pattern) { NSRegularExpression.escapedPattern(for: Self.text(of: $0)) }
	}

	private static func text(of value: JSONValue) -> String {
		value.stringValue ?? value.jsonString
	}

	/// Builds the result front to back from the original, so no index is used after a mutation.
	private func replacingPlaceholders(in text: String, render: (JSONValue) -> String) throws -> String {
		var result = ""
		var cursor = text.startIndex
		for match in Self.placeholder.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
			guard let whole = Range(match.range, in: text), let name = Range(match.range(at: 1), in: text) else { continue }
			result += text[cursor..<whole.lowerBound]
			result += render(try resolve(String(text[name])))
			cursor = whole.upperBound
		}
		result += text[cursor...]
		return result
	}

	private func wholeVariable(_ text: String) throws -> JSONValue? {
		let range = NSRange(text.startIndex..., in: text)
		guard let match = Self.placeholder.firstMatch(in: text, range: range), match.range == range,
			  let name = Range(match.range(at: 1), in: text) else { return nil }
		return try resolve(String(text[name]))
	}

	private func resolve(_ name: String) throws -> JSONValue {
		if name.hasPrefix("env:") {
			let key = String(name.dropFirst(4))
			guard let value = environment[key] else {
				throw ScenarioError("environment variable '\(key)' is not set")
			}
			return .string(value)
		}
		guard let value = variables[name] else {
			throw ScenarioError("variable '\(name)' was never captured")
		}
		return value
	}
}
