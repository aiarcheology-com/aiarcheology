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

	/// The screen on top: the app's layers, topmost first (AIA-0984).
	///
	/// This is the one declaration of the order. The views cannot be driven from it — each layer's
	/// place follows from where its view sits in the tree — so `HeadlessRouteDecisionTests` pins the
	/// same order and the parity test (`HeadlessParityUITests` against the `parity-*` scenarios)
	/// checks it against the app itself.
	///
	/// 1. **A sheet.** UIKit presents sheets above every SwiftUI layer, but only while the view that
	///    presents them is mounted: the web screen and the drawer live in the app proper
	///    (``presentedSheet``).
	/// 2. **The back-up question**, an overlay at the scene root (`backupConsentPrompt`), so above both
	///    gates and the app proper. The analytics question holds it (`ConsentQuestionOnScreenKey`).
	/// 3. **The root gate** (`SubscriptionGateView`): its hold or its wall replaces its content; the
	///    paywall over content and the Welcome screen are overlays on that content.
	/// 4. **The analytics gate** (`AnalyticsChoiceGate`), inside the root gate's content: its choice or
	///    its hold replaces the app proper; its question over content is an overlay on it.
	/// 5. **The tour**, an overlay on `ContentView`, inside the analytics gate's content.
	/// 6. **The app proper**: the drawer, or home.
	var route: HeadlessRoute {
		guard isReady else { return .launching }

		if let sheet = presentedSheet {
			return sheet
		}

		if isBackupConsentPending && isAnalyticsQuestionOnScreen == false {
			return .backupConsent
		}

		switch display {
		case .hold: return .gate
		case .wall, .wallOverContent: return .paywall
		case .content: break
		}
		if presentedWelcome != nil {
			return .welcome
		}

		if analyticsDisplay != .content || asksOverContent {
			return .consent
		}

		if isTourPendingOrRunning {
			// The coordinator starts an armed tour as soon as nothing is owed the screen ahead of it.
			return .tour
		}

		return isDrawerOpen ? .drawer : .home
	}

	/// The sheet that is up, when the view presenting it is mounted: the app proper is, which is what
	/// ``analyticsGateShowsContent`` says — the root gate shows its content (covered by the paywall
	/// or not) and the analytics gate shows its own.
	///
	/// The web screen presents the save sheet and, once that has closed, the sign-in offer; the drawer
	/// presents the account screen and the findings list, and only while it is open. The app reaches
	/// no state with two of them up (`HeadlessReachableStates`), so their order here settles only
	/// combinations it never produces.
	private var presentedSheet: HeadlessRoute? {
		guard analyticsGateShowsContent else { return nil }
		// The save sheet carries the tour inside it (`SaveFindingSheet`'s `.tourOverlay(_:inSheet:)`),
		// so a tour-guided capture shows the tour on top of the sheet.
		if isSaveFindingPresented { return isTourPendingOrRunning ? .tour : .saveFinding }
		if isSignInOfferPresented { return .account }
		guard isDrawerOpen else { return nil }
		if isAccountPresented { return .account }
		if isFindingsPresented { return .findings }
		return nil
	}

	/// Whether `AnalyticsChoiceGate` asks its question over content already shown.
	private var asksOverContent: Bool {
		AnalyticsChoiceDisplay.asksOverContent(
			presentation: consentPresentation,
			hasEverShownContent: hasEverShownAnalyticsContent,
			isAskDeferred: isAskDeferred
		)
	}

	/// Whether `AnalyticsChoiceGate` is putting its question on screen, which is what holds the
	/// back-up question (`ConsentQuestionOnScreenKey`). The gate is not mounted behind the wall.
	private var isAnalyticsQuestionOnScreen: Bool {
		guard display == .content || display == .wallOverContent else { return false }
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
