//
//  TransitionTests.swift
//  HeadlessKitTests
//
//  AIA-0994.
//

import Foundation
import XCTest
@testable import HeadlessKit

/// Declared transitions are enforced on every action: the three tiers, one hop of the app's own
/// moves, the origin excluded from a declared transition, the switch that turns the hop off, and an
/// app without a map.
@MainActor
final class TransitionTests: XCTestCase {

	private var app: RouteApp!

	override func setUp() async throws {
		app = RouteApp()
	}

	override func tearDown() async throws {
		app = nil
	}

	private func perform(
		_ action: String,
		from origin: Route,
		landingOn landing: Route,
		appMoves: AppMoves = .oneHop
	) async -> Response {
		app.route = origin
		app.landing = landing
		let session = HeadlessSession(application: app, pollInterval: .milliseconds(5), appMoves: appMoves)
		return await session.handle(Request(id: "1", command: .perform(action: action, arguments: [:])))
	}

	private func assertAccepted(
		_ action: String,
		from origin: Route,
		landingOn landing: Route,
		appMoves: AppMoves = .oneHop,
		file: StaticString = #filePath,
		line: UInt = #line
	) async {
		let response = await perform(action, from: origin, landingOn: landing, appMoves: appMoves)
		XCTAssertTrue(response.ok, "\(action) on \(origin) → \(landing): \(String(describing: response.error))", file: file, line: line)
		XCTAssertEqual(response.route, landing, file: file, line: line)
	}

	private func assertRefused(
		_ action: String,
		from origin: Route,
		landingOn landing: Route,
		appMoves: AppMoves = .oneHop,
		message: String? = nil,
		file: StaticString = #filePath,
		line: UInt = #line
	) async {
		let response = await perform(action, from: origin, landingOn: landing, appMoves: appMoves)
		XCTAssertEqual(response.error?.code, .undeclaredTransition, "\(action) on \(origin) → \(landing)", file: file, line: line)
		if let message {
			XCTAssertEqual(response.error?.message, message, file: file, line: line)
		}
		XCTAssertEqual(response.route, landing, "the response still reports where the app is", file: file, line: line)
	}

	// MARK: - (i) navigatesTo

	func testANavigatesToActionMayLandOnItsTargetOrOneAppMovePast() async {
		await assertAccepted("close", from: "drawer", landingOn: "home")
		await assertAccepted("close", from: "drawer", landingOn: "paywall")
		await assertAccepted("close", from: "drawer", landingOn: "consent")
	}

	func testANavigatesToActionThatDoesNotMoveFails() async {
		await assertRefused(
			"close",
			from: "drawer",
			landingOn: "drawer",
			message: "'close' on 'drawer' landed on 'drawer'; declared: home; accepted after the app's own moves: paywall, consent"
		)
	}

	/// home → consent → deep is two of the app's own moves: one hop only.
	func testTwoAppMovesPastTheTargetFail() async {
		await assertRefused("close", from: "drawer", landingOn: "deep")
	}

	// MARK: - (ii) declared edges

	func testAnActionWithDeclaredEdgesMayLandOnAnyOfThemOrOneAppMovePast() async {
		await assertAccepted("continue", from: "welcome", landingOn: "home")
		await assertAccepted("continue", from: "welcome", landingOn: "tour")
		await assertAccepted("continue", from: "welcome", landingOn: "consent")
		await assertRefused(
			"continue",
			from: "welcome",
			landingOn: "sheet",
			message: "'continue' on 'welcome' landed on 'sheet'; declared: home, tour; accepted after the app's own moves: paywall, consent"
		)
	}

	func testAnActionWithDeclaredEdgesThatDoesNotMoveFails() async {
		await assertRefused("continue", from: "welcome", landingOn: "welcome")
	}

	/// `upgrade` leads to the paywall, and the paywall can give way to the drawer on its own; the
	/// drawer is still refused, because it is where `upgrade` started.
	func testTheOriginIsNeverAcceptedForADeclaredTransition() async {
		await assertAccepted("upgrade", from: "drawer", landingOn: "paywall")
		await assertAccepted("upgrade", from: "drawer", landingOn: "home")
		await assertRefused(
			"upgrade",
			from: "drawer",
			landingOn: "drawer",
			message: "'upgrade' on 'drawer' landed on 'drawer'; declared: paywall; accepted after the app's own moves: home"
		)
	}

	// MARK: - (iii) no edge

	func testAnActionWithoutAnEdgeStaysOrLetsTheAppMoveOnce() async {
		await assertAccepted("refresh", from: "drawer", landingOn: "drawer")
		await assertAccepted("refresh", from: "drawer", landingOn: "paywall")
		await assertRefused(
			"refresh",
			from: "drawer",
			landingOn: "home",
			message: "'refresh' on 'drawer' landed on 'home'; declared: none (stays on 'drawer'); accepted after the app's own moves: paywall"
		)
	}

	// MARK: - The switch

	func testWithAppMovesOffOnlyTheDeclarationCounts() async {
		await assertAccepted("close", from: "drawer", landingOn: "home", appMoves: .off)
		await assertRefused(
			"close",
			from: "drawer",
			landingOn: "paywall",
			appMoves: .off,
			message: "'close' on 'drawer' landed on 'paywall'; declared: home; accepted after the app's own moves: none (app moves off)"
		)
		await assertAccepted("refresh", from: "drawer", landingOn: "drawer", appMoves: .off)
		await assertRefused("refresh", from: "drawer", landingOn: "paywall", appMoves: .off)
		await assertRefused("continue", from: "welcome", landingOn: "consent", appMoves: .off)
	}

	func testTheSessionDefaultsToOneHop() {
		XCTAssertEqual(HeadlessSession(application: app).appMoves, .oneHop)
	}

	// MARK: - Other paths

	func testGotoIsHeldToTheSameRule() async {
		app.route = "home"
		app.landing = "paywall"
		let session = HeadlessSession(application: app, pollInterval: .milliseconds(5))
		let raced = await session.handle(Request(id: "1", command: .goto("drawer")))
		XCTAssertTrue(raced.ok, "the paywall arriving first is one of the app's own moves past the drawer")
		app.route = "home"
		app.landing = "tour"
		let drifted = await session.handle(Request(id: "2", command: .goto("drawer")))
		XCTAssertEqual(drifted.error?.code, .undeclaredTransition)
	}

	func testAHandlerThatThrowsIsNotChecked() async {
		app.route = "drawer"
		app.landing = "tour"
		app.fails = true
		let session = HeadlessSession(application: app, pollInterval: .milliseconds(5))
		let response = await session.handle(Request(id: "1", command: .perform(action: "close", arguments: [:])))
		XCTAssertEqual(response.error?.code, .actionFailed, "the handler's own failure is the answer")
	}

	/// No map: only a set `navigatesTo` is checked, exactly, as before maps existed.
	func testAnAppWithoutAMapChecksOnlyNavigatesTo() async {
		app.map = .empty
		await assertAccepted("close", from: "drawer", landingOn: "home")
		await assertRefused(
			"close",
			from: "drawer",
			landingOn: "paywall",
			message: "'close' on 'drawer' landed on 'paywall'; declared: home; accepted after the app's own moves: none (no navigation map)"
		)
		await assertAccepted("refresh", from: "drawer", landingOn: "tour")
		await assertAccepted("continue", from: "welcome", landingOn: "deep")
	}

	// MARK: - The map's parts

	func testAppMovesAreOneHopFromTheGivenRoutes() {
		let map = RouteApp.declaredMap
		XCTAssertEqual(map.appMoves(from: ["home"]), ["paywall", "consent"])
		XCTAssertEqual(map.appMoves(from: ["home", "consent"]), ["paywall", "consent", "deep"])
		XCTAssertEqual(map.appMoves(from: ["sheet"]), [])
		XCTAssertEqual(map.targets(of: "continue", from: "welcome"), ["tour", "home"])
		XCTAssertEqual(map.ordered(["zzz", "tour", "home"]), ["home", "tour", "zzz"])
	}
}

/// An app whose every action lands wherever the test says, over a map shaped like a real one.
@MainActor
private final class RouteApp: HeadlessApplication {

	var route: Route = "home"
	/// Where the next action leaves the app.
	var landing: Route = "home"
	/// Whether the next action's handler throws instead.
	var fails = false
	var map = RouteApp.declaredMap

	var navigationMap: NavigationMap { map }

	/// Declaration order: home, drawer, welcome, tour, paywall, consent, deep, sheet.
	static let declaredMap = NavigationMap(routes: [
		RouteDeclaration(route: "home", summary: "Home.", transitions: [
			TransitionDeclaration(action: "open-drawer", to: "drawer", condition: "Always."),
			TransitionDeclaration(action: nil, to: "paywall", condition: "Access ran out."),
			TransitionDeclaration(action: nil, to: "consent", condition: "A question.")
		]),
		RouteDeclaration(route: "drawer", summary: "Drawer.", transitions: [
			TransitionDeclaration(action: "close", to: "home", condition: "Always."),
			TransitionDeclaration(action: "upgrade", to: "paywall", condition: "Always."),
			TransitionDeclaration(action: nil, to: "paywall", condition: "Access ran out.")
		]),
		RouteDeclaration(route: "welcome", summary: "Welcome.", transitions: [
			TransitionDeclaration(action: "continue", to: "tour", condition: "Tour armed."),
			TransitionDeclaration(action: "continue", to: "home", condition: "Nothing owed.")
		]),
		RouteDeclaration(route: "tour", summary: "Tour."),
		RouteDeclaration(route: "paywall", summary: "Paywall.", transitions: [
			TransitionDeclaration(action: nil, to: "drawer", condition: "Subscribed, menu open."),
			TransitionDeclaration(action: nil, to: "home", condition: "Subscribed.")
		]),
		RouteDeclaration(route: "consent", summary: "Consent.", transitions: [
			TransitionDeclaration(action: nil, to: "deep", condition: "Two moves from home.")
		]),
		RouteDeclaration(route: "deep", summary: "Deep."),
		RouteDeclaration(route: "sheet", summary: "A sheet.")
	])

	func currentScreen() -> any HeadlessScreen {
		Screen(app: self)
	}

	/// Offers every action on every route; each moves the app to `landing`.
	struct Screen: HeadlessScreen {
		let app: RouteApp

		var route: Route { app.route }

		func actions() -> [HeadlessAction] {
			let app = app
			func action(_ name: String, navigatesTo: Route? = nil) -> HeadlessAction {
				HeadlessAction(name, summary: name, navigatesTo: navigatesTo) { _ in
					struct Failure: Error {}
					if app.fails { throw Failure() }
					app.route = app.landing
					return nil
				}
			}
			switch app.route {
			case "home": return [action("open-drawer", navigatesTo: "drawer")]
			case "drawer": return [action("close", navigatesTo: "home"), action("upgrade"), action("refresh")]
			case "welcome": return [action("continue")]
			default: return []
			}
		}
	}
}
