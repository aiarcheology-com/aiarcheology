//
//  HeadlessCommandTypingTests.swift
//  ProjectToolCoreTests
//
//  AIA-0992.
//

import Foundation
import HeadlessKit
import XCTest
@testable import ProjectToolCore

/// `exec`'s conversion of `name=value` text to the declared types, end to end through a real session:
/// the protocol takes native types only, so the command line asks the app first.
@MainActor
final class HeadlessCommandTypingTests: XCTestCase {

	private var driver: RecordingDriver!

	override func setUp() async throws {
		driver = RecordingDriver(InProcessDriver(session: HeadlessSession(application: TypedApp(), pollInterval: .milliseconds(5))))
	}

	override func tearDown() async throws {
		driver = nil
	}

	/// Parses and types `words`, then sends the result, as `exec` does.
	private func exec(_ words: [String]) async throws -> Response {
		let command = try await HeadlessCommandLine.typed(try HeadlessCommandLine.parse(words), via: driver)
		return try await driver.send(command)
	}

	func testPerformConvertsTextToTheDeclaredTypes() async throws {
		let response = try await exec(["perform", "record", "title=2024", "count=3", "loud=TRUE", "weight=0.5"])
		XCTAssertTrue(response.ok, "\(String(describing: response.error))")
		XCTAssertEqual(
			response.result,
			["title": "2024", "count": 3, "loud": true, "weight": 0.5],
			"title=2024 stays a string: it is declared one, whatever it looks like"
		)
		XCTAssertEqual(driver.sent.map(\.name), ["actions", "perform"])
	}

	func testWaitConvertsItsArgumentsAndKeepsTheTimeout() async throws {
		let response = try await exec(["wait", "count-at-least", "value=0", "timeout=2"])
		XCTAssertTrue(response.ok, "\(String(describing: response.error))")
		XCTAssertEqual(driver.sent.map(\.name), ["help", "wait"])
		XCTAssertEqual(driver.sent.last, .wait(condition: "count-at-least", arguments: ["value": 0], timeout: 2))
	}

	func testTheBuiltInRouteConditionKeepsItsText() async throws {
		let response = try await exec(["wait", "route", "route=home", "timeout=1"])
		XCTAssertTrue(response.ok, "\(String(describing: response.error))")
		XCTAssertEqual(driver.sent.last, .wait(condition: "route", arguments: ["route": "home"], timeout: 1))
	}

	func testACommandWithoutArgumentsCostsNoExtraRequest() async throws {
		_ = try await exec(["perform", "noop"])
		_ = try await exec(["wait", "route", "timeout=1"])
		_ = try await exec(["state"])
		XCTAssertEqual(driver.sent.map(\.name), ["perform", "wait", "state"])
	}

	func testUndeclaredNamesStayTextForTheAppToRefuse() async throws {
		let unknownParameter = try await exec(["perform", "record", "colour=3"])
		XCTAssertEqual(driver.sent.last, .perform(action: "record", arguments: ["colour": "3"]))
		XCTAssertEqual(unknownParameter.error?.code, .invalidArgument)
		let unknownAction = try await exec(["perform", "fly", "height=3"])
		XCTAssertEqual(driver.sent.last, .perform(action: "fly", arguments: ["height": "3"]))
		XCTAssertEqual(unknownAction.error?.code, .unknownAction)
	}

	func testTextThatIsNotTheDeclaredTypeIsACommandLineError() async throws {
		for words in [
			["perform", "record", "count=three"],
			["perform", "record", "count=1.5"],
			["perform", "record", "loud=yes"],
			["perform", "record", "weight=nan"],
			["wait", "count-at-least", "value=x"]
		] {
			do {
				_ = try await exec(words)
				XCTFail("\(words) was sent")
			} catch let error as HeadlessCommandLine.Invalid {
				XCTAssertTrue(error.description.contains("must be"), error.description)
			}
		}
		XCTAssertFalse(driver.sent.contains { $0.name == "perform" || $0.name == "wait" }, "nothing unconverted reaches the app")
	}

	/// A JSON number is a `Double`: beyond 2^53 an `Int` would arrive rounded, as a different number.
	func testIntegersBeyondTheExactRangeAreRefused() throws {
		let count = [ParameterSpec("count", .integer)]
		XCTAssertEqual(
			try HeadlessCommandLine.typed(["count": "9007199254740991"], against: count, subject: "t"),
			["count": .number(9_007_199_254_740_991)]
		)
		XCTAssertEqual(
			try HeadlessCommandLine.typed(["count": "-9007199254740991"], against: count, subject: "t"),
			["count": .number(-9_007_199_254_740_991)]
		)
		for text in ["9007199254740992", "-9007199254740992", "9007199254740993"] {
			XCTAssertThrowsError(try HeadlessCommandLine.typed(["count": .string(text)], against: count, subject: "t"), text)
		}
	}
}

/// One screen with typed parameters, echoing what the session passed its handler.
@MainActor
private final class TypedApp: HeadlessApplication {
	func currentScreen() -> any HeadlessScreen { Screen() }

	func waitConditions() -> [WaitCondition] {
		[WaitCondition("count-at-least", summary: "Always at least zero.", parameters: [ParameterSpec("value", .integer)]) { arguments in
			try arguments.integer("value") <= 0
		}]
	}

	struct Screen: HeadlessScreen {
		var route: Route { "home" }

		func actions() -> [HeadlessAction] {
			[
				HeadlessAction(
					"record",
					summary: "Echoes its arguments.",
					parameters: [
						ParameterSpec("title", .string, required: false),
						ParameterSpec("count", .integer, required: false),
						ParameterSpec("loud", .boolean, required: false),
						ParameterSpec("weight", .number, required: false)
					]
				) { arguments in .object(arguments.values) },
				HeadlessAction("noop", summary: "Does nothing.") { _ in nil }
			]
		}
	}
}

/// Forwards to a driver and records every command sent through it.
@MainActor
private final class RecordingDriver: HeadlessDriving {
	private let inner: InProcessDriver
	private(set) var sent: [Command] = []

	init(_ inner: InProcessDriver) {
		self.inner = inner
	}

	func send(_ command: Command) async throws -> Response {
		sent.append(command)
		return try await inner.send(command)
	}
}
