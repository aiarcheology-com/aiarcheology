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
	let catalogProviders: [any CatalogProvider]
	/// Ephemeral catalog browsing state. It deliberately survives sheet dismissal during this
	/// launch, but is never written to disk or restored after the app restarts.
	lazy var catalogSearchManager = CatalogSearchManager(providers: catalogProviders)
	let demoDataManager: DemoDataManager
	let findingRepository: FindingRepository

	/// Real Clerk-backed auth vs. the DEBUG mock, decided by the composition root (AIA-0385).
	let usesRealAuth: Bool

	/// Interactive onboarding spotlight tour (AIA-0333). Dependency-free app-chrome state kept on
	/// the shell (not a feature internal). Kept alongside `chromeState` (AIA-0391); a further merge
	/// of the two chrome-level states is out of scope here.
	lazy var tour = TourState()

	/// App-chrome + navigation state (AIA-0391, formerly the chrome half of `Guide`). Lives on the
	/// shell (not a detection feature internal). Lazy → forced on first UI access, exactly as the
	/// former `guide` was. Borrows `detection.detectionState` for the whole-app reset path.
	lazy var chromeState = AppChromeState(
		detectionState: detection.detectionState,
		deep: deep,
		settings: settings,
		demoDataManager: demoDataManager,
		analytics: analytics
	)

	// MARK: - Feature sessions (own their construction; injected by DependencyContainer, AIA-0390)
	let detection: DetectionSession
	let browser: BrowserSession
	let account: AccountSession

	/// Remote feature flags (AIA-0350). Views read `featureFlags.snapshot` for flags that
	/// apply live; `isPaymentsEnabled` is captured at launch inside `AccountSession` instead
	/// and must not be read from here for gating the app root.
	let featureFlags: FeatureFlagsState
	/// Optional analytics choice and transport. Kept separate from `Settings` so views can
	/// trigger the state transition that initializes/terminates the SDK.
	let analytics: AnalyticsState

	/// Indicates whether the app initialization is complete
	@Published private(set) var isReady = false

	// MARK: - Forwarding accessors (feature-session internals surfaced on the shell)
	var detectionState: DetectionSessionState { detection.detectionState }
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
		catalogProviders: [any CatalogProvider],
		demoDataManager: DemoDataManager,
		findingRepository: FindingRepository,
		detection: DetectionSession,
		browser: BrowserSession,
		account: AccountSession,
		featureFlags: FeatureFlagsState,
		analytics: AnalyticsState,
		usesRealAuth: Bool
	) {
		self.dataController = dataController
		self.settings = settings
		self.snap = snap
		self.deep = deep
		self.downloader = downloader
		self.catalogProviders = catalogProviders
		self.demoDataManager = demoDataManager
		self.findingRepository = findingRepository
		self.detection = detection
		self.browser = browser
		self.account = account
		self.featureFlags = featureFlags
		self.analytics = analytics
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

		// 2c. AIA-0402: one-time re-derivation of `modelTypeParsed` for models that predate the
		// attribute. Migrated 0.0.0 rows default it to `false`, which would show a declared-type
		// model as user-editable; this re-parses each and locks the ones whose file declares a type.
		// Guarded by a UserDefaults flag, so it costs one `bool` read on every later launch.
		await ModelTypeBackfiller(dataController: dataController).backfillIfNeeded()

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
		// The flag is read from the launch-time snapshot captured in `AccountSession`, so a
		// later remote flip cannot start StoreKit mid-session (AIA-0350).
		if subscriptionState.isPaymentsSurfaceEnabled {
			await subscriptionState.start()
		}

		// 4. Signal ready
		isReady = true
		LoggingPolicy.debug("AppState ready", logger: .lifecycle)

		// 5. Best-effort remote flag refresh. Deliberately *after* `isReady`, and not
		// awaited: launch must never wait on ConfigCat (AIA-0350). Failures leave the
		// cached/compiled values in place.
		Task { [featureFlags] in
			await featureFlags.refresh()
		}
	}
}

#if DEBUG
extension AppState {
	/// Fully-wired `AppState` from the shared composition root, for SwiftUI previews.
	/// Keeps `DependencyContainer.shared` out of View files (AIA-0385) and never ships.
	static var preview: AppState { DependencyContainer.shared.makeAppState() }
}
#endif
