//
//  AI_ArcheologyApp.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 24.08.23.
//

import SwiftUI
import OSLog
import UIKit
import ClerkKit

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
	@StateObject private var appState: AppState

	init() {
		Observability.start(with: DependencyContainer.shared.crashReporter)
		Observability.runTestTriggersIfEnabled()
		// Configure Clerk for the auth gate (AIA-0340). Skipped for the DEBUG-only
		// mock-auth path used by UI tests, which must not touch Clerk or the network.
		if !DependencyContainer.shared.usesMockAuth {
			ClerkAuthProvider.configure()
		}
		// Build the app's single composition root LAST — after observability is started and
		// Clerk is configured — so service construction never precedes them (AIA-0385).
		_appState = StateObject(wrappedValue: DependencyContainer.shared.makeAppState())
		LoggingPolicy.info("MLBrowser app launching", logger: .lifecycle)
	}

	/// The app behind the authentication gate (AIA-0340). `Clerk.shared` is injected
	/// only on the real-auth path; the mock path never accesses it.
	@ViewBuilder
	private var authGatedContent: some View {
		let gate = AuthGateView(authState: appState.authState) {
			// Whole-app subscription gate (AIA-0343): once signed in, the app proper shows
			// only while subscribed (free trial counts); otherwise the paywall is the root.
			SubscriptionGateView(subscriptionState: appState.subscriptionState, authState: appState.authState) {
				ContentView()
					.environmentObject(appState)
					.environment(\.managedObjectContext, appState.dataController.container.viewContext)
			}
		}
		if appState.usesRealAuth == false {
			gate
		} else {
			gate.environment(Clerk.shared)
		}
	}

	var body: some Scene {
		WindowGroup {
			Group {
				if appState.isReady {
					authGatedContent
				} else {
					ProgressView("Loading...")
				}
			}
			// Single injection of the composition root's real-vs-mock auth flag for the whole
			// view tree; re-injected across sheet boundaries where needed (AIA-0385).
			.environment(\.usesRealAuth, appState.usesRealAuth)
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
