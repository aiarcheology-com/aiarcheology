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
import BackgroundTasks
import UserNotifications

// MARK: - App Delegate bridge (Background URLSession + message notifications)

/// Needed for background `URLSession` to relaunch the app and deliver download completion callbacks.
/// Also the bootstrap home (sanctioned `.shared` site, AGENTS §3) for message-notification taps and
/// the background app-refresh that keeps notifications current (AIA-0115, S7).
final class BackgroundDownloadAppDelegate: NSObject, UIApplicationDelegate {

	// The delegate conforms to `UIApplicationDelegate` (@MainActor), so the type is main-actor
	// isolated; the constants and the background-task entry points below are `nonisolated` because
	// BGTaskScheduler invokes them off the main actor.

	/// BGAppRefreshTask identifier for the periodic app-messages notification sync (AIA-0115, S7).
	/// Must match the `BGTaskSchedulerPermittedIdentifiers` entry in `MLBrowser-Info.plist`.
	nonisolated static let messagesRefreshTaskIdentifier = "com.aiarcheology.mlbrowser.messages.refresh"

	/// How far out the next background refresh is requested. iOS treats this as the *earliest* begin
	/// date and decides the actual timing from usage patterns.
	nonisolated private static let messagesRefreshInterval: TimeInterval = 4 * 60 * 60

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

	@MainActor
	func application(
		_ application: UIApplication,
		didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
	) -> Bool {
		// Receive taps / foreground presentation for message notifications (AIA-0115, S7).
		UNUserNotificationCenter.current().delegate = self

		// Register the background app-refresh handler before launch completes (BGTaskScheduler
		// requires registration during launch). `using: nil` runs the handler on a background queue;
		// the handler hops to the main actor for the actual work.
		BGTaskScheduler.shared.register(
			forTaskWithIdentifier: Self.messagesRefreshTaskIdentifier,
			using: nil
		) { task in
			Self.handleMessagesRefresh(task)
		}

		// Ask for the first refresh window. Submit errors are expected on the simulator (BGTask
		// submission is unsupported there) and are logged-and-ignored.
		Self.scheduleNextMessagesRefresh()
		return true
	}

	// MARK: Background app-refresh (message notifications)

	/// Submits the next background app-refresh request. Idempotent — a pending request of the same
	/// identifier is replaced.
	nonisolated static func scheduleNextMessagesRefresh() {
		let request = BGAppRefreshTaskRequest(identifier: messagesRefreshTaskIdentifier)
		request.earliestBeginDate = Date(timeIntervalSinceNow: messagesRefreshInterval)
		do {
			try BGTaskScheduler.shared.submit(request)
		} catch {
			LoggingPolicy.debug(
				"Background message-refresh submit failed: \(error.localizedDescription)",
				logger: .lifecycle
			)
		}
	}

	/// Runs a background message-notification sync, then completes the task exactly once. Reschedules
	/// the next window up front so a missed/expired run still re-arms.
	nonisolated static func handleMessagesRefresh(_ task: BGTask) {
		scheduleNextMessagesRefresh()

		let completion = BackgroundRefreshCompletion(task)
		let work = Task { @MainActor in
			await runMessagesRefresh()
			completion.complete(success: true)
		}
		task.expirationHandler = {
			work.cancel()
			completion.complete(success: false)
		}
	}

	/// The main-actor work for a background refresh: restore targeting, refresh flags, re-evaluate
	/// visibility, and reconcile scheduled notifications without requesting authorization.
	@MainActor
	private static func runMessagesRefresh() async {
		let container = DependencyContainer.shared

		// Restore the last targeting context so a background refresh evaluates the same targeted
		// config a signed-in session would (AIA-0115). Fail closed: apply a persisted context if
		// present; if absent, leave the provider untouched (evaluate untargeted defaults) rather
		// than clearing a user another path may have set.
		if let data = UserDefaults.standard.data(forKey: TargetingCoordinator.contextDefaultsKey),
		   let context = try? JSONDecoder().decode(TargetingCoordinator.Context.self, from: data) {
			container.featureFlagProvider.setUser(id: context.id, custom: context.custom)
		}

		// Cooperative cancellation between stages: when iOS expires the task, the expiration
		// handler cancels this Task and completes unsuccessfully — mutating notification state
		// after that point would race the system's suspension.
		await container.featureFlagsState.refresh()
		guard !Task.isCancelled else { return }
		container.messageCenterState.reevaluate()
		guard !Task.isCancelled else { return }
		await container.messageNotificationCoordinator.sync(allowAuthorizationRequest: false)
	}
}

// MARK: - Message-notification delegate

extension BackgroundDownloadAppDelegate: UNUserNotificationCenterDelegate {

	/// A tapped message notification buffers its message id; presentation happens once a surface is
	/// available (``MessageCenterState/presentMessage(id:)``). The completion handler is called
	/// synchronously so we never capture the non-`Sendable` block across the main-actor hop.
	/// `nonisolated`: UNUserNotificationCenterDelegate is not main-actor isolated, so it must opt out
	/// of the type's inferred @MainActor and hop explicitly for the buffered-tap mutation.
	nonisolated func userNotificationCenter(
		_ center: UNUserNotificationCenter,
		didReceive response: UNNotificationResponse,
		withCompletionHandler completionHandler: @escaping () -> Void
	) {
		if let messageID = MessageNotificationPlanner.messageID(
			fromNotificationID: response.notification.request.identifier
		) {
			Task { @MainActor in
				DependencyContainer.shared.messageCenterState.presentMessage(id: messageID)
			}
		}
		completionHandler()
	}

	/// Present our message notifications while the app is in the foreground; ignore any foreign ones.
	nonisolated func userNotificationCenter(
		_ center: UNUserNotificationCenter,
		willPresent notification: UNNotification,
		withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
	) {
		let isMessageNotification = MessageNotificationPlanner.messageID(
			fromNotificationID: notification.request.identifier
		) != nil
		completionHandler(isMessageNotification ? [.banner, .list] : [])
	}
}

/// Bridges a non-`Sendable` `BGTask` across the Swift 6 concurrency boundary so both the async
/// refresh work and the system's expiration handler can signal completion. `BGTask`'s
/// `setTaskCompleted(success:)` is documented as callable from any thread; the lock guarantees it
/// fires exactly once.
private final class BackgroundRefreshCompletion: @unchecked Sendable {
	private let task: BGTask
	private let lock = NSLock()
	private var didComplete = false

	init(_ task: BGTask) { self.task = task }

	func complete(success: Bool) {
		lock.lock()
		defer { lock.unlock() }
		guard !didComplete else { return }
		didComplete = true
		task.setTaskCompleted(success: success)
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
						// Same rationale (AIA-0115): the About screen observes remote messages directly.
						.environmentObject(appState.messageCenter)
						.environment(\.managedObjectContext, appState.dataController.container.viewContext)
				}
			}
		}
		// The Clerk environment is injected here, above the gates, and is what
		// `AuthLifecycleModifier`'s session watcher reads. Injection and watcher are rehomed
		// together on purpose (AIA-0536): separated, the watcher stays mounted and inert, and
		// out-of-band sign-outs stop being noticed with nothing failing to show it.
		if appState.usesRealAuth == false {
			gate.authLifecycle(appState.authState)
		} else {
			gate
				.environment(Clerk.shared)
				.authLifecycle(appState.authState)
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
			// Above the auth/subscription/analytics gates (AIA-0115): a remote message can appear
			// over the login and paywall screens too. The banner is state-driven — it renders only
			// while `messageCenter.presented != nil`, so it stays in the tree while visible.
			.appMessageBanner(
				messageCenter: appState.messageCenter,
				authState: appState.authState,
				subscriptionState: appState.subscriptionState,
				analytics: appState.analytics,
				isReady: appState.isReady
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

	/// Whether content has ever been shown. Once it has, a *transient* loss of scope must not evict
	/// it: an out-of-band account switch keeps `gate == .ready` (``AuthState/setGate(_:)`` suppresses
	/// equal values) while the outgoing account is cleared, so this gate stays mounted and the
	/// presentation dips to `.pending` for the whole validation round-trip. Rendering the hold there
	/// would tear down the browser subtree mid-session and lose in-flight web-view state.
	@State private var hasEverResolved = false

	private enum Display {
		case choice
		case content
		case hold
	}

	private var display: Display {
		switch analytics.consentPresentation {
		case .ask: .choice
		case .resolved: .content
		// Holding is only right *before* anything has been shown. Afterwards the user is already in
		// the app and an unresolved scope is not a reason to throw them out of it — analytics simply
		// fails closed until it resolves.
		case .pending, .unavailable: hasEverResolved ? .content : .hold
		}
	}

	var body: some View {
		// One `case` per outcome rather than per presentation, so `.resolved → .pending` with content
		// already shown keeps the same structural identity and SwiftUI does not remount the subtree.
		Group {
			switch display {
			case .choice:
				AnalyticsChoiceView(analytics: analytics)
			case .content:
				content
			case .hold:
				// First-launch hold. The paywall-first cut-over owns the visual treatment —
				// `.unavailable` should explain that a connection is needed rather than spin (#545).
				ProgressView()
					.frame(maxWidth: .infinity, maxHeight: .infinity)
			}
		}
		.onChange(of: analytics.consentPresentation, initial: true) { _, presentation in
			if presentation == .resolved { hasEverResolved = true }
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
