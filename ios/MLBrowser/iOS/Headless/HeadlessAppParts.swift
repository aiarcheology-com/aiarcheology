//
//  HeadlessAppParts.swift
//  AI Archeology
//
//  AIA-0982.
//

#if DEBUG
import Foundation

/// The collaborators the headless adapters work on: exactly what `MLBrowserHeadlessApplication`
/// and its screens read from the app, and nothing else.
///
/// The headless entry point builds it from the real `AppState` with `init(appState:launchOptions:)`;
/// a unit test builds it from isolated collaborators, so the headless application runs in-process
/// without an `AppState`.
@MainActor
struct HeadlessAppParts {
	let analytics: AnalyticsState
	let authState: AuthState
	let chromeState: AppChromeState
	let dataController: DataController
	let deep: DeepState
	let findingRepository: FindingRepository
	let findingsSync: FindingsSyncCoordinator
	let freeAccess: FreeAccessState
	let settings: Settings
	let subscriptionState: SubscriptionState
	let tour: TourState
	/// Whether the app finished launching: `AppState.isReady`, read live.
	let isReady: @MainActor () -> Bool
	/// Real Clerk-backed auth vs. the Debug mock.
	let usesRealAuth: Bool
	/// The images `detect-image` accepts, in launch order.
	let stagedNames: [String]
	/// Where those images are.
	let stagedDirectory: URL
	/// The screenshot directory `open-findings` sweeps of orphaned files; nil when there is none.
	let findingsDirectory: URL?
}

extension HeadlessAppParts {
	/// The app's own parts, as the headless entry point runs it. `AppState` lives for the whole
	/// process, so readiness is read from it unowned.
	init(appState: AppState, launchOptions: HeadlessLaunchOptions) {
		self.init(
			analytics: appState.analytics,
			authState: appState.authState,
			chromeState: appState.chromeState,
			dataController: appState.dataController,
			deep: appState.deep,
			findingRepository: appState.findingRepository,
			findingsSync: appState.findingsSync,
			freeAccess: appState.freeAccess,
			settings: appState.settings,
			subscriptionState: appState.subscriptionState,
			tour: appState.tour,
			isReady: { [unowned appState] in appState.isReady },
			usesRealAuth: appState.usesRealAuth,
			stagedNames: launchOptions.stagedImages,
			stagedDirectory: StagedImageCapture.defaultStagedDirectory,
			findingsDirectory: FindingScreenshotStore.directory
		)
	}
}
#endif
