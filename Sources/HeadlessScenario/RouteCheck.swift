//
//  RouteCheck.swift
//  HeadlessScenario
//
//  AIA-0983.
//

import Foundation
import HeadlessKit

/// Finds the routes a scenario names that the app does not declare — before anything runs, so a
/// typo fails in a second instead of after a launch and a whole wait timeout.
public enum RouteCheck {

	/// How a step names a route.
	public enum Kind: String, Hashable, Sendable {
		/// `"goto": "home"`
		case goto
		/// `"wait": {"condition": "route", "arguments": {"route": "home"}}`
		case wait
		/// `"expect": [{"route": "home"}]`, or `{"notRoute": "home"}`
		case expect
		/// `"unless": [{"notRoute": "save-finding"}]`, or `{"route": …}`
		case unless
	}

	/// One route a step names, as written.
	public struct Reference: Hashable, Sendable {
		/// `steps[3] "wait for home"`, as a step report says where it happened.
		public let location: String
		public let kind: Kind
		public let route: String

		/// Whether the route is filled in at run time, and so can only be checked then.
		public var isPlaceholder: Bool { route.contains("${") }
	}

	/// Every route reference in the scenario's steps and teardown, in order.
	public static func references(in scenario: Scenario) -> [Reference] {
		phases(of: scenario).flatMap { phase, steps in
			steps.enumerated().flatMap { index, step in references(in: step, phase: phase, index: index) }
		}
	}

	/// One line per literal route the scenario names that is not in `known`. An empty `known` means
	/// the app declares no routes, so nothing can be checked and nothing fails.
	public static func failures(in scenario: Scenario, known: [Route]) -> [String] {
		phases(of: scenario).flatMap { phase, steps in
			steps.enumerated().flatMap { index, step in failures(in: step, phase: phase, index: index, known: known) }
		}
	}

	/// The failures of every step checked against the routes its own installation declared at its
	/// first launch. An installation missing from `declared` declared none, and its steps are not
	/// checked. Nor are an installation's steps from its first `relaunch` on, teardown included: the
	/// relaunched process may be another build, whose own handshake decides when the step runs.
	static func failures(in scenario: Scenario, declared: [String: [Route]]) -> [String] {
		var relaunched: Set<String> = []
		return phases(of: scenario).flatMap { phase, steps in
			steps.enumerated().flatMap { index, step -> [String] in
				guard let installation = try? scenario.installation(for: step, label: "") else { return [] }
				if step.relaunch {
					relaunched.insert(installation)
				}
				guard relaunched.contains(installation) == false, let known = declared[installation] else { return [] }
				return failures(in: step, phase: phase, index: index, known: known)
			}
		}
	}

	/// The failures of one step, each prefixed with its location.
	static func failures(in step: Step, phase: String, index: Int, known: [Route]) -> [String] {
		references(in: step, phase: phase, index: index).compactMap { reference in
			guard reference.isPlaceholder == false,
				  let problem = problem(kind: reference.kind, route: reference.route, known: known) else { return nil }
			return "\(reference.location): \(problem)"
		}
	}

	/// Why `route` is not acceptable, or `nil` when it is — or when `known` is empty.
	///
	/// `wait route 'hme' is not a route of this app; did you mean 'home'? (known: …)`
	static func problem(kind: Kind, route: String, known: [Route]) -> String? {
		guard known.isEmpty == false, known.contains(Route(route)) == false else { return nil }
		return "\(kind.rawValue) route '\(route)' is not a route of this app; \(NavigationMap.suggestion(for: route, known: known))"
	}

	/// The routes `step` names, its wait's condition taken as written: the static check's form.
	static func references(in step: Step, phase: String, index: Int) -> [Reference] {
		references(in: step, phase: phase, index: index) { $0 }
	}

	/// The routes `step` names, as written: the one rule both the static check and the runner's
	/// check before sending use. A wait names a route when its condition is `route` after
	/// `resolvingCondition`, which the runner uses to resolve `${…}` in it.
	static func references(
		in step: Step,
		phase: String,
		index: Int,
		resolvingCondition: (String) throws -> String
	) rethrows -> [Reference] {
		let location = StepReport.location(phase: phase, index: index, name: step.name)
		var references: [Reference] = []
		if let route = step.goto {
			references.append(Reference(location: location, kind: .goto, route: route.rawValue))
		}
		if let wait = step.wait, try resolvingCondition(wait.condition) == HeadlessSession.routeCondition,
		   let route = wait.arguments["route"]?.stringValue {
			references.append(Reference(location: location, kind: .wait, route: route))
		}
		for (kind, expectations) in [(Kind.expect, step.expect), (Kind.unless, step.unless ?? [])] {
			for route in expectations.compactMap(namedRoute) {
				references.append(Reference(location: location, kind: kind, route: route.rawValue))
			}
		}
		return references
	}

	/// The route an expectation names. Exhaustive, so a new expectation that names a route cannot be
	/// left out of the check by accident.
	static func namedRoute(_ expectation: Expectation) -> Route? {
		switch expectation {
		case .route(let route), .notRoute(let route):
			return route
		case .equals, .exists, .absent, .matches, .error:
			return nil
		}
	}

	private static func phases(of scenario: Scenario) -> [(String, [Step])] {
		[("steps", scenario.steps), ("teardown", scenario.teardown)]
	}
}
