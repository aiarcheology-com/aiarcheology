//
//  DependencyContainer.swift
//  AI Archeology
//
//  Created by Agent on 2025-11-19.
//

import Foundation
import CoreData
import Combine
import OSLog

/// The app's **single composition root** (AIA-0385). Owns every shared service (Core Data,
/// settings, snap/deep state, downloader, demo data, auth/subscription providers) and builds
/// the fully-wired `AppState` via `makeAppState()`. Nothing outside bootstrap (`@main` app
/// entry + the background-session `UIApplicationDelegate`) may touch `DependencyContainer.shared`;
/// in particular Views never do — they read what they need from `AppState` / the environment.
@MainActor
class DependencyContainer {
	static let shared = DependencyContainer()
	
	// MARK: - Crash Reporting (Eager Initialization)
	
	/// The crash reporting service. Initialized eagerly to ensure Observability
	/// is started before any code can call DefaultCrashReporter.shared.
	let crashReporter: CrashReportingService
	
	// MARK: - Lazy Dependencies
    
    lazy var dataController: DataController = {
        return DataController()
    }()
    
    lazy var settings: Settings = {
        return Settings()
    }()
    
    lazy var snapState: SnapState = {
        return SnapState(settings: self.settings)
    }()
    
    lazy var deepState: DeepState = {
        return DeepState(dataController: self.dataController)
    }()
    
    lazy var downloader: Downloader = {
        return Downloader(dataController: self.dataController)
    }()

    lazy var catalogProviders: [any CatalogProvider] = {
        [
            HuggingFaceCatalogProvider(),
            AppleCoreMLCatalogProvider(),
            AwesomeCoreMLCatalogProvider(),
            PintoModelZooCatalogProvider(),
            JohnRockyCoreMLCatalogProvider(),
            GitHubCuratedCatalogProvider()
        ]
    }()
    
    lazy var demoDataManager: DemoDataManager = {
        return DemoDataManager(dataController: self.dataController)
    }()

    // `private(set)`: `AppState` captures this instance at construction; reassigning it afterwards
    // would hand later consumers a different repository/persistence context. Read-only to the outside.
    private(set) lazy var findingRepository: FindingRepository = {
        return FindingRepository(dataController: self.dataController)
    }()

    // MARK: - Authentication (AIA-0340)

    /// Whether the auth gate uses the in-memory mock instead of Clerk.
    /// DEBUG-only and gated on test runs, so it can never be present in
    /// Release/TestFlight builds — the auth bypass cannot ship.
    ///
    /// Covers UI tests (`UI_TESTING`), unit tests (`XCTestConfigurationFilePath`), and
    /// DEBUG builds without a valid publishable key (fresh clone with no `Secrets.xcconfig`,
    /// SwiftUI previews). All of these would otherwise take the real path and touch
    /// `Clerk.shared`, which traps (SIGILL) when Clerk was never configured. Release builds
    /// always use the real provider (the mock is `#if DEBUG`, so it can never ship).
    let usesMockAuth: Bool = {
        #if DEBUG
        return AppEnvironment.isRunningUITests
            || AppEnvironment.isRunningUnderAnyTests
            || ClerkAuthProvider.publishableKey.hasPrefix("pk_") == false
        #else
        return false
        #endif
    }()

    lazy var authProvider: AuthProviding = {
        #if DEBUG
        if self.usesMockAuth {
            return MockAuthProvider.fromLaunchArguments()
        }
        #endif
        return ClerkAuthProvider()
    }()

    // MARK: - Subscriptions (AIA-0343)

    /// Whether the subscription layer uses the in-memory mock instead of StoreKit.
    /// DEBUG-only and gated on test runs, mirroring `usesMockAuth`: UI tests and unit
    /// tests must never touch StoreKit / the App Store. Release builds always use the
    /// real provider (the mock is `#if DEBUG`, so it can never ship).
    let usesMockSubscription: Bool = {
        #if DEBUG
        return AppEnvironment.isRunningUITests
            || AppEnvironment.isRunningUnderAnyTests
        #else
        return false
        #endif
    }()

    lazy var subscriptionProvider: SubscriptionProviding = {
        #if DEBUG
        if self.usesMockSubscription {
            return MockSubscriptionProvider.fromLaunchArguments()
        }
        #endif
        return StoreKitSubscriptionProvider()
    }()

    /// Remote feature flags (AIA-0350). Tests and previews never reach ConfigCat, and a
    /// missing/empty SDK key degrades to the compiled defaults rather than failing launch.
    lazy var featureFlagProvider: FeatureFlagProviding = {
        if AppEnvironment.isRunningUnderAnyTests {
            return StaticFeatureFlagProvider()
        }
        return ConfigCatFeatureFlagProvider(sdkKey: ConfigCatFeatureFlagProvider.sdkKeyFromInfoPlist())
            ?? StaticFeatureFlagProvider()
    }()

    lazy var featureFlagsState: FeatureFlagsState = {
        FeatureFlagsState(provider: self.featureFlagProvider)
    }()

	// MARK: - Composition root

	/// Builds the fully-wired `AppState` from this container's shared services (AIA-0385).
	/// Every dependency is one of the container's own lazy singletons, so the `AppState`
	/// the app holds shares the exact instances reached elsewhere (e.g. the background-session
	/// `downloader`). `AppState` never touches `DependencyContainer.shared` itself.
	///
	/// AIA-0390: the derived feature states are grouped into three sessions built here and
	/// injected into `AppState` (which no longer constructs them). Each session receives the
	/// same shared singletons, so instances are identical across the graph.
	func makeAppState() -> AppState {
		let detection = DetectionSession(
			snap: snapState,
			settings: settings
		)
		let browser = BrowserSession(settings: settings, dataController: dataController)
		// The payments flag is resolved once here, at the session boundary, and handed to
		// the account session as a plain value (AIA-0350) — the app root must not swap
		// under the user if a later poll flips it.
		let account = AccountSession(
			authProvider: authProvider,
			subscriptionProvider: subscriptionProvider,
			isPaymentsEnabled: featureFlagsState.snapshot.isPaymentsEnabled
		)
		return AppState(
			dataController: dataController,
			settings: settings,
			snap: snapState,
		deep: deepState,
		downloader: downloader,
		catalogProviders: catalogProviders,
		demoDataManager: demoDataManager,
			findingRepository: findingRepository,
			detection: detection,
			browser: browser,
			account: account,
			featureFlags: featureFlagsState,
			usesRealAuth: usesMockAuth == false
		)
	}

	// MARK: - Initialization

    private init() {
		self.crashReporter = Self.crashReporterFactory()
	}
	
	private static func crashReporterFactory() -> CrashReportingService {
		// Create crash reporter FIRST - this must happen before anything else
		let reportingRate: Float = AppEnvironment.isAppStoreDistribution ? 0.2 : 1.0
		let isTestOrDebug = AppEnvironment.isRunningUnderAnyTests || AppEnvironment.isDebugConfiguration
		
		let shouldUseRealReporter = !isTestOrDebug || AppEnvironment.requiresRealCrashReporter
		let reporter: CrashReportingService = shouldUseRealReporter
			? SentryCrashReportingService(tracesSampleRate: reportingRate)
			: NoOpCrashReportingService()

		Logger.app.info(
			"""
			
			XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
			
				Observability initialized with reportingRate: \(reportingRate)
				isDebug: \(AppEnvironment.isDebugConfiguration)
				isTests: \(AppEnvironment.isRunningUnderAnyTests)
				requiresRealCrashReporter: \(AppEnvironment.requiresRealCrashReporter)
				usingRealReporter: \(shouldUseRealReporter)
				
			XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
			"""
		)
		
		return reporter
	}
}
