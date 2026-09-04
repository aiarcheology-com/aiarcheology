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

/// Keeps the app running long enough to finish one short piece of teardown after it leaves the
/// foreground (#785).
///
/// A notification handler is synchronous, so work that has to hop to an actor cannot be awaited
/// there. Without an assertion the process can be suspended before the hop lands, which is exactly
/// what the teardown existed to prevent.
///
/// A class rather than a bare identifier so the expiration handler has something to call: the
/// system reclaims the assertion if it is held too long, and an assertion that expires unhandled
/// terminates the app.
@MainActor
final class BackgroundTaskAssertion {
	private var identifier: UIBackgroundTaskIdentifier = .invalid

	init(name: String) {
		identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
			self?.end()
		}
	}

	/// Idempotent: the expiration handler and the completing work race, and only one may end it.
	func end() {
		guard identifier != .invalid else { return }
		UIApplication.shared.endBackgroundTask(identifier)
		identifier = .invalid
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
		// Clears readable support-log exports that a PRE-AIA-0643 build left in the temporary
		// container. iOS does not wipe `tmp` on update, and the in-sheet cleanup only runs if the
		// user opens the Support form — which most never will. Off the main thread and best-effort:
		// it touches nothing this launch depends on.
		Task.detached(priority: .utility) { SupportRequestView.purgeLegacyApplicationLogExports() }
		LoggingPolicy.info("MLBrowser app launching", logger: .lifecycle)
		// Answers "which Worker did this build talk to?" from a support log alone. Diagnosing
		// AIA-0791 needed a decrypted log plus three source files to answer it.
		LoggingPolicy.info(
			"Backend environment: \(BackendEnvironment.current.rawValue)",
			logger: .configuration
		)
		#if DEBUG
		// A Debug build pointed at production can write real findings and delete a real account,
		// so the warning is a window rather than a view modifier: it has to survive `.sheet` and
		// `.fullScreenCover`, which is where every destructive action lives.
		ProductionBannerWindow.install(usesMockAuth: DependencyContainer.shared.usesMockAuth)
		#endif
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
				// The tour decides *when* the day-0 paywall may land, and the repository is what
				// lets a walled user still get their findings out (AIA-0556).
				tour: appState.tour,
				findingRepository: appState.findingRepository,
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
				AnalyticsChoiceGate(
					analytics: appState.analytics,
					freeAccess: appState.freeAccess,
					// The tour is the third thing that can hold the consent question back, and since
					// AIA-0567 it is the one that usually does: it now runs between the Welcome
					// screen and this question.
					tour: appState.tour
				) {
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
					ProgressView(L10n.Common.loading)
				}
			}
			// Single injection of the composition root's real-vs-mock auth flag for the whole
			// view tree; re-injected across sheet boundaries where needed (AIA-0385).
			.environment(\.usesRealAuth, appState.usesRealAuth)
			// Shared finding links (AIA-0650). Attached at the scene root because that is where iOS
			// delivers them, and because a link must be caught whatever is on screen — including the
			// paywall, the consent screen, and the launch spinner above.
			//
			// This is the app's only `onOpenURL`, and with the activity handler below it is the whole
			// of its URL intake. It sees every URL the app is handed. That
			// includes Clerk's OAuth callback on `com.aiarcheology.ios`, which is normally consumed
			// by `ASWebAuthenticationSession` and must never be swallowed here. `handle` returns
			// whether the URL was ours, delegating the decision to `FindingShareLink`'s strict
			// host/path matching, so anything that is not a finding link falls through untouched.
			//
			// Deliberately NOT gated on `isFindingShareLinkEnabled`: that flag governs whether this
			// app *emits* links. Links already shared are out in the world regardless, and turning
			// emission off must not break them for the strangers who tap them.
			.task {
				// A UI test cannot hand the app a URL without driving Safari, so a configured link is
				// delivered here instead — the same entry point `onOpenURL` uses, so the test
				// exercises the real buffering and import rather than a parallel path. Gated on
				// `isRunningUITests`; `UITestLaunchConfiguration` is dead code in shipping builds.
				guard AppEnvironment.isRunningUITests,
				      let config = UITestLaunchConfiguration.fromEnvironment,
				      let raw = config.sharedLinkURL,
				      let url = URL(string: raw)
				else { return }
				// Delivered more than once when the test asks, so the duplicate-import guarantee can
				// be exercised at all — two launches cannot do it, because each one starts from an
				// empty store (AIA-0836).
				for _ in 0..<max(1, config.sharedLinkDeliveries ?? 1) {
					appState.sharedFinding.handle(url)
				}
			}
			.onOpenURL { url in
				LoggingPolicy.debug("Shared finding: URL delivered via onOpenURL", logger: .state)
				appState.sharedFinding.handle(url)
			}
			// **The other half of the same door, and the app was missing it.**
			//
			// A universal link does not always arrive as a URL. iOS hands it to the app as an
			// `NSUserActivity` of type `NSUserActivityTypeBrowsingWeb`, and only some routes are
			// bridged into `onOpenURL` above. Tapping a link in Safari happened to land there;
			// scanning the same link with the Code Scanner did not — so the app launched, the user
			// watched it open, and nothing whatsoever happened. Found on a real iPhone with build
			// 999, and invisible in the app log precisely because no handler ran (AIA-0657).
			//
			// Both handlers funnel into the same `handle`, which is idempotent for our purposes: it
			// replaces the pending link with the newest one, so a URL arriving down both routes
			// buffers the same payload twice rather than presenting twice.
			.onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
				guard let url = activity.webpageURL else { return }
				LoggingPolicy.debug("Shared finding: URL delivered via NSUserActivity", logger: .state)
				appState.sharedFinding.handle(url)
			}
			// The remote brake on the detailed application log (AIA-0602). `initial: true` so the
			// compiled default is applied on a first launch that has not synced yet, and the live
			// snapshot thereafter — `FeatureFlagsState` observes the provider's change stream, so a
			// dashboard flip lands without a relaunch, which is the point of an emergency brake.
			// `Settings` combines this with the user's own switch; off either way deletes the log.
			.onChange(of: appState.featureFlags.snapshot.isDetailedApplicationLogEnabled, initial: true) { _, isEnabled in
				appState.settings.isDetailedLoggingFeatureEnabled = isEnabled
			}
			.onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
				LoggingPolicy.info("App entering background", logger: .lifecycle)
				LoggingPolicy.flushApplicationLog()
				appState.analytics.flushDetectionSessionSummary()
				// Ends any sounding annotation voice before the process is suspended, and refuses
				// new ones until the app is back (#785). A player left alive across a suspend
				// outlives the shared audio session the system tears down, and the retention task
				// that eventually released it then deallocated a player whose queue was already gone.
				//
				// Held under a background-task assertion because this handler cannot await: the stop
				// reaches the player through an actor hop, and without the assertion the process may
				// be suspended before the hop lands — which is the state the stop exists to prevent,
				// so an unheld `Task` would leave the comment above claiming more than it delivers.
				let annotationSoundSuspension = BackgroundTaskAssertion(name: "Annotation sound suspend")
				Task { @MainActor in
					await appState.annotationSoundPlayer.suspend()
					annotationSoundSuspension.end()
				}
				if appState.detectionState.ontheflyDetectionEnabled {
					appState.settings.isDetectionPaused = true
					appState.detectionState.ontheflyDetectionTapped()
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
				LoggingPolicy.info("App entering foreground", logger: .lifecycle)
				Task { await appState.annotationSoundPlayer.resume() }
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
			// Asked here rather than on the findings list, because a user who never opens that
			// screen would never be asked -- and their findings would sit unsynced with nothing
			// saying so (AIA-727).
			.backupConsentPrompt(appState.findingsSync)
			.task {
				// Reconnect to background URLSession tasks after app launch.
				// (No-op during XCTest runs; gated inside Downloader.)
				await appState.dataController.awaitStoreReady()
				appState.downloader.reconnectBackgroundSession()
				// Started here rather than at construction: sync reads and writes findings, so it
				// must not run before the store is open (AIA-727).
				appState.findingsSync.start()
			}
			// A received shared finding (AIA-0650, moved here by AIA-0657). **Applied last, on
			// purpose**: this modifier must be the outermost one in the scene so the card sits above
			// everything — the subscription gate, the analytics gate, and also `.screenshotReportOffer`
			// and `.appMessageBanner` above, which are themselves applied outside the gates. "Outside
			// the gates" and "top of the z-order" are not the same claim, and only the second one is
			// what the ticket asks for.
			//
			// It used to hang off `ContentView`, i.e. *inside* both gates, so a link tapped by someone
			// who had not yet dealt with the paywall, the welcome screen or the telemetry question was
			// buffered and shown only afterwards — the visitor a shared link exists to attract met a
			// wall and no finding.
			//
			// Still an **overlay** rather than a `.sheet`, and now more so than before: as an ancestor
			// of every sheet the app raises, a sheet here would present and immediately auto-dismiss
			// whenever one was already up (the trap `AnalyticsChoiceGate` documents). A link arriving
			// while Settings or the composer is open would flash and be lost.
			.sharedFindingPresentation(appState)
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

	/// The onboarding tour, read for one bit: whether it still owes the user a turn (AIA-0567).
	///
	/// `@Observable`, so reading ``TourState/isPendingOrRunning`` during `body` is all the tracking
	/// it needs — and both properties behind it are stored, which is why it is not `hasSeenTour`.
	let tour: TourState

	private let content: Content

	init(
		analytics: AnalyticsState,
		freeAccess: FreeAccessState,
		tour: TourState,
		@ViewBuilder content: () -> Content
	) {
		self.analytics = analytics
		self.freeAccess = freeAccess
		self.tour = tour
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
	/// Three independent reasons, all of them about *when* to ask rather than whether analytics may
	/// run: a sign-out that revealed an unanswered anonymous bucket (AIA-0536), a free-access window
	/// granted on this launch that its Welcome screen has not introduced yet (AIA-0556), and an
	/// onboarding tour that has not had its turn (AIA-0567). Consent fails closed while any of them
	/// holds, so waiting costs nothing.
	///
	/// The third is what makes the new first-run order actually hold. Welcome's Continue releases
	/// the second reason, and without this the consent question would land on top of the tour that
	/// same tap starts. It is deliberately `isPendingOrRunning` and not `isActive`: on the launch
	/// after a force-quit over the Welcome screen the tour is merely *armed* when this gate first
	/// computes — `day0Shown` is durable, but `isDay0AcknowledgementPending` is in-memory and so
	/// false — and an `isActive` test would flash the consent screen full-width, unmounting
	/// `ContentView`, before the gate above had started anything.
	private var isAskDeferred: Bool {
		analytics.isAskDeferredAfterSignOut
			|| freeAccess.isDay0AcknowledgementPending
			|| tour.isPendingOrRunning
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
				// The root swap: this replaces content, so there is nothing behind the card to
				// show through its dim. The opaque background belongs here and only here — see
				// the overlay branch below (AIA-0763).
				AnalyticsChoiceView(analytics: analytics)
					.background(Color(uiColor: .systemBackground).ignoresSafeArea())
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
				// **No opaque background here, unlike the `.choice` branch below** (AIA-0763). The
				// card dims what is behind it, and there is something behind it on this path — the
				// app the user is already using. A `systemBackground` under the card would hide the
				// very content the dim exists to show through.
				AnalyticsChoiceView(analytics: analytics)
					.transition(.opacity)
			}
		}
		.onChange(of: display, initial: true) { _, value in
			if value == .content { hasEverShownContent = true }
		}
		// The gate publishes, up its own window's view tree, whether its question is actually
		// rendered — so the back-up question can hold rather than land on top of it (AIA-0763).
		//
		// A preference and not a flag on `AnalyticsState`: that object is shared by every scene and
		// this fact is per-window. It is also self-clearing, which is what makes stranding
		// impossible — the value is recomputed with the view tree, so a gate that stops asking, or
		// that is torn down with its window, reverts to the default without anything having to
		// remember to write `false`.
		.preference(key: ConsentQuestionOnScreenKey.self, value: isQuestionOnScreen)
	}

	/// Whether this gate is putting the telemetry question to the user right now, by either of the
	/// two routes it has: as the screen the user arrives at, or as an overlay on content.
	private var isQuestionOnScreen: Bool {
		display == .choice || asksOverContent
	}
}

/// The telemetry question, drawn as a ``ConsentCard`` — the same view type as the back-up question
/// (AIA-0763).
///
/// It used to be a bare full-screen `VStack`: no backdrop, no card, sized to the whole screen. That
/// is what made the overlap unreadable rather than merely untidy — the back-up card is an overlay
/// applied further out in the scene, so when both were raised the card sat in the middle of this
/// screen with this screen's icon above it and its buttons below, and nothing said the two belonged
/// to different questions.
private struct AnalyticsChoiceView: View {
	let analytics: AnalyticsState

	var body: some View {
		ConsentCard(
			systemImage: "chart.bar.xaxis",
			title: L10n.Analytics.Choice.title,
			message: L10n.Analytics.Choice.message,
			primaryTitle: L10n.Analytics.Choice.enable,
			primaryIdentifier: Testability.Button.analyticsChoiceEnable,
			primaryAction: { analytics.chooseAnalytics(enabled: true) },
			secondaryTitle: L10n.Analytics.Choice.notNow,
			secondaryIdentifier: Testability.Button.analyticsChoiceNotNow,
			secondaryAction: { analytics.chooseAnalytics(enabled: false) }
		)
	}
}
