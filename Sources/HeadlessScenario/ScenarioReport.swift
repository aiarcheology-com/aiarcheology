//
//  ScenarioReport.swift
//  HeadlessScenario
//
//  AIA-0970.
//

import Foundation
import HeadlessKit

/// The outcome of one scenario run.
public struct ScenarioReport: Codable, Sendable, Equatable {

	public let scenario: String
	/// Why the run could not start: an invalid scenario or a failed launch.
	public let setupFailure: String?
	public let steps: [StepReport]
	public let teardown: [StepReport]
	/// Whether every declared step ran. A run that stopped early has not passed even when the
	/// steps it ran did.
	public let completedAllSteps: Bool
	public let durationSeconds: Double

	public init(
		scenario: String,
		setupFailure: String?,
		steps: [StepReport],
		teardown: [StepReport],
		completedAllSteps: Bool,
		durationSeconds: Double
	) {
		self.scenario = scenario
		self.setupFailure = setupFailure
		self.steps = steps
		self.teardown = teardown
		self.completedAllSteps = completedAllSteps
		self.durationSeconds = durationSeconds
	}

	public var passed: Bool {
		setupFailure == nil
			&& completedAllSteps
			&& steps.allSatisfy(\.passed)
			// Only a teardown step can be best effort; a step's flag would be ignored, not honoured.
			&& teardown.allSatisfy { $0.passed || $0.bestEffort }
	}

	/// Every failure that fails the run, in order, prefixed with where it happened.
	public var failures: [String] {
		var messages: [String] = []
		if let setupFailure { messages.append("setup: \(setupFailure)") }
		let fatal = steps.filter { $0.passed == false } + teardown.filter { $0.passed == false && $0.bestEffort == false }
		for step in fatal {
			for failure in step.failures {
				messages.append("\(step.location): \(failure)")
			}
		}
		return messages
	}

	/// Failures of best-effort teardown steps: reported, never silently passed, but not fatal.
	public var warnings: [String] {
		teardown.filter { $0.passed == false && $0.bestEffort }.flatMap { step in
			step.failures.map { "\(step.location) (best effort): \($0)" }
		}
	}
}

public struct StepReport: Codable, Sendable, Equatable {

	public let phase: String
	public let index: Int
	public let name: String?
	public let installation: String?
	public let command: String
	/// Where the app was after the step, when it answered.
	public let route: Route?
	public let failures: [String]
	/// The full response of a failed step, for diagnosis. Omitted for passing steps to keep
	/// reports small.
	public let response: JSONValue?
	/// A best-effort teardown step: its failures are warnings, not a failed run.
	public let bestEffort: Bool

	/// Whether the step itself did what it asserted. A best-effort step can fail without failing
	/// the run; ``ScenarioReport/passed`` makes that distinction, not this.
	public var passed: Bool { failures.isEmpty }

	/// `steps[3] "enable the model"` — how a failure message says where it happened.
	public var location: String {
		Self.location(phase: phase, index: index, name: name)
	}

	/// The same form for a step that has not run, as a check before the run reports it.
	static func location(phase: String, index: Int, name: String?) -> String {
		"\(phase)[\(index)]" + (name.map { " \"\($0)\"" } ?? "")
	}

	private enum CodingKeys: String, CodingKey {
		case phase, index, name, installation, command, route, failures, response, bestEffort
	}

	/// Reads reports written before `bestEffort` existed as not best effort, like `Step` does.
	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		phase = try container.decode(String.self, forKey: .phase)
		index = try container.decode(Int.self, forKey: .index)
		name = try container.decodeIfPresent(String.self, forKey: .name)
		installation = try container.decodeIfPresent(String.self, forKey: .installation)
		command = try container.decode(String.self, forKey: .command)
		route = try container.decodeIfPresent(Route.self, forKey: .route)
		failures = try container.decode([String].self, forKey: .failures)
		response = try container.decodeIfPresent(JSONValue.self, forKey: .response)
		bestEffort = try container.decodeIfPresent(Bool.self, forKey: .bestEffort) ?? false
	}

	public init(
		phase: String,
		index: Int,
		name: String?,
		installation: String?,
		command: String,
		route: Route?,
		failures: [String],
		response: JSONValue? = nil,
		bestEffort: Bool = false
	) {
		self.phase = phase
		self.index = index
		self.name = name
		self.installation = installation
		self.command = command
		self.route = route
		self.failures = failures
		self.response = response
		self.bestEffort = bestEffort
	}
}
