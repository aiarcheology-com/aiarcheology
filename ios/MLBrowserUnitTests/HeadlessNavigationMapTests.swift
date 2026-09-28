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
		// path dismisses them (`AppChromeState.presentedSideMenu` → `DrawerPresentation.dismissSheets`).
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
		// The sign-in offer follows a save, so the menu is closed, and it offers no way to the drawer.
		if decision.isSignInOfferPresented && decision.isDrawerOpen {
			return "the sign-in offer is up over the open drawer"
		}
		// It is raised once the save sheet has closed, and nothing raises the save sheet over it.
		if decision.isSignInOfferPresented && decision.isSaveFindingPresented {
			return "the sign-in offer and the save sheet are both up"
		}
		// The root gate raises a Welcome screen only while it shows the app proper, and lowers it as
		// soon as it stops (`canPresentPromptChanged`); the headless application reconciles the gate
		// before every decision.
		if decision.presentedWelcome != nil && decision.display != .content {
			return "a Welcome screen is raised while the gate does not show the app proper"
		}
		// The hold and the wall come only before the app proper has ever shown
		// (`RootGateDisplay.resolve`), so nothing of it has been opened or rendered yet.
		let isSheetUp = decision.isAccountPresented || decision.isFindingsPresented || decision.isSaveFindingPresented
			|| decision.isSignInOfferPresented
		if (decision.display == .hold || decision.display == .wall)
			&& (decision.isDrawerOpen || isSheetUp || decision.hasEverShownAnalyticsContent) {
			return "the app proper is open behind a gate that has never shown it"
		}
		// A sheet is raised only from the app proper (`pick` on home, `save` for the sign-in offer, the
		// drawer's `open-account` and `open-findings`), which a Welcome screen, the tour and the consent question cover. None of
		// them is raised over a sheet by a modelled flow: the tour is armed only at launch, and the one
		// path that raises the question mid-session, `sign-in`, closes the account screen first.
		let isConsentOnScreen = decision.analyticsDisplay != .content || AnalyticsChoiceDisplay.asksOverContent(
			presentation: decision.consentPresentation,
			hasEverShownContent: decision.hasEverShownAnalyticsContent,
			isAskDeferred: decision.isAskDeferred
		)
		if isSheetUp && (decision.presentedWelcome != nil || decision.isTourPendingOrRunning || isConsentOnScreen) {
			return "a sheet is up under a Welcome screen, the tour or the consent question"
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
		let flagCount = 10
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
							isSignInOfferPresented: flag(9),
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

	// MARK: - Action names are scoped to their screen (AIA-0992)

	/// An action name means something only on the screen that offers it. A client reads `actions`,
	/// and before it performs one the app may move on its own; if the new screen offered an action of
	/// the same name, the client would run that one instead of failing with `unknownAction`. So two
	/// routes joined by an action-less edge, in either direction, must not share an action name.
	///
	/// Returns one line per shared name, e.g. `drawer <-> consent share 'close'`; empty when none.
	static func actionNamesSharedAcrossAppMoves(offered: [Route: Set<String>], in map: NavigationMap) -> [String] {
		var pairs: Set<[Route]> = []
		for declaration in map.routes {
			for transition in declaration.transitions where transition.action == nil {
				pairs.insert([declaration.route, transition.to].sorted { $0.rawValue < $1.rawValue })
			}
		}
		return pairs.sorted { $0.map(\.rawValue).joined() < $1.map(\.rawValue).joined() }.compactMap { pair in
			let shared = offered[pair[0], default: []].intersection(offered[pair[1], default: []])
			guard shared.isEmpty == false else { return nil }
			return "\(pair[0]) <-> \(pair[1]) share \(shared.sorted().map { "'\($0)'" }.joined(separator: ", "))"
		}
	}

	/// Every route's action names, as far as the map declares them: the actions that leave the route.
	/// `HeadlessWalkTests` adds the ones that stay (`enable`, `detect-image`, `refresh`, …).
	static func declaredActionNames(in map: NavigationMap) -> [Route: Set<String>] {
		var names: [Route: Set<String>] = [:]
		for declaration in map.routes {
			names[declaration.route] = Set(declaration.transitions.compactMap(\.action))
		}
		return names
	}

	func test_routesJoinedByAMoveOnTheAppsOwn_shareNoActionName() {
		let shared = Self.actionNamesSharedAcrossAppMoves(offered: Self.declaredActionNames(in: map), in: map)
		XCTAssertTrue(
			shared.isEmpty,
			"An app move between these routes would make an action name mean another action:\n" + shared.joined(separator: "\n")
		)
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
		return try XCTUnwrap(String(bytes: data, encoding: .utf8)) + "\n"
	}

	// MARK: - Sheet exits (Tier 1)

	/// Every reachable state showing a sheet closes to a route the map declares for that sheet's exit,
	/// and every declared exit is where some reachable state closes to, or one of the exit's own extra
	/// landings: the map claims neither less nor more than `route(afterClosing:)` can do.
	///
	/// `save` closes the save sheet like `cancel`, so its exits include every landing of
	/// `route(afterClosing: .saveFinding)`. It may also land on `backup-consent` on its own account: the
	/// sync the save starts can raise the back-up question. And on `account`: the first signed-out save
	/// raises the sign-in offer.
	func test_sheetExits_areExactlyWhereClosingASheetCanLand() {
		let exits: [(sheet: HeadlessRoute, action: String, extra: Set<String>)] = [
			(.account, "close", []),
			(.findings, "close", []),
			(.saveFinding, "cancel", []),
			(.saveFinding, "save", [HeadlessRoute.backupConsent.rawValue, HeadlessRoute.account.rawValue])
		]
		var produced: [HeadlessRoute: Set<String>] = [:]
		var undeclared: Set<String> = []
		for decision in HeadlessReachableStates.all {
			let sheet = decision.route
			let actions = exits.filter { $0.sheet == sheet }.map(\.action)
			guard actions.isEmpty == false else { continue }
			let landing = decision.route(afterClosing: sheet)
			produced[sheet, default: []].insert(landing.rawValue)
			for action in actions where map.declares(action: action, from: Route(sheet.rawValue), to: Route(landing.rawValue)) == false {
				undeclared.insert("\(sheet.rawValue) --\(action)--> \(landing.rawValue) (e.g. \(decision))")
			}
		}
		XCTAssertTrue(undeclared.isEmpty, "Closing a sheet can land where the map does not say:\n\(undeclared.sorted().joined(separator: "\n"))")

		for (sheet, action, extra) in exits {
			let declared = Set(
				map.declaration(for: Route(sheet.rawValue))?.transitions
					.filter { $0.action == action }
					.map(\.to.rawValue) ?? []
			)
			XCTAssertEqual(
				declared,
				(produced[sheet] ?? []).union(extra),
				"\(sheet.rawValue)'s declared '\(action)' exits differ from where a reachable state closes to"
			)
		}
	}

	// MARK: - Moves on the app's own (Tier 1)

	/// Declared moves on the app's own that no modelled input change produces, each with the reason.
	/// Every other action-less edge must be produced by `automaticMoves`.
	private static let unmodelledMoves: [String: String] = [
		"gate --> welcome": "the gate raises the owed Welcome screen in the same reconcile that lifts the hold: "
			+ "a second input change in one decision. HeadlessWalkTests' fresh install walks it.",
		"consent --> home": "the held question's scope resolving (consentPresentation leaving .pending) is not modelled: "
			+ "how it resolves depends on the account a sign-in brings.",
		"consent --> drawer": "as consent --> home, over the open menu after a sign-in.",
		"drawer --> consent": "as consent --> home: a sign-in's scope resolving to an unanswered question, once the "
			+ "account screen has closed onto the drawer.",
		"home --> consent": "as drawer --> consent, once the sign-in offer has closed onto home."
	]

	/// Every state change the app makes by itself, from each reachable state it can happen in: access
	/// running out or returning, the free-access window read after the hold, a sync raising the
	/// back-up question, and `AppState` becoming ready.
	private static func automaticMoves() -> [(change: String, from: HeadlessRouteDecision, to: HeadlessRouteDecision)] {
		var moves: [(change: String, from: HeadlessRouteDecision, to: HeadlessRouteDecision)] = []
		for state in HeadlessReachableStates.all {
			func change(_ name: String, _ body: (inout HeadlessRouteDecision) -> Void) {
				var next = state
				body(&next)
				moves.append((name, state, next))
			}
			switch state.display {
			case .content:
				// Once the app proper has shown, a closed window lays the wall over it, never swaps it.
				change("access ran out") { $0.display = .wallOverContent }
			case .wall, .wallOverContent:
				change("access returned") { $0.display = .content }
			case .hold:
				// `.wallOverContent` cannot follow the hold, which only precedes the app proper ever
				// showing; it is included anyway and adds no move of its own.
				for display in [RootGateDisplay.content, .wall, .wallOverContent] {
					change("the hold lifted to \(display)") { $0.display = display }
				}
			}
			if state.isBackupConsentPending == false {
				change("a sync raised the back-up question") { $0.isBackupConsentPending = true }
			}
			// The first ready decision: nothing of the app proper was open, the analytics gate has not
			// rendered, and the gate has never shown content. A back-up question may already be pending:
			// sync starts once the store opens, not once `AppState` is ready.
			let isSheetUp = state.isAccountPresented || state.isFindingsPresented || state.isSaveFindingPresented
				|| state.isSignInOfferPresented
			if state.isDrawerOpen == false && isSheetUp == false && state.hasEverShownAnalyticsContent == false
				&& state.display != .wallOverContent {
				var launching = state
				launching.isReady = false
				moves.append(("AppState became ready", launching, state))
			}
		}
		return moves
	}

	/// Whenever the app moves from one route to another on its own, the map declares that action-less
	/// edge; and every declared action-less edge is produced by some modelled change or explained in
	/// `unmodelledMoves`.
	func test_movesOnTheAppsOwn_areExactlyTheDeclaredActionlessEdges() {
		var produced: [String: String] = [:]
		for move in Self.automaticMoves() {
			let from = move.from.route, to = move.to.route
			guard from != to else { continue }
			let edge = "\(from.rawValue) --> \(to.rawValue)"
			if produced[edge] == nil {
				produced[edge] = "\(move.change), e.g. from \(move.from)"
			}
		}
		let declared = Set(map.routes.flatMap { declaration in
			declaration.transitions.filter { $0.action == nil }.map { "\(declaration.route.rawValue) --> \($0.to.rawValue)" }
		})

		let undeclared = produced.filter { declared.contains($0.key) == false }
		XCTAssertTrue(
			undeclared.isEmpty,
			"The app can move on its own where the map does not say:\n"
				+ undeclared.sorted { $0.key < $1.key }.map { "\($0.key) (\($0.value))" }.joined(separator: "\n")
		)
		let unexplained = declared.subtracting(produced.keys).subtracting(Self.unmodelledMoves.keys)
		XCTAssertTrue(
			unexplained.isEmpty,
			"Declared moves on the app's own that no modelled change produces: \(unexplained.sorted())"
		)
		XCTAssertEqual(
			Set(Self.unmodelledMoves.keys).intersection(produced.keys),
			[],
			"produced now, so no longer an exception"
		)
		XCTAssertTrue(
			Set(Self.unmodelledMoves.keys).isSubset(of: declared),
			"an exception that is not a declared move: \(Set(Self.unmodelledMoves.keys).subtracting(declared).sorted())"
		)
	}

	/// The enumeration is not vacuous: each sheet is the route of some reachable state.
	func test_everySheet_isReachable() {
		let routes = Set(HeadlessReachableStates.all.map(\.route))
		XCTAssertTrue(routes.isSuperset(of: [.account, .findings, .saveFinding]))
	}
}
