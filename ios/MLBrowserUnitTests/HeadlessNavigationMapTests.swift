//
//  HeadlessNavigationMapTests.swift
//  MLBrowserUnitTests
//
//  AIA-0982, AIA-0983.
//

import Foundation
import HeadlessKit
import XCTest
@testable import ML_Browser

/// The states `HeadlessRouteDecision` can take in the running app — the enumeration the map's sheet
/// exits are checked against, and the invariant the in-process walk holds every state it visits to.
///
/// Written as code with its reasons, so a new input or a new way to present a sheet has to decide
/// here whether it widens what is reachable.
enum HeadlessReachableStates {

	/// Why `decision` cannot occur in the app, or `nil` when it can.
	static func violation(of decision: HeadlessRouteDecision) -> String? {
		// Nothing is decided before `AppState` is ready: the route is `launching` whatever else holds.
		guard decision.isReady else { return "not ready" }
		// The account screen and the findings list are the drawer's sheets; closing the drawer by any
		// path dismisses them (`HeadlessPresentation.dismissSheetsIfDrawerClosed`).
		if decision.isDrawerOpen == false && (decision.isAccountPresented || decision.isFindingsPresented) {
			return "a drawer sheet is up with the drawer closed"
		}
		// Each is opened from the drawer itself, which the other covers.
		if decision.isAccountPresented && decision.isFindingsPresented {
			return "the account screen and the findings list are both up"
		}
		// `pick` is offered only on home, and the save sheet offers no way to the drawer.
		if decision.isSaveFindingPresented && decision.isDrawerOpen {
			return "the save sheet is up over the open drawer"
		}
		return nil
	}

	/// Every combination of the decision's inputs that `violation(of:)` allows. The Welcome screens and
	/// the gate displays each contribute every case; a free-access prompt's days and date do not
	/// affect the route, so one stands for all.
	static var all: [HeadlessRouteDecision] {
		let displays: [RootGateDisplay] = [.content, .wall, .wallOverContent, .hold]
		let welcomes: [WelcomePresentation?] = [
			nil,
			.freeAccess(FreeAccessPrompt(days: 14, endsOn: Date(timeIntervalSince1970: 0))),
			.introduction
		]
		let consents: [AnalyticsConsentPresentation] = [.pending, .ask, .resolved, .unavailable]
		let flagCount = 9
		var states: [HeadlessRouteDecision] = []
		for display in displays {
			for welcome in welcomes {
				for consent in consents {
					for bits in 0..<(1 << flagCount) {
						let flag = { (index: Int) in bits & (1 << index) != 0 }
						let decision = HeadlessRouteDecision(
							isReady: true,
							display: display,
							presentedWelcome: welcome,
							isDay0AcknowledgementPending: flag(0),
							isTourPendingOrRunning: flag(1),
							consentPresentation: consent,
							isAskDeferredAfterSignOut: flag(2),
							isDrawerOpen: flag(3),
							hasEverShownAnalyticsContent: flag(4),
							isAccountPresented: flag(5),
							isSaveFindingPresented: flag(6),
							isFindingsPresented: flag(7),
							isBackupConsentPending: flag(8)
						)
						if violation(of: decision) == nil {
							states.append(decision)
						}
					}
				}
			}
		}
		return states
	}
}

/// The app's navigation map: its routes are `HeadlessRoute`'s, its sheet exits are exactly what
/// `HeadlessRouteDecision` can produce, and the checked-in copy the lint reads is the declaration.
final class HeadlessNavigationMapTests: XCTestCase {

	private let map = HeadlessNavigationMap.declaration

	/// Where the lint's copy lives in the repository, for the failure message.
	private static let checkedInPath = "ios/HeadlessScenarios/Map/navigation-map.json"

	// MARK: - Shape

	func test_theMapDeclaresEveryRoute_inDeclarationOrder() {
		XCTAssertEqual(map.routeNames.map(\.rawValue), HeadlessRoute.allCases.map(\.rawValue))
	}

	func test_everyTransition_leadsToAnotherRoute() {
		for declaration in map.routes {
			for transition in declaration.transitions {
				XCTAssertNotNil(
					HeadlessRoute(rawValue: transition.to.rawValue),
					"\(declaration.route) declares a transition to '\(transition.to)', which is not a route"
				)
				// An action that stays on its route is not a transition; declaring it would make `map`
				// report an edge that goes nowhere.
				XCTAssertNotEqual(
					transition.to,
					declaration.route,
					"\(declaration.route) declares a self-loop via \(transition.action ?? "no action")"
				)
			}
		}
	}

	func test_noTransitionIsDeclaredTwice() {
		for declaration in map.routes {
			let pairs = declaration.transitions.map { "\($0.action ?? "(on its own)") → \($0.to)" }
			XCTAssertEqual(pairs.count, Set(pairs).count, "\(declaration.route) declares a transition twice: \(pairs)")
		}
	}

	// MARK: - The checked-in copy

	/// `ios/HeadlessScenarios/Map/navigation-map.json` is what `headless.sh test --lint` checks
	/// scenarios against without a build. Read from the test bundle, where the target's Resources
	/// phase copies it: Xcode Cloud runs prebuilt tests without the checkout, so a missing resource
	/// fails here rather than skipping.
	func test_theCheckedInMap_isTheDeclaration() throws {
		let url = try XCTUnwrap(
			Bundle(for: Self.self).url(forResource: "navigation-map", withExtension: "json"),
			"navigation-map.json is missing from the test bundle — check MLBrowserUnitTests' Resources phase."
		)
		let regenerated = try Self.regeneratedFile()
		let checkedIn: NavigationMap?
		do {
			checkedIn = try HeadlessCoding.makeDecoder().decode(NavigationMap.self, from: Data(contentsOf: url))
		} catch {
			checkedIn = nil
		}
		guard checkedIn != map else { return }
		let written = FileManager.default.temporaryDirectory.appending(path: "navigation-map.json")
		try Data(regenerated.utf8).write(to: written)
		print("Regenerated navigation map written to \(written.path)")
		XCTFail(
			"""
			\(Self.checkedInPath) \(checkedIn == nil ? "could not be decoded" : "differs from HeadlessNavigationMap.declaration"). \
			Replace \(Self.checkedInPath) with the following (also written to \(written.path)):
			\(regenerated)
			"""
		)
	}

	/// The file's exact bytes: pretty-printed, sorted keys, unescaped slashes, a trailing newline.
	static func regeneratedFile() throws -> String {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
		let data = try encoder.encode(HeadlessNavigationMap.declaration)
		return String(decoding: data, as: UTF8.self) + "\n"
	}

	// MARK: - Sheet exits (Tier 1)

	/// Every reachable state showing a sheet closes to a route the map declares for that sheet's exit,
	/// and every declared exit is where some reachable state closes to: the map claims neither less
	/// nor more than `route(afterClosing:)` can do.
	func test_sheetExits_areExactlyWhereClosingASheetCanLand() {
		let exits: [HeadlessRoute: String] = [.account: "close", .findings: "close", .saveFinding: "cancel"]
		var produced: [HeadlessRoute: Set<String>] = [:]
		var undeclared: Set<String> = []
		for decision in HeadlessReachableStates.all {
			let sheet = decision.route
			guard let action = exits[sheet] else { continue }
			let landing = decision.route(afterClosing: sheet)
			produced[sheet, default: []].insert(landing.rawValue)
			if map.declares(action: action, from: Route(sheet.rawValue), to: Route(landing.rawValue)) == false {
				undeclared.insert("\(sheet.rawValue) --\(action)--> \(landing.rawValue) (e.g. \(decision))")
			}
		}
		XCTAssertTrue(undeclared.isEmpty, "Closing a sheet can land where the map does not say:\n\(undeclared.sorted().joined(separator: "\n"))")

		for (sheet, action) in exits {
			let declared = Set(
				map.declaration(for: Route(sheet.rawValue))?.transitions
					.filter { $0.action == action }
					.map(\.to.rawValue) ?? []
			)
			XCTAssertEqual(
				declared,
				produced[sheet] ?? [],
				"\(sheet.rawValue)'s declared '\(action)' exits differ from where a reachable state closes to"
			)
		}
	}

	/// The enumeration is not vacuous: each sheet is the route of some reachable state.
	func test_everySheet_isReachable() {
		let routes = Set(HeadlessReachableStates.all.map(\.route))
		XCTAssertTrue(routes.isSuperset(of: [.account, .findings, .saveFinding]))
	}
}
