//
//  AI_ArcheologyApp.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 24.08.23.
//

import SwiftUI
import OSLog

@main
struct MLBrowser: App {
	@StateObject var appState = AppState()
	
	init() {
		Observability.start(with: DependencyContainer.shared.crashReporter)
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
