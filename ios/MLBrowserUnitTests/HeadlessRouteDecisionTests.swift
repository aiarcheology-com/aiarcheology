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
/// The baseline is the state a fresh install reaches once its Welcome screen is gone: the root gate
/// shows the app proper, the first-run tour is running, and consent is unanswered. The root gate's
/// own answers (`display`, the Welcome screen it raised) come from `SubscriptionGateCoordinator`,
/// whose ordering `SubscriptionGateCoordinatorTests` covers.
final class HeadlessRouteDecisionTests: XCTestCase {

	private func decision(_ adjust: (inout HeadlessRouteDecision) -> Void = { _ in }) -> HeadlessRouteDecision {
		var decision = HeadlessRouteDecision(
			isReady: true,
			display: .content,
			presentedWelcome: nil,
			isDay0AcknowledgementPending: false,
			isTourPendingOrRunning: true,
			consentPresentation: .ask,
			isAskDeferredAfterSignOut: false,
			isDrawerOpen: false,
			hasEverShownAnalyticsContent: false,
			isAccountPresented: false,
			isSaveFindingPresented: false,
			isSignInOfferPresented: false,
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

	func test_theAccountScreen_coversAConsentAskOverContent() {
		// The question over content is an overlay under the sheet (AnalyticsChoiceUITests
		// `testRestoreDefaultsTurnsAnalyticsOffAndShowsChoiceAgain`): it takes the screen only once the
		// account screen closes, which `sign-in` does.
		let asked = decision {
			$0.isTourPendingOrRunning = false
			$0.hasEverShownAnalyticsContent = true
			$0.isDrawerOpen = true
			$0.isAccountPresented = true
		}
		XCTAssertEqual(asked.route, .account)
		XCTAssertEqual(asked.route(afterClosing: .account), .consent)
	}

	func test_theRootGatesDisplay_decidesThePaywallAndTheHold() {
		XCTAssertEqual(decision { $0.display = .wall }.route, .paywall, "the wall")
		XCTAssertEqual(decision { $0.display = .wallOverContent }.route, .paywall, "the wall over the app")
		XCTAssertEqual(decision { $0.display = .hold }.route, .gate, "the hold")
		XCTAssertEqual(decision { $0.display = .content }.route, .tour)
	}

	func test_thePaywallOverTheApp_coversTheConsentQuestionAndTheApp() {
		XCTAssertEqual(decision {
			$0.display = .wallOverContent
			$0.isTourPendingOrRunning = false
			$0.hasEverShownAnalyticsContent = true
		}.route, .paywall, "the question is under the gate's overlay")
		XCTAssertEqual(decision { $0.display = .wallOverContent; $0.isDrawerOpen = true }.route, .paywall)
	}

	/// A sheet presented before access ran out is drawn above the whole gate, so it stays usable and
	/// can be closed; the paywall is what it closes onto.
	func test_aSheetOpenWhenAccessRunsOut_staysAboveThePaywall() {
		let expired: (inout HeadlessRouteDecision) -> Void = {
			$0.display = .wallOverContent
			$0.isTourPendingOrRunning = false
			$0.consentPresentation = .resolved
		}
		XCTAssertEqual(decision { expired(&$0); $0.isSaveFindingPresented = true }.route, .saveFinding)
		XCTAssertEqual(decision { expired(&$0); $0.isDrawerOpen = true; $0.isAccountPresented = true }.route, .account)
		let findings = decision { expired(&$0); $0.isDrawerOpen = true; $0.isFindingsPresented = true }
		XCTAssertEqual(findings.route, .findings)
		XCTAssertEqual(findings.route(afterClosing: .findings), .paywall)
		XCTAssertEqual(decision { $0.display = .wall; $0.isSaveFindingPresented = true }.route, .paywall, "no app behind the wall to present from")
	}

	/// The back-up question sits at the scene root, above the gate, and holds only for the analytics
	/// question — which the paywall hides but does not unmount.
	func test_theBackupQuestion_isAboveThePaywall_unlessTheAnalyticsQuestionHoldsIt() {
		XCTAssertEqual(decision { $0.display = .wall; $0.isBackupConsentPending = true }.route, .backupConsent)
		XCTAssertEqual(decision {
			$0.display = .wallOverContent
			$0.isTourPendingOrRunning = false
			$0.consentPresentation = .resolved
			$0.isBackupConsentPending = true
		}.route, .backupConsent)
		XCTAssertEqual(decision {
			$0.display = .wallOverContent
			$0.isTourPendingOrRunning = false
			$0.hasEverShownAnalyticsContent = true
			$0.isBackupConsentPending = true
		}.route, .paywall, "held by the analytics question under the paywall")
	}

	func test_aRaisedWelcomeScreen_isTheWelcomeRoute_overTheTour() {
		let prompt = FreeAccessPrompt(days: 14, endsOn: .distantFuture)
		XCTAssertEqual(decision { $0.presentedWelcome = .freeAccess(prompt) }.route, .welcome)
		XCTAssertEqual(decision { $0.presentedWelcome = .introduction }.route, .welcome, "the payments-off introduction")
		XCTAssertEqual(decision {
			$0.presentedWelcome = .introduction
			$0.isTourPendingOrRunning = false
			$0.isDay0AcknowledgementPending = true
		}.route, .welcome)
	}

	func test_aDay0AcknowledgementWithNoWelcomeUp_onlyDefersTheQuestion() {
		// The coordinator shows no Welcome screen to a subscriber whose window owes day 0, so only
		// the analytics gate reads the pending acknowledgement: the ask waits, content shows.
		XCTAssertEqual(decision {
			$0.isTourPendingOrRunning = false
			$0.isDay0AcknowledgementPending = true
		}.route, .home)
	}

	func test_consent_followsTheGatesOwnDisplayRules() {
		let noTour: (inout HeadlessRouteDecision) -> Void = { $0.isTourPendingOrRunning = false }
		XCTAssertEqual(decision { noTour(&$0); $0.consentPresentation = .pending }.route, .consent, "held before content")
		XCTAssertEqual(decision { noTour(&$0); $0.consentPresentation = .pending; $0.hasEverShownAnalyticsContent = true }.route, .home)
		XCTAssertEqual(decision { noTour(&$0); $0.consentPresentation = .unavailable }.route, .home, "never held on unavailable")
		XCTAssertEqual(decision { noTour(&$0); $0.isAskDeferredAfterSignOut = true }.route, .home, "a deferred ask is silent")
		XCTAssertEqual(decision { noTour(&$0); $0.hasEverShownAnalyticsContent = true }.route, .consent, "asked over content")
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

	/// A sheet sits above the tour and the question over content, and is gone with the view that
	/// presented it when a gate replaces the app proper.
	func test_theSaveSheet_coversTheTourAndTheQuestion_butNotAGateThatReplacesTheApp() {
		XCTAssertEqual(decision { $0.isSaveFindingPresented = true }.route, .saveFinding, "over the tour")
		XCTAssertEqual(decision {
			$0.isSaveFindingPresented = true
			$0.isTourPendingOrRunning = false
			$0.hasEverShownAnalyticsContent = true
		}.route, .saveFinding, "over the question asked over content")
		XCTAssertEqual(
			decision { $0.isSaveFindingPresented = true; $0.isTourPendingOrRunning = false }.route,
			.consent,
			"the analytics gate's choice replaces the app proper, and the web screen with it"
		)
		XCTAssertEqual(decision {
			$0.isSaveFindingPresented = true
			$0.isTourPendingOrRunning = false
			$0.consentPresentation = .resolved
			$0.display = .wall
		}.route, .paywall)
		XCTAssertEqual(decision { $0.isSaveFindingPresented = true; $0.isReady = false }.route, .launching)
	}

	/// The web screen's sign-in offer is the account screen without the menu: it follows a save, over
	/// the app proper with the drawer closed.
	func test_theSignInOffer_isTheAccountScreen_withTheDrawerClosed() {
		let content: (inout HeadlessRouteDecision) -> Void = {
			$0.isTourPendingOrRunning = false
			$0.consentPresentation = .resolved
		}
		let offer = decision { content(&$0); $0.isSignInOfferPresented = true }
		XCTAssertEqual(offer.route, .account)
		XCTAssertEqual(offer.route(afterClosing: .account), .home)

		var pending = offer
		pending.isBackupConsentPending = true
		XCTAssertEqual(pending.route, .account, "a sheet outranks the back-up question")
		XCTAssertEqual(pending.route(afterClosing: .account), .backupConsent)

		let expired = decision { content(&$0); $0.display = .wallOverContent; $0.isSignInOfferPresented = true }
		XCTAssertEqual(expired.route, .account, "a sheet presented before access ran out stays above the paywall")
		XCTAssertEqual(expired.route(afterClosing: .account), .paywall)
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
			$0.hasEverShownAnalyticsContent = true
			$0.isBackupConsentPending = true
		}.route, .consent, "asked over content")
		XCTAssertEqual(decision {
			$0.isTourPendingOrRunning = false
			$0.consentPresentation = .pending
			$0.isBackupConsentPending = true
		}.route, .backupConsent, "the analytics gate's hold is not its question: the back-up question draws over it")
		XCTAssertEqual(decision {
			$0.isTourPendingOrRunning = false
			$0.isBackupConsentPending = true
		}.route, .consent, "the choice replacing the app proper")
		XCTAssertEqual(decision { $0.isBackupConsentPending = true }.route, .backupConsent, "over the tour, from the scene root")
	}

	/// The back-up question is an overlay at the scene root, so it draws over both gates and the tour;
	/// only the analytics question on screen holds it.
	func test_theBackupQuestion_drawsOverTheGatesAndTheTour() {
		XCTAssertEqual(decision { $0.display = .hold; $0.isBackupConsentPending = true }.route, .backupConsent, "the hold")
		XCTAssertEqual(decision { $0.display = .wall; $0.isBackupConsentPending = true }.route, .backupConsent, "the wall")
		XCTAssertEqual(decision {
			$0.presentedWelcome = .introduction
			$0.isBackupConsentPending = true
		}.route, .backupConsent, "a Welcome screen")
	}

	/// The app's order, which replaces #974's: every sheet covers the question asked over content, as
	/// UIKit presents sheets above the analytics gate's overlay. `AnalyticsChoiceUITests`
	/// `testRestoreDefaultsTurnsAnalyticsOffAndShowsChoiceAgain` observes it in the app: the question
	/// raised while Settings is up is not hittable until Settings closes.
	func test_everySheet_coversTheQuestionAskedOverContent() {
		let asked: (inout HeadlessRouteDecision) -> Void = {
			$0.isTourPendingOrRunning = false
			$0.hasEverShownAnalyticsContent = true
			$0.isDrawerOpen = true
		}
		XCTAssertEqual(decision { asked(&$0); $0.isDrawerOpen = false; $0.isSaveFindingPresented = true }.route, .saveFinding)
		XCTAssertEqual(decision { asked(&$0); $0.isDrawerOpen = false; $0.isSignInOfferPresented = true }.route, .account)
		XCTAssertEqual(decision { asked(&$0); $0.isAccountPresented = true }.route, .account)
		XCTAssertEqual(decision { asked(&$0); $0.isFindingsPresented = true }.route, .findings)
		XCTAssertEqual(decision { asked(&$0) }.route, .consent, "and the question shows once they close")
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

	/// `AnalyticsChoiceGate` remembers content only while it is mounted — the root gate shows the
	/// app, covered or not — and renders its content, a deferred ask included.
	func test_theAnalyticsGatesMemory_followsItsMountAndItsOwnDisplay() {
		XCTAssertTrue(decision().analyticsGateShowsContent, "a deferred ask renders content")
		XCTAssertTrue(decision { $0.display = .wallOverContent }.analyticsGateShowsContent)
		XCTAssertFalse(decision { $0.display = .wall }.analyticsGateShowsContent, "not mounted behind the wall")
		XCTAssertFalse(decision { $0.display = .hold }.analyticsGateShowsContent, "not mounted during the hold")
		XCTAssertFalse(decision { $0.isTourPendingOrRunning = false }.analyticsGateShowsContent, "the question is the screen")
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
