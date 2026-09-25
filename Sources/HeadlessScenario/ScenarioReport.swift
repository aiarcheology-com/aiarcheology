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

	public var passed: Bool {
		setupFailure == nil
			&& completedAllSteps
			&& steps.allSatisfy(\.passed)
			&& teardown.allSatisfy(\.passed)
	}

	/// Every failure message, in order, prefixed with where it happened.
	public var failures: [String] {
		var messages: [String] = []
		if let setupFailure { messages.append("setup: \(setupFailure)") }
		for step in steps + teardown where step.passed == false {
			for failure in step.failures {
				messages.append("\(step.location): \(failure)")
			}
		}
		return messages
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

	public var passed: Bool { failures.isEmpty }

	/// `steps[3] "enable the model"` — how a failure message says where it happened.
	public var location: String {
		"\(phase)[\(index)]" + (name.map { " \"\($0)\"" } ?? "")
	}

	public init(
		phase: String,
		index: Int,
		name: String?,
		installation: String?,
		command: String,
		route: Route?,
		failures: [String],
		response: JSONValue? = nil
	) {
		self.phase = phase
		self.index = index
		self.name = name
		self.installation = installation
		self.command = command
		self.route = route
		self.failures = failures
		self.response = response
	}
}
