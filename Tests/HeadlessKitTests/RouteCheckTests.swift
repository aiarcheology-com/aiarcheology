//
//  RouteCheckTests.swift
//  HeadlessKitTests
//
//  AIA-0983.
//

import Foundation
import XCTest
import HeadlessKit
@testable import HeadlessScenario

@MainActor
final class RouteCheckTests: XCTestCase {

	private let known = "(known: home, drawer, settings, profile, about)"

	private func scenario(_ json: String) throws -> Scenario {
		let scenario = try HeadlessCoding.makeDecoder().decode(Scenario.self, from: Data(json.utf8))
		try scenario.validate()
		return scenario
	}

	private func run(_ json: String, launcher: FakeLauncher, environment: [String: String] = [:]) async throws -> ScenarioReport {
		try await ScenarioRunner(launcher: launcher, environment: environment).run(scenario(json))
	}

	// MARK: - The static check

	func testFailuresNameEachUnknownLiteralRouteWithItsStep() throws {
		let checked = try scenario(#"""
		{
		  "schemaVersion": 1, "name": "typos",
		  "installations": { "a": {} },
		  "steps": [
		    { "goto": "drawer", "expect": [ { "route": "drawer" } ] },
		    { "name": "go", "goto": "drawr" },
		    { "name": "wait for home", "wait": { "condition": "route", "arguments": { "route": "hme" } } },
		    { "expect": [ { "route": "Home" } ] },
		    { "goto": "${env:TARGET}", "expect": [ { "route": "${where}" } ] },
		    { "wait": { "condition": "count-at-least", "arguments": { "route": "not-a-route-here" } } },
		    { "wait": { "condition": "route", "arguments": { "route": "${target}" } } }
		  ],
		  "teardown": [ { "name": "back", "goto": "hom" } ]
		}
		"""#)
		XCTAssertEqual(RouteCheck.failures(in: checked, known: CounterApp.declaredMap.routeNames), [
			#"steps[1] "go": goto route 'drawr' is not a route of this app; did you mean 'drawer'? \#(known)"#,
			#"steps[2] "wait for home": wait route 'hme' is not a route of this app; did you mean 'home'? \#(known)"#,
			#"steps[3]: expect route 'Home' is not a route of this app; did you mean 'home'? \#(known)"#,
			#"teardown[0] "back": goto route 'hom' is not a route of this app; did you mean 'home'? \#(known)"#
		], "placeholders and other conditions' arguments are not checked here")
		XCTAssertEqual(RouteCheck.failures(in: checked, known: []), [], "no declaration, nothing to check")

		let references = RouteCheck.references(in: checked)
		XCTAssertEqual(references.map(\.kind), [.goto, .expect, .goto, .wait, .expect, .goto, .expect, .wait, .goto])
		XCTAssertEqual(references.filter(\.isPlaceholder).map(\.route), ["${env:TARGET}", "${where}", "${target}"])
		XCTAssertEqual(references.last?.location, #"teardown[0] "back""#)
	}

	// MARK: - Before the run

	func testATypoInGotoFailsTheRunBeforeAnyCommandIsSent() async throws {
		let launcher = FakeLauncher()
		let report = try await run(#"""
		{
		  "schemaVersion": 1, "name": "goto-typo",
		  "installations": { "a": {} },
		  "steps": [ { "perform": { "action": "increment" } }, { "name": "open", "goto": "drawr" } ],
		  "teardown": [ { "name": "cleanup", "perform": { "action": "increment" } } ]
		}
		"""#, launcher: launcher)
		XCTAssertFalse(report.passed)
		XCTAssertTrue(report.steps.isEmpty, "no step runs")
		XCTAssertFalse(report.completedAllSteps)
		let setup = try XCTUnwrap(report.setupFailure)
		XCTAssertTrue(setup.contains(#"steps[1] "open": goto route 'drawr' is not a route of this app; did you mean 'drawer'?"#), setup)
		XCTAssertEqual(report.teardown.map(\.name), ["cleanup"], "teardown still runs")
		XCTAssertTrue(report.teardown[0].passed)
		XCTAssertEqual(launcher.sent, ["a perform"], "only the teardown's command reached the app")
		XCTAssertEqual(launcher.log, ["launch a", "terminate a"])
	}

	func testATypoInWaitRouteFailsTheRunBeforeAnyCommandIsSent() async throws {
		let launcher = FakeLauncher()
		let report = try await run(#"""
		{
		  "schemaVersion": 1, "name": "wait-typo",
		  "installations": { "a": {} },
		  "steps": [ { "name": "settle", "wait": { "condition": "route", "arguments": { "route": "hme" }, "timeout": 30 } } ]
		}
		"""#, launcher: launcher)
		XCTAssertTrue(report.steps.isEmpty)
		let setup = try XCTUnwrap(report.setupFailure)
		XCTAssertTrue(setup.contains(#"steps[0] "settle": wait route 'hme' is not a route of this app; did you mean 'home'?"#), setup)
		XCTAssertEqual(launcher.sent, [])
		XCTAssertEqual(launcher.log, ["launch a", "terminate a"])
	}

	func testATypoInExpectRouteFailsTheRunBeforeAnyCommandIsSent() async throws {
		let launcher = FakeLauncher()
		let report = try await run(#"""
		{
		  "schemaVersion": 1, "name": "expect-typo",
		  "installations": { "a": {} },
		  "steps": [ { "name": "look", "perform": { "action": "increment" }, "expect": [ { "route": "hoem" } ] } ]
		}
		"""#, launcher: launcher)
		XCTAssertTrue(report.steps.isEmpty)
		let setup = try XCTUnwrap(report.setupFailure)
		XCTAssertTrue(setup.contains(#"steps[0] "look": expect route 'hoem' is not a route of this app; did you mean 'home'?"#), setup)
		XCTAssertEqual(launcher.sent, [])
	}

	/// AIA-0990: `notRoute` names a route as `route` does, in `expect` and in a teardown's `unless`,
	/// so a misspelling fails the check instead of always holding.
	func testATypoInNotRouteFailsTheCheckInExpectAndInUnless() async throws {
		let json = #"""
		{
		  "schemaVersion": 1, "name": "not-route-typos",
		  "installations": { "a": {} },
		  "steps": [ { "name": "look", "expect": [ { "notRoute": "drawr" } ] } ],
		  "teardown": [ { "name": "close", "perform": { "action": "close" }, "unless": [ { "notRoute": "drawre" } ] } ]
		}
		"""#
		let checked = try scenario(json)
		XCTAssertEqual(RouteCheck.references(in: checked).map(\.kind), [.expect, .unless])
		XCTAssertEqual(RouteCheck.failures(in: checked, known: CounterApp.declaredMap.routeNames), [
			#"steps[0] "look": expect route 'drawr' is not a route of this app; did you mean 'drawer'? \#(known)"#,
			#"teardown[0] "close": unless route 'drawre' is not a route of this app; did you mean 'drawer'? \#(known)"#
		])

		let launcher = FakeLauncher()
		let report = try await run(json, launcher: launcher)
		let setup = try XCTUnwrap(report.setupFailure)
		XCTAssertTrue(setup.contains("unless route 'drawre'"), setup)
		XCTAssertTrue(report.steps.isEmpty, "no step runs")
		// Teardown still runs, and a predicate the app cannot judge never skips a cleanup.
		XCTAssertEqual(report.teardown.map(\.skipped), [false])
		XCTAssertEqual(launcher.sent, ["a perform"])
	}

	func testEveryTypoIsReportedAtOnceAndATeardownTypoFailsWithoutBeingSent() async throws {
		let launcher = FakeLauncher()
		let report = try await run(#"""
		{
		  "schemaVersion": 1, "name": "many",
		  "installations": { "a": {} },
		  "steps": [ { "goto": "drawr" }, { "expect": [ { "route": "hme" } ] } ],
		  "teardown": [ { "name": "back", "goto": "hom" } ]
		}
		"""#, launcher: launcher)
		let setup = try XCTUnwrap(report.setupFailure)
		XCTAssertTrue(setup.contains("steps[0]: goto route 'drawr'"), setup)
		XCTAssertTrue(setup.contains("steps[1]: expect route 'hme'"), setup)
		XCTAssertTrue(setup.contains(#"teardown[0] "back": goto route 'hom'"#), setup)
		XCTAssertEqual(report.teardown.count, 1, "teardown runs")
		XCTAssertEqual(report.teardown[0].failures, ["goto route 'hom' is not a route of this app; did you mean 'home'? \(known)"])
		XCTAssertEqual(launcher.sent, [], "the misspelt teardown step is not sent either")
	}

	// MARK: - Resolved values

	func testAResolvedTypoFailsItsStepBeforeItIsSent() async throws {
		let json = #"""
		{
		  "schemaVersion": 1, "name": "resolved",
		  "installations": { "a": {} },
		  "steps": [
		    { "perform": { "action": "increment" } },
		    { "name": "go", "goto": "${env:TARGET}" },
		    { "name": "settle", "wait": { "condition": "${env:CONDITION}", "arguments": { "route": "${env:TARGET}" }, "timeout": 30 } },
		    { "name": "check", "expect": [ { "route": "${env:TARGET}" } ] }
		  ]
		}
		"""#
		let good = FakeLauncher()
		let passing = try await run(json, launcher: good, environment: ["TARGET": "drawer", "CONDITION": "route"])
		XCTAssertNil(passing.setupFailure, "placeholders are not checked before the run")
		XCTAssertTrue(passing.passed, passing.failures.joined(separator: "\n"))
		XCTAssertEqual(good.sent, ["a perform", "a goto", "a wait", "a state"], "declared once resolved, so sent")

		let gotoTypo = FakeLauncher()
		let failedGoto = try await run(json, launcher: gotoTypo, environment: ["TARGET": "drawr", "CONDITION": "route"])
		XCTAssertNil(failedGoto.setupFailure)
		XCTAssertEqual(failedGoto.failures, [
			#"steps[1] "go": goto route 'drawr' is not a route of this app; did you mean 'drawer'? \#(known)"#
		])
		XCTAssertNil(failedGoto.steps[1].route, "the app was never asked")
		XCTAssertEqual(gotoTypo.sent, ["a perform"])
	}

	func testResolvedWaitAndExpectRoutesAreCheckedBeforeSending() async throws {
		let waitLauncher = FakeLauncher()
		let waitReport = try await run(#"""
		{
		  "schemaVersion": 1, "name": "resolved-wait",
		  "installations": { "a": {} },
		  "steps": [ { "name": "settle", "wait": { "condition": "${env:CONDITION}", "arguments": { "route": "${env:TARGET}" }, "timeout": 30 } } ]
		}
		"""#, launcher: waitLauncher, environment: ["TARGET": "hme", "CONDITION": "route"])
		XCTAssertEqual(waitReport.failures, [
			#"steps[0] "settle": wait route 'hme' is not a route of this app; did you mean 'home'? \#(known)"#
		])
		XCTAssertEqual(waitLauncher.sent, [])

		let expectLauncher = FakeLauncher()
		let expectReport = try await run(#"""
		{
		  "schemaVersion": 1, "name": "resolved-expect",
		  "installations": { "a": {} },
		  "steps": [
		    { "capture": { "here": "/route" } },
		    { "name": "check", "perform": { "action": "increment" }, "expect": [ { "route": "${here}x" } ] }
		  ]
		}
		"""#, launcher: expectLauncher)
		XCTAssertEqual(expectReport.failures, [
			#"steps[1] "check": expect route 'homex' is not a route of this app; did you mean 'home'? \#(known)"#
		])
		XCTAssertEqual(expectLauncher.sent, ["a state"], "the perform was never sent")
	}

	func testARelaunchRereadsTheDeclaredRoutes() async throws {
		let launcher = FakeLauncher()
		let report = try await run(#"""
		{
		  "schemaVersion": 1, "name": "relaunch",
		  "installations": { "a": {} },
		  "steps": [ { "relaunch": true }, { "goto": "${env:TARGET}" } ]
		}
		"""#, launcher: launcher, environment: ["TARGET": "drawr"])
		XCTAssertEqual(report.failures.count, 1)
		XCTAssertTrue(report.failures[0].contains("goto route 'drawr' is not a route of this app"), report.failures[0])
		XCTAssertEqual(launcher.sent, ["a state"], "only the relaunch step's observation")
	}

	func testStepsAfterARelaunchAreCheckedAgainstTheRelaunchedBuild() async throws {
		// The first launch is a build without `drawer`; the relaunch is one that declares it.
		let olderBuild = NavigationMap(routes: CounterApp.declaredMap.routes.filter { $0.route != "drawer" })

		let launcher = FakeLauncher()
		launcher.firstLaunchMaps = ["a": olderBuild]
		let report = try await run(#"""
		{
		  "schemaVersion": 1, "name": "relaunch-into-a-newer-build",
		  "installations": { "a": {} },
		  "steps": [
		    { "expect": [ { "route": "home" } ] },
		    { "relaunch": true },
		    { "name": "open", "goto": "drawer", "expect": [ { "route": "drawer" } ] }
		  ]
		}
		"""#, launcher: launcher)
		XCTAssertNil(report.setupFailure, "a step after the relaunch is not judged by the first launch's routes")
		XCTAssertTrue(report.passed, report.failures.joined(separator: "\n"))
		XCTAssertEqual(launcher.sent, ["a state", "a state", "a goto"])

		let typoLauncher = FakeLauncher()
		typoLauncher.firstLaunchMaps = ["a": olderBuild]
		let typo = try await run(#"""
		{
		  "schemaVersion": 1, "name": "typo-after-relaunch",
		  "installations": { "a": {} },
		  "steps": [ { "relaunch": true }, { "name": "open", "goto": "drawr" } ]
		}
		"""#, launcher: typoLauncher)
		XCTAssertNil(typo.setupFailure)
		XCTAssertEqual(typo.failures, [
			#"steps[1] "open": goto route 'drawr' is not a route of this app; did you mean 'drawer'? \#(known)"#
		], "checked at its step, against the relaunched build")
		XCTAssertNil(try XCTUnwrap(typo.steps.dropFirst().first).route, "the app was never asked")
		XCTAssertEqual(typoLauncher.sent, ["a state"], "only the relaunch step's observation")
	}

	// MARK: - An app that declares no routes

	func testAnInstallationWithoutDeclaredRoutesKeepsTodaysBehavior() async throws {
		let launcher = FakeLauncher()
		launcher.undeclaredInstallations = ["b"]
		let report = try await run(#"""
		{
		  "schemaVersion": 1, "name": "old-build",
		  "installations": { "a": {}, "b": {} },
		  "steps": [
		    { "on": "a", "goto": "drawer" },
		    { "on": "b", "name": "go", "goto": "drawr", "expect": [ { "route": "hme" } ] }
		  ]
		}
		"""#, launcher: launcher)
		XCTAssertNil(report.setupFailure, "b declares nothing, so its steps are not checked")
		XCTAssertEqual(launcher.sent, ["a goto", "b goto"], "the step is sent, as before")
		XCTAssertEqual(report.failures.count, 1)
		XCTAssertTrue(report.failures[0].contains("unreachable"), report.failures[0])
	}
}
