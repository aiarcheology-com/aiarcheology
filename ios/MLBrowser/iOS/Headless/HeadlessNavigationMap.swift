//
//  HeadlessNavigationMap.swift
//  AI Archeology
//
//  AIA-0982.
//

#if DEBUG
import Foundation
import HeadlessKit

/// Every route the headless build reports and the transitions that are **possible** between them:
/// what `map` answers, and the source of the checked-in `ios/HeadlessScenarios/Map/navigation-map.json`.
///
/// Built by an exhaustive `switch` over `HeadlessRoute`, so a new route does not compile without a
/// declaration. A transition names the action that takes it — `nil` when the app moves there on its
/// own — and the one condition under which it applies. Actions that stay on their route (`enable`,
/// `refresh`, `set-backup`, …) are not transitions and are not declared.
///
/// Kept honest by `HeadlessNavigationMapTests` (the sheet exits and the moves on the app's own against
/// `HeadlessRouteDecision`) and `HeadlessWalkTests` (every live transition of the states the scenarios reach).
enum HeadlessNavigationMap {

	static let declaration = NavigationMap(routes: HeadlessRoute.allCases.map(declaration(for:)))

	private static func declaration(for route: HeadlessRoute) -> RouteDeclaration {
		switch route {
		case .launching:
			return RouteDeclaration(
				route: route,
				summary: "The app is still launching; nothing to do but wait.",
				transitions: [
					moves(to: .gate, "ready while the free-access window is still being read"),
					moves(to: .paywall, "ready without access: payments on, not subscribed, no open window"),
					moves(to: .welcome, "ready and a Welcome screen is owed"),
					moves(to: .tour, "ready, no Welcome screen owed, and the tour is armed"),
					moves(to: .consent, "ready with the analytics question unanswered or its scope unresolved"),
					moves(to: .home, "ready with nothing owed"),
					moves(to: .backupConsent, "ready with a back-up question already pending and nothing owed ahead of it")
				]
			)
		case .gate:
			return RouteDeclaration(
				route: route,
				summary: "The root gate holds while the free-access window is being read.",
				transitions: [
					moves(to: .paywall, "the window is closed and there is no subscription"),
					moves(to: .welcome, "the window is open and its Welcome screen is owed"),
					moves(to: .tour, "access is granted, no Welcome screen owed, and the tour is armed"),
					moves(to: .consent, "access is granted with the analytics question unanswered"),
					moves(to: .home, "access is granted with nothing owed"),
					moves(to: .backupConsent, "a back-up question is pending and nothing is owed ahead of it, over the app or the wall")
				]
			)
		case .paywall:
			return RouteDeclaration(
				route: route,
				summary: "The paywall; purchasing is not automatable, so it offers nothing.",
				transitions: [
					moves(to: .tour, "a subscription became active and the tour is armed"),
					moves(to: .consent, "a subscription became active with the analytics question unanswered"),
					moves(to: .home, "a subscription became active, menu closed"),
					moves(to: .drawer, "a subscription became active while the paywall covered the open menu"),
					moves(to: .backupConsent, "a back-up question is raised while the analytics question is not on screen")
				]
			)
		case .welcome:
			return RouteDeclaration(
				route: route,
				summary: "A Welcome screen: the free-access offer, or the payments-off introduction.",
				transitions: [
					TransitionDeclaration(action: "continue", to: .tour, condition: "the tour is armed"),
					TransitionDeclaration(action: "continue", to: .consent, condition: "no tour, and the analytics question is unanswered"),
					TransitionDeclaration(action: "continue", to: .home, condition: "nothing else is owed"),
					moves(to: .paywall, "access ran out"),
					moves(to: .backupConsent, "access ran out with a back-up question pending")
				]
			)
		case .tour:
			return RouteDeclaration(
				route: route,
				summary: "The onboarding tour is armed or running.",
				transitions: [
					TransitionDeclaration(action: "skip", to: .consent, condition: "the analytics question is unanswered"),
					TransitionDeclaration(action: "skip", to: .home, condition: "the analytics question is answered"),
					moves(to: .paywall, "access ran out"),
					moves(to: .backupConsent, "access ran out with a back-up question pending")
				]
			)
		case .consent:
			let answered: [TransitionDeclaration] = ["allow", "deny"].flatMap { action in
				[
					TransitionDeclaration(action: action, to: .home, condition: "the menu is closed"),
					TransitionDeclaration(action: action, to: .drawer, condition: "asked over the open menu, after a sign-in"),
					TransitionDeclaration(action: action, to: .backupConsent, condition: "a back-up question is pending")
				]
			}
			return RouteDeclaration(
				route: route,
				summary: "The analytics consent question, or its hold while the scope resolves.",
				transitions: answered + [
					moves(to: .home, "the held question's scope resolved with nothing to ask, menu closed"),
					moves(to: .drawer, "the held question's scope resolved with nothing to ask, menu open"),
					moves(
						to: .backupConsent,
						"a back-up question is pending and the held question's scope resolved with nothing to ask, or access ran out"
					),
					moves(to: .paywall, "access ran out")
				]
			)
		case .home:
			return RouteDeclaration(
				route: route,
				summary: "The app proper, menu closed.",
				transitions: [
					TransitionDeclaration(action: "open-drawer", to: .drawer, condition: "always"),
					TransitionDeclaration(action: "pick", to: .saveFinding, condition: "a detect-image result is held"),
					moves(to: .paywall, "access ran out mid-session"),
					moves(to: .backupConsent, "a sync found findings saved before this account signed in")
				]
			)
		case .drawer:
			return RouteDeclaration(
				route: route,
				summary: "The app proper, menu open.",
				transitions: [
					TransitionDeclaration(action: "close", to: .home, condition: "always"),
					TransitionDeclaration(action: "open-findings", to: .findings, condition: "always"),
					TransitionDeclaration(action: "open-account", to: .account, condition: "auth is anonymous or validated"),
					moves(to: .paywall, "access ran out mid-session"),
					moves(to: .consent, "a sign-in's account has not answered the analytics question"),
					moves(to: .backupConsent, "a sync found findings saved before this account signed in")
				]
			)
		case .account:
			return RouteDeclaration(
				route: route,
				summary: "The account screen over the open menu: sign in, or the signed-in account.",
				transitions: sheetExits(action: "close", over: .drawer) + [
					TransitionDeclaration(
						action: "sign-in",
						to: .drawer,
						condition: "signed in with the question answered (verified only by the sign-in scenario)"
					),
					TransitionDeclaration(
						action: "sign-in",
						to: .consent,
						condition: "the new account has not answered the analytics question (verified only by the sign-in scenario)"
					),
					TransitionDeclaration(
						action: "sign-in",
						to: .backupConsent,
						condition: "findings saved before sign-in await the back-up question (verified only by the sign-in scenario)"
					),
					TransitionDeclaration(
						action: "sign-in",
						to: .paywall,
						condition: "access ran out while the account screen was up: signing in closes it onto the wall "
							+ "(verified only by the sign-in scenario)"
					),
					TransitionDeclaration(action: "sign-out", to: .drawer, condition: "access remains"),
					TransitionDeclaration(action: "sign-out", to: .paywall, condition: "access ran out while the sheet was up")
				]
			)
		case .saveFinding:
			return RouteDeclaration(
				route: route,
				summary: "The save-finding sheet for a picked detection.",
				transitions: sheetExits(action: "cancel", over: .home) + sheetExits(action: "save", over: .home)
			)
		case .findings:
			return RouteDeclaration(
				route: route,
				summary: "The findings list over the open menu.",
				transitions: sheetExits(action: "close", over: .drawer)
			)
		case .backupConsent:
			let answered: [TransitionDeclaration] = ["accept", "decline"].flatMap { action in
				[
					TransitionDeclaration(action: action, to: .home, condition: "the question covered the app, menu closed"),
					TransitionDeclaration(action: action, to: .drawer, condition: "the question covered the open menu"),
					TransitionDeclaration(action: action, to: .paywall, condition: "the question covered the paywall")
				]
			}
			return RouteDeclaration(
				route: route,
				summary: "The back-up question for findings saved before this account signed in.",
				transitions: answered + [
					// Both outrank the back-up question: it waits under them until they are done.
					moves(to: .tour, "access returned while the question covered the wall, and the tour is armed"),
					moves(to: .consent, "access returned while the question covered the wall, and the analytics question is unanswered")
				]
			)
		}
	}

	/// Where a sheet's dismissal lands: `HeadlessRouteDecision.route(afterClosing:)`'s answers.
	private static func sheetExits(action: String, over covered: HeadlessRoute) -> [TransitionDeclaration] {
		[
			TransitionDeclaration(action: action, to: covered, condition: "no back-up question is pending and access remains"),
			TransitionDeclaration(action: action, to: .backupConsent, condition: "a back-up question is pending"),
			TransitionDeclaration(action: action, to: .paywall, condition: "access ran out while the sheet was up")
		]
	}

	/// A transition the app takes on its own.
	private static func moves(to route: HeadlessRoute, _ condition: String) -> TransitionDeclaration {
		TransitionDeclaration(action: nil, to: Route(route.rawValue), condition: condition)
	}
}

private extension RouteDeclaration {
	init(route: HeadlessRoute, summary: String, transitions: [TransitionDeclaration]) {
		self.init(route: Route(route.rawValue), summary: summary, transitions: transitions)
	}
}

private extension TransitionDeclaration {
	init(action: String, to route: HeadlessRoute, condition: String) {
		self.init(action: action, to: Route(route.rawValue), condition: condition)
	}
}
#endif
