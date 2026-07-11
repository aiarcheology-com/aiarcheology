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

// Responsible for keeping the data consistency across the app
// and setting up the demo structures.
//
// AIA-0385: AppState is NOT a composition root. `DependencyContainer` is the app's single
// composition root; it constructor-injects the shared services below via
// `DependencyContainer.makeAppState()`. AppState must never reference
// `DependencyContainer.shared` — it holds the injected services and owns only the
// app/view-derived state (guide, renderers, browser/visit state, tour, auth/subscription).
@MainActor
final class AppState: ObservableObject {
	// MARK: - Injected shared services (owned by DependencyContainer)
	let snap: SnapState
	let deep: DeepState
	let dataController: DataController
	let settings: Settings
	let downloader: Downloader
	let demoDataManager: DemoDataManager
	let findingRepository: FindingRepository

	/// Real Clerk-backed auth vs. the DEBUG mock, decided by the composition root.
	/// Surfaced to Views through the `\.usesRealAuth` environment value (AIA-0385).
	let usesRealAuth: Bool

	private let authProvider: AuthProviding
	private let subscriptionProvider: SubscriptionProviding

	// MARK: - App/view-derived state (owned by AppState)
	lazy var guide = Guide(
        snap: self.snap,
        deep: self.deep,
        settings: self.settings,
        dataController: self.dataController,
        demoDataManager: self.demoDataManager,
        snapAdjustment: self.snapAdjustment
    )
	lazy var renderer = DefaultRenderer()
	lazy var snapAdjustment = SnapAdjustment()
	lazy var webViewRenderer = WebSnapshotRenderer(adjustment: self.snapAdjustment)
	lazy var browserState = BrowserState(settings: self.settings)
	lazy var visitTrail = VisitTrailRecorder(browserState: self.browserState, dataController: self.dataController)

	/// Interactive onboarding spotlight tour (AIA-0333). Replaces the old slideshow as the
	/// first-launch experience and is re-runnable from Settings.
	lazy var tour = TourState()

	/// Authentication & access launch gate (AIA-0340).
	lazy var authState = AuthState(provider: self.authProvider)

	/// Subscription / entitlement state (AIA-0343).
	lazy var subscriptionState = SubscriptionState(provider: self.subscriptionProvider)

	/// Indicates whether the app initialization is complete
	@Published private(set) var isReady = false

	init(
		dataController: DataController,
		settings: Settings,
		snapState: SnapState,
		deepState: DeepState,
		downloader: Downloader,
		demoDataManager: DemoDataManager,
		findingRepository: FindingRepository,
		authProvider: AuthProviding,
		subscriptionProvider: SubscriptionProviding,
		usesRealAuth: Bool
	) {
		self.dataController = dataController
		self.settings = settings
		self.snap = snapState
		self.deep = deepState
		self.downloader = downloader
		self.demoDataManager = demoDataManager
		self.findingRepository = findingRepository
		self.authProvider = authProvider
		self.subscriptionProvider = subscriptionProvider
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
