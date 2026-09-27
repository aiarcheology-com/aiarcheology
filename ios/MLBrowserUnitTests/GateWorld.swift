//
//  GateWorld.swift
//  MLBrowserUnitTests
//
//  AIA-0982. Moved out of SubscriptionGateCoordinatorTests so the headless walk builds the same world.
//

import XCTest
@testable import ML_Browser

/// A clock the test moves by hand; a class so the service's `now` closure sees an advance.
final class GateTestClock {
	var now: Date
	init(_ now: Date) { self.now = now }
}

/// The inputs one app process shares between its windows, built the way `AppState.initialize()`
/// orders them: the tour is armed before the free-access window is started.
@MainActor
struct GateWorld {
	let clock: GateTestClock
	let provider: MockSubscriptionProvider
	let subscriptionState: SubscriptionState
	let freeAccess: FreeAccessState
	let tour: TourState
	let analytics: AnalyticsState
	let tracker: RecordingAnalyticsTracker
	let notificationCenter: NotificationCenter

	nonisolated static let foregroundNotification = Notification.Name("GateWorld.willEnterForeground")

	/// Gregorian in GMT, so day arithmetic in the tests never crosses a DST change.
	nonisolated static var calendar: Calendar {
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = .gmt
		return calendar
	}

	func coordinator() -> SubscriptionGateCoordinator {
		SubscriptionGateCoordinator(
			subscriptionState: subscriptionState,
			freeAccess: freeAccess,
			tour: tour,
			analytics: analytics
		)
	}

	func foreground() {
		notificationCenter.post(name: Self.foregroundNotification, object: nil)
	}

	/// What `AppState.initialize()` does once the window's inputs are known: start the free-access
	/// window. Called by the world itself unless it was built with `startFreeAccess: false`.
	func startFreeAccess() {
		freeAccess.start(
			isEntitled: subscriptionState.isSubscribed,
			isPaymentsSurfaceEnabled: subscriptionState.isPaymentsSurfaceEnabled
		)
	}
}

@MainActor
extension XCTestCase {

	/// A gate world on `defaults`, which the caller owns and removes.
	///
	/// - Parameters:
	///   - startFreeAccess: `false` leaves the free-access window unread (`.undetermined`), the
	///     state the root gate holds on; call `GateWorld.startFreeAccess()` to read it.
	///   - answersConsent: `false` leaves the analytics question unanswered, as on a fresh install.
	func makeGateWorld(
		defaults: UserDefaults,
		isPaymentsEnabled: Bool = true,
		isFreeAccessPeriodEnabled: Bool = true,
		outcome: MockSubscriptionProvider.Outcome = .notSubscribed,
		seededFastRecord: FreeAccessWindow.Record? = nil,
		startFreeAccess: Bool = true,
		answersConsent: Bool = true
	) async throws -> GateWorld {
		let calendar = GateWorld.calendar
		let clock = GateTestClock(try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 2, hour: 18))))
		if let seededFastRecord {
			defaults.set(try JSONEncoder().encode(seededFastRecord), forKey: FreeAccessAnchorService.defaultsKey)
		}

		let (analytics, tracker) = makeGateAnalytics(answersConsent: answersConsent)
		let provider = MockSubscriptionProvider(outcome: outcome)
		let subscriptionState = SubscriptionState(provider: provider, isPaymentsEnabled: isPaymentsEnabled)
		await subscriptionState.start()

		let tour = TourState(defaults: defaults)
		tour.migrateAndArmIfNeeded()

		let notificationCenter = NotificationCenter()
		let service = FreeAccessAnchorService(
			defaults: defaults,
			durableStore: EphemeralFreeAccessAnchorStore(),
			calendar: calendar,
			now: { clock.now }
		)
		let freeAccess = FreeAccessState(
			service: service,
			isFreeAccessPeriodEnabled: isFreeAccessPeriodEnabled,
			analytics: analytics,
			notificationCenter: notificationCenter,
			foregroundNotification: GateWorld.foregroundNotification
		)

		let world = GateWorld(
			clock: clock,
			provider: provider,
			subscriptionState: subscriptionState,
			freeAccess: freeAccess,
			tour: tour,
			analytics: analytics,
			tracker: tracker,
			notificationCenter: notificationCenter
		)
		if startFreeAccess {
			world.startFreeAccess()
		}
		return world
	}

	/// A device-wide analytics stack whose deliveries the tests can read, as `FreeAccessStateTests`
	/// builds it: consented unless `answersConsent` is `false`. Resets the shared `Settings()` now and
	/// again at teardown.
	func makeGateAnalytics(answersConsent: Bool = true) -> (AnalyticsState, RecordingAnalyticsTracker) {
		let settings = Settings()
		settings.reset()
		settings.analyticsFreeAccessExpiryReported = false
		addTeardownBlock { @MainActor in
			settings.reset()
			settings.analyticsFreeAccessExpiryReported = false
		}
		let tracker = RecordingAnalyticsTracker()
		let analytics = AnalyticsState(
			settings: settings,
			tracker: tracker,
			featureFlags: FeatureFlagsState(provider: StaticFeatureFlagProvider(overrides: [.isAnalyticsEnabled: true])),
			isAccountIdentityEnabled: false
		)
		if answersConsent {
			analytics.chooseAnalytics(enabled: true)
		}
		return (analytics, tracker)
	}
}
