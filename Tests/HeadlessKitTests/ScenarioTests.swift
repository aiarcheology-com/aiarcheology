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
	/// Installations whose app declares no navigation map, as an app built before maps did.
	var undeclaredInstallations: Set<String> = []
	/// Maps an installation's first launch declares instead of `CounterApp.declaredMap`, as an older
	/// build would; a relaunch declares the current map.
	var firstLaunchMaps: [String: NavigationMap] = [:]
	/// Every command sent, as `<installation> <command name>`, in order.
	var sent: [String] = []
	private var storedCounts: [String: Int] = [:]
	private var running: [String: CounterApp] = [:]

	func launch(installation: String, options: JSONValue, relaunch: Bool) async throws -> any HeadlessDriving {
		log.append("launch \(installation)\(relaunch ? " (relaunch)" : "")")
		if failingInstallations.contains(installation) {
			throw ScenarioError("cannot launch \(installation)")
		}
		let app = CounterApp()
		app.count = relaunch ? storedCounts[installation, default: 0] : (options.value(at: "/start")?.intValue ?? 0)
		app.extraContext = options.value(at: "/context")?.objectValue ?? [:]
		if undeclaredInstallations.contains(installation) {
			app.navigationMap = .empty
		} else if relaunch == false, let map = firstLaunchMaps[installation] {
			app.navigationMap = map
		}
		running[installation] = app
		let driver = InProcessDriver(session: HeadlessSession(application: app, pollInterval: .milliseconds(5)))
		return RecordingDriver(driver: driver) { [unowned self] command in
			self.sent.append("\(installation) \(command.name)")
		}
	}

	func terminate(installation: String) async throws {
		log.append("terminate \(installation)")
		storedCounts[installation] = running[installation]?.count
		running[installation] = nil
	}
}

/// Forwards to an in-process driver and records what it sends, so a test can prove a step sent
/// nothing.
@MainActor
final class RecordingDriver: HeadlessDriving {

	let driver: InProcessDriver
	let record: (Command) -> Void

	init(driver: InProcessDriver, record: @escaping (Command) -> Void) {
		self.driver = driver
		self.record = record
	}

	func send(_ command: Command) async throws -> Response {
		record(command)
		return try await driver.send(command)
	}

	func declaredRoutes() async -> [Route]? {
		await driver.declaredRoutes()
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

	func testAVariableInARegexIsMatchedLiterally() async throws {
		let json = #"""
		{
		  "schemaVersion": 1, "name": "regex",
		  "installations": { "a": {} },
		  "steps": [
		    { "perform": { "action": "rename", "arguments": { "name": "a.b" } }, "capture": { "name": "/result/name" } },
		    { "perform": { "action": "rename", "arguments": { "name": "${env:SECOND}" } },
		      "expect": [ { "matches": { "pointer": "/result/name", "regex": "^${name}$" } } ] }
		  ]
		}
		"""#
		let literal = try await run(json, environment: ["SECOND": "a.b"])
		XCTAssertTrue(literal.passed, literal.failures.joined(separator: "\n"))
		let wildcard = try await run(json, environment: ["SECOND": "axb"])
		XCTAssertFalse(wildcard.passed, "a captured '.' must not act as a regex wildcard")
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

	// MARK: - Best-effort teardown (AIA-0974)

	func testABestEffortTeardownFailureIsAWarningNotAFailedRun() async throws {
		let report = try await run(#"""
		{
		  "schemaVersion": 1, "name": "cleanup-from-anywhere",
		  "installations": { "a": {} },
		  "steps": [ { "perform": { "action": "increment" } } ],
		  "teardown": [
		    { "name": "sign out if still in", "goto": "settings", "bestEffort": true },
		    { "name": "cleanup", "perform": { "action": "increment" } }
		  ]
		}
		"""#)
		XCTAssertTrue(report.passed, report.failures.joined(separator: "\n"))
		XCTAssertEqual(report.failures, [])
		XCTAssertEqual(report.warnings.count, 1)
		XCTAssertTrue(report.warnings[0].hasPrefix(#"teardown[0] "sign out if still in" (best effort): "#), report.warnings[0])
		XCTAssertTrue(report.warnings[0].contains("unreachable"), report.warnings[0])
		XCTAssertEqual(report.teardown.map(\.passed), [false, true], "the failed best-effort step does not stop the rest")
		// The report's own JSON says which failure was tolerated, so nothing downstream reads it as a pass.
		let json = try XCTUnwrap(String(bytes: HeadlessCoding.makeEncoder().encode(report), encoding: .utf8))
		XCTAssertTrue(json.contains(#""bestEffort":true"#), json)
	}

	func testAnOrdinaryTeardownFailureStillFailsTheRun() async throws {
		let report = try await run(#"""
		{
		  "schemaVersion": 1, "name": "strict-cleanup",
		  "installations": { "a": {} },
		  "steps": [ { "perform": { "action": "increment" } } ],
		  "teardown": [ { "name": "cleanup", "goto": "settings" } ]
		}
		"""#)
		XCTAssertFalse(report.passed)
		XCTAssertEqual(report.warnings, [])
		XCTAssertEqual(report.failures.count, 1)
		XCTAssertTrue(report.failures[0].hasPrefix(#"teardown[0] "cleanup": "#), report.failures[0])
	}

	func testAReportWrittenBeforeBestEffortStillDecodes() throws {
		let old = #"""
		{ "command": "perform increment", "failures": ["x"], "index": 0, "phase": "teardown" }
		"""#
		let step = try HeadlessCoding.makeDecoder().decode(StepReport.self, from: Data(old.utf8))
		XCTAssertFalse(step.bestEffort)
		XCTAssertFalse(step.skipped)
		XCTAssertFalse(step.passed)
	}

	func testBestEffortIsRejectedOutsideTeardown() throws {
		let inSteps = #"""
		{ "schemaVersion": 1, "name": "x", "installations": { "a": {} },
		  "steps": [ { "perform": { "action": "increment" }, "bestEffort": true } ] }
		"""#
		XCTAssertThrowsError(try HeadlessCoding.makeDecoder().decode(Scenario.self, from: Data(inSteps.utf8)),
			"the decoder itself refuses a best-effort step")
		// Built in code rather than decoded, validation refuses it too.
		let built = Scenario(name: "x", installations: ["a": Installation()], steps: [Step(perform: Perform(action: "increment"), bestEffort: true)])
		XCTAssertThrowsError(try built.validate())

		let inTeardown = #"""
		{ "schemaVersion": 1, "name": "x", "installations": { "a": {} }, "steps": [],
		  "teardown": [ { "perform": { "action": "increment" }, "bestEffort": true } ] }
		"""#
		XCTAssertNoThrow(try scenario(inTeardown))
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
			#"{ "schemaVersion": 1, "name": "x", "installations": { "a": {} }, "steps": [ { "expect": [ { "equal": {} } ] } ] }"#,
			#"{ "schemaVersion": 1, "name": "x", "installations": { "a": {} }, "steps": [ { "expect": [ { "equals": { "pointer": "/a", "value": 1, "vaule": 2 } } ] } ] }"#,
			#"{ "schemaVersion": 1, "name": "x", "installations": { "a": {} }, "steps": [ { "expect": [ { "matches": { "pointer": "/a", "regex": "x", "flags": "i" } } ] } ] }"#
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
			#"{ "schemaVersion": 1, "name": "x", "installations": { "a": {} }, "steps": [ { "expect": [ { "matches": { "pointer": "/a", "regex": "(" } } ] } ] }"#,
			// Without the leading slash these address nothing: `absent` would always pass.
			#"{ "schemaVersion": 1, "name": "x", "installations": { "a": {} }, "steps": [ { "expect": [ { "absent": "state/error" } ] } ] }"#,
			#"{ "schemaVersion": 1, "name": "x", "installations": { "a": {} }, "steps": [ { "expect": [ { "equals": { "pointer": "state/a", "value": 1 } } ] } ] }"#,
			#"{ "schemaVersion": 1, "name": "x", "installations": { "a": {} }, "steps": [ { "expect": [ { "exists": "state" } ] } ] }"#
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
			teardown: [
				Step(perform: Perform(action: "close")),
				Step(goto: "home", bestEffort: true),
				Step(perform: Perform(action: "close"), expect: [.notRoute("home")], bestEffort: true, unless: [.notRoute("drawer"), .equals(pointer: "/context/count", value: 0)])
			]
		)
		let data = try HeadlessCoding.makeEncoder().encode(original)
		XCTAssertEqual(try HeadlessCoding.makeDecoder().decode(Scenario.self, from: data), original)
	}
}
