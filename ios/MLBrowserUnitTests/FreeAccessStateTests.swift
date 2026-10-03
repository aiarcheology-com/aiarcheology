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

		let prompt = try XCTUnwrap(state.duePrompt, "Expected the day-0 paywall to be due.")
		XCTAssertEqual(prompt.days, 14)
		// The date the copy tells the user to subscribe by is the window's own expiry, not a
		// recomputation that could drift from the record that was actually written.
		XCTAssertEqual(prompt.endsOn, durableStore.record?.expiresAt)
	}

	/// The marker is written at presentation, so a force-quit while the paywall is up cannot make it
	/// fire again on every later launch.
	@MainActor
	func testMarkPromptShown_forDay0_isRememberedAcrossARelaunch() throws {
		let clock = TestClock(try date(2026, 3, 2))
		let durableStore = StubDurableStore()
		let state = makeState(service: try makeService(clock: clock, durableStore: durableStore))
		state.start(isEntitled: false, isPaymentsSurfaceEnabled: true)

		state.markPromptShown()
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

		XCTAssertNotNil(relaunched.duePrompt, "the day-0 paywall must still be owed")
	}

	/// A window granted while payments were on, whose priced day-0 screen never made it on screen,
	/// must not raise that screen after payments are switched off (AIA-0955) — and must still owe it
	/// once they are back on. The screen names a price, a trial length and a subscription, none of
	/// which a payments-off session may show.
	@MainActor
	func testStart_whenPaymentsAreOff_withholdsAnUnshownDay0Prompt_withoutForgettingIt() throws {
		let clock = TestClock(try date(2026, 3, 2))
		let durableStore = StubDurableStore()
		let granting = makeState(service: try makeService(clock: clock, durableStore: durableStore))
		granting.start(isEntitled: false, isPaymentsSurfaceEnabled: true)
		XCTAssertNotNil(granting.duePrompt, "precondition: the granting launch owes the day-0 screen")

		let paymentsOff = makeState(service: try makeService(clock: clock, durableStore: durableStore))
		paymentsOff.start(isEntitled: false, isPaymentsSurfaceEnabled: false)
		XCTAssertNil(paymentsOff.duePrompt, "a payments-off launch raised the priced day-0 screen")
		paymentsOff.reevaluate()
		XCTAssertNil(paymentsOff.duePrompt, "a foreground re-evaluation brought the priced screen back")
		XCTAssertEqual(paymentsOff.availability, .open, "the window itself must still be honoured")

		let paymentsBackOn = makeState(service: try makeService(clock: clock, durableStore: durableStore))
		paymentsBackOn.start(isEntitled: false, isPaymentsSurfaceEnabled: true)
		XCTAssertNotNil(paymentsBackOn.duePrompt, "suppression must not have marked the screen shown")
	}

	// MARK: - Priced Welcome receipt for the onboarding carry-over (AIA-1036)

	@MainActor
	func testHasShownDay0Welcome_beforeStart_andForAnUnshownWindow_isFalse() throws {
		let clock = TestClock(try date(2026, 3, 2))
		let durableStore = StubDurableStore()
		let state = makeState(service: try makeService(clock: clock, durableStore: durableStore))
		XCTAssertFalse(state.hasShownDay0Welcome, "nothing has been read yet")

		state.start(isEntitled: false, isPaymentsSurfaceEnabled: true)
		XCTAssertNotNil(state.duePrompt, "precondition: a granted window owes its day-0 screen")
		XCTAssertFalse(state.hasShownDay0Welcome, "a granted window is not a shown Welcome")

		state.markPromptShown()
		XCTAssertTrue(state.hasShownDay0Welcome)
	}

	/// The upgrade from 1.0.7/1.0.8 after payments are switched off: the record says the priced screen was
	/// shown, and that must be the answer however the session is configured — payments off and free
	/// access off both included — and whether or not the window has since run out.
	@MainActor
	func testHasShownDay0Welcome_readsTheRecord_whateverThePhaseAndFlags() throws {
		let grantDate = try date(2026, 3, 2)
		for ageDays in [3, 20] {
			for shown in [true, false] {
				var record = FreeAccessWindow.record(grantedAt: grantDate, thresholds: .standard, calendar: calendar)
				record.day0Shown = shown
				try seedFastRecord(record)
				let clock = TestClock(try day(ageDays, after: grantDate))
				let state = makeState(
					service: try makeService(clock: clock, durableStore: StubDurableStore(record: record)),
					isFreeAccessPeriodEnabled: false
				)

				state.start(isEntitled: false, isPaymentsSurfaceEnabled: false)

				XCTAssertEqual(state.hasShownDay0Welcome, shown, "day \(ageDays), day0Shown \(shown)")
				if ageDays == 20 {
					XCTAssertEqual(state.availability, .closed, "precondition: the day-20 window has expired")
				}
			}
		}
	}

	/// Away from day 5 to day 16: the wall is what they meet, and the explanation of a window that is
	/// already spent does not fire on the way to it.
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

	/// Showing the day-0 paywall reports nothing of its own. `paywall.shown` already covers the
	/// screen and `window_granted` covers the window it explains, so a third event there would only
	/// double-count the same moment.
	// MARK: - Cross-window Welcome claims (AIA-0567)

	@MainActor
	func testWelcomeClaim_isVisibleImmediately() throws {
		let state = makeState(service: try makeService(clock: TestClock(try date(2026, 3, 2)), durableStore: StubDurableStore()))

		XCTAssertFalse(state.isWelcomePresented)
		_ = state.claimWelcomePresentation()
		XCTAssertTrue(state.isWelcomePresented, "The claim must be visible on the same turn it is taken")
	}

	/// Two windows, and only the second one closing frees the screen.
	@MainActor
	func testWelcomeClaim_releasingOneOfTwo_keepsTheScreenClaimed() throws {
		let state = makeState(service: try makeService(clock: TestClock(try date(2026, 3, 2)), durableStore: StubDurableStore()))

		let first = state.claimWelcomePresentation()
		let second = state.claimWelcomePresentation()

		state.releaseWelcomePresentation(first)
		XCTAssertTrue(state.isWelcomePresented, "A sibling window still has its Welcome screen up")
		state.releaseWelcomePresentation(second)
		XCTAssertFalse(state.isWelcomePresented)
	}

	/// The reason this is a token set and not a count: a duplicated `onDisappear` must not release
	/// somebody else's screen. A count would have decremented twice and freed the tour under it.
	@MainActor
	func testWelcomeClaim_releasingTheSameTokenTwice_cannotFreeASiblingsClaim() throws {
		let state = makeState(service: try makeService(clock: TestClock(try date(2026, 3, 2)), durableStore: StubDurableStore()))

		let mine = state.claimWelcomePresentation()
		_ = state.claimWelcomePresentation()

		state.releaseWelcomePresentation(mine)
		state.releaseWelcomePresentation(mine)

		XCTAssertTrue(state.isWelcomePresented, "A double release freed a claim it did not own")
	}

	@MainActor
	func testMarkPromptShown_forDay0_reportsTheWelcomeScreen() throws {
		// AIA-0567 inverted this. Day 0 used to report nothing of its own, on the grounds that
		// `paywallShown` already covered the screen — but the day-0 screen is now `WelcomeView`,
		// which is deliberately not a purchase screen and does not emit that event, so without
		// `welcomeShown` the funnel would simply lose the stage.
		let (analytics, tracker) = makeAnalytics()
		let grantDate = try date(2026, 3, 2)
		let clock = TestClock(grantDate)
		let state = makeState(
			service: try makeService(clock: clock, durableStore: StubDurableStore()),
			analytics: analytics
		)
		state.start(isEntitled: false, isPaymentsSurfaceEnabled: true)

		state.markPromptShown()

		XCTAssertEqual(tracker.events, [.freeAccessWindowGranted, .welcomeShown])
	}

	@MainActor
	func testMarkPromptShown_calledTwice_reportsTheWelcomeScreenOnce() throws {
		// The once-per-window guarantee, and the reason the event is emitted here rather than from
		// the presenter: this is the call that writes the durable marker, so the event cannot
		// outnumber the screen even if a view re-raised it.
		let (analytics, tracker) = makeAnalytics()
		let clock = TestClock(try date(2026, 3, 2))
		let state = makeState(
			service: try makeService(clock: clock, durableStore: StubDurableStore()),
			analytics: analytics
		)
		state.start(isEntitled: false, isPaymentsSurfaceEnabled: true)

		state.markPromptShown()
		state.markPromptShown()

		XCTAssertEqual(tracker.events.filter { $0 == .welcomeShown }.count, 1)
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

	// MARK: - Days remaining (AIA-0623)
	//
	// The number the purchase confirmation states out loud. Every case here is about it agreeing
	// with the gate rather than with the raw clock.

	@MainActor
	func testWindowDaysRemaining_beforeStart_isNil() throws {
		let clock = TestClock(try date(2026, 3, 2))
		let state = makeState(service: try makeService(clock: clock, durableStore: StubDurableStore()))

		XCTAssertNil(state.windowDaysRemaining)
	}

	@MainActor
	func testWindowDaysRemaining_onTheGrantDay_isTheWholeWindow() throws {
		let clock = TestClock(try date(2026, 3, 2))
		let state = makeState(service: try makeService(clock: clock, durableStore: StubDurableStore()))

		state.start(isEntitled: false, isPaymentsSurfaceEnabled: true)

		XCTAssertEqual(state.availability, .open)
		XCTAssertEqual(state.windowDaysRemaining, 14)
	}

	@MainActor
	func testWindowDaysRemaining_midWindow_countsDownWithTheClock() throws {
		let grantDate = try date(2026, 3, 2)
		let clock = TestClock(grantDate)
		let state = makeState(service: try makeService(clock: clock, durableStore: StubDurableStore()))
		state.start(isEntitled: false, isPaymentsSurfaceEnabled: true)

		clock.now = try day(10, after: grantDate)
		state.reevaluate()

		XCTAssertEqual(state.availability, .open)
		XCTAssertEqual(state.windowDaysRemaining, 4)
	}

	@MainActor
	func testWindowDaysRemaining_afterTheWindowRunsOut_isNil() throws {
		let grantDate = try date(2026, 3, 2)
		let clock = TestClock(grantDate)
		let state = makeState(service: try makeService(clock: clock, durableStore: StubDurableStore()))
		state.start(isEntitled: false, isPaymentsSurfaceEnabled: true)

		clock.now = try day(14, after: grantDate)
		state.reevaluate()

		XCTAssertEqual(state.availability, .closed)
		XCTAssertNil(state.windowDaysRemaining, "A spent window has no days to offer anyone.")
	}

	@MainActor
	func testWindowDaysRemaining_whenNoWindowWasEverGranted_isNil() throws {
		let clock = TestClock(try date(2026, 3, 2))
		let state = makeState(
			service: try makeService(clock: clock, durableStore: StubDurableStore()),
			isFreeAccessPeriodEnabled: false
		)

		state.start(isEntitled: false, isPaymentsSurfaceEnabled: true)

		XCTAssertEqual(state.availability, .closed)
		XCTAssertNil(state.windowDaysRemaining)
	}

	/// **The one this property exists to get right.** The count is taken from the phase, which
	/// counts from the monotonic floor — so a device clock wound back to day 1 still reports the
	/// four days the gate believes in, not the thirteen a fresh `Calendar` count from `now` would
	/// hand out. Offering days the gate will not honour is how the confirmation would turn into its
	/// own kind of lie.
	@MainActor
	func testWindowDaysRemaining_whenTheClockIsWoundBack_reportsTheClampedCount() throws {
		let grantDate = try date(2026, 3, 2)
		let clock = TestClock(grantDate)
		let state = makeState(service: try makeService(clock: clock, durableStore: StubDurableStore()))
		state.start(isEntitled: false, isPaymentsSurfaceEnabled: true)

		// Observed at day 10, which advances the floor and persists it.
		clock.now = try day(10, after: grantDate)
		state.reevaluate()
		XCTAssertEqual(state.windowDaysRemaining, 4)

		// Then wound back to day 1.
		clock.now = try day(1, after: grantDate)
		state.reevaluate()

		XCTAssertEqual(state.availability, .open)
		XCTAssertEqual(state.windowDaysRemaining, 4, "The floor, not the rolled-back clock, decides.")
		XCTAssertNotEqual(state.windowDaysRemaining, 13, "13 is what an unclamped count from `now` would say.")
	}

	// MARK: - Debug reset (AIA-0826)

	/// A reset must survive the rest of its own session, not just the moment it runs.
	///
	/// Clearing the two stores is the easy half. The in-memory `window` still holds the record that
	/// was just deleted, and `reevaluate()` — which runs on every foreground and from the expiry
	/// wake-up — advances the monotonic floor through `observe(_:)`, which persists to *both*
	/// stores. Without the freeze this test would find the anchor restored: the user taps Reset,
	/// switches away from the app and back, and relaunches into the window they thought they had
	/// just deleted, with nothing anywhere saying why.
	///
	/// The foreground notification is posted rather than `reevaluate()` called directly, because
	/// the subscription is the path that actually bit — a test calling the method would still pass
	/// against a fix that only guarded the direct call.
	@MainActor
	func testResetAnchorForDebugging_whenTheAppForegroundsBeforeRelaunch_doesNotWriteTheAnchorBack() throws {
		let grantDate = try date(2026, 3, 2)
		let clock = TestClock(grantDate)
		let durableStore = StubDurableStore()
		let state = makeState(service: try makeService(clock: clock, durableStore: durableStore))
		state.start(isEntitled: false, isPaymentsSurfaceEnabled: true)
		XCTAssertNotNil(durableStore.record, "arrange did not grant a window")

		try state.resetAnchorForDebugging()
		XCTAssertNil(durableStore.record)
		XCTAssertNil(try XCTUnwrap(defaults).data(forKey: FreeAccessAnchorService.defaultsKey))

		// Time moves, which is what makes the floor worth persisting, and the app comes forward.
		clock.now = try day(3, after: grantDate)
		notificationCenter.post(name: foregroundNotification, object: nil)

		XCTAssertNil(durableStore.record, "the foreground wrote the cleared anchor back to the Keychain")
		XCTAssertNil(
			try XCTUnwrap(defaults).data(forKey: FreeAccessAnchorService.defaultsKey),
			"the foreground wrote the cleared anchor back to UserDefaults"
		)
	}
}
