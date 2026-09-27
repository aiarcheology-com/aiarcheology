//
//  SubscriptionGateCoordinatorTests.swift
//  AI ArcheologyTests
//
//  The root gate's orchestration, driven the way `SubscriptionGateView` drives it (AIA-0976).
//

import XCTest
@testable import ML_Browser

/// The ordering decisions `SubscriptionGateCoordinator` makes: which Welcome screen goes up, when it
/// comes down, and when the onboarding tour may start.
///
/// Every test drives the coordinator through ``GateViewDriver``, which calls the coordinator's
/// handlers exactly as the view's `onChange` modifiers do — on mount with `initial: true`, then only
/// for values that changed since the last render, in declaration order. The UI suite covers the view
/// wiring itself (`FreeAccessUITests`, `SubscriptionGateUITests`).
@MainActor
final class SubscriptionGateCoordinatorTests: XCTestCase {

	/// A clock the test moves by hand; a class so the service's `now` closure sees an advance.
	private final class TestClock {
		var now: Date
		init(_ now: Date) { self.now = now }
	}

	/// The inputs one app process shares between its windows, built the way `AppState.initialize()`
	/// orders them: the tour is armed before the free-access window is started.
	@MainActor
	private struct World {
		let clock: TestClock
		let provider: MockSubscriptionProvider
		let subscriptionState: SubscriptionState
		let freeAccess: FreeAccessState
		let tour: TourState
		let analytics: AnalyticsState
		let tracker: RecordingAnalyticsTracker
		let notificationCenter: NotificationCenter

		func coordinator() -> SubscriptionGateCoordinator {
			SubscriptionGateCoordinator(
				subscriptionState: subscriptionState,
				freeAccess: freeAccess,
				tour: tour,
				analytics: analytics
			)
		}

		func foreground() {
			notificationCenter.post(name: SubscriptionGateCoordinatorTests.foregroundNotification, object: nil)
		}
	}

	/// Replays `SubscriptionGateView`'s handlers against a coordinator: mounting fires the two
	/// `initial: true` handlers, and each ``render()`` fires the handler of every observed value that
	/// changed, in the view's declaration order, until nothing changes (each handler's state change
	/// is another render). The Welcome screen's `onDisappear` fires when it leaves the overlay.
	@MainActor
	private final class GateViewDriver {
		let coordinator: SubscriptionGateCoordinator
		private let world: World
		private var display: RootGateDisplay
		private var canPresent: Bool
		private var duePrompt: FreeAccessPrompt?
		private var isIntroductionOwed: Bool
		private var welcomeClaims: Set<UUID>
		private var welcomeOnScreen: Bool

		init(world: World) {
			self.world = world
			coordinator = world.coordinator()
			display = coordinator.display
			canPresent = coordinator.canPresentPrompt
			duePrompt = world.freeAccess.duePrompt
			isIntroductionOwed = world.tour.isIntroductionOwed
			welcomeClaims = world.freeAccess.welcomeClaims
			welcomeOnScreen = false
			coordinator.displayChanged(to: display)
			coordinator.canPresentPromptChanged(to: canPresent)
			render()
		}

		func render() {
			for _ in 0..<20 {
				var changed = false
				if coordinator.display != display {
					display = coordinator.display
					coordinator.displayChanged(to: display)
					changed = true
				}
				if coordinator.canPresentPrompt != canPresent {
					canPresent = coordinator.canPresentPrompt
					coordinator.canPresentPromptChanged(to: canPresent)
					changed = true
				}
				if world.freeAccess.duePrompt != duePrompt {
					duePrompt = world.freeAccess.duePrompt
					coordinator.duePromptChanged()
					changed = true
				}
				if world.tour.isIntroductionOwed != isIntroductionOwed {
					isIntroductionOwed = world.tour.isIntroductionOwed
					coordinator.introductionOwedChanged()
					changed = true
				}
				if world.freeAccess.welcomeClaims != welcomeClaims {
					welcomeClaims = world.freeAccess.welcomeClaims
					coordinator.welcomeClaimsChanged()
					changed = true
				}
				let isOnScreen = coordinator.presentedPrompt != nil && display != .wallOverContent
				if welcomeOnScreen && isOnScreen == false {
					coordinator.releaseWelcomeClaim()
					changed = true
				}
				welcomeOnScreen = isOnScreen
				if changed == false { return }
			}
			XCTFail("The gate never settled: a handler keeps changing what it observes.")
		}

		/// The Welcome screen's Continue button, then the render it causes.
		func tapContinue() throws {
			let presented = try XCTUnwrap(coordinator.presentedPrompt, "No Welcome screen is up to continue from.")
			coordinator.continueWelcome(presented)
			render()
		}
	}

	nonisolated static let foregroundNotification = Notification.Name("SubscriptionGateCoordinatorTests.willEnterForeground")

	private var suiteName = ""
	private var defaults: UserDefaults?

	override func setUp() async throws {
		try await super.setUp()
		suiteName = "com.aiarcheology.ios.tests.subscriptionGateCoordinator.\(UUID().uuidString)"
		defaults = UserDefaults(suiteName: suiteName)
	}

	override func tearDown() async throws {
		defaults?.removePersistentDomain(forName: suiteName)
		defaults = nil
		try await super.tearDown()
	}

	// MARK: - Helpers

	private var calendar: Calendar {
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = .gmt
		return calendar
	}

	private func makeWorld(
		isPaymentsEnabled: Bool = true,
		isFreeAccessPeriodEnabled: Bool = true,
		outcome: MockSubscriptionProvider.Outcome = .notSubscribed,
		seededFastRecord: FreeAccessWindow.Record? = nil,
		separateInstall: Bool = false
	) async throws -> World {
		let defaults: UserDefaults
		if separateInstall {
			// A second, independent install: its own tour and anchor storage.
			let name = "\(suiteName).other"
			defaults = try XCTUnwrap(UserDefaults(suiteName: name))
			addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
		} else {
			defaults = try XCTUnwrap(self.defaults)
		}
		let clock = TestClock(try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 2, hour: 18))))
		if let seededFastRecord {
			defaults.set(try JSONEncoder().encode(seededFastRecord), forKey: FreeAccessAnchorService.defaultsKey)
		}

		let (analytics, tracker) = makeAnalytics()
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
			foregroundNotification: Self.foregroundNotification
		)
		freeAccess.start(isEntitled: subscriptionState.isSubscribed, isPaymentsSurfaceEnabled: isPaymentsEnabled)

		return World(
			clock: clock,
			provider: provider,
			subscriptionState: subscriptionState,
			freeAccess: freeAccess,
			tour: tour,
			analytics: analytics,
			tracker: tracker,
			notificationCenter: notificationCenter
		)
	}

	/// A consented, device-wide analytics stack whose deliveries the tests can read, as
	/// `FreeAccessStateTests` builds it.
	private func makeAnalytics() -> (AnalyticsState, RecordingAnalyticsTracker) {
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
		analytics.chooseAnalytics(enabled: true)
		return (analytics, tracker)
	}

	// MARK: - First run

	func testFirstRun_paymentsOn_raisesTheFreeAccessWelcome_andHoldsTheTourBehindIt() async throws {
		let world = try await makeWorld()
		let gate = GateViewDriver(world: world)

		guard case let .freeAccess(prompt) = gate.coordinator.presentedPrompt else {
			return XCTFail("Expected the free-access Welcome, got \(String(describing: gate.coordinator.presentedPrompt))")
		}
		XCTAssertEqual(prompt.days, 14)
		XCTAssertEqual(gate.coordinator.display, .content)
		XCTAssertTrue(world.freeAccess.isWelcomePresented, "Raising the screen claims the shared presentation.")
		XCTAssertNil(world.freeAccess.duePrompt, "Raising marks it shown, so it is no longer due.")
		XCTAssertFalse(world.tour.isIntroductionOwed, "Either Welcome screen receipts the introduction.")
		XCTAssertTrue(world.tour.isArmed)
		XCTAssertFalse(world.tour.isActive, "The tour must not run underneath the Welcome screen.")
		XCTAssertTrue(world.freeAccess.isDay0AcknowledgementPending)
		XCTAssertTrue(world.tracker.events.contains(.welcomeShown))
	}

	func testContinue_lowersTheWelcome_acknowledgesDay0_andStartsTheTour() async throws {
		let world = try await makeWorld()
		let gate = GateViewDriver(world: world)

		try gate.tapContinue()

		XCTAssertNil(gate.coordinator.presentedPrompt)
		XCTAssertFalse(world.freeAccess.isWelcomePresented, "Continue releases the claim.")
		XCTAssertFalse(world.freeAccess.isDay0AcknowledgementPending)
		XCTAssertTrue(world.tour.isActive, "Continue hands the screen to the tour.")
		XCTAssertEqual(world.tracker.events.filter { $0 == .freeAccessContinueTapped }.count, 1)
	}

	func testPaymentsOff_raisesTheIntroduction_andItsContinueReportsNoDecline() async throws {
		let world = try await makeWorld(isPaymentsEnabled: false)
		let gate = GateViewDriver(world: world)

		XCTAssertEqual(gate.coordinator.presentedPrompt, .introduction)
		XCTAssertFalse(world.tour.isActive)

		try gate.tapContinue()

		XCTAssertNil(gate.coordinator.presentedPrompt)
		XCTAssertTrue(world.tour.isActive)
		XCTAssertFalse(world.tracker.events.contains(.freeAccessContinueTapped), "The introduction declines nothing.")
	}

	/// The second window of an iPad: its own coordinator, sharing the process's state.
	func testTheTourDoesNotStartUnderAWelcomeScreenInAnotherWindow() async throws {
		let world = try await makeWorld()
		let windowA = GateViewDriver(world: world)
		let windowB = GateViewDriver(world: world)

		XCTAssertNotNil(windowA.coordinator.presentedPrompt)
		XCTAssertNil(windowB.coordinator.presentedPrompt, "Only one window raises the once-per-window screen.")
		windowB.render()
		XCTAssertFalse(world.tour.isActive, "Window B must not start the tour under window A's Welcome screen.")

		try windowA.tapContinue()
		windowB.render()

		XCTAssertTrue(world.tour.isActive)
	}

	// MARK: - Entitlement

	func testAnEntitlementArrivingMidWelcome_lowersIt_andStartsTheTour() async throws {
		let world = try await makeWorld()
		let gate = GateViewDriver(world: world)
		XCTAssertNotNil(gate.coordinator.presentedPrompt)

		world.provider.simulateEntitlementChange(to: .subscribed)   // e.g. Ask-to-Buy approved
		gate.render()

		XCTAssertNil(gate.coordinator.presentedPrompt)
		XCTAssertFalse(world.freeAccess.isWelcomePresented)
		XCTAssertFalse(world.freeAccess.isDay0AcknowledgementPending)
		XCTAssertTrue(world.tour.isActive)
		XCTAssertFalse(world.tracker.events.contains(.freeAccessContinueTapped), "Nobody tapped Continue.")
	}

	/// A subscriber whose window still owes an unshown day 0 can never have it raised, so the tour
	/// must not wait for it.
	func testASubscriberWithAnUnshownDay0_stillGetsTheTour() async throws {
		let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 2, hour: 12)))
		let owedWindow = FreeAccessWindow.Record(
			grantedAt: start,
			expiresAt: try XCTUnwrap(calendar.date(byAdding: .day, value: 14, to: start)),
			maxObservedDate: start,
			day0Shown: false
		)
		let world = try await makeWorld(outcome: .subscribed, seededFastRecord: owedWindow)
		XCTAssertNotNil(world.freeAccess.duePrompt, "Precondition: the window still owes its day-0 screen.")

		let gate = GateViewDriver(world: world)

		XCTAssertNil(gate.coordinator.presentedPrompt)
		XCTAssertTrue(world.tour.isActive)
	}

	func testTheWallThenAPurchase_startsTheTour() async throws {
		let world = try await makeWorld(isFreeAccessPeriodEnabled: false)
		let gate = GateViewDriver(world: world)
		XCTAssertEqual(gate.coordinator.display, .wall)
		XCTAssertFalse(world.tour.isActive)

		world.provider.simulateEntitlementChange(to: .subscribed)
		gate.render()

		XCTAssertEqual(gate.coordinator.display, .content)
		XCTAssertNil(gate.coordinator.presentedPrompt, "A subscriber is shown no Welcome screen.")
		XCTAssertTrue(world.tour.isActive)
	}

	// MARK: - Memory of content

	func testAWindowRunningOutMidSession_coversTheAppRatherThanReplacingIt() async throws {
		let world = try await makeWorld()
		let gate = GateViewDriver(world: world)
		try gate.tapContinue()
		XCTAssertTrue(gate.coordinator.hasEverShownContent)

		world.clock.now = try XCTUnwrap(calendar.date(byAdding: .day, value: 16, to: world.clock.now))
		world.foreground()
		gate.render()

		XCTAssertEqual(world.freeAccess.availability, .closed)
		XCTAssertEqual(gate.coordinator.display, .wallOverContent)
	}

	func testTheSameExpiryOnAFreshLaunch_isTheWall() async throws {
		let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 2, hour: 12)))
		let spentWindow = FreeAccessWindow.Record(
			grantedAt: start,
			expiresAt: try XCTUnwrap(calendar.date(byAdding: .day, value: 14, to: start)),
			maxObservedDate: start,
			day0Shown: true
		)
		let world = try await makeWorld(seededFastRecord: spentWindow)
		let gate = GateViewDriver(world: world)

		XCTAssertEqual(gate.coordinator.display, .wall)
		XCTAssertFalse(gate.coordinator.hasEverShownContent)
		XCTAssertNil(gate.coordinator.presentedPrompt)
	}

	// MARK: - The headless build's reconcile()

	/// What a flow leaves behind, for comparing two ways of driving it.
	private struct Outcome: Equatable {
		let display: RootGateDisplay
		let presentedPrompt: WelcomePresentation?
		let hasEverShownContent: Bool
		let isTourActive: Bool
		let isTourArmed: Bool
		let isWelcomePresented: Bool
		let isDay0AcknowledgementPending: Bool
		let isIntroductionOwed: Bool
		let events: [AnalyticsEvent]

		@MainActor
		init(_ world: World, _ gate: SubscriptionGateCoordinator) {
			display = gate.display
			presentedPrompt = gate.presentedPrompt
			hasEverShownContent = gate.hasEverShownContent
			isTourActive = world.tour.isActive
			isTourArmed = world.tour.isArmed
			isWelcomePresented = world.freeAccess.isWelcomePresented
			isDay0AcknowledgementPending = world.freeAccess.isDay0AcknowledgementPending
			isIntroductionOwed = world.tour.isIntroductionOwed
			events = world.tracker.events
		}
	}

	/// One flow's steps, applied to either driver: `settle` renders or reconciles.
	private typealias Flow = (World, SubscriptionGateCoordinator, () -> Void) throws -> Void

	/// Runs `flow` once through the view's handlers and once through `reconcile()`, each on its own
	/// fresh install, and requires the same outcome at every checkpoint the flow marks.
	private func assertReconcileMatchesTheView(
		isPaymentsEnabled: Bool = true,
		isFreeAccessPeriodEnabled: Bool = true,
		outcome: MockSubscriptionProvider.Outcome = .notSubscribed,
		seededFastRecord: FreeAccessWindow.Record? = nil,
		_ flow: Flow,
		file: StaticString = #filePath,
		line: UInt = #line
	) async throws {
		var viewCheckpoints: [Outcome] = []
		let viewWorld = try await makeWorld(
			isPaymentsEnabled: isPaymentsEnabled, isFreeAccessPeriodEnabled: isFreeAccessPeriodEnabled,
			outcome: outcome, seededFastRecord: seededFastRecord
		)
		let view = GateViewDriver(world: viewWorld)
		viewCheckpoints.append(Outcome(viewWorld, view.coordinator))
		try flow(viewWorld, view.coordinator) {
			view.render()
			viewCheckpoints.append(Outcome(viewWorld, view.coordinator))
		}

		var reconcileCheckpoints: [Outcome] = []
		let headlessWorld = try await makeWorld(
			isPaymentsEnabled: isPaymentsEnabled, isFreeAccessPeriodEnabled: isFreeAccessPeriodEnabled,
			outcome: outcome, seededFastRecord: seededFastRecord, separateInstall: true
		)
		let headless = headlessWorld.coordinator()
		headless.reconcile()
		reconcileCheckpoints.append(Outcome(headlessWorld, headless))
		try flow(headlessWorld, headless) {
			headless.reconcile()
			reconcileCheckpoints.append(Outcome(headlessWorld, headless))
		}

		XCTAssertEqual(reconcileCheckpoints, viewCheckpoints, file: file, line: line)
	}

	func testReconcile_matchesTheView_firstRunThenContinue() async throws {
		try await assertReconcileMatchesTheView { _, gate, settle in
			let presented = try XCTUnwrap(gate.presentedPrompt)
			gate.continueWelcome(presented)
			settle()
		}
	}

	func testReconcile_matchesTheView_paymentsOffIntroduction() async throws {
		try await assertReconcileMatchesTheView(isPaymentsEnabled: false) { _, gate, settle in
			let presented = try XCTUnwrap(gate.presentedPrompt)
			gate.continueWelcome(presented)
			settle()
		}
	}

	func testReconcile_matchesTheView_entitlementArrivingMidWelcome() async throws {
		try await assertReconcileMatchesTheView { world, _, settle in
			world.provider.simulateEntitlementChange(to: .subscribed)
			settle()
		}
	}

	func testReconcile_matchesTheView_wallThenPurchase() async throws {
		try await assertReconcileMatchesTheView(isFreeAccessPeriodEnabled: false) { world, _, settle in
			settle()
			world.provider.simulateEntitlementChange(to: .subscribed)
			settle()
		}
	}

	func testReconcile_matchesTheView_expiryOverContent() async throws {
		try await assertReconcileMatchesTheView { world, gate, settle in
			let presented = try XCTUnwrap(gate.presentedPrompt)
			gate.continueWelcome(presented)
			settle()
			world.clock.now = try XCTUnwrap(self.calendar.date(byAdding: .day, value: 16, to: world.clock.now))
			world.foreground()
			settle()
		}
	}

	func testReconcile_matchesTheView_subscriberWithAnUnshownDay0() async throws {
		let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 2, hour: 12)))
		let owedWindow = FreeAccessWindow.Record(
			grantedAt: start,
			expiresAt: try XCTUnwrap(calendar.date(byAdding: .day, value: 14, to: start)),
			maxObservedDate: start,
			day0Shown: false
		)
		try await assertReconcileMatchesTheView(outcome: .subscribed, seededFastRecord: owedWindow) { _, _, settle in
			settle()
		}
	}

	/// A Welcome screen that is up stays up however often the headless build reconciles.
	func testReconcile_isIdempotent_withAWelcomeScreenUp() async throws {
		let world = try await makeWorld()
		let gate = world.coordinator()
		gate.reconcile()
		let first = Outcome(world, gate)
		XCTAssertNotNil(first.presentedPrompt)

		gate.reconcile()
		gate.reconcile()

		XCTAssertEqual(Outcome(world, gate), first)
	}

	// MARK: - Observation

	/// Nothing in the coordinator reacts on its own: the view's handlers are what act, and they fire
	/// because the view observes the same `ObservableObject`s.
	func testAStateChangeDoesNothingUntilAHandlerRuns() async throws {
		let world = try await makeWorld(isFreeAccessPeriodEnabled: false)
		let gate = GateViewDriver(world: world)
		XCTAssertEqual(gate.coordinator.display, .wall)

		world.provider.simulateEntitlementChange(to: .subscribed)

		XCTAssertEqual(gate.coordinator.display, .content, "The derived display follows its inputs...")
		XCTAssertFalse(gate.coordinator.hasEverShownContent, "...but nothing was recorded without a handler...")
		XCTAssertFalse(world.tour.isActive, "...and nothing was started.")

		gate.render()

		XCTAssertTrue(gate.coordinator.hasEverShownContent)
		XCTAssertTrue(world.tour.isActive)
	}
}
