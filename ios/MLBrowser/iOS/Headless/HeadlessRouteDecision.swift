//
//  HeadlessRouteDecision.swift
//  AI Archeology
//
//  AIA-0970.
//

#if DEBUG
import Foundation

/// The screens the headless build can report.
enum HeadlessRoute: String, CaseIterable {
	/// `AppState` is not ready yet.
	case launching
	/// The root gate's hold while the free-access window is still being read. Nothing to do but
	/// wait; `context.gate` says which inputs hold it there.
	case gate
	/// The paywall: the wall a user without access arrives at, or the one laid over the app when
	/// access ran out mid-session. Purchasing is not automatable, so it offers nothing.
	case paywall
	/// A Welcome screen over the app: the free-access window's day-0 offer, or the payments-off
	/// introduction.
	case welcome
	/// The onboarding tour is armed or running.
	case tour
	/// The analytics consent question is on screen, or is being held while its scope resolves.
	case consent
	/// The app proper, drawer closed.
	case home
	/// The app proper, drawer open.
	case drawer
	/// The account screen, over the open menu: sign in while signed out, the signed-in account
	/// otherwise. Also the sign-in offer the web screen shows after the first signed-out save, over the
	/// app proper with the menu closed.
	case account
	/// The save-finding sheet, over the app proper, for a picked detection.
	case saveFinding = "save-finding"
	/// The findings list, a sheet over the open menu.
	case findings
	/// The back-up question: findings from before this account signed in wait for the user to say
	/// whether they may be backed up. A root overlay, so it sits below every sheet.
	case backupConsent = "backup-consent"
}

/// What the app shows, decided from the same state — and the same code — the root views use.
///
/// The root gate's part comes from `SubscriptionGateCoordinator`, the object `SubscriptionGateView`
/// itself runs on (AIA-0976): its `display` and the Welcome screen it has raised are inputs here, not
/// re-derived. The analytics gate's part comes from `AnalyticsChoiceDisplay`, as in
/// `AnalyticsChoiceGate`.
struct HeadlessRouteDecision: Equatable {

	var isReady: Bool
	/// The root gate's display: `SubscriptionGateCoordinator.display`.
	var display: RootGateDisplay
	/// The Welcome screen the root gate has raised: `SubscriptionGateCoordinator.presentedPrompt`.
	var presentedWelcome: WelcomePresentation?
	var isDay0AcknowledgementPending: Bool
	var isTourPendingOrRunning: Bool
	var consentPresentation: AnalyticsConsentPresentation
	var isAskDeferredAfterSignOut: Bool
	var isDrawerOpen: Bool
	/// Whether the analytics gate has ever rendered its content in this process — the memory
	/// `AnalyticsChoiceGate` keeps in its own `@State`, kept by the headless application instead.
	var hasEverShownAnalyticsContent: Bool
	/// Whether the account screen is up — the sign-in sheet or the account's Settings: the drawer's
	/// `DrawerPresentation.isAccountPresented`, the model the drawer view binds to. Only meaningful
	/// while the drawer is open.
	var isAccountPresented: Bool
	/// Whether the save-finding sheet is up: a detection was picked and is neither saved nor
	/// cancelled yet. The web screen's `SaveFindingPresentation.isPresented`, the model the web
	/// screen binds to.
	var isSaveFindingPresented: Bool
	/// Whether the web screen's sign-in offer sheet is up: `SaveFindingPresentation.isSignInOfferPresented`,
	/// read from the shared model the web screen binds to.
	var isSignInOfferPresented: Bool
	/// Whether the findings list is up: the drawer's `DrawerPresentation.isFindingsPresented`, the
	/// model the drawer view binds to. Only meaningful while the drawer is open.
	var isFindingsPresented: Bool
	/// Whether the sync coordinator holds an unanswered back-up question.
	var isBackupConsentPending: Bool

	var route: HeadlessRoute {
		guard isReady else { return .launching }

		switch display {
		case .hold: return .gate
		case .wall, .wallOverContent: return paywallOrWhatCoversIt
		case .content: break
		}

		// The Welcome screen is the root gate's own overlay, above everything the app proper shows.
		if presentedWelcome != nil {
			return .welcome
		}

		if isTourPendingOrRunning {
			// The coordinator starts an armed tour as soon as nothing is owed the screen ahead of it.
			return .tour
		}

		let consentDisplay = analyticsDisplay
		let asksOverContent = AnalyticsChoiceDisplay.asksOverContent(
			presentation: consentPresentation,
			hasEverShownContent: hasEverShownAnalyticsContent,
			isAskDeferred: isAskDeferred
		)
		// Consent outranking a sheet is #974's decision. No modelled flow reaches it: the one path
		// that raises the question while a sheet is up, `sign-in`, closes the account screen (and the
		// sign-in offer) first.
		if consentDisplay != .content || asksOverContent {
			return .consent
		}

		// The save sheet is modal over the web screen, so it covers the menu too.
		if isSaveFindingPresented {
			return .saveFinding
		}
		// The sign-in offer is the web screen's other sheet, raised once the save sheet has closed, so
		// it never shares the screen with it. It is the account screen, without the menu.
		if isSignInOfferPresented {
			return .account
		}

		// The account screen and the findings list are raised from the drawer and never show
		// without it.
		if isDrawerOpen && isAccountPresented {
			return .account
		}
		if isDrawerOpen && isFindingsPresented {
			return .findings
		}

		// The back-up question is an overlay at the scene root: it draws below any sheet and over
		// the app proper, menu open or not. The analytics question holds it, which the consent
		// check above already covers.
		if isBackupConsentPending {
			return .backupConsent
		}

		return isDrawerOpen ? .drawer : .home
	}

	/// The paywall, unless something drawn above the root gate covers it.
	///
	/// The paywall is the gate's own overlay (or, as the wall, its whole content), so it covers the
	/// analytics question and the app proper. Two things are drawn above the gate: a sheet the app
	/// presented before access ran out (only possible over `.wallOverContent`, where the content is
	/// still mounted), and the back-up question, which sits at the scene root and holds only while
	/// the analytics question is on screen.
	private var paywallOrWhatCoversIt: HeadlessRoute {
		if display == .wallOverContent {
			if isSaveFindingPresented { return .saveFinding }
			if isSignInOfferPresented { return .account }
			if isDrawerOpen && isAccountPresented { return .account }
			if isDrawerOpen && isFindingsPresented { return .findings }
		}
		if isBackupConsentPending && isAnalyticsQuestionOnScreen == false {
			return .backupConsent
		}
		return .paywall
	}

	/// Whether `AnalyticsChoiceGate` is putting its question on screen, which is what holds the
	/// back-up question (`ConsentQuestionOnScreenKey`). The gate is not mounted behind the wall.
	private var isAnalyticsQuestionOnScreen: Bool {
		guard display == .content || display == .wallOverContent else { return false }
		let asksOverContent = AnalyticsChoiceDisplay.asksOverContent(
			presentation: consentPresentation,
			hasEverShownContent: hasEverShownAnalyticsContent,
			isAskDeferred: isAskDeferred
		)
		return analyticsDisplay == .choice || asksOverContent
	}

	/// Whether the consent question must wait: `AnalyticsChoiceGate.isAskDeferred`.
	var isAskDeferred: Bool {
		AnalyticsChoiceDisplay.isAskDeferred(
			afterSignOut: isAskDeferredAfterSignOut,
			isDay0AcknowledgementPending: isDay0AcknowledgementPending,
			isTourPendingOrRunning: isTourPendingOrRunning
		)
	}

	/// What `AnalyticsChoiceGate` renders: `AnalyticsChoiceGate.display`.
	var analyticsDisplay: AnalyticsChoiceDisplay {
		AnalyticsChoiceDisplay.resolve(
			presentation: consentPresentation,
			hasEverShownContent: hasEverShownAnalyticsContent,
			isAskDeferred: isAskDeferred
		)
	}

	/// Whether `AnalyticsChoiceGate` is rendering its content right now, which is what it remembers:
	/// the gate is mounted (the root gate shows the app proper, covered or not) and its own display is
	/// `.content` — its `onChange(of: display, initial: true)`.
	var analyticsGateShowsContent: Bool {
		(display == .content || display == .wallOverContent) && analyticsDisplay == .content
	}

	/// Where the app will be once `sheet` closes: this decision without that sheet.
	///
	/// Derived from `route` rather than written out, so a sheet's dismissal declares exactly the
	/// screen the session will find after it — the back-up question when one is pending, otherwise
	/// what the sheet covered. A route that is not a sheet is returned as the current route.
	func route(afterClosing sheet: HeadlessRoute) -> HeadlessRoute {
		var next = self
		switch sheet {
		case .saveFinding: next.isSaveFindingPresented = false
		case .account:
			// Whichever of the two is up: the drawer's account screen or the web screen's sign-in offer.
			next.isAccountPresented = false
			next.isSignInOfferPresented = false
		case .findings: next.isFindingsPresented = false
		case .launching, .gate, .paywall, .welcome, .tour, .consent, .home, .drawer, .backupConsent: break
		}
		return next.route
	}
}
#endif
