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
			isSaveFindingPresented: false,
			isFindingsPresented: false,
			isBackupConsentPending: false
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

	func test_theFindingsList_showsOnlyOverTheOpenDrawer() {
		let content: (inout HeadlessRouteDecision) -> Void = {
			$0.isTourPendingOrRunning = false
			$0.consentPresentation = .resolved
			$0.isFindingsPresented = true
		}
		XCTAssertEqual(decision { content(&$0); $0.isDrawerOpen = true }.route, .findings)
		XCTAssertEqual(decision { content(&$0) }.route, .home, "the findings list never shows without the drawer")
		XCTAssertEqual(HeadlessRoute.findings.rawValue, "findings")
	}

	func test_aPendingBackupQuestion_coversHomeAndTheDrawer() {
		let pending: (inout HeadlessRouteDecision) -> Void = {
			$0.isTourPendingOrRunning = false
			$0.consentPresentation = .resolved
			$0.isBackupConsentPending = true
		}
		XCTAssertEqual(decision { pending(&$0) }.route, .backupConsent)
		XCTAssertEqual(decision { pending(&$0); $0.isDrawerOpen = true }.route, .backupConsent)
		XCTAssertEqual(HeadlessRoute.backupConsent.rawValue, "backup-consent", "the route string screens and scenarios use")
	}

	func test_everySheet_winsOverAPendingBackupQuestion() {
		let pending: (inout HeadlessRouteDecision) -> Void = {
			$0.isTourPendingOrRunning = false
			$0.consentPresentation = .resolved
			$0.isBackupConsentPending = true
		}
		XCTAssertEqual(decision { pending(&$0); $0.isSaveFindingPresented = true }.route, .saveFinding)
		XCTAssertEqual(decision { pending(&$0); $0.isDrawerOpen = true; $0.isAccountPresented = true }.route, .account)
		XCTAssertEqual(decision { pending(&$0); $0.isDrawerOpen = true; $0.isFindingsPresented = true }.route, .findings)
	}

	func test_theAnalyticsQuestion_holdsTheBackupQuestion() {
		XCTAssertEqual(decision {
			$0.isTourPendingOrRunning = false
			$0.hasEverShownContent = true
			$0.isBackupConsentPending = true
		}.route, .consent, "asked over content")
		XCTAssertEqual(decision {
			$0.isTourPendingOrRunning = false
			$0.consentPresentation = .pending
			$0.isBackupConsentPending = true
		}.route, .consent, "held before content")
		XCTAssertEqual(decision { $0.isBackupConsentPending = true }.route, .tour)
	}

	/// #974's order, kept: the analytics question outranks every sheet. No modelled flow reaches it
	/// (`sign-in` closes the account screen before the question can arrive), so this pins the order
	/// rather than a path.
	func test_theAnalyticsQuestion_outranksEverySheet() {
		let asked: (inout HeadlessRouteDecision) -> Void = {
			$0.isTourPendingOrRunning = false
			$0.hasEverShownContent = true
			$0.isDrawerOpen = true
		}
		XCTAssertEqual(decision { asked(&$0); $0.isSaveFindingPresented = true }.route, .consent)
		XCTAssertEqual(decision { asked(&$0); $0.isAccountPresented = true }.route, .consent)
		XCTAssertEqual(decision { asked(&$0); $0.isFindingsPresented = true }.route, .consent)
	}

	func test_closingASheet_landsOnTheBackupQuestionWhenOneIsPending() {
		let content: (inout HeadlessRouteDecision) -> Void = {
			$0.isTourPendingOrRunning = false
			$0.consentPresentation = .resolved
		}
		let account = decision { content(&$0); $0.isDrawerOpen = true; $0.isAccountPresented = true }
		let findings = decision { content(&$0); $0.isDrawerOpen = true; $0.isFindingsPresented = true }
		let save = decision { content(&$0); $0.isSaveFindingPresented = true }

		XCTAssertEqual(account.route(afterClosing: .account), .drawer)
		XCTAssertEqual(findings.route(afterClosing: .findings), .drawer)
		XCTAssertEqual(save.route(afterClosing: .saveFinding), .home)

		func pending(_ decision: HeadlessRouteDecision) -> HeadlessRouteDecision {
			var pending = decision
			pending.isBackupConsentPending = true
			return pending
		}
		XCTAssertEqual(pending(account).route(afterClosing: .account), .backupConsent)
		XCTAssertEqual(pending(findings).route(afterClosing: .findings), .backupConsent)
		XCTAssertEqual(pending(save).route(afterClosing: .saveFinding), .backupConsent)
	}

	func test_closingASheet_keepsWhatElseIsPresented() {
		// The save sheet over an open menu closes onto the menu, not onto home.
		let saveOverDrawer = decision {
			$0.isTourPendingOrRunning = false
			$0.consentPresentation = .resolved
			$0.isDrawerOpen = true
			$0.isSaveFindingPresented = true
		}
		XCTAssertEqual(saveOverDrawer.route(afterClosing: .saveFinding), .drawer)
		XCTAssertEqual(saveOverDrawer.route(afterClosing: .home), .saveFinding, "a route that is not a sheet closes nothing")
	}

	@MainActor
	func test_closingTheDrawer_dismissesItsSheets() {
		let presentation = HeadlessPresentation()
		presentation.isAccountPresented = true
		presentation.isFindingsPresented = true

		presentation.dismissSheetsIfDrawerClosed(isDrawerOpen: true)
		XCTAssertTrue(presentation.isAccountPresented)
		XCTAssertTrue(presentation.isFindingsPresented)

		presentation.dismissSheetsIfDrawerClosed(isDrawerOpen: false)
		XCTAssertFalse(presentation.isAccountPresented)
		XCTAssertFalse(presentation.isFindingsPresented)
	}

	func test_showsContent() {
		XCTAssertEqual(
			HeadlessRoute.allCases.filter(HeadlessRouteDecision.showsContent),
			[.tour, .home, .drawer, .account, .saveFinding, .findings, .backupConsent]
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
