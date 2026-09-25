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
		if consentDisplay != .content || asksOverContent {
			return .consent
		}

		return isDrawerOpen ? .drawer : .home
	}

	/// Whether `route` puts the app proper on screen, which is what the gates remember.
	static func showsContent(_ route: HeadlessRoute) -> Bool {
		switch route {
		case .tour, .home, .drawer: true
		case .launching, .gate, .consent: false
		}
	}
}
#endif
