//
//  ConnectivityMonitor.swift
//  AI Archeology
//
//  AIA-0757: the connectivity trigger `AuthState` was missing.
//

import Foundation
import Network
import OSLog

/// Reports the moment the device regains a usable network path.
///
/// A boundary protocol rather than a bare `NWPathMonitor` because the thing that needs testing is
/// precisely the behaviour a real monitor cannot be asked for: "the network came back". The two
/// other monitors in the app (`Downloader`, `FindingsSyncCoordinator`) drive work that is harmless
/// to run again, so they can hold theirs directly; this one drives a **gate the UI reads as fact**,
/// and a wrong answer there tells the user signing in is unavailable when it is available.
///
/// `@MainActor` for the same reason ``AuthProviding`` is: the only consumer is main-actor isolated,
/// and hopping off just to hop back would buy nothing.
@MainActor
protocol ConnectivityMonitoring: AnyObject {
	/// Begins watching, and calls `onReconnect` on each **unsatisfied → satisfied** transition.
	///
	/// Deliberately edge-triggered. `NWPath.satisfied` means "an interface is up", not "the server is
	/// reachable", and it is reported for changes that are not reconnections at all (a new interface,
	/// a DNS change, a route update). A level-triggered handler would re-ask on every one of them.
	///
	/// Calling this more than once is a no-op — see ``NWPathConnectivityMonitor``.
	///
	/// `onReconnect` is `async` so the work it starts is something a caller can await. That is what
	/// lets a test drive a reconnection and assert on the result without sleeping or yielding a
	/// guessed number of times.
	func start(onReconnect: @escaping @MainActor () async -> Void)
}

/// The unsatisfied → satisfied rule, as a value so it can be tested without a real network path.
///
/// Extracted deliberately: the `NWPathMonitor` wiring around it cannot be unit-tested, and leaving
/// the rule inside that wiring would mean the one piece of logic here shipped with no coverage at
/// all. What is left untested is the wiring — a mis-wired handler is what P3b's airplane-mode check
/// is for.
struct ConnectivityEdgeDetector {
	/// The previous satisfaction, or `nil` before the first report.
	private var wasSatisfied: Bool?

	/// Records `isSatisfied` and answers whether it is a **reconnection**.
	///
	/// The first report is never one: it describes the state the app launched in, and treating it as
	/// an edge would fire a refresh on every cold launch that already had signal — duplicating the
	/// pass `AuthState.start()` is about to run anyway.
	mutating func isReconnection(isSatisfied: Bool) -> Bool {
		defer { wasSatisfied = isSatisfied }
		return wasSatisfied == false && isSatisfied
	}
}

/// The production monitor, wrapping `NWPathMonitor`.
///
/// **Never started by a test.** `AuthState` takes its monitor as an optional injected dependency
/// with no production default precisely so the ~23 existing `AuthState(provider:)` constructions in
/// the unit suite cannot spin up real network monitoring underneath assertions that count
/// validation round-trips. (`FeatureSessionTests` does *construct* one, by forcing
/// `AccountSession.authState` — but constructing is inert: nothing observes the network until
/// ``start(onReconnect:)`` runs, and only `AuthState.start()` calls it.)
///
/// No `cancel()`/`deinit` teardown: the only instance is owned by `AccountSession`, which is owned by
/// the composition root, so it lives exactly as long as the process. A `stop()` nothing calls would
/// be dead code claiming a lifecycle this type does not have.
@MainActor
final class NWPathConnectivityMonitor: ConnectivityMonitoring {
	private let monitor = NWPathMonitor()
	private let queue = DispatchQueue(label: "com.aiarcheology.auth.connectivity")

	/// Guards `NWPathMonitor.start(queue:)`, which traps when called twice on the same monitor.
	private var isRunning = false

	/// Confined to ``queue``, which is the only place it is touched.
	///
	/// Deliberately evaluated there rather than on the main actor. Hopping first and deciding after
	/// meant one unstructured `Task` per path update, and those have no ordering guarantee between
	/// them — a queued `unsatisfied, satisfied` pair could be processed in reverse, which both
	/// fabricates an edge that never happened and swallows the one that did. `NWPathMonitor`
	/// delivers to its queue serially, so deciding there is what makes the sequence trustworthy;
	/// only the callback needs the main actor.
	private nonisolated(unsafe) var edges = ConnectivityEdgeDetector()

	func start(onReconnect: @escaping @MainActor () async -> Void) {
		guard isRunning == false else { return }
		isRunning = true
		monitor.pathUpdateHandler = { [weak self] path in
			guard let self, self.edges.isReconnection(isSatisfied: path.status == .satisfied) else { return }
			LoggingPolicy.info("Network path came back — re-evaluating the auth gate", logger: .networking)
			Task { @MainActor in await onReconnect() }
		}
		monitor.start(queue: queue)
	}
}
