//
//  ScenarioTests.swift
//  HeadlessKitTests
//
//  AIA-0970.
//

import Foundation
import XCTest
import HeadlessKit
@testable import HeadlessScenario

/// Launches `CounterApp`s in-process. An installation's "data" — its count — survives a relaunch
/// and nothing else, the way an app's storage survives quitting it.
@MainActor
final class FakeLauncher: InstallationLauncher {

	var log: [String] = []
	var failingInstallations: Set<String> = []
	private var storedCounts: [String: Int] = [:]
	private var running: [String: CounterApp] = [:]

	func launch(installation: String, options: JSONValue, relaunch: Bool) async throws -> any HeadlessDriving {
		log.append("launch \(installation)\(relaunch ? " (relaunch)" : "")")
		if failingInstallations.contains(installation) {
			throw ScenarioError("cannot launch \(installation)")
		}
		let app = CounterApp()
		app.count = relaunch ? storedCounts[installation, default: 0] : (options.value(at: "/start")?.intValue ?? 0)
		running[installation] = app
		return InProcessDriver(session: HeadlessSession(application: app, pollInterval: .milliseconds(5)))
	}

	func terminate(installation: String) async throws {
		log.append("terminate \(installation)")
		storedCounts[installation] = running[installation]?.count
		running[installation] = nil
	}
}

@MainActor
final class ScenarioTests: XCTestCase {

	private func scenario(_ json: String) throws -> Scenario {
		let scenario = try HeadlessCoding.makeDecoder().decode(Scenario.self, from: Data(json.utf8))
		try scenario.validate()
		return scenario
	}

	private func run(_ json: String, launcher: FakeLauncher = FakeLauncher(), environment: [String: String] = [:]) async throws -> ScenarioReport {
		try await ScenarioRunner(launcher: launcher, environment: environment).run(scenario(json))
	}

	// MARK: - Running

	func testCapturedValuesFeedLaterSteps() async throws {
		let report = try await run(#"""
		{
		  "schemaVersion": 1,
		  "name": "capture",
		  "installations": { "a": { "launch": { "start": 2 } } },
		  "steps": [
		    { "name": "read", "expect": [ { "route": "home" } ], "capture": { "start": "/state/count" } },
		    { "perform": { "action": "increment", "arguments": { "by": "${start}" } },
		      "expect": [ { "equals": { "pointer": "/state/count", "value": 4 } } ] },
		    { "goto": "drawer", "expect": [ { "route": "drawer" }, { "exists": "/actions/0" }, { "absent": "/error" } ] }
		  ]
		}
		"""#)
		XCTAssertTrue(report.passed, report.failures.joined(separator: "\n"))
		XCTAssertEqual(report.steps.map(\.command), ["state", "perform", "goto"])
	}

	func testAWholeStringVariableKeepsItsType() async throws {
		let report = try await run(#"""
		{
		  "schemaVersion": 1, "name": "typed",
		  "installations": { "a": {} },
		  "steps": [
		    { "capture": { "open": "/context/drawerOpen" } },
		    { "expect": [ { "equals": { "pointer": "/context/drawerOpen", "value": "${open}" } } ] }
		  ]
		}
		"""#)
		XCTAssertTrue(report.passed, report.failures.joined(separator: "\n"))
	}

	func testEnvironmentVariablesAreSubstitutedAndMissingOnesFail() async throws {
		let json = #"""
		{
		  "schemaVersion": 1, "name": "env",
		  "installations": { "a": {} },
		  "steps": [
		    { "perform": { "action": "rename", "arguments": { "name": "user-${env:WHO}" } },
		      "expect": [ { "matches": { "pointer": "/result/name", "regex": "^user-ada$" } } ] }
		  ]
		}
		"""#
		let present = try await run(json, environment: ["WHO": "ada"])
		XCTAssertTrue(present.passed, present.failures.joined(separator: "\n"))
		let missing = try await run(json)
		XCTAssertFalse(missing.passed)
		XCTAssertTrue(missing.failures.contains { $0.contains("WHO") }, missing.failures.joined(separator: "\n"))
	}

	func testTheRunStopsAtTheFirstFailureButTeardownStillRuns() async throws {
		let launcher = FakeLauncher()
		let report = try await run(#"""
		{
		  "schemaVersion": 1, "name": "stop",
		  "installations": { "a": {} },
		  "steps": [
		    { "name": "wrong", "perform": { "action": "increment" }, "expect": [ { "equals": { "pointer": "/state/count", "value": 9 } } ] },
		    { "name": "never", "perform": { "action": "increment" } }
		  ],
		  "teardown": [ { "name": "cleanup", "perform": { "action": "increment", "arguments": { "by": 10 } } } ]
		}
		"""#, launcher: launcher)
		XCTAssertFalse(report.passed)
		XCTAssertFalse(report.completedAllSteps)
		XCTAssertEqual(report.steps.map(\.name), ["wrong"])
		XCTAssertEqual(report.teardown.map(\.name), ["cleanup"])
		XCTAssertTrue(report.teardown[0].passed)
		XCTAssertEqual(report.failures, [#"steps[0] "wrong": /state/count: expected 9, got 1"#])
		XCTAssertNotNil(report.steps[0].response, "a failed step keeps the response for diagnosis")
		XCTAssertEqual(launcher.log, ["launch a", "terminate a"])
	}

	func testAnErrorResponseFailsAStepUnlessItIsExpected() async throws {
		let unexpected = try await run(#"""
		{ "schemaVersion": 1, "name": "e1", "installations": { "a": {} }, "steps": [ { "goto": "settings" } ] }
		"""#)
		XCTAssertFalse(unexpected.passed)
		XCTAssertTrue(unexpected.failures[0].contains("unreachable"), unexpected.failures[0])

		let expected = try await run(#"""
		{ "schemaVersion": 1, "name": "e2", "installations": { "a": {} },
		  "steps": [ { "goto": "settings", "expect": [ { "error": "unreachable" }, { "route": "home" } ] } ] }
		"""#)
		XCTAssertTrue(expected.passed, expected.failures.joined(separator: "\n"))

		let wrongCode = try await run(#"""
		{ "schemaVersion": 1, "name": "e3", "installations": { "a": {} },
		  "steps": [ { "goto": "drawer", "expect": [ { "error": "unreachable" } ] } ] }
		"""#)
		XCTAssertFalse(wrongCode.passed, "expecting an error that does not happen fails")
	}

	func testRelaunchKeepsTheInstallationsData() async throws {
		let launcher = FakeLauncher()
		let report = try await run(#"""
		{
		  "schemaVersion": 1, "name": "relaunch",
		  "installations": { "a": {}, "b": {} },
		  "steps": [
		    { "on": "a", "perform": { "action": "increment", "arguments": { "by": 5 } } },
		    { "on": "a", "relaunch": true, "expect": [ { "equals": { "pointer": "/state/count", "value": 5 } } ] },
		    { "on": "b", "expect": [ { "equals": { "pointer": "/state/count", "value": 0 } } ] }
		  ]
		}
		"""#, launcher: launcher)
		XCTAssertTrue(report.passed, report.failures.joined(separator: "\n"))
		XCTAssertEqual(launcher.log, ["launch a", "launch b", "terminate a", "launch a (relaunch)", "terminate a", "terminate b"])
	}

	func testWaitStepsUseNamedConditions() async throws {
		let report = try await run(#"""
		{
		  "schemaVersion": 1, "name": "wait",
		  "installations": { "a": {} },
		  "steps": [
		    { "perform": { "action": "increment-later" } },
		    { "wait": { "condition": "count-at-least", "arguments": { "value": 1 }, "timeout": 2 },
		      "expect": [ { "equals": { "pointer": "/state/count", "value": 1 } } ] }
		  ]
		}
		"""#)
		XCTAssertTrue(report.passed, report.failures.joined(separator: "\n"))
	}

	func testAFailedLaunchIsASetupFailureAndWhatStartedIsStopped() async throws {
		let launcher = FakeLauncher()
		launcher.failingInstallations = ["b"]
		let report = try await run(#"""
		{ "schemaVersion": 1, "name": "setup", "installations": { "a": {}, "b": {} },
		  "steps": [ { "on": "a", "perform": { "action": "increment" } } ],
		  "teardown": [ { "on": "a", "perform": { "action": "increment" } }, { "on": "b", "perform": { "action": "increment" } } ] }
		"""#, launcher: launcher)
		XCTAssertFalse(report.passed)
		XCTAssertNotNil(report.setupFailure)
		XCTAssertTrue(report.steps.isEmpty)
		XCTAssertEqual(report.teardown.count, 1, "teardown skips the installation that never started")
		XCTAssertEqual(launcher.log, ["launch a", "launch b", "terminate a"])
	}

	// MARK: - Reading scenarios

	func testUnknownKeysAreErrorsAtEveryLevel() {
		let misspelt = [
			#"{ "schemaVersion": 1, "name": "x", "installations": { "a": {} }, "stpes": [] }"#,
			#"{ "schemaVersion": 1, "name": "x", "installations": { "a": { "lunch": {} } }, "steps": [] }"#,
			#"{ "schemaVersion": 1, "name": "x", "installations": { "a": {} }, "steps": [ { "expcet": [] } ] }"#,
			#"{ "schemaVersion": 1, "name": "x", "installations": { "a": {} }, "steps": [ { "perform": { "action": "a", "args": {} } } ] }"#,
			#"{ "schemaVersion": 1, "name": "x", "installations": { "a": {} }, "steps": [ { "expect": [ { "equal": {} } ] } ] }"#
		]
		for json in misspelt {
			XCTAssertThrowsError(try HeadlessCoding.makeDecoder().decode(Scenario.self, from: Data(json.utf8)), json)
		}
	}

	func testValidationCatchesWhatDecodingCannot() {
		let invalid = [
			#"{ "schemaVersion": 2, "name": "x", "installations": { "a": {} }, "steps": [] }"#,
			#"{ "schemaVersion": 1, "name": "x", "installations": {}, "steps": [] }"#,
			#"{ "schemaVersion": 1, "name": "x", "installations": { "a": {}, "b": {} }, "steps": [ { "goto": "home" } ] }"#,
			#"{ "schemaVersion": 1, "name": "x", "installations": { "a": {} }, "steps": [ { "on": "c", "goto": "home" } ] }"#,
			#"{ "schemaVersion": 1, "name": "x", "installations": { "a": {} }, "steps": [ { "goto": "home", "relaunch": true } ] }"#,
			#"{ "schemaVersion": 1, "name": "x", "installations": { "a": {} }, "steps": [ { "capture": { "v": "state" } } ] }"#,
			#"{ "schemaVersion": 1, "name": "x", "installations": { "a": {} }, "steps": [ { "expect": [ { "matches": { "pointer": "/a", "regex": "(" } } ] } ] }"#
		]
		for json in invalid {
			XCTAssertThrowsError(try scenario(json), json)
		}
	}

	func testAnExpectationHasExactlyOneKind() {
		let json = #"{ "schemaVersion": 1, "name": "x", "installations": { "a": {} }, "steps": [ { "expect": [ { "route": "a", "exists": "/b" } ] } ] }"#
		XCTAssertThrowsError(try scenario(json))
	}

	func testScenariosRoundTrip() throws {
		let original = Scenario(
			name: "round-trip",
			installations: ["a": Installation(launch: ["start": 1])],
			steps: [
				Step(name: "go", on: "a", goto: "drawer", expect: [.route("drawer"), .error(.unreachable)]),
				Step(perform: Perform(action: "increment", arguments: ["by": 1]), capture: ["c": "/state/count"]),
				Step(wait: Wait(condition: "route", arguments: ["route": "home"], timeout: 1)),
				Step(relaunch: true, expect: [.equals(pointer: "/a", value: 1), .exists(pointer: "/b"), .absent(pointer: "/c"), .matches(pointer: "/d", regex: "x")])
			],
			teardown: [Step(perform: Perform(action: "close"))]
		)
		let data = try HeadlessCoding.makeEncoder().encode(original)
		XCTAssertEqual(try HeadlessCoding.makeDecoder().decode(Scenario.self, from: data), original)
	}
}
