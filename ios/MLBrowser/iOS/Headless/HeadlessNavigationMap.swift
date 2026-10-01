//
//  HeadlessNavigationMap.swift
//  AI Archeology
//
//  AIA-0982.
//

#if DEBUG
import Foundation
import HeadlessKit

/// Every route headless mode reports, the actions each can offer and the moves the app makes on its
/// own: what `map` answers, and the source of the checked-in `ios/HeadlessScenarios/Map/navigation-map.json`.
///
/// Built by an exhaustive `switch` over `HeadlessRoute`, so a new route does not compile without a
/// declaration. The map is the catalog (HeadlessKit's docs/moves.md): each route lists every action its
/// screen can offer, staying ones included, from the screen's own `catalog`, with every way each can end
/// (`.stays`, or `.route` under its condition). `appMoves` are the moves the app makes there on its own.
/// A live action references its entry by name, so the declaration lives here and only here.
///
/// Enforced: after every action the session accepts only the action's outcomes, plus one move on the
/// app's own (`HeadlessSession`, AIA-0994), so an outcome set the app does not keep fails the action with
/// `undeclaredTransition`. Kept honest by `HeadlessNavigationMapTests` (the sheet exits and the moves on the app's own against
/// `HeadlessRouteDecision`) and `HeadlessWalkTests` (every live action of the states the scenarios reach).
enum HeadlessNavigationMap {

	static let declaration = NavigationMap(routes: HeadlessRoute.allCases.map(declaration(for:)))

	private static func declaration(for route: HeadlessRoute) -> RouteDeclaration {
		switch route {
		case .launching:
			return RouteDeclaration(
				route: route,
				summary: "The app is still launching; nothing to do but wait.",
				actions: [],
				appMoves: [
					.route(.gate, when: "ready while the free-access window is still being read"),
					.route(.paywall, when: "ready without access: payments on, not subscribed, no open window"),
					.route(.welcome, when: "ready and a Welcome screen is owed"),
					.route(.tour, when: "ready, no Welcome screen owed, and the tour is armed"),
					.route(.consent, when: "ready with the analytics question unanswered or its scope unresolved"),
					.route(.home, when: "ready with nothing owed"),
					.route(.backupConsent, when: "ready with a back-up question already pending and the analytics question not on screen")
				]
			)
		case .gate:
			return RouteDeclaration(
				route: route,
				summary: "The root gate holds while the free-access window is being read.",
				actions: [],
				appMoves: [
					.route(.paywall, when: "the window is closed and there is no subscription"),
					.route(.welcome, when: "the window is open and its Welcome screen is owed"),
					.route(.tour, when: "access is granted, no Welcome screen owed, and the tour is armed"),
					.route(.consent, when: "access is granted with the analytics question unanswered"),
					.route(.home, when: "access is granted with nothing owed"),
					.route(.backupConsent, when: "a back-up question is pending and the analytics question is not on screen: it draws over the hold")
				]
			)
		case .paywall:
			return RouteDeclaration(
				route: route,
				summary: "The paywall; purchasing is not automatable, so it offers nothing.",
				actions: [],
				appMoves: [
					.route(.tour, when: "a subscription became active and the tour is armed"),
					.route(.consent, when: "a subscription became active with the analytics question unanswered"),
					.route(.home, when: "a subscription became active, menu closed"),
					.route(.drawer, when: "a subscription became active while the paywall covered the open menu"),
					.route(.backupConsent, when: "a back-up question is raised while the analytics question is not on screen")
				]
			)
		case .welcome:
			return RouteDeclaration(
				route: route,
				summary: "A Welcome screen: the free-access offer, or the payments-off introduction.",
				actions: HeadlessWelcomeScreen.catalog,
				appMoves: [
					.route(.paywall, when: "access ran out"),
					.route(.backupConsent, when: "a back-up question is pending: it draws over the Welcome screen")
				]
			)
		case .tour:
			return RouteDeclaration(
				route: route,
				summary: "The onboarding tour is armed or running.",
				actions: HeadlessTourScreen.catalog,
				appMoves: [
					.route(.paywall, when: "access ran out"),
					.route(.backupConsent, when: "a back-up question is pending: it draws over the tour")
				]
			)
		case .consent:
			return RouteDeclaration(
				route: route,
				summary: "The analytics consent question, or its hold while the scope resolves.",
				actions: HeadlessConsentScreen.catalog,
				appMoves: [
					.route(.home, when: "the held question's scope resolved with nothing to ask, menu closed"),
					.route(.drawer, when: "the held question's scope resolved with nothing to ask, menu open"),
					.route(
						.backupConsent,
						when: "a back-up question is raised over the held question, which does not hold it; or one is pending and the held question's scope resolved with nothing to ask, or access ran out"
					),
					.route(.paywall, when: "access ran out")
				]
			)
		case .home:
			return RouteDeclaration(
				route: route,
				summary: "The app proper, menu closed.",
				actions: HeadlessHomeScreen.catalog,
				appMoves: [
					.route(.paywall, when: "access ran out mid-session"),
					.route(.consent, when: "a sign-in from the sign-in offer: its account has not answered the analytics question"),
					.route(.backupConsent, when: "a sync found findings saved before this account signed in")
				]
			)
		case .drawer:
			return RouteDeclaration(
				route: route,
				summary: "The app proper, menu open.",
				actions: HeadlessDrawerScreen.catalog,
				appMoves: [
					.route(.paywall, when: "access ran out mid-session"),
					.route(.consent, when: "a sign-in's account has not answered the analytics question"),
					.route(.backupConsent, when: "a sync found findings saved before this account signed in")
				]
			)
		case .account:
			return RouteDeclaration(
				route: route,
				summary: "The account screen over the open menu: sign in, or the signed-in account. "
					+ "Also the sign-in offer after the first signed-out save, menu closed.",
				actions: HeadlessAccountScreen.catalog
			)
		case .saveFinding:
			return RouteDeclaration(route: route, summary: "The save-finding sheet for a picked detection.", actions: HeadlessSaveFindingScreen.catalog)
		case .findings:
			return RouteDeclaration(route: route, summary: "The findings list over the open menu.", actions: HeadlessFindingsScreen.catalog)
		case .backupConsent:
			return RouteDeclaration(
				route: route,
				summary: "The back-up question for findings saved before this account signed in.",
				actions: HeadlessBackupConsentScreen.catalog,
				appMoves: [
					// The analytics question holds the back-up question (`ConsentQuestionOnScreenKey`): once
					// it is on screen, the back-up question waits under it until it is answered.
					.route(.consent, when: "access returned while the question covered the wall, and the analytics question is unanswered"),
					.route(.paywall, when: "the gate lifted to the paywall over the app, whose analytics question holds it")
				]
			)
		}
	}

	/// Where a sheet's dismissal lands: `HeadlessRouteDecision.route(afterClosing:)`'s answers. A sheet's
	/// `close` or `cancel` declares them all and narrows to the one that holds when its screen is listed.
	static func sheetExits(over covered: HeadlessRoute) -> [ActionOutcome] {
		[
			.route(covered, when: "no back-up question is pending and access remains"),
			.route(.backupConsent, when: "a back-up question is pending"),
			.route(.paywall, when: "access ran out while the sheet was up")
		]
	}
}

/// Only for the leading-dot spelling (`.route(.paywall)`): the kit's `some RawRepresentable<String>`
/// overload takes `HeadlessRoute` values directly, but a generic parameter cannot infer `.paywall`.
extension ActionOutcome {
	static func route(_ route: HeadlessRoute, when condition: String = "") -> ActionOutcome {
		.route(Route(route.rawValue), when: condition)
	}
}
#endif
