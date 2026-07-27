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
import ClerkKit
// UIKit is composition-root-only here: it supplies the foreground notification name that
// MessageCenterState receives by injection (keeping `*State` types UI-framework-free, AGENTS §7).
import UIKit

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
            GitHubCuratedCatalogProvider(),
            ONNXModelZooCatalogProvider()
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
    ///
    /// The three markers are all load-bearing, exactly as in `usesMockAuth`. `UI_TESTING`
    /// especially: the app under test is a *separate process* from the UI-test runner, so
    /// `XCTestConfigurationFilePath` is absent there (see `AppEnvironment.isRunningUITests`).
    /// Gating on that alone would send every UI test to the live ConfigCat CDN *and* silently
    /// drop `featureFlagOverrides` on the floor — the overrides would appear to work while
    /// the app answered from the network.
    lazy var featureFlagProvider: FeatureFlagProviding = {
        if AppEnvironment.isRunningUITests
            || AppEnvironment.isRunningUnderAnyTests
            || AppEnvironment.isRunningInPreviews {
            return StaticFeatureFlagProvider(
                overrides: Self.uiTestFlagOverrides(),
                appMessagesJSON: UITestLaunchConfiguration.fromEnvironment?.appMessagesJSON ?? ""
            )
        }
        return ConfigCatFeatureFlagProvider(sdkKey: ConfigCatFeatureFlagProvider.sdkKeyFromInfoPlist())
            ?? StaticFeatureFlagProvider()
    }()

    /// Scenario flag overrides from the UI-test launch configuration (AIA-0350). Empty for
    /// unit tests and for UI tests that do not vary a flag, leaving every compiled default.
    private static func uiTestFlagOverrides() -> [FeatureFlagKey: Bool] {
        guard let raw = UITestLaunchConfiguration.fromEnvironment?.featureFlagOverrides else { return [:] }
        var overrides: [FeatureFlagKey: Bool] = [:]
        for (key, value) in raw {
            guard let flag = FeatureFlagKey(rawValue: key) else {
                fatalError("Unknown feature flag override '\(key)' — a UI test must never proceed on a misread configuration")
            }
            overrides[flag] = value
        }
        return overrides
    }

    lazy var featureFlagsState: FeatureFlagsState = {
        FeatureFlagsState(provider: self.featureFlagProvider)
    }()

	// MARK: - Optional analytics (AIA-0350)

	/// Tests and previews must never initialize TelemetryDeck: initialization itself sends a
	/// lifecycle signal. The production service is also dormant until `AnalyticsState` receives
	/// the user's active opt-in.
	lazy var analyticsTracker: AnalyticsTracking = {
		if AppEnvironment.isRunningUITests
			|| AppEnvironment.isRunningUnderAnyTests
			|| AppEnvironment.isRunningInPreviews {
			return NoOpAnalyticsTracking()
		}
		return TelemetryDeckAnalyticsProvider()
	}()

	lazy var analyticsState: AnalyticsState = {
		AnalyticsState(
			settings: self.settings,
			tracker: self.analyticsTracker,
			featureFlags: self.featureFlagsState
		)
	}()

	/// Rating-prompt bookkeeping (AIA-0117).
	///
	/// The suppression set is the usual three test/preview markers plus **TestFlight-like
	/// distribution**: Apple does not display the review sheet in TestFlight builds, so a request
	/// made there would be spent against our own cooldown for a prompt nobody could ever see.
	lazy var reviewPromptCoordinator: ReviewPromptCoordinator = {
		ReviewPromptCoordinator(
			settings: self.settings,
			featureFlags: self.featureFlagsState,
			isSuppressedEnvironment: AppEnvironment.isRunningUITests
				|| AppEnvironment.isRunningUnderAnyTests
				|| AppEnvironment.isRunningInPreviews
				|| AppEnvironment.isTestFlightLikeDistribution
		)
	}()

	// MARK: - Remote in-app messaging (AIA-0115)

	/// Reply storage on the Clerk user record. The mock-auth path (UI tests, previews, keyless
	/// clones) gets the no-op writer for the same reason it gets `MockAuthProvider`: `Clerk.shared`
	/// traps when Clerk was never configured.
	lazy var messageReplyWriter: MessageReplyWriting = {
		if usesMockAuth {
			return NoOpMessageReplyWriter()
		}
		return ClerkMessageReplyWriter()
	}()

	/// Identity for account-scoped messaging state and ConfigCat targeting. Mirrors
	/// SupportRequestView: the real Clerk user id only on the real-auth path — the mock / UI-test
	/// path has no configured Clerk instance, and touching `Clerk.shared` there traps — so it
	/// stays anonymous. One helper shared by both closures below so they can never drift.
	private func messagingUserContext() -> (userID: String?, isSignedIn: Bool) {
		let userID = usesMockAuth ? nil : Clerk.shared.user?.id
		return (userID: userID, isSignedIn: authProvider.isSignedIn)
	}

	lazy var messageCenterState: MessageCenterState = {
		MessageCenterState(
			featureFlags: self.featureFlagsState,
			userContext: { [weak self] in self?.messagingUserContext() ?? (nil, false) },
			// The authoritative replied set: what the server already holds. Local unsynced marks
			// are unioned in by MessageCenterState itself.
			serverRepliedIDs: { [writer = self.messageReplyWriter] in
				Set(writer.serverReplies().keys)
			},
			foregroundNotification: UIApplication.willEnterForegroundNotification
		)
	}()

	/// Retained here (nothing observes it); instantiated from `makeAppState()` so reply delivery
	/// is armed exactly once, alongside the state it drains.
	lazy var messageReplyCoordinator: MessageReplyCoordinator = {
		MessageReplyCoordinator(
			messageCenter: self.messageCenterState,
			writer: self.messageReplyWriter,
			isSignedIn: { [authProvider = self.authProvider] in authProvider.isSignedIn }
		)
	}()

	/// Keeps ConfigCat targeting in step with the signed-in identity (AIA-0115). Built in
	/// `makeAppState()` — it observes the auth/subscription state that `AccountSession` owns —
	/// and retained here.
	private(set) var targetingCoordinator: TargetingCoordinator?

	/// Local-notification scheduling seam (AIA-0115, S7). Tests, UI tests, and previews get the
	/// no-op recorder for the same reason `analyticsTracker` does: they must never touch
	/// UNUserNotificationCenter or request authorization.
	lazy var userNotificationScheduler: UserNotificationScheduling = {
		if AppEnvironment.isRunningUITests
			|| AppEnvironment.isRunningUnderAnyTests
			|| AppEnvironment.isRunningInPreviews {
			return NoOpUserNotificationScheduler()
		}
		return UNUserNotificationCenterScheduler()
	}()

	/// Keeps scheduled local notifications in step with the notify-worthy message set (AIA-0115, S7).
	/// Hooks `messageCenterState` on init and is retained here; armed from `makeAppState()`.
	lazy var messageNotificationCoordinator: MessageNotificationCoordinator = {
		MessageNotificationCoordinator(
			messageCenter: self.messageCenterState,
			scheduler: self.userNotificationScheduler
		)
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
			settings: settings,
			analytics: analyticsState
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
		// Arm reply delivery (AIA-0115): the coordinator hooks messageCenterState on init and is
		// retained by this container; nothing else references it.
		_ = messageReplyCoordinator
		// Arm notification scheduling (AIA-0115, S7): hooks messageCenterState's reevaluation
		// observer on init so every visibility recompute reconciles scheduled notifications.
		_ = messageNotificationCoordinator
		// Arm identity-driven targeting (AIA-0115): auth/subscription transitions retarget
		// ConfigCat and re-run message visibility (interactive requires sign-in).
		targetingCoordinator = TargetingCoordinator(
			identity: { [weak self] in self?.messagingUserContext() ?? (nil, false) },
			isSubscribed: { [subscriptionState = account.subscriptionState] in
				subscriptionState.isSubscribed
			},
			authGateChanges: account.authState.$gate.eraseToAnyPublisher(),
			subscriptionChanges: account.subscriptionState.$isSubscribed.eraseToAnyPublisher(),
			provider: featureFlagProvider,
			featureFlags: featureFlagsState,
			messageCenter: messageCenterState
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
			analytics: analyticsState,
			reviewPrompt: reviewPromptCoordinator,
			messageCenter: messageCenterState,
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
