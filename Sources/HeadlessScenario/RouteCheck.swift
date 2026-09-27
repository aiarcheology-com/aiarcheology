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
		/// `"expect": [{"route": "home"}]`
		case expect
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

	/// The failures of every step checked against the routes its own installation declared. An
	/// installation missing from `declared` declared none, and its steps are not checked.
	static func failures(in scenario: Scenario, declared: [String: [Route]]) -> [String] {
		phases(of: scenario).flatMap { phase, steps in
			steps.enumerated().flatMap { index, step -> [String] in
				guard let installation = try? scenario.installation(for: step, label: ""),
					  let known = declared[installation] else { return [] }
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

	static func references(in step: Step, phase: String, index: Int) -> [Reference] {
		let location = StepReport.location(phase: phase, index: index, name: step.name)
		var references: [Reference] = []
		if let route = step.goto {
			references.append(Reference(location: location, kind: .goto, route: route.rawValue))
		}
		if let wait = step.wait, wait.condition == HeadlessSession.routeCondition,
		   let route = wait.arguments["route"]?.stringValue {
			references.append(Reference(location: location, kind: .wait, route: route))
		}
		for expectation in step.expect {
			if case .route(let route) = expectation {
				references.append(Reference(location: location, kind: .expect, route: route.rawValue))
			}
		}
		return references
	}

	private static func phases(of scenario: Scenario) -> [(String, [Step])] {
		[("steps", scenario.steps), ("teardown", scenario.teardown)]
	}
}
