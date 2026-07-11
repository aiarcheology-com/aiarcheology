//
//  Appstate.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

import Foundation
import SwiftUI
import Vision
import OSLog

// Responsible for keeping the data consistency across the app and setting up the demo structures.
//
// AIA-0385: `DependencyContainer` is the single composition root; it constructor-injects AppState.
// AIA-0390: AppState is a bootstrap shell. It no longer constructs the derived feature states —
// those are grouped into three injectable sessions (`DetectionSession`, `BrowserSession`,
// `AccountSession`) built by `DependencyContainer.makeAppState()`. AppState holds the sessions
// plus shell-level shared services + cross-cutting state, and exposes thin forwarding accessors so
// existing `appState.<feature>` call sites keep working. Caller migration to `appState.detection.*`
// etc. is deferred to #391. AppState must never reference `DependencyContainer.shared`.
@MainActor
final class AppState: ObservableObject {
	// MARK: - Shell: shared services + cross-cutting state (owned directly)
	let dataController: DataController
	let settings: Settings
	let snap: SnapState
	let deep: DeepState
	let downloader: Downloader
	let demoDataManager: DemoDataManager

	/// Real Clerk-backed auth vs. the DEBUG mock, decided by the composition root (AIA-0385).
	let usesRealAuth: Bool

	/// Interactive onboarding spotlight tour (AIA-0333). Dependency-free app-chrome state kept on
	/// the shell (not a feature internal); to be absorbed by #391's AppChromeState.
	lazy var tour = TourState()

	// MARK: - Feature sessions (own their construction; injected by DependencyContainer, AIA-0390)
	let detection: DetectionSession
	let browser: BrowserSession
	let account: AccountSession

	/// Indicates whether the app initialization is complete
	@Published private(set) var isReady = false

	// MARK: - Forwarding accessors (back-compat facade; callers migrate onto the sessions in #391)
	var guide: Guide { detection.guide }
	var renderer: DefaultRenderer { detection.renderer }
	var snapAdjustment: SnapAdjustment { detection.snapAdjustment }
	var webViewRenderer: WebSnapshotRenderer { detection.webViewRenderer }
	var browserState: BrowserState { browser.browserState }
	var visitTrail: VisitTrailRecorder { browser.visitTrail }
	var authState: AuthState { account.authState }
	var subscriptionState: SubscriptionState { account.subscriptionState }

	init(
		dataController: DataController,
		settings: Settings,
		snap: SnapState,
		deep: DeepState,
		downloader: Downloader,
		demoDataManager: DemoDataManager,
		detection: DetectionSession,
		browser: BrowserSession,
		account: AccountSession,
		usesRealAuth: Bool
	) {
		self.dataController = dataController
		self.settings = settings
		self.snap = snap
		self.deep = deep
		self.downloader = downloader
		self.demoDataManager = demoDataManager
		self.detection = detection
		self.browser = browser
		self.account = account
		self.usesRealAuth = usesRealAuth

		LoggingPolicy.debug("AppState initializing", logger: .lifecycle)
		Task {
			await initialize()
		}
	}

	private func initialize() async {
		// 1. Wait for Core Data to be ready
		await dataController.awaitStoreReady()

		// 2. Create demo data if needed (checked against Core Data, not UserDefaults)
		await demoDataManager.createDemoDataIfNeeded()

		// 2b. First-launch onboarding tour (AIA-0333). Decided here — before `isReady` flips
		// and the UI appears — so the onboarding demo page is staged deterministically ahead of
		// WebScreen's initial load (no race). UI-test launches start the tour from ContentView
		// via the launch flag instead, so skip the production auto-start path here.
		if AppEnvironment.isRunningUITests == false, tour.migrateAndAutostartIfNeeded() {
			settings.onboardingInitialPage = DemoDataManager.onboardingDemoPage
		}

		// 3. Start recording the browsing trail (lazy — must be touched to subscribe)
		_ = visitTrail

		// 3b. Install the StoreKit transaction listener and drain pending/unfinished
		// transactions (Ask-to-Buy, interrupted) at launch, BEFORE any purchase UI
		// can appear, then publish the initial entitlement (AIA-0343).
		if FeatureFlags.isPaymentsEnabled {
			await subscriptionState.start()
		}

		// 4. Signal ready
		isReady = true
		LoggingPolicy.debug("AppState ready", logger: .lifecycle)
	}
}

#if DEBUG
extension AppState {
	/// Fully-wired `AppState` from the shared composition root, for SwiftUI previews.
	/// Keeps `DependencyContainer.shared` out of View files (AIA-0385) and never ships.
	static var preview: AppState { DependencyContainer.shared.makeAppState() }
}
#endif
