//
//  HeadlessSessionTests.swift
//  HeadlessKitTests
//
//  AIA-0970.
//

import Foundation
import XCTest
@testable import HeadlessKit

@MainActor
final class HeadlessSessionTests: XCTestCase {

	private var app: CounterApp!
	private var session: HeadlessSession!
	private var nextID = 0

	override func setUp() async throws {
		app = CounterApp()
		session = HeadlessSession(application: app, defaultWaitTimeout: .seconds(2), pollInterval: .milliseconds(5))
	}

	override func tearDown() async throws {
		app = nil
		session = nil
	}

	private func send(_ command: Command) async -> Response {
		nextID += 1
		return await session.handle(Request(id: String(nextID), command: command))
	}

	// MARK: - Describing

	func testEveryResponseDescribesTheCurrentScreen() async {
		let response = await send(.state)
		XCTAssertTrue(response.ok)
		XCTAssertEqual(response.id, "1")
		XCTAssertEqual(response.route, "home")
		XCTAssertEqual(response.state, ["count": 0])
		XCTAssertEqual(response.context, ["count": 0, "drawerOpen": false])
		XCTAssertEqual(response.actions.first?.name, "open-drawer")
		XCTAssertEqual(response.actions.first?.navigatesTo, "drawer")
	}

	func testHelpListsBuiltInAndAppConditions() async {
		let response = await send(.help)
		let names = response.result?.value(at: "/conditions")?.arrayValue?.compactMap { $0.value(at: "/name")?.stringValue }
		XCTAssertEqual(names, ["route", "count-at-least"])
	}

	// MARK: - perform

	func testPerformRunsTheHandlerAndReportsTheStateAfterIt() async {
		let response = await send(.perform(action: "increment", arguments: ["by": 3]))
		XCTAssertTrue(response.ok, "\(String(describing: response.error))")
		XCTAssertEqual(response.result, ["count": 3])
		XCTAssertEqual(response.state, ["count": 3])
	}

	func testPerformValidatesArgumentsBeforeTheHandlerRuns() async {
		let unknown = await send(.perform(action: "increment", arguments: ["bye": 1]))
		XCTAssertEqual(unknown.error?.code, .invalidArgument)
		let missing = await send(.perform(action: "rename", arguments: [:]))
		XCTAssertEqual(missing.error?.code, .invalidArgument)
		let wrongType = await send(.perform(action: "rename", arguments: ["name": "x", "loud": "maybe"]))
		XCTAssertEqual(wrongType.error?.code, .invalidArgument)
		XCTAssertEqual(app.count, 0)
	}

	func testPerformPassesOnlyDeclaredArguments() async {
		let response = await send(.perform(action: "rename", arguments: ["name": "n", "loud": false, "weight": 2]))
		XCTAssertEqual(response.result?.value(at: "/arguments"), ["name": "n", "loud": false, "weight": 2])
	}

	func testAnActionNotOfferedHereIsUnknown() async {
		let response = await send(.perform(action: "close", arguments: [:]))
		XCTAssertEqual(response.error?.code, .unknownAction)
		XCTAssertTrue(response.error?.message.contains("open-drawer") == true, "the error lists what is available")
	}

	func testHandlerErrorsKeepTheirCodeOrBecomeActionFailed() async {
		let coded = await send(.perform(action: "reject", arguments: [:]))
		XCTAssertEqual(coded.error, HeadlessError(.invalidArgument, "not today"))
		let arbitrary = await send(.perform(action: "crash", arguments: [:]))
		XCTAssertEqual(arbitrary.error?.code, .actionFailed)
		XCTAssertEqual(arbitrary.route, "home", "a failure still reports the screen")
	}

	func testADeclaredTransitionThatDoesNotArriveFails() async {
		let response = await send(.perform(action: "broken-transition", arguments: [:]))
		XCTAssertEqual(response.error?.code, .actionFailed)
		XCTAssertEqual(
			response.error?.message,
			"'broken-transition' declares a transition to 'about' but the app shows 'home'",
			"the declared route passes the map check and fails on arrival"
		)
		XCTAssertEqual(response.route, "home")
	}

	// MARK: - goto

	func testGotoTakesTheOneTransitionThatLeadsThere() async {
		let response = await send(.goto("drawer"))
		XCTAssertTrue(response.ok)
		XCTAssertEqual(response.route, "drawer")
		XCTAssertEqual(app.performed, ["open-drawer"])
	}

	func testGotoToTheCurrentRouteDoesNothing() async {
		let response = await send(.goto("home"))
		XCTAssertTrue(response.ok)
		XCTAssertEqual(app.performed, [])
	}

	func testGotoCannotTeleport() async {
		let response = await send(.goto("settings"))
		XCTAssertEqual(response.error?.code, .unreachable, "settings is reachable only from the drawer")
		XCTAssertEqual(response.route, "home")
	}

	func testGotoRefusesToChooseBetweenTransitions() async {
		_ = await send(.goto("drawer"))
		let response = await send(.goto("settings"))
		XCTAssertEqual(response.error?.code, .unreachable)
		XCTAssertTrue(response.error?.message.contains("settings-from-header") == true)
	}

	func testGotoRefusesATransitionThatNeedsArguments() async {
		_ = await send(.goto("drawer"))
		let response = await send(.goto("profile"))
		XCTAssertEqual(response.error?.code, .unreachable)
	}

	// MARK: - wait

	func testWaitReturnsOnceTheConditionHolds() async {
		_ = await send(.perform(action: "increment-later", arguments: [:]))
		let response = await send(.wait(condition: "count-at-least", arguments: ["value": 1], timeout: nil))
		XCTAssertTrue(response.ok, "\(String(describing: response.error))")
		XCTAssertEqual(response.state, ["count": 1])
	}

	func testWaitTimesOutWithACode() async {
		let response = await send(.wait(condition: "count-at-least", arguments: ["value": 5], timeout: 0.05))
		XCTAssertEqual(response.error?.code, .timeout)
	}

	func testTheBuiltInRouteCondition() async {
		let now = await send(.wait(condition: "route", arguments: ["route": "home"], timeout: 0.05))
		XCTAssertTrue(now.ok)
		let never = await send(.wait(condition: "route", arguments: ["route": "drawer"], timeout: 0.05))
		XCTAssertEqual(never.error?.code, .timeout)
	}

	func testWaitRejectsUnknownConditionsAndBadTimeouts() async {
		let unknown = await send(.wait(condition: "sunrise", arguments: [:], timeout: nil))
		XCTAssertEqual(unknown.error?.code, .unknownCondition)
		for timeout in [0, -1, 601, 1e30, .infinity, .nan] as [Double] {
			let response = await send(.wait(condition: "route", arguments: ["route": "home"], timeout: timeout))
			XCTAssertEqual(response.error?.code, .invalidArgument, "timeout \(timeout)")
		}
	}

	// MARK: - Ordering

	func testCommandsRunOneAtATimeInArrivalOrder() async {
		let session: HeadlessSession = self.session
		let slow = Task { await session.handle(Request(id: "a", command: .perform(action: "increment-slowly", arguments: [:]))) }
		// Main-actor jobs run in order, so yielding lets `slow` enter `handle`, whose chaining is
		// synchronous: from then on the next request is queued behind it, wherever it has got to.
		await Task.yield()
		XCTAssertEqual(app.count, 0, "precondition: the first command is still in flight")
		let observed = await session.handle(Request(id: "b", command: .state))
		let first = await slow.value
		XCTAssertEqual(first.state, ["count": 1])
		XCTAssertEqual(observed.state, ["count": 1], "the second command must not see the first half-done")
	}

	func testRejectDescribesTheScreenToo() {
		let response = session.reject(id: "x", error: HeadlessError(.malformedRequest, "bad"))
		XCTAssertFalse(response.ok)
		XCTAssertEqual(response.route, "home")
	}

	func testInProcessDriverNumbersRequests() async throws {
		let driver = InProcessDriver(session: session)
		let first = try await driver.send(.state)
		let second = try await driver.send(.state)
		XCTAssertEqual([first.id, second.id], ["1", "2"])
	}
}
