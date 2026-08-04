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

	/// The app behind the subscription gate (AIA-0536).
	///
	/// **Entitlement is the gate; signing in is not.** The auth gate used to wrap this, so nobody
	/// reached the paywall — or the app — without an account. That inverted on #543: a paywall the
	/// user meets before they have experienced anything is a worse ask than a sign-in wall, and the
	/// sign-in wall was the larger 5.1.1(v) risk. Sign-in is now offered contextually instead
	/// (`SignInSheet`), from the paywall, the drawer, Settings, and once after a finding is saved.
	///
	/// `AuthState` is still driven — by `.authLifecycle()` below — because analytics consent,
	/// purchase tagging and the account UI all depend on knowing who is signed in. It just no
	/// longer decides whether the app renders.
	///
	/// `Clerk.shared` is injected only on the real-auth path; the mock path never accesses it.
	@ViewBuilder
	private var authGatedContent: some View {
		let gate = Group {
			// Whole-app subscription gate (AIA-0343), now the root: the app proper shows while
			// subscribed (a free trial counts) or inside the app-managed free-access window
			// (AIA-0556); otherwise the paywall is what the user meets.
			SubscriptionGateView(
				subscriptionState: appState.subscriptionState,
				authState: appState.authState,
				freeAccess: appState.freeAccess,
				analytics: appState.analytics
			) {
				// Analytics consent is asked after the paywall (AIA-0447), of every entitled user —
				// anonymous included (AIA-0536). Funnel events fired on the paywall are buffered by
				// AnalyticsState until this choice is made, then flushed on enable.
				//
				// `freeAccess` is passed for the ordering, not the gating: a window granted on this
				// launch opens the gate before the user has seen anything, so the ask waits until the
				// paywall that explains the window has been shown (AIA-0556) — otherwise "Enable
				// analytics?" is the first screen of a brand-new install and the tour never mounts.
				AnalyticsChoiceGate(analytics: appState.analytics, freeAccess: appState.freeAccess) {
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
		// `.environment` must come AFTER `.authLifecycle`, not before (AIA-0536).
		//
		// The lifecycle modifier mounts `ClerkSessionWatcher` in its own `.background`, which is a
		// *sibling* of the content it wraps — not a descendant of it. Applying the environment to
		// `gate` first therefore hands Clerk to everything except the one view that needs it, and
		// the watcher is left mounted and inert: out-of-band sign-outs stop being noticed, with
		// nothing failing to show it. Applied last, the environment is an ancestor of the whole
		// modified view, background included.
		if appState.usesRealAuth == false {
			gate.authLifecycle(appState.authState)
		} else {
			gate
				.authLifecycle(appState.authState)
				.environment(Clerk.shared)
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
			// over the paywall too. The banner is state-driven — it renders only
			// while `messageCenter.presented != nil`, so it stays in the tree while visible.
			.appMessageBanner(
				messageCenter: appState.messageCenter,
				subscriptionState: appState.subscriptionState,
				analytics: appState.analytics,
				freeAccess: appState.freeAccess,
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
///
/// The ask is *deferred*, never skipped, while something else has the floor: a sign-out that
/// revealed an unanswered bucket (AIA-0536), or a free-access window granted on this launch whose
/// paywall the user has not met yet (AIA-0556) — see ``isAskDeferred``.
private struct AnalyticsChoiceGate<Content: View>: View {
	@ObservedObject var analytics: AnalyticsState
	@ObservedObject var freeAccess: FreeAccessState
	private let content: Content

	init(analytics: AnalyticsState, freeAccess: FreeAccessState, @ViewBuilder content: () -> Content) {
		self.analytics = analytics
		self.freeAccess = freeAccess
		self.content = content()
	}

	/// Whether content has ever been shown. Once it has, a *transient* loss of scope must not evict
	/// it: an out-of-band account switch keeps `gate == .ready` (``AuthState/setGate(_:)`` suppresses
	/// equal values) while the outgoing account is cleared, so this gate stays mounted and the
	/// presentation dips to `.pending` for the whole validation round-trip. Rendering the hold there
	/// would tear down the browser subtree mid-session and lose in-flight web-view state.
	///
	/// Derived from what was *shown*, not from consent having resolved (AIA-0556). A deferred ask
	/// renders content while consent is still unanswered, so "has resolved" no longer implies "has
	/// been on screen" — and when the deferral lifts, this is what routes the question to the
	/// overlay instead of a root swap that would take the tour's web view with it.
	@State private var hasEverShownContent = false

	private enum Display: Equatable {
		case choice
		case content
		case hold
	}

	/// Whether the consent question must wait rather than be put to the user right now.
	///
	/// Two independent reasons, both of them about *when* to ask rather than whether analytics may
	/// run: a sign-out that revealed an unanswered anonymous bucket (AIA-0536), and a free-access
	/// window granted on this launch that has not yet been introduced by its paywall (AIA-0556).
	/// Consent fails closed while either holds, so waiting costs nothing.
	private var isAskDeferred: Bool {
		analytics.isAskDeferredAfterSignOut || freeAccess.isDay0AcknowledgementPending
	}

	/// Whether the consent question is being asked *over* content the user is already using, rather
	/// than as the screen they arrive at. Rendered as an overlay in that case — see ``body``.
	private var asksOverContent: Bool {
		// Deferred asks stay silent: a sign-out is a disengagement act, and a first-run window is
		// still being explained. Analytics simply stays off; the question returns at the next
		// arrival, sign-in, explicit reset, or once the day-0 paywall has been seen.
		hasEverShownContent && analytics.consentPresentation == .ask && !isAskDeferred
	}

	private var display: Display {
		switch analytics.consentPresentation {
		// Asking is a full screen only on the way *in*. Afterwards it must not replace the root:
		// under paywall-first, signing in happens mid-session by design, and a first sign-in — or an
		// A→B switch, or a sign-out for anyone whose anonymous bucket is unanswered — selects a new
		// scope with no stored choice, which lands here. Swapping the root then destroys the
		// `WKWebView` the user is looking at, along with the page, scroll position and history.
		// Before the cut-over this was unreachable: consent could only ever be asked at launch.
		//
		// A deferred ask takes the same branch for a different reason: the question is not refused,
		// it is queued behind the paywall that explains the free window, and content goes up first.
		case .ask: (hasEverShownContent || isAskDeferred) ? .content : .choice
		case .resolved: .content
		// Holding is only right *before* anything has been shown, and only while the wait is going
		// to end. Afterwards the user is already in the app, and an unresolved scope is not a reason
		// to throw them out of it — analytics simply fails closed until it resolves.
		case .pending: hasEverShownContent ? .content : .hold
		// **Never hold on `.unavailable`.** It means no scope can be selected *at all* — the session
		// cannot be verified — so the wait would never end. On a cold launch in airplane mode an
		// entitled user reaches exactly this state, and holding here would strand them on a spinner
		// in front of an app whose features are entirely on-device. That is the lockout AIA-0536
		// exists to remove (#532); it must not come back through the consent gate. They go in, with
		// analytics off until a scope can be resolved.
		case .unavailable: .content
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
		// An **overlay**, deliberately not a sheet. Both keep `content` mounted, which is the point —
		// but this gate is an ancestor of every sheet the app presents, and a sheet presented from an
		// ancestor while a descendant's sheet is up presents-then-auto-dismisses (the same trap
		// `SettingsView` documents for the Clerk profile). Sign-in and Restore Defaults both happen
		// *inside* the Settings sheet, so a sheet here would never be seen on exactly the paths that
		// raise the question.
		//
		// The consequence is deliberate and worth stating: while a sheet covers the app, the question
		// waits behind it and appears when that sheet closes. Finishing in Settings and then being
		// asked is a better sequence than having Settings yanked away mid-action, which is what the
		// old root swap did.
		.overlay {
			if asksOverContent {
				AnalyticsChoiceView(analytics: analytics)
					.background(Color(uiColor: .systemBackground))
					.transition(.opacity)
			}
		}
		.onChange(of: display, initial: true) { _, value in
			if value == .content { hasEverShownContent = true }
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
