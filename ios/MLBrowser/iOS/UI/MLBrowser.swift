//
//  AI_ArcheologyApp.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 24.08.23.
//

import SwiftUI
import OSLog
import UIKit

// MARK: - App Delegate bridge (Background URLSession)

/// Needed for background `URLSession` to relaunch the app and deliver download completion callbacks.
final class BackgroundDownloadAppDelegate: NSObject, UIApplicationDelegate {
	@MainActor
	func application(
		_ application: UIApplication,
		handleEventsForBackgroundURLSession identifier: String,
		completionHandler: @escaping () -> Void
	) {
		// Only handle our downloader session; otherwise, release immediately.
		guard identifier == Downloader.backgroundSessionIdentifier else {
			completionHandler()
			return
		}

		Task { @MainActor in
			let downloader = DependencyContainer.shared.downloader
			downloader.backgroundSessionCompletionHandler = completionHandler
			downloader.reconnectBackgroundSession()
		}
	}
}

@main
struct MLBrowser: App {
	@UIApplicationDelegateAdaptor(BackgroundDownloadAppDelegate.self) var appDelegate
	@StateObject var appState = AppState()
	
	init() {
		Observability.start(with: DependencyContainer.shared.crashReporter)
		Observability.runTestTriggersIfEnabled()
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
			.task {
				// Reconnect to background URLSession tasks after app launch.
				// (No-op during XCTest runs; gated inside Downloader.)
				await appState.dataController.awaitStoreReady()
				appState.downloader.reconnectBackgroundSession()
			}
		}
	}
}
