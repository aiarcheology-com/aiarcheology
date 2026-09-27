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
	/// A root gate the headless build cannot drive yet: the paywall, the Welcome screen, or the hold
	/// while free access is still being determined. Read-only; `context.gate` says which inputs hold
	/// it there.
	case gate
	/// The onboarding tour is armed or running.
	case tour
	/// The analytics consent question is on screen, or is being held while its scope resolves.
	case consent
	/// The app proper, drawer closed.
	case home
	/// The app proper, drawer open.
	case drawer
	/// The account screen, over the open menu: sign in while signed out, the signed-in account
	/// otherwise.
	case account
	/// The save-finding sheet, over the app proper, for a picked detection.
	case saveFinding = "save-finding"
	/// The findings list, a sheet over the open menu.
	case findings
	/// The back-up question: findings from before this account signed in wait for the user to say
	/// whether they may be backed up. A root overlay, so it sits below every sheet.
	case backupConsent = "backup-consent"
}

/// What the app shows, decided from the same state — and the same pure deciders — the root views
/// read: `RootGateDisplay`, `WelcomePresentation`, `TourStartDecision` and `AnalyticsChoiceDisplay`.
///
/// It does not re-implement the gate views' orchestration. Where that orchestration would put a
/// screen the headless build cannot drive yet (the paywall, Welcome), the answer is `gate`, which
/// exposes no actions — so a client can see where the app is but cannot act past it.
struct HeadlessRouteDecision: Equatable {

	var isReady: Bool
	var isPaymentsSurfaceEnabled: Bool
	var isSubscribed: Bool
	var freeAccess: FreeAccessAvailability
	var freeAccessPrompt: FreeAccessPrompt?
	var isWelcomePresented: Bool
	var isDay0AcknowledgementPending: Bool
	var isIntroductionOwed: Bool
	var isTourActive: Bool
	var isTourPendingOrRunning: Bool
	var consentPresentation: AnalyticsConsentPresentation
	var isAskDeferredAfterSignOut: Bool
	var isDrawerOpen: Bool
	/// Whether the app proper has been on screen in this process — the memory the gate views keep
	/// in their own `@State`, kept by the headless application instead.
	var hasEverShownContent: Bool
	/// Whether the account screen is up — the sign-in sheet or the account's Settings, `@State` in the
	/// drawer, kept by the headless application instead. Only meaningful while the drawer is open.
	var isAccountPresented: Bool
	/// Whether the save-finding sheet is up: a detection was picked and is neither saved nor
	/// cancelled yet. `@State` on the web screen, kept by the headless application instead.
	var isSaveFindingPresented: Bool
	/// Whether the findings list is up — `@State` in the drawer, kept by the headless application
	/// instead. Only meaningful while the drawer is open.
	var isFindingsPresented: Bool
	/// Whether the sync coordinator holds an unanswered back-up question.
	var isBackupConsentPending: Bool

	var route: HeadlessRoute {
		guard isReady else { return .launching }

		let rootDisplay = RootGateDisplay.resolve(
			isPaymentsSurfaceEnabled: isPaymentsSurfaceEnabled,
			isSubscribed: isSubscribed,
			freeAccess: freeAccess,
			hasEverShownContent: hasEverShownContent
		)
		guard rootDisplay == .content else { return .gate }

		// The Welcome screen the subscription gate would raise: due, and presentable (the gate's
		// `canPresentPrompt` — content showing, not subscribed, no tour running).
		let dueWelcome = WelcomePresentation.due(
			isPaymentsSurfaceEnabled: isPaymentsSurfaceEnabled,
			freeAccessPrompt: freeAccessPrompt,
			isIntroductionOwed: isIntroductionOwed
		)
		let canPresentWelcome = isSubscribed == false && isTourActive == false
		if (dueWelcome != nil && canPresentWelcome) || isWelcomePresented || isDay0AcknowledgementPending {
			return .gate
		}

		if isTourPendingOrRunning {
			// An armed tour starts as soon as the content shows unless a Welcome screen has the floor,
			// and every such case returned `gate` above — so `TourStartDecision.mayStart` holds here.
			return .tour
		}

		let isAskDeferred = AnalyticsChoiceDisplay.isAskDeferred(
			afterSignOut: isAskDeferredAfterSignOut,
			isDay0AcknowledgementPending: isDay0AcknowledgementPending,
			isTourPendingOrRunning: isTourPendingOrRunning
		)
		let consentDisplay = AnalyticsChoiceDisplay.resolve(
			presentation: consentPresentation,
			hasEverShownContent: hasEverShownContent,
			isAskDeferred: isAskDeferred
		)
		let asksOverContent = AnalyticsChoiceDisplay.asksOverContent(
			presentation: consentPresentation,
			hasEverShownContent: hasEverShownContent,
			isAskDeferred: isAskDeferred
		)
		// Consent outranking a sheet is #974's decision. No modelled flow reaches it: the one path
		// that raises the question while a sheet is up, `sign-in`, closes the account screen first.
		if consentDisplay != .content || asksOverContent {
			return .consent
		}

		// The save sheet is modal over the web screen, so it covers the menu too.
		if isSaveFindingPresented {
			return .saveFinding
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

	/// Where the app will be once `sheet` closes: this decision without that sheet.
	///
	/// Derived from `route` rather than written out, so a sheet's dismissal declares exactly the
	/// screen the session will find after it — the back-up question when one is pending, otherwise
	/// what the sheet covered. A route that is not a sheet is returned as the current route.
	func route(afterClosing sheet: HeadlessRoute) -> HeadlessRoute {
		var next = self
		switch sheet {
		case .saveFinding: next.isSaveFindingPresented = false
		case .account: next.isAccountPresented = false
		case .findings: next.isFindingsPresented = false
		case .launching, .gate, .tour, .consent, .home, .drawer, .backupConsent: break
		}
		return next.route
	}

	/// Whether `route` puts the app proper on screen, which is what the gates remember.
	static func showsContent(_ route: HeadlessRoute) -> Bool {
		switch route {
		case .tour, .home, .drawer, .account, .saveFinding, .findings, .backupConsent: true
		case .launching, .gate, .consent: false
		}
	}
}
#endif
