//
//  AppRuntimeTests.swift
//  MLBrowserUnitTests
//
//  AIA-0970, AIA-0993.
//

import Combine
import StoreKit
import UIKit
import XCTest
@testable import ML_Browser

/// The launch-order mechanism `AppRuntime` starts auth through: `afterReady` never runs its operation
/// before `AppState.isReady`.
///
/// `AccountAnalyticsCoordinator` depends on entitlement resolving before auth at launch; starting
/// auth first would mark every signed-in subscriber anonymous on every launch. This pins the helper,
/// not its call site: an `AppState` cannot be built outside the composition root, so that
/// `startAuthWhenReady` goes through `afterReady` is left to review.
@MainActor
final class AppRuntimeTests: XCTestCase {

	private final class Readiness: ObservableObject {
		@Published var isReady = false
	}

	@MainActor
	private final class Probe {
		var runs = 0
	}

	func test_afterReady_doesNotRunBeforeReady_thenRunsOnce() async {
		let readiness = Readiness()
		let probe = Probe()
		let task = AppRuntime.afterReady(readiness.$isReady) { probe.runs += 1 }

		// Give the task every chance to run early.
		for _ in 0..<20 {
			await Task.yield()
		}
		XCTAssertEqual(probe.runs, 0, "auth must not start before the app is ready")

		readiness.isReady = true
		await task.value
		XCTAssertEqual(probe.runs, 1)
	}

	func test_afterReady_runsAtOnceWhenAlreadyReady() async {
		let readiness = Readiness()
		readiness.isReady = true
		let probe = Probe()
		await AppRuntime.afterReady(readiness.$isReady) { probe.runs += 1 }.value
		XCTAssertEqual(probe.runs, 1)
	}

	func test_afterReady_cancelledBeforeReady_neverRuns() async {
		let readiness = Readiness()
		let probe = Probe()
		let task = AppRuntime.afterReady(readiness.$isReady) { probe.runs += 1 }
		task.cancel()
		readiness.isReady = true
		await task.value
		XCTAssertEqual(probe.runs, 0)
	}
}

/// The foreground entitlement re-check (AIA-0993), which moved out of `SubscriptionGateView` into
/// `AppRuntime` so that headless mode runs it too.
///
/// Each test uses its own `NotificationCenter`: the unit tests run inside the app, whose own
/// `AppRuntime` observes `.default`. Notifications are posted from the main actor, as UIKit posts
/// `willEnterForeground`; the re-check's sink assumes it. As with `afterReady`, that `start()` wires
/// this helper to `AppState.isReady` and `.default` is left to review.
@MainActor
final class AppRuntimeForegroundEntitlementTests: XCTestCase {

	/// Counts `start()` calls and reports a settable entitlement, which `SubscriptionState` publishes
	/// after each call.
	@MainActor
	private final class CountingSubscriptionProvider: SubscriptionProviding {
		var onEntitlementChange: (() -> Void)?
		var isSubscribed = false
		var products: [Product] = []
		var currentTransactionID: UInt64? { isSubscribed ? 1 : nil }
		var currentExpirationDate: Date? { nil }
		var isInTrial: Bool { false }
		private(set) var startCalls = 0
		var onStart: (() -> Void)?

		func start() async {
			startCalls += 1
			onStart?()
		}

		func resetStartCalls() {
			startCalls = 0
		}

		func loadProducts() async {}
		func purchase(_ product: Product) async -> PurchaseOutcome { .failed }
		func restore() async -> RestoreOutcome { .nothingToRestore }
	}

	@MainActor
	private final class Readiness {
		var isReady = false
	}

	private var cancellables: Set<AnyCancellable> = []

	override func tearDown() async throws {
		cancellables.removeAll()
		try await super.tearDown()
	}

	private func observe(
		_ center: NotificationCenter,
		readiness: Readiness,
		subscriptionState: SubscriptionState
	) {
		AppRuntime.recheckEntitlementOnForeground(
			notifications: center,
			isReady: { readiness.isReady },
			subscriptionState: subscriptionState
		)
		.store(in: &cancellables)
	}

	private func postForeground(_ center: NotificationCenter) {
		center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
	}

	/// Lets every main-actor job enqueued so far run. A re-check started by a post is enqueued during
	/// that post, so the main actor's FIFO order runs it before these barriers complete.
	private func drainMainActor() async {
		for _ in 0..<3 {
			await Task { @MainActor in }.value
		}
	}

	/// Posts one foreground and waits until the re-check has run `expected` times in all, then lets
	/// anything else it started finish, so a second, unexpected re-check is counted too.
	private func postForegroundAndWait(
		_ center: NotificationCenter,
		provider: CountingSubscriptionProvider,
		until expected: Int
	) async {
		let started = expectation(description: "entitlement re-check started")
		provider.onStart = { if provider.startCalls >= expected { started.fulfill() } }
		postForeground(center)
		await fulfillment(of: [started], timeout: 5)
		provider.onStart = nil
		await drainMainActor()
	}

	func test_foreground_beforeReady_doesNotRecheck_thenRechecksOnceReady() async {
		let provider = CountingSubscriptionProvider()
		let subscriptionState = SubscriptionState(provider: provider, isPaymentsEnabled: true)
		let center = NotificationCenter()
		let readiness = Readiness()
		observe(center, readiness: readiness, subscriptionState: subscriptionState)

		postForeground(center)
		await drainMainActor()
		XCTAssertEqual(provider.startCalls, 0, "the gate that did this was not mounted before the app was ready")

		readiness.isReady = true
		await postForegroundAndWait(center, provider: provider, until: 1)
		XCTAssertEqual(provider.startCalls, 1)
	}

	func test_foreground_whenReady_rechecksExactlyOncePerForeground() async {
		let provider = CountingSubscriptionProvider()
		let subscriptionState = SubscriptionState(provider: provider, isPaymentsEnabled: true)
		let center = NotificationCenter()
		let readiness = Readiness()
		readiness.isReady = true
		observe(center, readiness: readiness, subscriptionState: subscriptionState)

		await postForegroundAndWait(center, provider: provider, until: 1)
		XCTAssertEqual(provider.startCalls, 1)

		await postForegroundAndWait(center, provider: provider, until: 2)
		XCTAssertEqual(provider.startCalls, 2)
	}

	func test_foreground_withPaymentsSurfaceOff_doesNotRecheck() async {
		let provider = CountingSubscriptionProvider()
		let subscriptionState = SubscriptionState(provider: provider, isPaymentsEnabled: false)
		let center = NotificationCenter()
		let readiness = Readiness()
		readiness.isReady = true
		observe(center, readiness: readiness, subscriptionState: subscriptionState)

		postForeground(center)
		await drainMainActor()
		XCTAssertEqual(provider.startCalls, 0)
	}

	func test_foreground_afterLapseWhileBackgrounded_publishesUnsubscribed() async {
		let provider = CountingSubscriptionProvider()
		let subscriptionState = SubscriptionState(provider: provider, isPaymentsEnabled: true)
		let center = NotificationCenter()
		let readiness = Readiness()

		// The launch: entitlement resolves before the app is ready.
		provider.isSubscribed = true
		await subscriptionState.start()
		XCTAssertTrue(subscriptionState.isSubscribed)
		readiness.isReady = true
		observe(center, readiness: readiness, subscriptionState: subscriptionState)
		provider.resetStartCalls()

		// It lapses while the app is in the background, with no `Transaction.updates` event.
		provider.isSubscribed = false
		await postForegroundAndWait(center, provider: provider, until: 1)

		XCTAssertEqual(provider.startCalls, 1)
		XCTAssertFalse(subscriptionState.isSubscribed, "a lapse while backgrounded must reach the gate on foreground")
	}
}
