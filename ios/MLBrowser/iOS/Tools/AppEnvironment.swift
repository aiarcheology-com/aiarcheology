//
//  AppEnvironment.swift
//  AI Archeology
//
//  Created by Vladimír Cortes Slavík on 26.11.25.
//

import Foundation

/// Centralized environment detection for the app (build config, tests, distribution).
///
/// ## Usage / setup
///
/// ### 1) Debug configuration
/// Xcode defines `DEBUG` for Debug builds.
/// `AppEnvironment.isDebugConfiguration` is `true` only there.
///
/// ### 2) Runtime UI-test vs unit-test detection
/// In the UI test target’s `setUp` (or before launching):
///
/// ```swift
/// let app = XCUIApplication()
/// app.launchEnvironment["UI_TESTING"] = "1"
/// app.launch()
/// ```
///
/// Inside the app process, `isRunningUITests` reads only that `UI_TESTING` marker — the
/// app under test is a separate process from the runner and does not see the XCTest
/// environment. `isRunningUnitTests` reads the XCTest environment, which *is* present
/// because unit tests run in-process.
///
/// ### 3) Runtime distribution channel detection (App Store vs TestFlight-like vs Dev/AdHoc)
/// - Store-distributed apps typically do NOT include `embedded.mobileprovision`.
///   If it exists → treat as development-like (Xcode / AdHoc / Enterprise).
/// - Otherwise, inspect the receipt filename:
///   - `receipt`        → App Store production
///   - `sandboxReceipt` → TestFlight-like (also possible during App Review / sandbox)
/// - `Bundle.main.appStoreReceiptURL` can be non-nil even when no receipt exists, so
///   we additionally check that the receipt file exists on disk.
enum AppEnvironment {
	static let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
	static let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

    // MARK: - Compile-time configuration

    /// True only in Debug configuration (standard Xcode `DEBUG` flag).
    static let isDebugConfiguration: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    // MARK: - Runtime detection (tests)

    /// True whenever *any* XCTest bundle is driving this process.
    static var isRunningUnderAnyTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// True when the app is currently being UI-tested.
    ///
    /// Requires the UI test target to set:
    ///     app.launchEnvironment["UI_TESTING"] = "1"
    static var isRunningUITests: Bool {
        // The app under test runs in a SEPARATE process from the UI-test runner, so
        // `XCTestConfigurationFilePath` is not present here — only the `UI_TESTING`
        // launch-environment marker the UI-test target sets. Gating on that marker alone
        // is safe: launch environment cannot be injected into a sandboxed production app.
        ProcessInfo.processInfo.environment["UI_TESTING"] == "1"
    }

    /// True when this process is rendering a SwiftUI preview.
    ///
    /// Previews are neither a test nor a real run: they get a valid Debug `Secrets.xcconfig`,
    /// so anything gated only on the test markers would happily open real network clients
    /// every time a canvas re-renders.
    static var isRunningInPreviews: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    /// True when the app is currently being *unit*-tested (not UI-tested).
    ///
    /// Assumes:
    ///   - XCTest sets `XCTestConfigurationFilePath` for all test runs.
    ///   - UI tests additionally set `UI_TESTING = "1"` in the launch env.
    static var isRunningUnitTests: Bool {
        let env = ProcessInfo.processInfo.environment
        guard env["XCTestConfigurationFilePath"] != nil else { return false }
        return env["UI_TESTING"] == nil
    }

    // MARK: - Runtime detection (distribution)

    enum DistributionChannel: Equatable {
        /// Xcode install, AdHoc, Enterprise (has embedded provisioning profile).
        case developmentLike
        /// App Store production receipt (`.../receipt`)
        case appStore
        /// Sandbox receipt (`.../sandboxReceipt`) — typically TestFlight, but can also be App Review / sandbox-like.
        case testFlightLike
        /// Simulator build (no provisioning profile or receipt).
        case unknown
    }
	
	/// True if running in iOS Simulator.
	static var isSimulator: Bool {
		#if targetEnvironment(simulator)
		return true
		#else
		return false
		#endif
	}

    /// True if the bundle contains an embedded provisioning profile.
    /// Store-distributed apps (App Store / TestFlight) typically do not.
    static var hasEmbeddedProvisioningProfile: Bool {
        Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") != nil
    }

    /// True if the receipt file exists on disk.
    static var hasReceiptFile: Bool {
        guard let url = Bundle.main.appStoreReceiptURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Best-effort runtime channel detection:
    /// 1) Simulator -> simulator
    /// 2) embedded.mobileprovision present -> developmentLike
    /// 3) receipt exists -> sandboxReceipt (testFlightLike) vs receipt (appStore)
    /// 4) DEBUG build -> developmentLike (fallback for edge cases)
    /// 5) else unknown
    static var distributionChannel: DistributionChannel {
		// A Simulator can contain a local StoreKit testing receipt named `receipt`.
		// That file must never make a simulator look like an App Store install: among
		// other things, doing so would force production auth and hide the test/dev
		// environment picker on the sign-in screen.
		if isSimulator {
			return .unknown
		}

		// Device with provisioning profile = Xcode/AdHoc/Enterprise install
        if hasEmbeddedProvisioningProfile {
            return .developmentLike
        }

		// Check for App Store / TestFlight receipts
        if let url = Bundle.main.appStoreReceiptURL,
		   FileManager.default.fileExists(atPath: url.path) {
			switch url.lastPathComponent {
			case "sandboxReceipt": return .testFlightLike
			case "receipt": return .appStore
			default: break
			}
		}
		
		// Fallback: DEBUG builds without receipt are likely development
		if isDebugConfiguration {
			return .developmentLike
		}

        return .unknown
    }

    static var isAppStoreDistribution: Bool { distributionChannel == .appStore }
    static var isTestFlightLikeDistribution: Bool { distributionChannel == .testFlightLike }

    /// True whenever in-app purchases run against StoreKit's sandbox / a local `.storekit` test
    /// configuration instead of charging real money — i.e. everywhere except a genuine App Store
    /// production install. Simulator and Debug builds are forced `true` because a local
    /// StoreKit-test receipt is named `receipt`, which `distributionChannel` would otherwise
    /// misread as `.appStore` (it never special-cases the simulator).
    ///
    /// **Currently has no callers.** Its only one was the under-construction badge, which moved to
    /// ``showsUnderConstructionBadge`` in AIA-0455 — see there for why the two must not be the same
    /// property. Kept because the question it answers is a real one and the answer is subtle: a
    /// future caller asking "is this purchase for real?" should use this rather than
    /// `!isAppStoreDistribution`, and must get "assume not" when the channel is unidentifiable.
    /// That is the opposite of what the badge needs, which is exactly why they are separate.
    static var purchasesUseSandbox: Bool {
        if isSimulator || isDebugConfiguration { return true }
        return distributionChannel != .appStore
    }

    /// Whether this build may wear the "under construction / safe to tap" decoration
    /// (``UnderConstructionBadgeModifier``).
    ///
    /// Deliberately **not** ``purchasesUseSandbox``, which the badge used to read (AIA-0455). That
    /// property answers "is this purchase real money?", and it decides by *elimination*:
    /// `distributionChannel != .appStore`. `distributionChannel` recognises the App Store only by
    /// finding a receipt file on disk, and Apple documents that the app receipt can be absent until
    /// refreshed — after a restore from backup, for instance. A production install without its
    /// receipt therefore falls through to `.unknown`, and `.unknown != .appStore` is `true`, which
    /// put a yellow wrench on a paying customer's Subscribe button.
    ///
    /// This fails **closed** instead: it names the channels that are genuinely not production, and
    /// a channel it cannot identify is treated as production. The trade is deliberate — a tester on
    /// an unidentifiable install loses a reassurance; the alternative decorates someone's money.
    ///
    /// `purchasesUseSandbox` keeps its meaning untouched, because for a caller deciding whether a
    /// purchase is real, "I don't know" must never resolve to "yes, real money".
    static var showsUnderConstructionBadge: Bool {
        if isSimulator || isDebugConfiguration { return true }
        return decoratesControls(on: distributionChannel)
    }

    /// The channel half of ``showsUnderConstructionBadge``, as a pure function.
    ///
    /// Split out because the property is unreachable from a test: it short-circuits on
    /// `isSimulator || isDebugConfiguration`, both compile-time `true` in every test process, so
    /// no test can ever drive the switch below through the property. Testing the classification
    /// therefore needs it addressable on its own — the same reason ``EntitlementTransaction``
    /// exists for `StoreKit.Transaction`.
    ///
    /// Exhaustive on purpose, with no `default`: adding a channel must break the build here rather
    /// than silently opting production into a decoration.
    static func decoratesControls(on channel: DistributionChannel) -> Bool {
        switch channel {
        case .developmentLike, .testFlightLike: return true
        case .appStore, .unknown: return false
        }
    }
    static var isDevelopmentLikeDistribution: Bool {
		switch distributionChannel {
		case .developmentLike: return true
		default: return false
		}
	}
    
    /// True if Sentry throttle smoke test is enabled via env var.
    static var sentryThrottleSmokeTestMode: String? {
		if isAppStoreDistribution { return nil }
		return ProcessInfo.processInfo.environment["SENTRY_THROTTLE_SMOKE_TEST"]
	}
	
	// MARK: - Sentry Test Environment Variables
	
	/// Set `SENTRY_TEST_ERROR=1` to trigger a test error via LoggingPolicy.error at launch.
	/// Only available in non-App Store builds.
	static var shouldTriggerTestError: Bool {
		if isAppStoreDistribution { return false }
		return ProcessInfo.processInfo.environment["SENTRY_TEST_ERROR"] != nil
	}
	
	/// Set `SENTRY_TEST_CRASH=1` to trigger an immediate crash via SentrySDK.crash() at launch.
	/// Only available in non-App Store builds.
	static var shouldTriggerTestCrash: Bool {
		if isAppStoreDistribution { return false }
		return ProcessInfo.processInfo.environment["SENTRY_TEST_CRASH"] != nil
	}
	
	/// True if any Sentry test mode is enabled that requires the real crash reporter.
	/// Includes: throttle smoke test, test error, and test crash modes.
	static var requiresRealCrashReporter: Bool {
		sentryThrottleSmokeTestMode?.isEmpty == false
		|| shouldTriggerTestError
		|| shouldTriggerTestCrash
	}
}
