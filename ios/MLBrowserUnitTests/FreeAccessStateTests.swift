//
//  FreeAccessStateTests.swift
//  AI ArcheologyTests
//
//  The observable owner of the free-access window: reconciliation, the grant decision, and the
//  wake-up that ends the window on time (AIA-0556).
//

import XCTest
@testable import ML_Browser

final class FreeAccessStateTests: XCTestCase {

	/// A clock the test moves by hand. A class so the service's `now` closure and the test body see
	/// the same value after an advance.
	private final class TestClock {
		var now: Date
		init(_ now: Date) { self.now = now }
	}

	/// A durable store whose read can be made to fail — the state a real Keychain cannot be
	/// persuaded into, and the one that decides whether a mid-window user is wrongly walled.
	private final class StubDurableStore: FreeAccessAnchorDurableStore {
		var record: FreeAccessWindow.Record?
		var readError: Error?
		var writeError: Error?

		init(record: FreeAccessWindow.Record? = nil) {
			self.record = record
		}

		func loadRecord() throws -> FreeAccessWindow.Record? {
			if let readError { throw readError }
			return record
		}

		func saveRecord(_ record: FreeAccessWindow.Record) throws {
			if let writeError { throw writeError }
			self.record = record
		}

		func deleteRecord() throws { record = nil }
	}

	private let calendar: Calendar = {
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = .gmt
		return calendar
	}()

	private var suiteName = ""
	private var defaults: UserDefaults?
	private let foregroundNotification = Notification.Name("FreeAccessStateTests.willEnterForeground")
	private var notificationCenter = NotificationCenter()

	override func setUpWithError() throws {
		try super.setUpWithError()
		suiteName = "com.aiarcheology.ios.tests.freeAccessState.\(UUID().uuidString)"
		defaults = UserDefaults(suiteName: suiteName)
		notificationCenter = NotificationCenter()
	}

	override func tearDownWithError() throws {
		defaults?.removePersistentDomain(forName: suiteName)
		defaults = nil
		try super.tearDownWithError()
	}

	// MARK: - Helpers
	//
	// `nonisolated` on purpose: a closure formed in a `@MainActor` test body would be inferred
	// main-actor-isolated, and `FreeAccessAnchorService` is not a main-actor type.

	private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 18) throws -> Date {
		try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)))
	}

	private func day(_ offset: Int, after start: Date, hour: Int = 9) throws -> Date {
		let shifted = try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: start))
		return try XCTUnwrap(calendar.date(bySettingHour: hour, minute: 0, second: 0, of: shifted))
	}

	private func makeService(
		clock: TestClock,
		durableStore: FreeAccessAnchorDurableStore
	) throws -> FreeAccessAnchorService {
		FreeAccessAnchorService(
			defaults: try XCTUnwrap(defaults),
			durableStore: durableStore,
			calendar: calendar,
			now: { clock.now }
		)
	}

	private func seedFastRecord(_ record: FreeAccessWindow.Record) throws {
		let data = try JSONEncoder().encode(record)
		try XCTUnwrap(defaults).set(data, forKey: FreeAccessAnchorService.defaultsKey)
	}

	@MainActor
	private func makeState(
		service: FreeAccessAnchorService,
		isFreeAccessPeriodEnabled: Bool = true,
		analytics: AnalyticsState? = nil
	) -> FreeAccessState {
		FreeAccessState(
			service: service,
			isFreeAccessPeriodEnabled: isFreeAccessPeriodEnabled,
			analytics: analytics,
			notificationCenter: notificationCenter,
			foregroundNotification: foregroundNotification
		)
	}

	/// A consented analytics stack whose deliveries the funnel tests can read (AIA-0556).
	///
	/// Device-wide mode (`isAccountIdentityEnabled: false`) on purpose: the free-access stages are
	/// facts about the *install*, so they must report with nobody signed in — which is also the only
	/// state a first launch is ever in. Consent is answered up front so the events land in the
	/// tracker rather than the pre-consent buffer; `AnalyticsTests` owns the buffered path.
	@MainActor
	private func makeAnalytics() -> (AnalyticsState, RecordingAnalyticsTracker) {
		let settings = Settings()
		settings.reset()
		// `reset()` deliberately preserves the expiry marker (AIA-0556) and it lives in the host
		// app's real `UserDefaults`, so one earlier expiry observed on this simulator would make
		// `reportFreeAccessWindowExpiredIfNeeded` honestly refuse forever and fail these tests on
		// every later run. The fixture owns its world — see the same guard in `AnalyticsTests`.
		settings.analyticsFreeAccessExpiryReported = false
		// And leave the container as clean as it was found, for the same reason: a marker left set
		// here would silently disarm the next run of this suite and of `AnalyticsTests`. A teardown
		// block rather than `tearDownWithError`, which is not main-actor isolated.
		addTeardownBlock { @MainActor in
			settings.reset()
			settings.analyticsFreeAccessExpiryReported = false
		}

		let tracker = RecordingAnalyticsTracker()
		let flags = FeatureFlagsState(provider: StaticFeatureFlagProvider(overrides: [.isAnalyticsEnabled: true]))
		let analytics = AnalyticsState(
			settings: settings,
			tracker: tracker,
			featureFlags: flags,
			isAccountIdentityEnabled: false
		)
		analytics.chooseAnalytics(enabled: true)
		return (analytics, tracker)
	}

	// MARK: - Reconciliation must not read as a refusal

	/// Nothing has been read yet, so neither answer is available. The gate renders neither side;
	/// see `SubscriptionGateDisplayTests`.
	@MainActor
	func testBeforeStart_availabilityIsUndetermined() throws {
		let clock = TestClock(try date(2026, 3, 2))
		let state = makeState(service: try makeService(clock: clock, durableStore: StubDurableStore()))

		XCTAssertEqual(state.availability, .undetermined)
	}

	/// An unreadable Keychain with nothing in the fast store leaves the window `.reconciling`, where
	/// granting is forbidden. That must still produce a *definite* gate answer: holding forever would
	/// strand the user on a spinner, which is the lockout AIA-0536 exists to remove.
	@MainActor
	func testStart_whenTheDurableReadFailsWithNoFastRecord_closesAccessRatherThanHoldingForever() throws {
		let clock = TestClock(try date(2026, 3, 2))
		let durableStore = StubDurableStore()
		durableStore.readError = FreeAccessAnchorError.keychain(errSecIO)
		let state = makeState(service: try makeService(clock: clock, durableStore: durableStore))

		state.start(isEntitled: false, isPaymentsSurfaceEnabled: true)

		XCTAssertEqual(state.availability, .closed)
		// And nothing was granted on the strength of a store that never answered.
		XCTAssertNil(durableStore.record)
	}

	/// The mirror image, and the one that wrongly walled a legitimate user: the container survived
	/// (so this is not a reinstall) and the fast record proves the window. A transient Keychain
	/// failure must not take it away.
	@MainActor
	func testStart_whenTheDurableReadFailsButTheFastRecordSurvived_honoursTheOpenWindow() throws {
		let grantDate = try date(2026, 3, 2)
		let clock = TestClock(try day(3, after: grantDate))
		try seedFastRecord(FreeAccessWindow.record(grantedAt: grantDate, thresholds: .standard, calendar: calendar))
		let durableStore = StubDurableStore()
		durableStore.readError = FreeAccessAnchorError.keychain(errSecIO)
		let state = makeState(service: try makeService(clock: clock, durableStore: durableStore))

		state.start(isEntitled: false, isPaymentsSurfaceEnabled: true)

		XCTAssertEqual(state.availability, .open)
	}

	// MARK: - Granting

	@MainActor
	func testStart_onAFreshInstall_grantsAWindowAndOpensAccess() throws {
		let clock = TestClock(try date(2026, 3, 2))
		let durableStore = StubDurableStore()
		let state = makeState(service: try makeService(clock: clock, durableStore: durableStore))

		state.start(isEntitled: false, isPaymentsSurfaceEnabled: true)

		XCTAssertEqual(state.availability, .open)
		XCTAssertEqual(durableStore.record?.grantedAt, clock.now)
	}

	/// A payer has no use for a 14-day app window, and one granted silently would only expire under
	/// them later for no cause they could see. Their free period is Apple's trial, and StoreKit owns it.
	@MainActor
	func testStart_whenAlreadyEntitled_grantsNoWindow() throws {
		let clock = TestClock(try date(2026, 3, 2))
		let durableStore = StubDurableStore()
		let state = makeState(service: try makeService(clock: clock, durableStore: durableStore))

		state.start(isEntitled: true, isPaymentsSurfaceEnabled: true)

		XCTAssertNil(durableStore.record, "An entitled user must not be handed an app-managed window.")
		XCTAssertEqual(state.availability, .closed)
	}

	@MainActor
	func testStart_whenTheFlagIsOff_grantsNothing() throws {
		let clock = TestClock(try date(2026, 3, 2))
		let durableStore = StubDurableStore()
		let state = makeState(
			service: try makeService(clock: clock, durableStore: durableStore),
			isFreeAccessPeriodEnabled: false
		)

		state.start(isEntitled: false, isPaymentsSurfaceEnabled: true)

		XCTAssertNil(durableStore.record)
		XCTAssertEqual(state.availability, .closed)
	}

	/// Shipping the feature dark must not spend the window nobody can see.
	///
	/// With payments off there is no gate to be let through, and `AppState` skips
	/// `subscriptionState.start()` entirely, so `isEntitled` is false for everyone including
	/// subscribers. Granting on that would run every install's 14 days down behind an open door,
	/// and the day payments were switched on the whole base would meet the wall at once, having
	/// had no free period at all. The window is measured from the first launch on which payments
	/// are live.
	@MainActor
	func testStart_whenPaymentsAreOff_grantsNothingSoTheWindowIsNotSpentUnseen() throws {
		let clock = TestClock(try date(2026, 3, 2))
		let durableStore = StubDurableStore()
		let state = makeState(
			service: try makeService(clock: clock, durableStore: durableStore),
			isFreeAccessPeriodEnabled: true
		)

		state.start(isEntitled: false, isPaymentsSurfaceEnabled: false)

		XCTAssertNil(durableStore.record, "a window was granted while payments were off")
	}

	/// The flag is a tap on the intake, not a revocation. Turning it off must not wall everyone who
	/// is already mid-window — they were promised those days before it moved.
	@MainActor
	func testStart_whenTheFlagIsOffButAWindowIsAlreadyOpen_honoursItToItsNaturalExpiry() throws {
		let grantDate = try date(2026, 3, 2)
		let clock = TestClock(try day(10, after: grantDate))
		let record = FreeAccessWindow.record(grantedAt: grantDate, thresholds: .standard, calendar: calendar)
		try seedFastRecord(record)
		let state = makeState(
			service: try makeService(clock: clock, durableStore: StubDurableStore(record: record)),
			isFreeAccessPeriodEnabled: false
		)

		state.start(isEntitled: false, isPaymentsSurfaceEnabled: true)

		XCTAssertEqual(state.availability, .open)
	}

	@MainActor
	func testStart_isIdempotent() throws {
		let clock = TestClock(try date(2026, 3, 2))
		let durableStore = StubDurableStore()
		let state = makeState(service: try makeService(clock: clock, durableStore: durableStore))

		state.start(isEntitled: false, isPaymentsSurfaceEnabled: true)
		let firstGrant = durableStore.record?.grantedAt
		clock.now = try day(5, after: clock.now)
		state.start(isEntitled: false, isPaymentsSurfaceEnabled: true)

		XCTAssertEqual(durableStore.record?.grantedAt, firstGrant)
	}

	// MARK: - Day-0 acknowledgement (the analytics-ask deferral)

	/// The ordering bug this flag exists for: a granted window opens the root gate, and without the
	/// deferral the very first screen of a brand-new install is "Enable analytics?" — `ContentView`,
	/// and with it the onboarding tour, never mounts until it is answered (AIA-0447).
	@MainActor
	func testStart_whenAWindowIsGranted_defersTheAnalyticsAskUntilAcknowledged() throws {
		let clock = TestClock(try date(2026, 3, 2))
		let state = makeState(service: try makeService(clock: clock, durableStore: StubDurableStore()))
		XCTAssertFalse(state.isDay0AcknowledgementPending, "nothing is owed before the window exists")

		state.start(isEntitled: false, isPaymentsSurfaceEnabled: true)

		XCTAssertTrue(state.isDay0AcknowledgementPending)
	}

	@MainActor
	func testAcknowledgeDay0Presentation_releasesTheDeferral() throws {
		let clock = TestClock(try date(2026, 3, 2))
		let state = makeState(service: try makeService(clock: clock, durableStore: StubDurableStore()))
		state.start(isEntitled: false, isPaymentsSurfaceEnabled: true)

		state.acknowledgeDay0Presentation()

		XCTAssertFalse(state.isDay0AcknowledgementPending)
	}

	/// A returning user is mid-window, not day 0. Nothing new is being explained to them, so the
	/// consent question must not be silenced for the launch.
	@MainActor
	func testStart_whenAWindowWasAlreadyOpen_defersNothing() throws {
		let grantDate = try date(2026, 3, 2)
		let clock = TestClock(try day(3, after: grantDate))
		let record = FreeAccessWindow.record(grantedAt: grantDate, thresholds: .standard, calendar: calendar)
		try seedFastRecord(record)
		let state = makeState(
			service: try makeService(clock: clock, durableStore: StubDurableStore(record: record))
		)

		state.start(isEntitled: false, isPaymentsSurfaceEnabled: true)

		XCTAssertEqual(state.availability, .open)
		XCTAssertFalse(state.isDay0AcknowledgementPending)
	}

	/// Fail-closed grants must not silence the ask either: a durable write that fails leaves the user
	/// with no window, so there is nothing to introduce and nothing to wait for.
	@MainActor
	func testStart_whenTheGrantFailsToPersist_defersNothing() throws {
		let clock = TestClock(try date(2026, 3, 2))
		let durableStore = StubDurableStore()
		durableStore.writeError = FreeAccessAnchorError.keychain(errSecIO)
		let state = makeState(service: try makeService(clock: clock, durableStore: durableStore))

		state.start(isEntitled: false, isPaymentsSurfaceEnabled: true)

		XCTAssertEqual(state.availability, .closed)
		XCTAssertFalse(state.isDay0AcknowledgementPending)
	}

	// MARK: - The paywalls an open window owes (S9, S10)

	@MainActor
	func testStart_onAFreshInstall_owesTheDay0Paywall() throws {
		let clock = TestClock(try date(2026, 3, 2))
		let durableStore = StubDurableStore()
		let state = makeState(service: try makeService(clock: clock, durableStore: durableStore))

		state.start(isEntitled: false, isPaymentsSurfaceEnabled: true)

		guard case let .day0(days, endsOn) = state.duePrompt else {
			return XCTFail("Expected the day-0 paywall to be due, found \(String(describing: state.duePrompt)).")
		}
		XCTAssertEqual(days, 14)
		// The date the copy tells the user to subscribe by is the window's own expiry, not a
		// recomputation that could drift from the record that was actually written.
		XCTAssertEqual(endsOn, durableStore.record?.expiresAt)
	}

	/// The marker is written at presentation, so a force-quit while the paywall is up cannot make it
	/// fire again on every later launch.
	@MainActor
	func testMarkPromptShown_forDay0_isRememberedAcrossARelaunch() throws {
		let clock = TestClock(try date(2026, 3, 2))
		let durableStore = StubDurableStore()
		let state = makeState(service: try makeService(clock: clock, durableStore: durableStore))
		state.start(isEntitled: false, isPaymentsSurfaceEnabled: true)

		state.markPromptShown(try XCTUnwrap(state.duePrompt))
		XCTAssertNil(state.duePrompt)

		let relaunched = makeState(service: try makeService(clock: clock, durableStore: durableStore))
		relaunched.start(isEntitled: false, isPaymentsSurfaceEnabled: true)
		XCTAssertNil(relaunched.duePrompt)
	}

	/// The other half of the same rule: a launch that died before the paywall was ever raised must
	/// not lose it. Nothing was marked, so it is still owed.
	@MainActor
	func testStart_whenAnEarlierLaunchNeverShowedTheDay0Paywall_stillOwesIt() throws {
		let clock = TestClock(try date(2026, 3, 2))
		let durableStore = StubDurableStore()
		let state = makeState(service: try makeService(clock: clock, durableStore: durableStore))
		state.start(isEntitled: false, isPaymentsSurfaceEnabled: true)
		XCTAssertNotNil(state.duePrompt)

		let relaunched = makeState(service: try makeService(clock: clock, durableStore: durableStore))
		relaunched.start(isEntitled: false, isPaymentsSurfaceEnabled: true)

		guard case .day0 = relaunched.duePrompt else {
			return XCTFail("Expected the day-0 paywall to still be owed, found \(String(describing: relaunched.duePrompt)).")
		}
	}

	/// The reminder fires once, ever — explicitly not once per launch.
	@MainActor
	func testMarkPromptShown_forTheReminder_isRememberedAcrossARelaunch() throws {
		let grantDate = try date(2026, 3, 2)
		let clock = TestClock(grantDate)
		let durableStore = StubDurableStore()
		let state = makeState(service: try makeService(clock: clock, durableStore: durableStore))
		state.start(isEntitled: false, isPaymentsSurfaceEnabled: true)
		state.markPromptShown(try XCTUnwrap(state.duePrompt))

		clock.now = try day(7, after: grantDate)
		state.reevaluate()
		guard case let .reminder(days, _) = state.duePrompt else {
			return XCTFail("Expected the reminder to be due, found \(String(describing: state.duePrompt)).")
		}
		XCTAssertEqual(days, 7)

		state.markPromptShown(try XCTUnwrap(state.duePrompt))
		XCTAssertNil(state.duePrompt)

		let relaunched = makeState(service: try makeService(clock: clock, durableStore: durableStore))
		relaunched.start(isEntitled: false, isPaymentsSurfaceEnabled: true)
		XCTAssertNil(relaunched.duePrompt)
	}

	/// Away from day 5 to day 16: the wall is what they meet, and the reminder does not fire late.
	@MainActor
	func testReevaluate_afterTheWindowRunsOut_owesNothing() throws {
		let grantDate = try date(2026, 3, 2)
		let clock = TestClock(grantDate)
		let state = makeState(service: try makeService(clock: clock, durableStore: StubDurableStore()))
		state.start(isEntitled: false, isPaymentsSurfaceEnabled: true)

		clock.now = try day(16, after: grantDate)
		state.reevaluate()

		XCTAssertEqual(state.availability, .closed)
		XCTAssertNil(state.duePrompt)
	}

	// MARK: - Expiry

	/// A `Date`-derived phase does not recompute itself. This is the re-read the wake-up and the
	/// foreground observer both perform; without it a session left open across the last midnight is
	/// never walled.
	@MainActor
	func testReevaluate_afterTheWindowRunsOut_closesAccess() throws {
		let grantDate = try date(2026, 3, 2)
		let clock = TestClock(grantDate)
		let state = makeState(service: try makeService(clock: clock, durableStore: StubDurableStore()))
		state.start(isEntitled: false, isPaymentsSurfaceEnabled: true)
		XCTAssertEqual(state.availability, .open)

		clock.now = try day(14, after: grantDate)
		state.reevaluate()

		XCTAssertEqual(state.availability, .closed)
	}

	@MainActor
	func testForeground_afterTheWindowRunsOut_closesAccess() throws {
		let grantDate = try date(2026, 3, 2)
		let clock = TestClock(grantDate)
		let state = makeState(service: try makeService(clock: clock, durableStore: StubDurableStore()))
		state.start(isEntitled: false, isPaymentsSurfaceEnabled: true)

		clock.now = try day(20, after: grantDate)
		notificationCenter.post(name: foregroundNotification, object: nil)

		XCTAssertEqual(state.availability, .closed)
	}

	/// The trap the wake-up exists for: a backgrounded app has no timer to fire, but a foregrounded
	/// one has no foreground notification either. Granting must arm a wake-up at the exact expiry.
	@MainActor
	func testStart_armsAWakeUpAtTheExpiryInstant() throws {
		// A real-clock grant, because the delay is measured against the real clock — a fake date in
		// the past is not a deadline and must not arm anything.
		let clock = TestClock(Date())
		let durableStore = StubDurableStore()
		let state = makeState(service: try makeService(clock: clock, durableStore: durableStore))

		state.start(isEntitled: false, isPaymentsSurfaceEnabled: true)

		XCTAssertEqual(state.scheduledExpiry, durableStore.record?.expiresAt)
		XCTAssertEqual(state.availability, .open)
	}

	@MainActor
	func testScheduledExpiry_isClearedOnceTheWindowHasClosed() throws {
		let grantDate = try date(2026, 3, 2)
		let clock = TestClock(grantDate)
		let state = makeState(service: try makeService(clock: clock, durableStore: StubDurableStore()))
		state.start(isEntitled: false, isPaymentsSurfaceEnabled: true)

		clock.now = try day(14, after: grantDate)
		state.reevaluate()

		XCTAssertNil(state.scheduledExpiry)
	}

	// MARK: - Funnel events (AIA-0556)

	@MainActor
	func testStart_whenAWindowIsGranted_reportsTheGrant() throws {
		let (analytics, tracker) = makeAnalytics()
		let clock = TestClock(try date(2026, 3, 2))
		let state = makeState(
			service: try makeService(clock: clock, durableStore: StubDurableStore()),
			analytics: analytics
		)

		state.start(isEntitled: false, isPaymentsSurfaceEnabled: true)

		XCTAssertEqual(tracker.events, [.freeAccessWindowGranted])
	}

	/// A grant whose durable write failed leaves the user with **no** window, so reporting one would
	/// make every later stage read as drop-off from a cohort that never existed.
	@MainActor
	func testStart_whenTheGrantFailsToPersist_reportsNothing() throws {
		let (analytics, tracker) = makeAnalytics()
		let clock = TestClock(try date(2026, 3, 2))
		let durableStore = StubDurableStore()
		durableStore.writeError = FreeAccessAnchorError.keychain(errSecIO)
		let state = makeState(
			service: try makeService(clock: clock, durableStore: durableStore),
			analytics: analytics
		)

		state.start(isEntitled: false, isPaymentsSurfaceEnabled: true)

		XCTAssertEqual(tracker.events, [])
	}

	/// An install that already had a window resumes it. Nothing was granted, so nothing is reported —
	/// otherwise `window_granted` would count launches rather than windows.
	@MainActor
	func testStart_whenAWindowWasAlreadyOpen_reportsNoGrant() throws {
		let (analytics, tracker) = makeAnalytics()
		let grantDate = try date(2026, 3, 2)
		let clock = TestClock(grantDate)
		let durableStore = StubDurableStore()
		makeState(service: try makeService(clock: clock, durableStore: durableStore))
			.start(isEntitled: false, isPaymentsSurfaceEnabled: true)

		let relaunched = makeState(
			service: try makeService(clock: clock, durableStore: durableStore),
			analytics: analytics
		)
		relaunched.start(isEntitled: false, isPaymentsSurfaceEnabled: true)

		XCTAssertEqual(tracker.events, [])
	}

	/// The reminder reports; day 0 does not. `paywall.shown` already covers the day-0 screen and
	/// `window_granted` covers the window it explains, so a third event there would only double-count
	/// the same moment.
	@MainActor
	func testMarkPromptShown_reportsTheReminderAndNotDay0() throws {
		let (analytics, tracker) = makeAnalytics()
		let grantDate = try date(2026, 3, 2)
		let clock = TestClock(grantDate)
		let state = makeState(
			service: try makeService(clock: clock, durableStore: StubDurableStore()),
			analytics: analytics
		)
		state.start(isEntitled: false, isPaymentsSurfaceEnabled: true)

		state.markPromptShown(try XCTUnwrap(state.duePrompt))
		XCTAssertEqual(tracker.events, [.freeAccessWindowGranted])

		clock.now = try day(7, after: grantDate)
		state.reevaluate()
		state.markPromptShown(try XCTUnwrap(state.duePrompt))

		XCTAssertEqual(tracker.events, [.freeAccessWindowGranted, .freeAccessReminderShown])
	}

	/// Expiry is re-observed on every launch and every foreground for the rest of the install's life.
	/// The stage has to survive that, or it stops being comparable with `window_granted` at all.
	@MainActor
	func testExpiry_isReportedOnceHoweverOftenItIsObserved() throws {
		let (analytics, tracker) = makeAnalytics()
		let grantDate = try date(2026, 3, 2)
		let clock = TestClock(grantDate)
		let durableStore = StubDurableStore()
		let state = makeState(
			service: try makeService(clock: clock, durableStore: durableStore),
			analytics: analytics
		)
		state.start(isEntitled: false, isPaymentsSurfaceEnabled: true)

		clock.now = try day(20, after: grantDate)
		state.reevaluate()
		notificationCenter.post(name: foregroundNotification, object: nil)

		// A cold launch on top of the two in-session observations, which is the case a purely
		// in-memory guard would miss: the marker is durable, so the relaunch stays silent.
		let relaunched = makeState(
			service: try makeService(clock: clock, durableStore: durableStore),
			analytics: analytics
		)
		relaunched.start(isEntitled: false, isPaymentsSurfaceEnabled: true)

		XCTAssertEqual(tracker.events, [.freeAccessWindowGranted, .freeAccessWindowExpired])
	}

	/// `.notGranted` closes access exactly as `.expired` does, and it is what every user with the
	/// flag off reports. Counting them as expired free trials would make the funnel's last stage
	/// larger than its first.
	@MainActor
	func testNoWindowEverGranted_reportsNoExpiry() throws {
		let (analytics, tracker) = makeAnalytics()
		let clock = TestClock(try date(2026, 3, 2))
		let state = makeState(
			service: try makeService(clock: clock, durableStore: StubDurableStore()),
			isFreeAccessPeriodEnabled: false,
			analytics: analytics
		)

		state.start(isEntitled: false, isPaymentsSurfaceEnabled: true)

		XCTAssertEqual(state.availability, .closed)
		XCTAssertEqual(tracker.events, [])
	}
}
