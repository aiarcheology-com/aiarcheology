//
//  ScenarioUnlessTests.swift
//  HeadlessKitTests
//
//  AIA-0990.
//

import Foundation
import XCTest
import HeadlessKit
@testable import HeadlessScenario

/// What a teardown step's `unless` does: a step with nothing to do is skipped, and any doubt runs it.
@MainActor
final class ScenarioUnlessTests: XCTestCase {

	private func scenario(_ json: String) throws -> Scenario {
		let scenario = try HeadlessCoding.makeDecoder().decode(Scenario.self, from: Data(json.utf8))
		try scenario.validate()
		return scenario
	}

	private func run(_ json: String, launcher: any InstallationLauncher, environment: [String: String] = [:]) async throws -> ScenarioReport {
		try await ScenarioRunner(launcher: launcher, environment: environment).run(scenario(json))
	}

	// MARK: - Holding and not holding

	func testAStepWhoseUnlessHoldsIsSkippedAndOnlyTheReadIsSent() async throws {
		let launcher = FakeLauncher()
		// Not best effort: `close` is not offered on home, so sending it would fail the run.
		let report = try await run(#"""
		{
		  "schemaVersion": 1, "name": "nothing-to-close",
		  "installations": { "a": {} },
		  "steps": [ { "perform": { "action": "increment" } } ],
		  "teardown": [ { "name": "close the drawer", "perform": { "action": "close" }, "unless": [ { "notRoute": "drawer" } ] } ]
		}
		"""#, launcher: launcher)
		XCTAssertTrue(report.passed, report.failures.joined(separator: "\n"))
		XCTAssertEqual(report.failures, [])
		XCTAssertEqual(report.warnings, [])
		XCTAssertEqual(report.skipped, [#"teardown[0] "close the drawer" (skipped: unless held)"#])
		let step = try XCTUnwrap(report.teardown.first)
		XCTAssertTrue(step.skipped)
		XCTAssertTrue(step.passed, "a skipped step has no failures")
		XCTAssertEqual(step.route, "home", "the route the read found")
		XCTAssertEqual(step.command, "perform")
		XCTAssertEqual(launcher.sent, ["a perform", "a state"], "the read, and not the step")
		// The report's own JSON says the step was skipped.
		let json = try XCTUnwrap(String(bytes: HeadlessCoding.makeEncoder().encode(report), encoding: .utf8))
		XCTAssertTrue(json.contains(#""skipped":true"#), json)
	}

	func testAStepWhoseUnlessDoesNotHoldRunsAsWritten() async throws {
		let launcher = FakeLauncher()
		let report = try await run(#"""
		{
		  "schemaVersion": 1, "name": "drawer-left-open",
		  "installations": { "a": {} },
		  "steps": [ { "goto": "drawer" } ],
		  "teardown": [ { "perform": { "action": "close" }, "unless": [ { "notRoute": "drawer" } ] } ]
		}
		"""#, launcher: launcher)
		XCTAssertTrue(report.passed, report.failures.joined(separator: "\n"))
		XCTAssertEqual(report.skipped, [])
		XCTAssertEqual(report.teardown.map(\.skipped), [false])
		XCTAssertEqual(report.teardown.first?.route, "home", "the step ran and closed the drawer")
		XCTAssertEqual(launcher.sent, ["a goto", "a state", "a perform"])
	}

	func testEveryExpectationMustHoldForTheStepToBeSkipped() async throws {
		let launcher = FakeLauncher()
		let report = try await run(#"""
		{
		  "schemaVersion": 1, "name": "one-of-two",
		  "installations": { "a": {} },
		  "steps": [],
		  "teardown": [ { "perform": { "action": "increment" },
		                  "unless": [ { "notRoute": "drawer" }, { "equals": { "pointer": "/context/count", "value": 5 } } ] } ]
		}
		"""#, launcher: launcher)
		XCTAssertTrue(report.passed, report.failures.joined(separator: "\n"))
		XCTAssertEqual(report.teardown.map(\.skipped), [false], "the route holds, the count does not")
		XCTAssertEqual(launcher.sent, ["a state", "a perform"])
	}

	// MARK: - With bestEffort

	func testABestEffortStepWhoseUnlessHoldsIsSkippedWithoutAWarning() async throws {
		let report = try await run(#"""
		{
		  "schemaVersion": 1, "name": "signed-out-already",
		  "installations": { "a": { "launch": { "context": { "auth": { "accountPresent": false } } } } },
		  "steps": [],
		  "teardown": [ { "perform": { "action": "sign-out" }, "bestEffort": true,
		                  "unless": [ { "equals": { "pointer": "/context/auth/accountPresent", "value": false } } ] } ]
		}
		"""#, launcher: FakeLauncher())
		XCTAssertTrue(report.passed, report.failures.joined(separator: "\n"))
		XCTAssertEqual(report.warnings, [])
		XCTAssertEqual(report.skipped.count, 1)
	}

	/// The leak the warning exists for: a run that died while auth was still resolving leaves a
	/// session (`accountPresent`) with no `sign-out` offered. The step must still run, and still warn.
	func testSignOutStillRunsAndWarnsWhenAuthIsStillResolving() async throws {
		let launcher = FakeLauncher()
		let report = try await run(#"""
		{
		  "schemaVersion": 1, "name": "died-mid-auth",
		  "installations": { "a": { "launch": { "context": { "auth": { "accountPresent": true } } } } },
		  "steps": [],
		  "teardown": [ { "name": "end any session", "perform": { "action": "sign-out" }, "bestEffort": true,
		                  "unless": [ { "equals": { "pointer": "/context/auth/accountPresent", "value": false } } ] } ]
		}
		"""#, launcher: launcher)
		XCTAssertTrue(report.passed, "a best-effort failure is a warning")
		XCTAssertEqual(report.skipped, [])
		XCTAssertEqual(report.teardown.map(\.skipped), [false])
		XCTAssertEqual(launcher.sent, ["a state", "a perform"], "sign-out was sent")
		XCTAssertEqual(report.warnings.count, 1)
		XCTAssertTrue(report.warnings[0].hasPrefix(#"teardown[0] "end any session" (best effort): "#), report.warnings[0])
		XCTAssertTrue(report.warnings[0].contains("unknownAction"), report.warnings[0])
	}

	// MARK: - Doubt runs the step

	func testAFailedReadRunsTheStep() async throws {
		let launcher = ReadFaultLauncher(fault: .throwing)
		let report = try await run(Self.holdsIfReadable, launcher: launcher)
		XCTAssertTrue(report.passed, report.failures.joined(separator: "\n"))
		XCTAssertEqual(report.teardown.map(\.skipped), [false])
		XCTAssertEqual(launcher.fake.sent, ["a state", "a perform"], "the step ran after the read failed")
	}

	func testAnErrorAnsweringTheReadRunsTheStep() async throws {
		let launcher = ReadFaultLauncher(fault: .errorResponse)
		let report = try await run(Self.holdsIfReadable, launcher: launcher)
		XCTAssertTrue(report.passed, report.failures.joined(separator: "\n"))
		XCTAssertEqual(report.teardown.map(\.skipped), [false], "an error response never holds, whatever it carries")
		XCTAssertEqual(launcher.fake.sent, ["a state", "a perform"])
	}

	/// A read that succeeded would skip this step: its count is 0 and it is on home.
	private static let holdsIfReadable = #"""
	{
	  "schemaVersion": 1, "name": "doubt",
	  "installations": { "a": {} },
	  "steps": [],
	  "teardown": [ { "perform": { "action": "increment" },
	                  "unless": [ { "equals": { "pointer": "/context/count", "value": 0 } }, { "notRoute": "drawer" } ] } ]
	}
	"""#

	func testAnUnresolvableUnlessRunsTheStepWithoutReading() async throws {
		let launcher = FakeLauncher()
		let report = try await run(#"""
		{
		  "schemaVersion": 1, "name": "never-captured",
		  "installations": { "a": {} },
		  "steps": [],
		  "teardown": [ { "perform": { "action": "increment" }, "unless": [ { "notRoute": "${where}" } ] } ]
		}
		"""#, launcher: launcher)
		XCTAssertTrue(report.passed, report.failures.joined(separator: "\n"))
		XCTAssertEqual(report.teardown.map(\.skipped), [false])
		XCTAssertEqual(launcher.sent, ["a perform"], "decided before any read: the step runs")
	}

	func testAnUnlessRouteResolvedToAnUndeclaredRouteRunsTheStep() async throws {
		let launcher = FakeLauncher()
		let report = try await run(#"""
		{
		  "schemaVersion": 1, "name": "resolved-typo",
		  "installations": { "a": {} },
		  "steps": [],
		  "teardown": [ { "perform": { "action": "increment" }, "unless": [ { "notRoute": "${env:SHEET}" } ] } ]
		}
		"""#, launcher: launcher, environment: ["SHEET": "drawr"])
		XCTAssertTrue(report.passed, "the route check never blocks a cleanup through its unless")
		XCTAssertEqual(report.teardown.map(\.skipped), [false])
		XCTAssertEqual(launcher.sent, ["a perform"])
	}

	func testWhyUnlessWasNotDecidedIsReportedWhenTheStepFails() async throws {
		let report = try await run(#"""
		{
		  "schemaVersion": 1, "name": "doubt-and-failure",
		  "installations": { "a": {} },
		  "steps": [],
		  "teardown": [ { "perform": { "action": "close" }, "bestEffort": true, "unless": [ { "notRoute": "${where}" } ] } ]
		}
		"""#, launcher: FakeLauncher())
		XCTAssertEqual(report.warnings.count, 2, report.warnings.joined(separator: "\n"))
		XCTAssertTrue(report.warnings[1].contains("unless could not be evaluated, so the step ran: variable 'where' was never captured"), report.warnings[1])
	}

	// MARK: - notRoute

	func testNotRouteHoldsOnAnyOtherRoute() async throws {
		let report = try await run(#"""
		{
		  "schemaVersion": 1, "name": "not-route",
		  "installations": { "a": {} },
		  "steps": [
		    { "expect": [ { "notRoute": "drawer" } ] },
		    { "goto": "drawer", "expect": [ { "notRoute": "drawer" } ] }
		  ]
		}
		"""#, launcher: FakeLauncher())
		XCTAssertEqual(report.failures, [#"steps[1]: expected a route other than 'drawer'"#])
	}

	// MARK: - Where unless is allowed

	func testUnlessIsRejectedOutsideTeardown() throws {
		let inSteps = #"""
		{ "schemaVersion": 1, "name": "x", "installations": { "a": {} },
		  "steps": [ { "perform": { "action": "increment" }, "unless": [ { "notRoute": "home" } ] } ] }
		"""#
		XCTAssertThrowsError(try HeadlessCoding.makeDecoder().decode(Scenario.self, from: Data(inSteps.utf8)),
			"the decoder itself refuses a skippable step")
		let built = Scenario(name: "x", installations: ["a": Installation()], steps: [
			Step(perform: Perform(action: "increment"), unless: [.notRoute("home")])
		])
		XCTAssertThrowsError(try built.validate())
	}

	func testUnlessIsRejectedWhereASkipWouldMislead() {
		let invalid: [(String, String)] = [
			("not a perform", #"{ "goto": "home", "unless": [ { "notRoute": "drawer" } ] }"#),
			("a relaunch", #"{ "relaunch": true, "unless": [ { "notRoute": "drawer" } ] }"#),
			("empty", #"{ "perform": { "action": "increment" }, "unless": [] }"#),
			("an error", #"{ "perform": { "action": "increment" }, "unless": [ { "error": "unreachable" } ] }"#),
			("a capture", #"{ "perform": { "action": "increment" }, "unless": [ { "notRoute": "drawer" } ], "capture": { "c": "/state/count" } }"#),
			("a bad pattern", #"{ "perform": { "action": "increment" }, "unless": [ { "matches": { "pointer": "/route", "regex": "(" } } ] }"#),
			("a bad pointer", #"{ "perform": { "action": "increment" }, "unless": [ { "absent": "route" } ] }"#)
		]
		for (reason, step) in invalid {
			let json = #"{ "schemaVersion": 1, "name": "x", "installations": { "a": {} }, "steps": [], "teardown": [ "# + step + " ] }"
			XCTAssertThrowsError(try scenario(json), reason)
		}
	}
}

/// Wraps `FakeLauncher`'s drivers so that a `state` read fails: thrown, as a lost connection, or
/// answered with an error that carries a state the predicate would otherwise accept.
@MainActor
private final class ReadFaultLauncher: InstallationLauncher {

	enum Fault {
		case throwing
		case errorResponse
	}

	let fake = FakeLauncher()
	let fault: Fault

	init(fault: Fault) {
		self.fault = fault
	}

	func launch(installation: String, options: JSONValue, relaunch: Bool) async throws -> any HeadlessDriving {
		ReadFaultDriver(driver: try await fake.launch(installation: installation, options: options, relaunch: relaunch), fault: fault)
	}

	func terminate(installation: String) async throws {
		try await fake.terminate(installation: installation)
	}
}

@MainActor
private final class ReadFaultDriver: HeadlessDriving {

	let driver: any HeadlessDriving
	let fault: ReadFaultLauncher.Fault

	init(driver: any HeadlessDriving, fault: ReadFaultLauncher.Fault) {
		self.driver = driver
		self.fault = fault
	}

	func send(_ command: Command) async throws -> Response {
		let response = try await driver.send(command)
		guard case .state = command else { return response }
		switch fault {
		case .throwing:
			throw ScenarioError("the connection was lost")
		case .errorResponse:
			return Response(
				id: response.id,
				route: response.route,
				state: response.state,
				actions: response.actions,
				context: response.context,
				error: HeadlessError(.actionFailed, "the app could not answer")
			)
		}
	}

	func declaredRoutes() async -> [Route]? {
		await driver.declaredRoutes()
	}
}
