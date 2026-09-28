//
//  AppRuntime.swift
//  AI Archeology
//
//  AIA-0970: the process-level runtime, shared by the SwiftUI app and headless mode.
//

import Combine
import Foundation
import UIKit

/// What the app does whether or not any view is on screen: bootstrap, and the work that used to
/// hang off the root scene's modifiers — store-dependent services, the detailed-log brake,
/// background/foreground handling, the foreground entitlement re-check (AIA-0993), and starting auth.
///
/// Both entry points use it: `MLBrowser` (the SwiftUI app) and headless mode (AIA-0970).
/// That is what makes headless mode the app itself rather than a second implementation of it.
/// Presentation stays in the UI entry: the production banner, overlays, URL intake, and the Clerk
/// session watcher, which observes Clerk through the view environment and has no headless user yet.
///
/// Not an `ObservableObject` and not a singleton: the entry point that bootstraps it owns it for the
/// life of the process.
@MainActor
final class AppRuntime {

	let appState: AppState
	private var hasStarted = false
	private var subscriptions: Set<AnyCancellable> = []
	/// Owned here so their owner is explicit. The runtime lives as long as the process, so they are
	/// never cancelled — the same lifetime the root scene's `.task` had.
	private var tasks: [Task<Void, Never>] = []

	/// Builds the composition root in launch order. Called once, by an entry point — a bootstrap
	/// site, which is why it takes the container rather than reaching for it.
	///
	/// The order is load-bearing (AIA-0385): observability first, so nothing can report before it is
	/// listening; Clerk configured before any service might touch it; the composition root last.
	static func bootstrap(container: DependencyContainer) -> AppState {
		Observability.start(with: container.crashReporter)
		Observability.runTestTriggersIfEnabled()
		// Skipped for the DEBUG-only mock-auth path, which must not touch Clerk or the network.
		if container.usesMockAuth == false {
			ClerkAuthProvider.configure()
		}
		let appState = container.makeAppState()
		LoggingPolicy.info("MLBrowser app launching", logger: .lifecycle)
		// Answers "which Worker did this build talk to?" from a support log alone (AIA-0791).
		LoggingPolicy.info("Backend environment: \(BackendEnvironment.current.rawValue)", logger: .configuration)
		return appState
	}

	init(appState: AppState) {
		self.appState = appState
	}

	/// Starts the process-level work. Runs once per process, however often it is called:
	/// `UIApplicationSupportsMultipleScenes` is `false`, so the root scene's modifiers this replaces
	/// also ran once, and `FindingsSyncCoordinator.start()` in particular is not idempotent.
	func start() {
		guard hasStarted == false else { return }
		hasStarted = true
		startStoreDependentServices()
		bindDetailedApplicationLog()
		observeBackgroundAndForeground()
		observeForegroundForEntitlement()
		startAuthWhenReady()
	}

	// MARK: - Early: as soon as the process runs

	private func startStoreDependentServices() {
		let appState = appState
		tasks.append(Task { @MainActor in
			await appState.dataController.awaitStoreReady()
			// Reconnect to background URLSession tasks after launch. (No-op during XCTest runs;
			// gated inside Downloader.)
			appState.downloader.reconnectBackgroundSession()
			// Started after the store opens: sync reads and writes findings (AIA-727).
			appState.findingsSync.start()
		})
	}

	/// The remote brake on the detailed application log (AIA-0602). `@Published` delivers the current
	/// value on subscription, so the compiled default applies on a first launch that has not synced
	/// yet, and every live snapshot after it — a dashboard flip lands without a relaunch. `Settings`
	/// combines this with the user's own switch; off either way deletes the log.
	private func bindDetailedApplicationLog() {
		let settings = appState.settings
		appState.featureFlags.$snapshot
			.map(\.isDetailedApplicationLogEnabled)
			.removeDuplicates()
			.sink { isEnabled in
				settings.isDetailedLoggingFeatureEnabled = isEnabled
			}
			.store(in: &subscriptions)
	}

	private func observeBackgroundAndForeground() {
		let appState = appState
		NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
			.sink { _ in
				MainActor.assumeIsolated { Self.enterBackground(appState) }
			}
			.store(in: &subscriptions)
		NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
			.sink { _ in
				MainActor.assumeIsolated { Self.enterForeground(appState) }
			}
			.store(in: &subscriptions)
	}

	private static func enterBackground(_ appState: AppState) {
		LoggingPolicy.info("App entering background", logger: .lifecycle)
		LoggingPolicy.flushApplicationLog()
		appState.analytics.flushDetectionSessionSummary()
		// Ends any sounding annotation voice before the process is suspended, and refuses new ones
		// until the app is back (#785). A player left alive across a suspend outlives the shared audio
		// session the system tears down, and the retention task that eventually released it then
		// deallocated a player whose queue was already gone.
		//
		// Held under a background-task assertion because this handler cannot await: the stop reaches
		// the player through an actor hop, and without the assertion the process may be suspended
		// before the hop lands.
		let annotationSoundSuspension = BackgroundTaskAssertion(name: "Annotation sound suspend")
		Task { @MainActor in
			await appState.annotationSoundPlayer.suspend()
			annotationSoundSuspension.end()
		}
		if appState.detectionState.ontheflyDetectionEnabled {
			appState.settings.isDetectionPaused = true
			// `isUserInitiated: false`: this pause and the foreground resume are one detection session
			// either side of a suspend. Treating them as a fresh start would clear an outstanding
			// web-content interruption and refill the escalation budget (AIA-0879).
			appState.detectionState.ontheflyDetectionTapped(isUserInitiated: false)
		}
	}

	private static func enterForeground(_ appState: AppState) {
		LoggingPolicy.info("App entering foreground", logger: .lifecycle)
		Task { await appState.annotationSoundPlayer.resume() }
		if appState.settings.isDetectionPaused {
			appState.settings.isDetectionPaused = false
			// Resume is a continuation of the same detection session, not a new run.
			appState.detectionState.ontheflyDetectionTapped(recordAnalytics: false, isUserInitiated: false)
		}
	}

	/// Re-checks the StoreKit entitlement on every foreground once the app is ready (AIA-0993; it used
	/// to be `SubscriptionGateView`'s `onReceive`). A subscription that lapses while the app is in the
	/// background may push no `Transaction.updates` event, so without this the gate could stay open on
	/// a stale entitlement until the next cold launch.
	private func observeForegroundForEntitlement() {
		// Captured strongly: the runtime owns `appState` for the life of the process, and `AppState`
		// does not reference the runtime, so there is no cycle.
		let appState = appState
		Self.recheckEntitlementOnForeground(
			notifications: .default,
			isReady: { appState.isReady },
			subscriptionState: appState.subscriptionState
		)
		.store(in: &subscriptions)
	}

	/// The foreground entitlement re-check itself, parameterised so it can be tested without an
	/// `AppState`.
	///
	/// It is registered at `start()` and checks readiness **when the foreground arrives**, rather than
	/// being armed after `isReady` as auth's foreground refresh is, because the two are opposite. The
	/// view that did this was mounted only once `isReady` was true, and the launch entitlement check
	/// (`AppState.initialize()`) finishes *before* `isReady`, so a foreground during that check was
	/// skipped, and must stay skipped. Auth's first check runs after `isReady`, and a foreground
	/// during it has to queue a re-evaluation — see ``startAuthWhenReady()``.
	///
	/// On each `willEnterForeground`, once ready and with the payments surface on, it starts exactly
	/// one ``SubscriptionState/start()``, unserialized, as the view did: nothing coalesces it with a
	/// purchase, a restore or an earlier re-check still in flight. It is registered before the auth
	/// refresh, but both only start a task that then waits on StoreKit or the network, so neither
	/// the observer order nor which one finishes first is a contract.
	static func recheckEntitlementOnForeground(
		notifications: NotificationCenter,
		isReady: @escaping @MainActor () -> Bool,
		subscriptionState: SubscriptionState
	) -> AnyCancellable {
		notifications.publisher(for: UIApplication.willEnterForegroundNotification)
			.sink { _ in
				MainActor.assumeIsolated {
					guard isReady(), subscriptionState.isPaymentsSurfaceEnabled else { return }
					LoggingPolicy.info("Entitlement re-check on foreground", logger: .lifecycle)
					Task { await subscriptionState.start() }
				}
			}
	}

	// MARK: - After AppState is ready

	/// Starts auth only once `AppState` is ready, as the view root did: `.authLifecycle` was applied
	/// to content mounted only after `isReady`. `AccountAnalyticsCoordinator` depends on that order —
	/// entitlement resolves before auth at launch, and starting auth first would mark every signed-in
	/// subscriber anonymous on every launch.
	///
	/// The foreground refresh is armed at the same point and *before* the first check is awaited, as
	/// the view armed both together: that check is a network round trip, and a foreground during it
	/// must still queue a re-evaluation (`AuthState.refresh()` coalesces into `refreshPending`).
	private func startAuthWhenReady() {
		let appState = appState
		tasks.append(Self.afterReady(appState.$isReady) { [weak self] in
			self?.observeForegroundForAuth()
			await appState.authState.start()
		})
	}

	private func observeForegroundForAuth() {
		let authState = appState.authState
		NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
			.sink { _ in
				Task { await authState.refresh() }
			}
			.store(in: &subscriptions)
	}

	/// Runs `operation` once `isReady` first delivers `true`, and never before.
	///
	/// Static and parameterised by the publisher so the ordering contract can be tested without
	/// building an `AppState`.
	static func afterReady(
		_ isReady: Published<Bool>.Publisher,
		run operation: @escaping @MainActor () async -> Void
	) -> Task<Void, Never> {
		Task { @MainActor in
			for await ready in isReady.values where ready {
				break
			}
			guard Task.isCancelled == false else { return }
			await operation()
		}
	}
}
