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
/// the fully-wired `AppState` via `makeAppState()`. Nothing outside bootstrap (the app entry points
/// `MLBrowser` and the headless `MLBrowserHeadless`, plus the background-session
/// `UIApplicationDelegate`) may touch `DependencyContainer.shared`;
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

	/// Shared player boundary for app-provided annotation sounds (AIA-0716). The actor owns its
	/// AVAudioPlayer off the main actor; views receive it through AppState rather than `.shared`.
	lazy var annotationSoundPlayer: any AnnotationSoundPlaying = {
		AnnotationSoundPlayer()
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

	/// Owns the durable source-package cleanup actor shared by launch recovery and model import.
	lazy var nativeConversionSourceCleanupService = NativeModelSourceCleanupService()

    // `private(set)`: `AppState` captures this instance at construction; reassigning it afterwards
    // would hand later consumers a different repository/persistence context. Read-only to the outside.
    private(set) lazy var findingRepository: FindingRepository = {
        return FindingRepository(dataController: self.dataController)
    }()

    /// Findings to the cloud and back (AIA-727).
    ///
    /// Constructed lazily like everything else here, but note that constructing it is what wires
    /// the repository's delete hook — so a delete only becomes a tombstone once something has
    /// asked for this. `AppState` does, at launch.
    lazy var findingsSync: FindingsSyncCoordinator = {
        FindingsSyncCoordinator(
            authProvider: self.authProvider,
            analytics: self.analyticsState,
            findingRepository: self.findingRepository,
            dataController: self.dataController
        )
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
    /// tests must never touch StoreKit / the App Store. The headless build opts in per launch
    /// with `-mockSubscription` (AIA-0970). Release builds always use the real provider (the
    /// mock is `#if DEBUG`, so it can never ship).
    let usesMockSubscription: Bool = {
        #if DEBUG
        #if AIA_APP_INTERFACE_headless
        // Headless (AIA-0970): real StoreKit is the default. It reaches the sandbox and reads as not
        // subscribed, and a subscribed install would need a real sandbox purchase (AIA-0976). A
        // manual launch can still opt into the mock with `-mockSubscription`, which the handshake
        // echoes; no committed scenario may.
        if HeadlessLaunchOptions.current.mockSubscription != nil {
            return true
        }
        #endif
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
        return StoreKitSubscriptionProvider(
            // Purchase tagging reads the *validated* auth context, never `Clerk.shared` directly
            // (AIA-0536). The paywall-first gate order lets a purchase happen while auth is still
            // checking, offline, or signed out, and a stale session must not tag one — so anything
            // short of `.validated` yields no token and the purchase is simply untagged.
            accountIdentifierSource: { [weak self] in
                self?.taggingAuthState?.effectiveContext.validatedAccount
            }
        )
    }()

    /// Late-bound `AuthState` for purchase tagging.
    ///
    /// The subscription provider is constructed *before* the `AccountSession` that owns `AuthState`,
    /// so the reference cannot be passed at init. Assigned once in `makeAppState()` and read only
    /// when a purchase actually happens, long afterwards. Weak because `AppState` owns the session;
    /// the container must not be what keeps it alive.
    private weak var taggingAuthState: AuthState?

    // MARK: - Free-access period (AIA-0556)

    /// The durable half of the free-access anchor.
    ///
    /// Tests and previews get the ephemeral store, for a reason specific to this feature: the
    /// Keychain item deliberately outlives app deletion, while `Settings.init()` wipes the UI-test
    /// defaults suite on every launch and test runs reinstall rather than erase. A UI test that
    /// granted a window would otherwise leave behind a durable anchor no later run could clear,
    /// permanently poisoning every "fresh install" path on that simulator. `#if DEBUG` like
    /// `authProvider`'s mock: the markers that select it are launch-controlled, so keeping the type
    /// out of shipping binaries is what actually guarantees a Release build reaches the Keychain.
    ///
    /// The headless build uses the Keychain (AIA-0976). Its fresh installs erase the device, and
    /// `simctl erase` clears the item (measured on the iOS 27.0 simulator); the launcher also resets
    /// the device's Keychain in case another runtime keeps it.
    lazy var freeAccessDurableStore: FreeAccessAnchorDurableStore = {
        #if DEBUG
        if AppEnvironment.isRunningUITests
            || AppEnvironment.isRunningUnderAnyTests
            || AppEnvironment.isRunningInPreviews {
            return EphemeralFreeAccessAnchorStore()
        }
        #endif
        return KeychainFreeAccessAnchorService()
    }()

    lazy var freeAccessAnchorService: FreeAccessAnchorService = {
        FreeAccessAnchorService(
            // The store `Settings` actually resolved to, never `.standard`: under UI testing
            // `Settings` moves to an ephemeral suite, and the fast half of the anchor has to land
            // where the rest of the app is looking.
            defaults: self.settings.persistenceStore,
            durableStore: self.freeAccessDurableStore
        )
    }()

    lazy var freeAccessState: FreeAccessState = {
        FreeAccessState(
            service: self.freeAccessAnchorService,
            // Session-boundary capture like `isPaymentsEnabled` (AIA-0350), resolved through the
            // launch mirror rather than the unsynced snapshot (AIA-0513). It gates granting only:
            // a window already open is honoured to its natural expiry whatever the flag later says.
            isFreeAccessPeriodEnabled: self.launchCapturedFlag(.isFreeAccessPeriodEnabled),
            // The free-access funnel (AIA-0556). A grant and an expiry have no screen to report
            // them from, so the state that decides both is what emits them.
            analytics: self.analyticsState,
            foregroundNotification: UIApplication.willEnterForegroundNotification
        )
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
        #if DEBUG && AIA_APP_INTERFACE_headless
        // Headless flag pins (AIA-0970), layered over the live provider. Upstream of
        // `FeatureFlagsState`, so the launch mirror records pinned values too.
        let pins = HeadlessLaunchOptions.current.flagOverrides
        if pins.isEmpty == false {
            return OverridingFeatureFlagProvider(base: Self.makeLiveFeatureFlagProvider(), overrides: pins)
        }
        #endif
        if AppEnvironment.isRunningUITests
            || AppEnvironment.isRunningUnderAnyTests
            || AppEnvironment.isRunningInPreviews {
            return StaticFeatureFlagProvider(
                overrides: Self.uiTestFlagOverrides(),
                appMessagesJSON: UITestLaunchConfiguration.fromEnvironment?.appMessagesJSON ?? ""
            )
        }
        return Self.makeLiveFeatureFlagProvider()
    }()

    /// ConfigCat, or the compiled defaults when there is no SDK key. One definition for the app and
    /// the headless build's pinned provider, so neither can drift from the other.
    private static func makeLiveFeatureFlagProvider() -> FeatureFlagProviding {
        ConfigCatFeatureFlagProvider(sdkKey: ConfigCatFeatureFlagProvider.sdkKeyFromInfoPlist())
            ?? StaticFeatureFlagProvider()
    }

    /// Scenario flag overrides from the UI-test launch configuration (AIA-0350). Empty for
    /// unit tests and for UI tests that do not vary a flag, leaving every compiled default.
    private static func uiTestFlagOverrides() -> [FeatureFlagKey: Bool] {
        // Baseline: UI tests run in the pre-AIA-0437 device-wide consent model unless a test opts
        // in. The suite's deterministic baseline skips the consent screen by setting
        // `analyticsChoiceMade`, and under account-scoped consent that flag alone no longer
        // qualifies — so without this every unrelated UI test would stop at the consent gate.
        // Tests that mean to exercise the account-scoped path override it explicitly, and the
        // loop below lets any explicit value win.
        //
        // `isFreeAccessPeriodEnabled` is baselined off for the same reason (AIA-0556). It defaults
        // *on*, so without this every test that launches `-mockSubscription notSubscribed` to reach
        // the paywall would be handed a 14-day window and land in the app instead — the paywall
        // suites would pass while asserting nothing. Free-access scenarios override it explicitly.
        //
        // `isPaymentsEnabled` is baselined *on* for the mirror-image reason (AIA-0955). It now
        // defaults closed, and every paywall and subscription test in the suite was written against
        // the payments surface being live. Free-mode scenarios override it to `false` explicitly.
        var overrides: [FeatureFlagKey: Bool] = [
            .isCrossDeviceAnalyticsIdentityEnabled: false,
            .isFreeAccessPeriodEnabled: false,
            .isPaymentsEnabled: true
        ]
        guard let raw = UITestLaunchConfiguration.fromEnvironment?.featureFlagOverrides else { return overrides }
        for (key, value) in raw {
            guard let flag = FeatureFlagKey(rawValue: key) else {
                fatalError("Unknown feature flag override '\(key)' — a UI test must never proceed on a misread configuration")
            }
            overrides[flag] = value
        }
        return overrides
    }

    lazy var featureFlagsState: FeatureFlagsState = {
        let state = FeatureFlagsState(provider: self.featureFlagProvider)
        // Armed here rather than from `makeAppState()`: a background app-refresh launch touches
        // `featureFlagsState` and syncs it without ever building `AppState`, so arming later would
        // subscribe with an already-synced snapshot current — which `dropFirst()` would then
        // swallow, losing that session's only observation (AIA-0513).
        self.flagLaunchValueMirror = FlagLaunchValueMirror(flags: state, settings: self.settings)
        return state
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

	/// Retained here; nothing else references it. Constructed inside the `featureFlagsState`
	/// initializer so it subscribes in the same synchronous frame as the state it mirrors —
	/// see ``FlagLaunchValueMirror`` for why arming it later would silently lose a value.
	private var flagLaunchValueMirror: FlagLaunchValueMirror?

	/// The value a **launch-captured** flag should be resolved with (AIA-0513).
	///
	/// Reads the previous session's mirrored dashboard value first. Reading the live snapshot here
	/// instead would capture the compiled default on every launch, because the ConfigCat SDK has
	/// not synced when the composition root runs — that is the whole defect. The snapshot fallback
	/// serves exactly the cases with no mirror: a genuine first launch, and tests, where the static
	/// provider IS synchronous.
	///
	/// Only for flags captured once per session. Anything read live must use the published
	/// snapshot so it still tracks changes within a session.
	private func launchCapturedFlag(_ key: FeatureFlagKey) -> Bool {
		LaunchCapturedFlags.resolve(
			key,
			mirror: settings.remoteFlagLaunchValues,
			snapshot: featureFlagsState.snapshot
		)
	}

	/// The identity flag in force this session (AIA-0437), resolved **once** and shared by both of
	/// its consumers — `analyticsState` and the coordinator gate in `makeAppState()`.
	///
	/// One resolution rather than two reads is load-bearing: if the two diverged, a coordinator
	/// could feed account ids into an `AnalyticsState` running device-wide, installing an identity
	/// under a consent model that never asked the user about one.
	private lazy var isAccountIdentityEnabledResolved: Bool =
		launchCapturedFlag(.isCrossDeviceAnalyticsIdentityEnabled)

	lazy var analyticsState: AnalyticsState = {
		AnalyticsState(
			settings: self.settings,
			tracker: self.analyticsTracker,
			featureFlags: self.featureFlagsState,
			// Session-boundary capture like `isPaymentsEnabled` (AIA-0350): this flag selects which
			// consent model is in force, so a mid-session flip would move the goalposts under a
			// user who has already answered. See `isAccountIdentityEnabledResolved` for why the
			// value must come from the mirror rather than the snapshot.
			isAccountIdentityEnabled: self.isAccountIdentityEnabledResolved
		)
	}()

	/// Cross-device analytics identity + funnel events (AIA-0437).
	///
	/// Retained here for the same reason as `targetingCoordinator` — it is pure Combine
	/// subscriptions, so a local would deallocate and silently stop working. `nil` while
	/// `isCrossDeviceAnalyticsIdentityEnabled` is off, which is what makes the feature ship dark:
	/// with no coordinator no identity is installed and neither funnel event fires.
	private(set) var accountAnalyticsCoordinator: AccountAnalyticsCoordinator?

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
		let browser = BrowserSession(
			settings: settings,
			dataController: dataController,
			// AIA-0509: retry a failed page load when the app becomes active — `didBecomeActive`
			// rather than `willEnterForeground`, which fires before the app is actually active.
			activeNotification: UIApplication.didBecomeActiveNotification
		)
		let detection = DetectionSession(
			snap: snapState,
			settings: settings,
			analytics: analyticsState,
			// AIA-0846: every detection snapshot records which document it came from, so a finding
			// made from it can be held to that document. Read only when a snapshot runs, by which
			// time the web view (and so `browserState`) exists; nothing is forced here.
			captureContext: { [weak browser] in browser?.browserState.captureContext }
		)
		// The payments flag is resolved once here, at the session boundary, and handed to
		// the account session as a plain value (AIA-0350) — the app root must not swap
		// under the user if a later poll flips it.
		let account = AccountSession(
			authProvider: authProvider,
			subscriptionProvider: subscriptionProvider,
			// AIA-0513: resolved through the launch mirror, not the live snapshot. Reading the
			// snapshot here captured the compiled default on every launch, so the payments kill
			// switch could never be turned off from the dashboard.
			isPaymentsEnabled: launchCapturedFlag(.isPaymentsEnabled)
		)
		// Arm reply delivery (AIA-0115): the coordinator hooks messageCenterState on init and is
		// retained by this container; nothing else references it.
		// Late-bind purchase tagging now that `AuthState` exists (AIA-0536).
		taggingAuthState = account.authState
		// Account deletion must erase the cloud copy BEFORE Clerk deletes the user, or the session
		// token that is the only way to reach that data goes with it (AIA-728).
		//
		// Not wired under the mock auth provider: its token is a stand-in the Worker rightly
		// refuses, so a purge could only ever fail — and a failed purge deliberately blocks
		// deletion. A build with no real account has no cloud data to erase, so there is nothing
		// this skips.
		if usesMockAuth == false {
			account.authState.purgeCloudData = { [findingsSync] operation in try await findingsSync.purgeCloudData(operation: operation) }
		}
		// Signing in is its own trigger. It is none of the three the coordinator watches for, so
		// without this the first thing a new user does -- sign in -- produces silence (AIA-727).
		//
		// Wired on every path, unlike the purge above: the mock provider has no cloud data to
		// erase, but it does change accounts, and a trigger that only exists in release builds is
		// one no test can reach.
		account.authState.accountDidChange = { [findingsSync] _ in _ = findingsSync.syncNow() }
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
		// Arm the cross-device analytics identity (AIA-0437). Built only while the flag is on, and
		// before `AppState` starts its work, so the first account transition is already observed.
		if isAccountIdentityEnabledResolved {
			accountAnalyticsCoordinator = AccountAnalyticsCoordinator(
				analytics: analyticsState,
				authState: account.authState,
				subscriptionState: account.subscriptionState
			)
		}
		return AppState(
			dataController: dataController,
			settings: settings,
			snap: snapState,
		deep: deepState,
		annotationSoundPlayer: annotationSoundPlayer,
		downloader: downloader,
		catalogProviders: catalogProviders,
		demoDataManager: demoDataManager,
			findingRepository: findingRepository,
			findingsSync: findingsSync,
		nativeConversionSourceCleanupService: nativeConversionSourceCleanupService,
			detection: detection,
			browser: browser,
			account: account,
			freeAccess: freeAccessState,
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
