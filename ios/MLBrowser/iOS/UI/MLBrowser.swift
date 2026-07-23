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
			SubscriptionGateView(
				subscriptionState: appState.subscriptionState,
				authState: appState.authState,
				analytics: appState.analytics
			) {
				// Analytics consent is asked AFTER login + paywall (AIA-0447): the demanding
				// question no longer fronts the app. Funnel events fired on the paywall are
				// buffered by AnalyticsState until this choice is made, then flushed on enable.
				AnalyticsChoiceGate(analytics: appState.analytics) {
					ContentView()
						.environmentObject(appState)
						.environmentObject(appState.analytics)
						// Injected separately from `appState` because a nested ObservableObject
						// does not republish through its parent — views that gate on a live flag
						// must observe this directly (AIA-0350).
						.environmentObject(appState.featureFlags)
						.environment(\.managedObjectContext, appState.dataController.container.viewContext)
				}
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
				appState.analytics.flushDetectionSessionSummary()
				if appState.detectionState.ontheflyDetectionEnabled {
					appState.settings.isDetectionPaused = true
					appState.detectionState.ontheflyDetectionTapped()
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
				LoggingPolicy.info("App entering foreground", logger: .lifecycle)
				if appState.settings.isDetectionPaused {
					appState.settings.isDetectionPaused = false
					// Resume is a continuation of the same detection session, not a new run.
					appState.detectionState.ontheflyDetectionTapped(recordAnalytics: false)
				}
			}
			// Attached above the analytics/auth/subscription gates, so a bug on the paywall or the
			// sign-in screen is reportable too — exactly the screens a stuck user cannot get past
			// to reach Settings (AIA-0454).
			.screenshotReportOffer(
				settings: appState.settings,
				featureFlags: appState.featureFlags,
				// Passed explicitly: this modifier sits outside the `.environment(\.usesRealAuth)`
				// injection above, so its sheet cannot inherit the value.
				usesRealAuth: appState.usesRealAuth,
				currentURL: { appState.browserState.currentURL?.absoluteString }
			)
			.task {
				// Reconnect to background URLSession tasks after app launch.
				// (No-op during XCTest runs; gated inside Downloader.)
				await appState.dataController.awaitStoreReady()
				appState.downloader.reconnectBackgroundSession()
			}
		}
	}
}

/// Shows the analytics choice — now after login + paywall (AIA-0447) — until the user has answered
/// it, then renders its content. Keeping this as a distinct observed view is important: `AppState`
/// does not republish nested objects.
private struct AnalyticsChoiceGate<Content: View>: View {
	@ObservedObject var analytics: AnalyticsState
	private let content: Content

	init(analytics: AnalyticsState, @ViewBuilder content: () -> Content) {
		self.analytics = analytics
		self.content = content()
	}

	var body: some View {
		if analytics.shouldShowChoice {
			AnalyticsChoiceView(analytics: analytics)
		} else {
			content
		}
	}
}

private struct AnalyticsChoiceView: View {
	let analytics: AnalyticsState

	var body: some View {
		VStack(spacing: 20) {
			Spacer()
			Image(systemName: "chart.bar.xaxis")
				.font(.system(size: 48))
				.foregroundStyle(.tint)
				.accessibilityHidden(true)
			Text(L10n.Analytics.Choice.title)
				.font(.title2.bold())
				.multilineTextAlignment(.center)
			Text(L10n.Analytics.Choice.message)
				.multilineTextAlignment(.center)
				.foregroundStyle(.secondary)
				.padding(.horizontal, 28)
			Button(L10n.Analytics.Choice.enable) {
				analytics.chooseAnalytics(enabled: true)
			}
			.buttonStyle(.borderedProminent)
			.controlSize(.large)
			.testability(Testability.Button.analyticsChoiceEnable)
			Button(L10n.Analytics.Choice.notNow) {
				analytics.chooseAnalytics(enabled: false)
			}
			.buttonStyle(.bordered)
			.controlSize(.large)
			.testability(Testability.Button.analyticsChoiceNotNow)
			Spacer()
		}
		.padding()
	}
}
