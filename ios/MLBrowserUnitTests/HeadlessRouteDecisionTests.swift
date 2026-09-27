//
//  HeadlessRouteDecisionTests.swift
//  MLBrowserUnitTests
//
//  AIA-0970.
//

import XCTest
@testable import ML_Browser

/// Which screen the headless build reports, from the inputs the root gates read.
///
/// The baseline is the state a headless scenario launches into: subscribed through the mock, payments
/// on, no free-access window, and the first-run tour armed with consent unanswered.
final class HeadlessRouteDecisionTests: XCTestCase {

	private func decision(_ adjust: (inout HeadlessRouteDecision) -> Void = { _ in }) -> HeadlessRouteDecision {
		var decision = HeadlessRouteDecision(
			isReady: true,
			isPaymentsSurfaceEnabled: true,
			isSubscribed: true,
			freeAccess: .closed,
			freeAccessPrompt: nil,
			isWelcomePresented: false,
			isDay0AcknowledgementPending: false,
			isIntroductionOwed: false,
			isTourActive: false,
			isTourPendingOrRunning: true,
			consentPresentation: .ask,
			isAskDeferredAfterSignOut: false,
			isDrawerOpen: false,
			hasEverShownContent: false,
			isAccountPresented: false,
			isSaveFindingPresented: false
		)
		adjust(&decision)
		return decision
	}

	func test_beforeReady_isLaunching() {
		XCTAssertEqual(decision { $0.isReady = false }.route, .launching)
	}

	func test_firstRun_walksTourThenConsentThenHome() {
		XCTAssertEqual(decision().route, .tour, "an armed tour starts before consent is asked")
		XCTAssertEqual(decision { $0.isTourPendingOrRunning = false }.route, .consent)
		XCTAssertEqual(decision {
			$0.isTourPendingOrRunning = false
			$0.consentPresentation = .resolved
		}.route, .home)
	}

	func test_drawerOpen_isDrawer() {
		let open = decision {
			$0.isTourPendingOrRunning = false
			$0.consentPresentation = .resolved
			$0.isDrawerOpen = true
		}
		XCTAssertEqual(open.route, .drawer)
	}

	func test_theAccountScreen_showsOnlyOverTheOpenDrawer() {
		let content: (inout HeadlessRouteDecision) -> Void = {
			$0.isTourPendingOrRunning = false
			$0.consentPresentation = .resolved
		}
		XCTAssertEqual(decision { content(&$0); $0.isDrawerOpen = true; $0.isAccountPresented = true }.route, .account)
		XCTAssertEqual(decision { content(&$0); $0.isDrawerOpen = true; $0.isAccountPresented = false }.route, .drawer)
		XCTAssertEqual(
			decision { content(&$0); $0.isDrawerOpen = false; $0.isAccountPresented = true }.route,
			.home,
			"the account screen never shows without the drawer"
		)
	}

	func test_aConsentAskOverContent_winsOverTheAccountScreen() {
		// After a sign-in the new account's consent question can take the screen from the account UI.
		XCTAssertEqual(decision {
			$0.isTourPendingOrRunning = false
			$0.hasEverShownContent = true
			$0.isDrawerOpen = true
			$0.isAccountPresented = true
		}.route, .consent)
	}

	func test_thePaywallAndTheHold_areGates() {
		XCTAssertEqual(decision { $0.isSubscribed = false; $0.freeAccess = .closed }.route, .gate, "the wall")
		XCTAssertEqual(decision { $0.isSubscribed = false; $0.freeAccess = .undetermined }.route, .gate, "the hold")
		XCTAssertEqual(decision { $0.isSubscribed = false; $0.freeAccess = .open }.route, .tour, "an open window is content")
		XCTAssertEqual(decision { $0.isSubscribed = false; $0.isPaymentsSurfaceEnabled = false }.route, .tour, "payments off is content")
	}

	func test_aWelcomeScreenTheGateWouldRaise_isAGate() {
		XCTAssertEqual(decision {
			$0.isSubscribed = false
			$0.freeAccess = .open
			$0.freeAccessPrompt = FreeAccessPrompt(days: 14, endsOn: .distantFuture)
		}.route, .gate)
		XCTAssertEqual(decision {
			$0.isPaymentsSurfaceEnabled = false
			$0.isSubscribed = false
			$0.isIntroductionOwed = true
		}.route, .gate, "the payments-off introduction")
		XCTAssertEqual(decision { $0.isDay0AcknowledgementPending = true }.route, .gate, "a Welcome screen still on screen")
	}

	func test_aSubscriberIsNeverShownWelcome_soTheTourRuns() {
		// The gate cannot present Welcome to a subscriber (`canPresentPrompt`), so an owed day 0
		// must not hold the tour back — `TourStartDecision` lets it start.
		XCTAssertEqual(decision { $0.freeAccessPrompt = FreeAccessPrompt(days: 14, endsOn: .distantFuture) }.route, .tour)
	}

	func test_consent_followsTheGatesOwnDisplayRules() {
		let noTour: (inout HeadlessRouteDecision) -> Void = { $0.isTourPendingOrRunning = false }
		XCTAssertEqual(decision { noTour(&$0); $0.consentPresentation = .pending }.route, .consent, "held before content")
		XCTAssertEqual(decision { noTour(&$0); $0.consentPresentation = .pending; $0.hasEverShownContent = true }.route, .home)
		XCTAssertEqual(decision { noTour(&$0); $0.consentPresentation = .unavailable }.route, .home, "never held on unavailable")
		XCTAssertEqual(decision { noTour(&$0); $0.isAskDeferredAfterSignOut = true }.route, .home, "a deferred ask is silent")
		XCTAssertEqual(decision { noTour(&$0); $0.hasEverShownContent = true }.route, .consent, "asked over content")
	}

	func test_aPickedDetection_isTheSaveSheet_overHomeAndTheDrawer() {
		let content: (inout HeadlessRouteDecision) -> Void = {
			$0.isTourPendingOrRunning = false
			$0.consentPresentation = .resolved
			$0.isSaveFindingPresented = true
		}
		XCTAssertEqual(decision { content(&$0) }.route, .saveFinding)
		XCTAssertEqual(decision { content(&$0); $0.isDrawerOpen = true }.route, .saveFinding, "the sheet is modal over the menu")
		XCTAssertEqual(decision { content(&$0); $0.isDrawerOpen = true; $0.isAccountPresented = true }.route, .saveFinding)
		XCTAssertEqual(HeadlessRoute.saveFinding.rawValue, "save-finding", "the route string screens and scenarios use")
	}

	func test_theGatesTheTourAndConsent_stillWinOverTheSaveSheet() {
		XCTAssertEqual(decision { $0.isSaveFindingPresented = true }.route, .tour)
		XCTAssertEqual(decision { $0.isSaveFindingPresented = true; $0.isTourPendingOrRunning = false }.route, .consent)
		XCTAssertEqual(decision {
			$0.isSaveFindingPresented = true
			$0.isTourPendingOrRunning = false
			$0.consentPresentation = .resolved
			$0.isSubscribed = false
		}.route, .gate)
		XCTAssertEqual(decision { $0.isSaveFindingPresented = true; $0.isReady = false }.route, .launching)
	}

	func test_showsContent() {
		XCTAssertEqual(
			HeadlessRoute.allCases.filter(HeadlessRouteDecision.showsContent),
			[.tour, .home, .drawer, .account, .saveFinding]
		)
	}
}

/// The consent gate's rules, now a pure decider shared by `AnalyticsChoiceGate` and the headless
/// build. Pins the behaviour the view had before the extraction.
final class AnalyticsChoiceDisplayTests: XCTestCase {

	func test_resolve() {
		XCTAssertEqual(AnalyticsChoiceDisplay.resolve(presentation: .ask, hasEverShownContent: false, isAskDeferred: false), .choice)
		XCTAssertEqual(AnalyticsChoiceDisplay.resolve(presentation: .ask, hasEverShownContent: true, isAskDeferred: false), .content)
		XCTAssertEqual(AnalyticsChoiceDisplay.resolve(presentation: .ask, hasEverShownContent: false, isAskDeferred: true), .content)
		XCTAssertEqual(AnalyticsChoiceDisplay.resolve(presentation: .resolved, hasEverShownContent: false, isAskDeferred: false), .content)
		XCTAssertEqual(AnalyticsChoiceDisplay.resolve(presentation: .pending, hasEverShownContent: false, isAskDeferred: false), .hold)
		XCTAssertEqual(AnalyticsChoiceDisplay.resolve(presentation: .pending, hasEverShownContent: true, isAskDeferred: false), .content)
		XCTAssertEqual(AnalyticsChoiceDisplay.resolve(presentation: .unavailable, hasEverShownContent: false, isAskDeferred: false), .content)
	}

	func test_asksOverContent_onlyWhenShownAndNotDeferred() {
		XCTAssertTrue(AnalyticsChoiceDisplay.asksOverContent(presentation: .ask, hasEverShownContent: true, isAskDeferred: false))
		XCTAssertFalse(AnalyticsChoiceDisplay.asksOverContent(presentation: .ask, hasEverShownContent: true, isAskDeferred: true))
		XCTAssertFalse(AnalyticsChoiceDisplay.asksOverContent(presentation: .ask, hasEverShownContent: false, isAskDeferred: false))
		XCTAssertFalse(AnalyticsChoiceDisplay.asksOverContent(presentation: .resolved, hasEverShownContent: true, isAskDeferred: false))
	}

	func test_isAskDeferred_isAnyOfTheThreeReasons() {
		XCTAssertFalse(AnalyticsChoiceDisplay.isAskDeferred(afterSignOut: false, isDay0AcknowledgementPending: false, isTourPendingOrRunning: false))
		XCTAssertTrue(AnalyticsChoiceDisplay.isAskDeferred(afterSignOut: true, isDay0AcknowledgementPending: false, isTourPendingOrRunning: false))
		XCTAssertTrue(AnalyticsChoiceDisplay.isAskDeferred(afterSignOut: false, isDay0AcknowledgementPending: true, isTourPendingOrRunning: false))
		XCTAssertTrue(AnalyticsChoiceDisplay.isAskDeferred(afterSignOut: false, isDay0AcknowledgementPending: false, isTourPendingOrRunning: true))
	}
}
