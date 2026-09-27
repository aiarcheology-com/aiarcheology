//
//  NavigationMapTests.swift
//  HeadlessKitTests
//
//  AIA-0982, AIA-0983.
//

import Foundation
import XCTest
@testable import HeadlessKit

@MainActor
final class NavigationMapTests: XCTestCase {

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

	private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
		try HeadlessCoding.makeDecoder().decode(type, from: Data(json.utf8))
	}

	private func encode<T: Encodable>(_ value: T) throws -> String {
		try XCTUnwrap(String(bytes: HeadlessCoding.makeEncoder().encode(value), encoding: .utf8))
	}

	/// The `map` result's transitions of `route`, by action name.
	private func transitions(of route: String, in result: JSONValue?) -> [String: JSONValue] {
		let routes = result?.value(at: "/routes")?.arrayValue ?? []
		let declaration = routes.first { $0.value(at: "/route") == .string(route) }
		var byAction: [String: JSONValue] = [:]
		for transition in declaration?.value(at: "/transitions")?.arrayValue ?? [] {
			byAction[transition.value(at: "/action")?.stringValue ?? "(automatic)"] = transition
		}
		return byAction
	}

	// MARK: - The wire

	func testTheMapRequestRoundTripsWithNoExtraKeys() throws {
		let request = Request(id: "7", command: .map)
		XCTAssertEqual(try encode(request), #"{"command":"map","id":"7"}"#)
		XCTAssertEqual(try decode(Request.self, try encode(request)), request)
		XCTAssertEqual(Command.map.name, "map")
	}

	func testTheUnknownCommandTextListsMap() {
		XCTAssertThrowsError(try decode(Request.self, #"{"id":"1","command":"teleport"}"#)) { error in
			XCTAssertEqual((error as? HeadlessError)?.code, .unknownCommand)
			XCTAssertTrue((error as? HeadlessError)?.message.contains("map") == true, "\(error)")
		}
	}

	func testServerHelloCarriesRoutesOnlyWhenDeclared() throws {
		let declared = ServerHello(metadata: ["app": "x"], routes: ["home", "drawer"])
		XCTAssertEqual(
			try encode(declared),
			#"{"metadata":{"app":"x"},"protocolVersion":\#(HeadlessProtocol.version),"routes":["home","drawer"]}"#
		)
		XCTAssertEqual(try decode(ServerHello.self, try encode(declared)), declared)

		let undeclared = ServerHello(metadata: [:])
		XCTAssertFalse(try encode(undeclared).contains("routes"), "an absent list is absent, not null")
		let old = try decode(ServerHello.self, #"{"protocolVersion":1,"metadata":{"app":"x"}}"#)
		XCTAssertNil(old.routes, "a hello from before routes existed still decodes")
		XCTAssertEqual(old.metadata, ["app": "x"])
	}

	func testTheSessionHelloAndDriverReportTheDeclaredRoutes() async {
		XCTAssertEqual(session.serverHello.routes, ["home", "drawer", "settings", "profile", "about"])
		let driver = InProcessDriver(session: session)
		let routes = await driver.declaredRoutes()
		XCTAssertEqual(routes, CounterApp.declaredMap.routeNames)
		app.navigationMap = .empty
		XCTAssertNil(session.serverHello.routes)
		let none = await driver.declaredRoutes()
		XCTAssertNil(none)
	}

	func testHelpListsMap() async {
		let response = await send(.help)
		let commands = response.result?.value(at: "/commands")?.arrayValue?.compactMap(\.stringValue)
		XCTAssertTrue(commands?.contains("map") == true, "\(String(describing: commands))")
	}

	// MARK: - The map command

	func testMapDescribesPossibleTransitionsAndWhichAreOpenNow() async {
		let response = await send(.map)
		XCTAssertTrue(response.ok, "\(String(describing: response.error))")
		XCTAssertEqual(response.route, "home", "the usual screen comes with the map")
		XCTAssertEqual(response.state, ["count": 0])
		let result = response.result
		XCTAssertEqual(result?.value(at: "/guarantee"), "possible")
		XCTAssertNotNil(result?.value(at: "/note")?.stringValue)
		XCTAssertEqual(result?.value(at: "/current"), "home")
		XCTAssertEqual(
			result?.value(at: "/routes")?.arrayValue?.compactMap { $0.value(at: "/route")?.stringValue },
			["home", "drawer", "settings", "profile", "about"]
		)
		XCTAssertEqual(result?.value(at: "/routes/0/current"), true)
		XCTAssertEqual(result?.value(at: "/routes/1/current"), false)
		XCTAssertEqual(result?.value(at: "/routes/0/summary"), "The counter.")

		let home = transitions(of: "home", in: result)
		XCTAssertEqual(home["open-drawer"], ["action": "open-drawer", "to": "drawer", "condition": "Always.", "open": true])
		XCTAssertEqual(home["broken-transition"]?.value(at: "/open"), true, "offered now and declared to lead there")
		let drawer = transitions(of: "drawer", in: result)
		XCTAssertNil(drawer["close"]?.value(at: "/open"), "only the current route's transitions are open")
		XCTAssertEqual(result?.value(at: "/undeclared"), [])

		_ = await send(.goto("drawer"))
		let moved = await send(.map)
		XCTAssertEqual(moved.result?.value(at: "/current"), "drawer")
		XCTAssertEqual(transitions(of: "drawer", in: moved.result)["close"]?.value(at: "/open"), true)
		XCTAssertNil(transitions(of: "home", in: moved.result)["open-drawer"]?.value(at: "/open"))
	}

	func testAnActionWithoutADestinationIsAvailableNotOpen() async {
		app.navigationMap = NavigationMap(routes: [
			RouteDeclaration(route: "home", summary: "", transitions: [
				TransitionDeclaration(action: "open-drawer", to: "drawer", condition: "Always."),
				TransitionDeclaration(action: "broken-transition", to: "about", condition: "Always."),
				// `increment` offers no `navigatesTo`: where it leads is decided when it runs.
				TransitionDeclaration(action: "increment", to: "drawer", condition: "Only in this test."),
				TransitionDeclaration(action: "close", to: "home", condition: "Not offered here."),
				TransitionDeclaration(action: nil, to: "drawer", condition: "On its own.")
			]),
			RouteDeclaration(route: "drawer", summary: ""),
			RouteDeclaration(route: "about", summary: "")
		])
		let home = transitions(of: "home", in: await send(.map).result)
		XCTAssertEqual(home["increment"]?.value(at: "/available"), true)
		XCTAssertNil(home["increment"]?.value(at: "/open"))
		XCTAssertNil(home["close"]?.value(at: "/open"), "an action not offered now is neither open nor available")
		XCTAssertNil(home["close"]?.value(at: "/available"))
		XCTAssertEqual(home["(automatic)"], ["to": "drawer", "condition": "On its own."],
			"a transition the app takes by itself is never open or available")
	}

	func testUndeclaredListsLiveTransitionsTheMapLacks() async {
		// (a) `broken-transition` is missing; (b) `open-drawer` is declared under another name, to
		// the same target — the pair is what counts, so the live action is still undeclared.
		app.navigationMap = NavigationMap(routes: [
			RouteDeclaration(route: "home", summary: "", transitions: [
				TransitionDeclaration(action: "show-drawer", to: "drawer", condition: "Always.")
			]),
			RouteDeclaration(route: "drawer", summary: ""),
			RouteDeclaration(route: "about", summary: "")
		])
		let result = await send(.map).result
		XCTAssertEqual(result?.value(at: "/undeclared"), [
			["action": "open-drawer", "to": "drawer"],
			["action": "broken-transition", "to": "about"]
		])
		XCTAssertNil(transitions(of: "home", in: result)["show-drawer"]?.value(at: "/open"))
	}

	func testAnAppWithoutAMapStillAnswersMap() async {
		app.navigationMap = .empty
		let result = await send(.map).result
		XCTAssertEqual(result?.value(at: "/routes"), [])
		XCTAssertEqual(result?.value(at: "/current"), "home")
		XCTAssertEqual(result?.value(at: "/undeclared"), [
			["action": "open-drawer", "to": "drawer"],
			["action": "broken-transition", "to": "about"]
		], "every live transition, and nothing that is not one")
	}

	// MARK: - Rejecting undeclared routes

	func testGotoAnUndeclaredRouteFailsWithASuggestion() async {
		let response = await send(.goto("drawr"))
		XCTAssertEqual(response.error?.code, .invalidArgument)
		XCTAssertEqual(
			response.error?.message,
			"unknown route 'drawr'; did you mean 'drawer'? (known: home, drawer, settings, profile, about)"
		)
		XCTAssertEqual(app.performed, [])
	}

	func testGotoTheCurrentRouteIsStillCheckedFirst() async {
		app.navigationMap = NavigationMap(routes: [RouteDeclaration(route: "drawer", summary: "")])
		let response = await send(.goto("home"))
		XCTAssertEqual(response.error?.code, .invalidArgument, "the check runs before 'already there'")
	}

	func testWaitForAnUndeclaredRouteFailsAtOnce() async {
		let clock = ContinuousClock()
		let started = clock.now
		let response = await send(.wait(condition: "route", arguments: ["route": "hme"], timeout: 5))
		let elapsed = clock.now - started
		XCTAssertEqual(response.error?.code, .invalidArgument)
		XCTAssertEqual(response.error?.message.hasPrefix("unknown route 'hme'; did you mean 'home'?"), true,
			String(describing: response.error))
		XCTAssertLessThan(elapsed, .seconds(1), "rejected before polling, not after the timeout")
	}

	func testWaitStillValidatesItsArgumentsFirst() async {
		let response = await send(.wait(condition: "route", arguments: [:], timeout: 5))
		XCTAssertEqual(response.error?.code, .invalidArgument)
		XCTAssertEqual(response.error?.message, "condition 'route' requires 'route'")
	}

	func testWithoutAMapUnknownRoutesBehaveAsBefore() async {
		app.navigationMap = .empty
		let goto = await send(.goto("nowhere"))
		XCTAssertEqual(goto.error?.code, .unreachable)
		let wait = await send(.wait(condition: "route", arguments: ["route": "nowhere"], timeout: 0.05))
		XCTAssertEqual(wait.error?.code, .timeout)
	}

	// MARK: - Suggestions

	func testClosestIsCaseInsensitiveAndTiesGoToTheFirstDeclared() {
		let map = NavigationMap(routes: ["launching", "gate", "home", "drawer", "hole"].map {
			RouteDeclaration(route: Route($0), summary: "")
		})
		XCTAssertEqual(map.closest(to: "hme"), "home")
		XCTAssertEqual(map.closest(to: "DRAWR"), "drawer")
		XCTAssertEqual(map.closest(to: "hoe"), "home", "home and hole are both one edit away; home is declared first")
		XCTAssertEqual(map.closest(to: ""), "gate", "the shortest route is closest to nothing")
		XCTAssertNil(NavigationMap.empty.closest(to: "home"))
		XCTAssertEqual(NavigationMap.closest(to: "gat", among: ["gate"]), "gate")
	}

	func testTheMapIsCodableAndAnswersQuestions() throws {
		let map = CounterApp.declaredMap
		let json = try encode(map)
		XCTAssertEqual(try decode(NavigationMap.self, json), map)
		XCTAssertFalse(json.contains("null"))
		XCTAssertTrue(map.declares(action: "open-drawer", from: "home", to: "drawer"))
		XCTAssertFalse(map.declares(action: "open-drawer", from: "home", to: "about"))
		XCTAssertFalse(map.declares(action: "open-drawer", from: "drawer", to: "drawer"))
		XCTAssertEqual(map.declaration(for: "drawer")?.transitions.count, 4)
		XCTAssertNil(map.declaration(for: "nowhere"))
		XCTAssertTrue(NavigationMap.empty.isEmpty)

		let automatic = TransitionDeclaration(action: nil, to: "home", condition: "Once ready.")
		let automaticJSON = try encode(automatic)
		XCTAssertEqual(automaticJSON, #"{"condition":"Once ready.","to":"home"}"#, "no action key, not null")
		XCTAssertEqual(try decode(TransitionDeclaration.self, automaticJSON), automatic)
	}
}
