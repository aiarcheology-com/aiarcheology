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
/// ### 2) Compile-time “is test build?” flags (optional)
/// Add Swift flags per target (usually in Debug):
/// - Unit Test target → Build Settings → Other Swift Flags: `-D UNIT_TESTING`
/// - UI Test target   → Build Settings → Other Swift Flags: `-D UI_TESTING`
///
/// `isCompiledForUnitTests` / `isCompiledForUITests` become compile-time constants
/// that the optimizer can strip from non-test builds.
///
/// ### 3) Runtime UI-test vs unit-test detection
/// In the UI test target’s `setUp` (or before launching):
///
/// ```swift
/// let app = XCUIApplication()
/// app.launchEnvironment["UI_TESTING"] = "1"
/// app.launch()
/// ```
///
/// Inside the app process, `isRunningUITests` / `isRunningUnitTests` use the XCTest
/// environment plus that `UI_TESTING` marker.
///
/// ### 4) Runtime distribution channel detection (App Store vs TestFlight-like vs Dev/AdHoc)
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

    /// True when the code was compiled for the Unit Test target
    /// (requires `-D UNIT_TESTING` in that target’s Swift flags).
    static let isCompiledForUnitTests: Bool = {
        #if UNIT_TESTING
        return true
        #else
        return false
        #endif
    }()

    /// True when the code was compiled for the UI Test target
    /// (requires `-D UI_TESTING` in that target’s Swift flags).
    static let isCompiledForUITests: Bool = {
        #if UI_TESTING
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
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil &&
               env["UI_TESTING"] == "1"
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
