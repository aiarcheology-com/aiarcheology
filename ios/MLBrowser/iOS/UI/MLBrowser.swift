//
//  AI_ArcheologyApp.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 24.08.23.
//

import SwiftUI
import OSLog
import Sentry

@main
struct MLBrowser: App {
	@StateObject var appState = AppState()
	
	init() {
		Observability.start(with: DependencyContainer.shared.crashReporter)
		Self.runSentryTestErrorIfEnabled()
		Self.runSentryTestCrashIfEnabled()
		Self.runSentryThrottleSmokeTestIfEnabled()

		LoggingPolicy.info("MLBrowser app launching", logger: .lifecycle)
	}
	
	var body: some Scene {
		WindowGroup {
			Group {
				if appState.isReady {
					ContentView()
						.environmentObject(appState)
						.environment(\.managedObjectContext, appState.dataController.container.viewContext)
				} else {
					ProgressView("Loading...")
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
				LoggingPolicy.info("App entering background", logger: .lifecycle)
				if appState.guide.ontheflyDetectionEnabled {
					appState.settings.isDetectionPaused = true
					appState.guide.ontheflyDetectionTapped()
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
				LoggingPolicy.info("App entering foreground", logger: .lifecycle)
				if appState.settings.isDetectionPaused {
					appState.settings.isDetectionPaused = false
					appState.guide.ontheflyDetectionTapped()
				}
			}
		}
	}
	
	/// Triggers a test error via `LoggingPolicy.error` when `SENTRY_TEST_ERROR` env var is set.
	/// Use to verify Sentry error capture is working correctly.
	/// Not available in App Store builds.
	private static func runSentryTestErrorIfEnabled() {
		guard AppEnvironment.shouldTriggerTestError else { return }
		
		Logger.logger.warning("[SentryTest] SENTRY_TEST_ERROR is set - triggering test error")
		LoggingPolicy.error(
			"Sentry test error triggered via SENTRY_TEST_ERROR environment variable",
			error: NSError(domain: "SentryTestError", code: 42, userInfo: [
				NSLocalizedDescriptionKey: "This is a test error to verify Sentry integration"
			]),
			logger: .lifecycle
		)
		Logger.logger.info("[SentryTest] Test error sent to Sentry")
	}
	
	/// Triggers an immediate crash via `SentrySDK.crash()` when `SENTRY_TEST_CRASH` env var is set.
	/// Use to verify Sentry crash reporting is working correctly.
	/// Not available in App Store builds.
	private static func runSentryTestCrashIfEnabled() {
		guard AppEnvironment.shouldTriggerTestCrash else { return }
		
		Logger.logger.warning("[SentryTest] SENTRY_TEST_CRASH is set - triggering test crash in 1 second")
		
		// Delay slightly to ensure Sentry SDK is fully initialized and breadcrumb is recorded
		LoggingPolicy.fault("About to trigger test crash via SENTRY_TEST_CRASH", logger: .lifecycle)
		
		DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
			Logger.logger.fault("[SentryTest] Triggering SentrySDK.crash() now")
			SentrySDK.crash()
		}
	}
	
	/// Opt-in smoke test to validate Sentry throttling/deduplication.
	///
	/// Enable by setting environment variable `SENTRY_THROTTLE_SMOKE_TEST`:
	/// - `duplicate`: emits many identical errors (should mostly be deduped)
	/// - `global`: emits many unique errors (should hit global cap)
	/// Guarded to **Release builds only** to avoid confusion (Debug uses NoOp crash reporter).
	private static func runSentryThrottleSmokeTestIfEnabled() {
		let mode = AppEnvironment.sentryThrottleSmokeTestMode
		guard let mode, !mode.isEmpty else { return }
		
		Logger.logger.info("[SentryThrottle] Starting smoke test with mode: \(mode, privacy: .public)")
		
		Task.detached(priority: .background) {
			switch mode {
			case "duplicate":
				for _ in 0..<120 {
					LoggingPolicy.error(
						"Sentry throttle smoke test (duplicate)",
						error: NSError(domain: "SentryThrottleSmokeTest", code: 1)
					)
				}
				Logger.logger.info("[SentryThrottle] Smoke test 'duplicate' completed: sent 120 duplicate events")
				
			case "global":
				for i in 0..<200 {
					LoggingPolicy.error(
						"Sentry throttle smoke test (global)",
						error: NSError(domain: "SentryThrottleSmokeTest", code: i)
					)
				}
				Logger.logger.info("[SentryThrottle] Smoke test 'global' completed: sent 200 unique events")
				
			default:
				Logger.logger.warning("Unknown SENTRY_THROTTLE_SMOKE_TEST value: \(mode, privacy: .public)")
			}
		}
	}
}
