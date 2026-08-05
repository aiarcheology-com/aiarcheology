//
//  FreeAccessWindowTests.swift
//  AI ArcheologyTests
//
//  The free-access state machine, boundary by boundary (AIA-0556).
//

import XCTest
@testable import ML_Browser

final class FreeAccessWindowTests: XCTestCase {

	/// A fixed Gregorian/UTC calendar, so "day 7" is a fact about the test rather than about
	/// whichever locale the simulator happens to carry.
	private let calendar: Calendar = {
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = .gmt
		return calendar
	}()

	// MARK: - Helpers

	private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 18) throws -> Date {
		try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)))
	}

	private func day(_ offset: Int, after start: Date, hour: Int = 9) throws -> Date {
		let shifted = try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: start))
		return try XCTUnwrap(calendar.date(bySettingHour: hour, minute: 0, second: 0, of: shifted))
	}

	/// A window that has been reconciled empty and then granted — the ordinary first-launch path.
	private func grantedWindow(
		at grantDate: Date,
		thresholds: FreeAccessThresholds = .standard
	) -> FreeAccessWindow {
		var window = FreeAccessWindow(calendar: calendar)
		window.settle(fast: nil, durable: nil)
		_ = window.grant(at: grantDate, thresholds: thresholds)
		return window
	}

	/// The same, for a user who has already seen the reminder. Needed for any assertion past the
	/// reminder day: an undelivered reminder keeps reporting `.reminderDue`, which is correct
	/// behaviour but would mask what those tests are actually about.
	private func grantedWindowAfterReminder(
		at grantDate: Date,
		thresholds: FreeAccessThresholds = .standard
	) -> FreeAccessWindow {
		var window = grantedWindow(at: grantDate, thresholds: thresholds)
		_ = window.markReminderShown()
		return window
	}

	private enum TestFailure: Error { case anchorNotGranted }

	private func grantedRecord(in window: FreeAccessWindow) throws -> FreeAccessWindow.Record {
		guard case let .granted(record) = window.anchor else {
			XCTFail("Expected a granted anchor, found \(window.anchor).")
			throw TestFailure.anchorNotGranted
		}
		return record
	}

	// MARK: - The reconciliation gate

	func testCanGrant_whileReconciling_isFalse() {
		let window = FreeAccessWindow(calendar: calendar)

		XCTAssertFalse(window.canGrant)
		XCTAssertEqual(window.anchor, .reconciling)
	}

	func testPhase_whileReconciling_isNotGranted() throws {
		let window = FreeAccessWindow(calendar: calendar)
		let phase = window.phase(at: try date(2026, 3, 2))

		// Identical to a genuinely ungranted window on purpose — which is exactly why `canGrant`
		// is a separate answer, and why this one must never be read as permission to grant.
		XCTAssertEqual(phase, .notGranted)
	}

	func testCanGrant_afterBothStoresReadEmpty_isTrue() {
		var window = FreeAccessWindow(calendar: calendar)

		window.settle(fast: nil, durable: nil)

		XCTAssertTrue(window.canGrant)
		XCTAssertEqual(window.anchor, .absent)
	}

	func testGrant_whileReconciling_isRefused() throws {
		var window = FreeAccessWindow(calendar: calendar)

		let record = window.grant(at: try date(2026, 3, 2), thresholds: .standard)

		XCTAssertNil(record)
		XCTAssertEqual(window.anchor, .reconciling)
	}

	func testGrant_whenAnAnchorAlreadyExists_isRefused() throws {
		let grantDate = try date(2026, 3, 2)
		var window = grantedWindow(at: grantDate)

		let second = window.grant(at: try day(3, after: grantDate), thresholds: .standard)

		XCTAssertNil(second)
		XCTAssertEqual(try grantedRecord(in: window).grantedAt, grantDate)
	}

	// MARK: - Day boundaries

	func testPhase_onTheGrantDay_isActiveForTheWholeWindow() throws {
		let grantDate = try date(2026, 3, 2)
		let window = grantedWindow(at: grantDate)

		XCTAssertEqual(window.phase(at: grantDate), .active(remaining: 14))
	}

	func testPhase_onDaySix_isActiveWithEightDaysRemaining() throws {
		let grantDate = try date(2026, 3, 2)
		let window = grantedWindow(at: grantDate)
		let phase = window.phase(at: try day(6, after: grantDate))

		XCTAssertEqual(phase, .active(remaining: 8))
	}

	func testPhase_onDaySeven_isReminderDue() throws {
		let grantDate = try date(2026, 3, 2)
		let window = grantedWindow(at: grantDate)
		let phase = window.phase(at: try day(7, after: grantDate))

		XCTAssertEqual(phase, .reminderDue(remaining: 7))
	}

	func testPhase_onDaySevenWhenTheReminderWasAlreadyShown_isActive() throws {
		let grantDate = try date(2026, 3, 2)
		let window = grantedWindowAfterReminder(at: grantDate)
		let phase = window.phase(at: try day(7, after: grantDate))

		XCTAssertEqual(phase, .active(remaining: 7))
	}

	func testPhase_onDayThirteen_isActiveWithOneDayRemaining() throws {
		let grantDate = try date(2026, 3, 2)
		let window = grantedWindowAfterReminder(at: grantDate)
		let phase = window.phase(at: try day(13, after: grantDate))

		XCTAssertEqual(phase, .active(remaining: 1))
	}

	func testPhase_onDayFourteen_isExpired() throws {
		let grantDate = try date(2026, 3, 2)
		let window = grantedWindowAfterReminder(at: grantDate)
		let phase = window.phase(at: try day(14, after: grantDate))

		XCTAssertEqual(phase, .expired)
	}

	func testPhase_atTheExactExpiryInstant_isExpired() throws {
		let grantDate = try date(2026, 3, 2)
		let window = grantedWindowAfterReminder(at: grantDate)
		let record = try grantedRecord(in: window)

		XCTAssertEqual(window.phase(at: record.expiresAt), .expired)
		XCTAssertEqual(window.phase(at: record.expiresAt.addingTimeInterval(-1)), .active(remaining: 1))
	}

	func testPhase_afterExpiryWithTheReminderNeverShown_isExpiredNotReminderDue() throws {
		let grantDate = try date(2026, 3, 2)
		// The reminder came due on day 7 and was never delivered — a user who did not open the app.
		let window = grantedWindow(at: grantDate)

		// It must not fire late: expiry wins, or the wall arrives wearing a reminder's clothes.
		XCTAssertEqual(window.phase(at: try day(14, after: grantDate)), .expired)
		XCTAssertEqual(window.phase(at: try day(40, after: grantDate)), .expired)
	}

	func testPhase_onDayTenWithTheReminderStillUnshown_isReminderDue() throws {
		let grantDate = try date(2026, 3, 2)
		let window = grantedWindow(at: grantDate)
		let phase = window.phase(at: try day(10, after: grantDate))

		// Due, not missed: the reminder is owed until it is shown or the window ends.
		XCTAssertEqual(phase, .reminderDue(remaining: 4))
	}

	func testMarkReminderShown_calledTwice_reportsNoSecondChange() throws {
		var window = grantedWindow(at: try date(2026, 3, 2))

		let first = window.markReminderShown()
		let second = window.markReminderShown()

		XCTAssertNotNil(first)
		XCTAssertNil(second)
	}

	// MARK: - What the window still owes the user (S9, S10)

	func testDuePrompt_onAFreshWindow_offersTheWholeWindow() throws {
		let grantDate = try date(2026, 3, 2)
		let window = grantedWindow(at: grantDate)
		let record = try grantedRecord(in: window)

		XCTAssertEqual(
			window.duePrompt(at: grantDate),
			.day0(days: 14, endsOn: record.expiresAt)
		)
	}

	func testDuePrompt_onceTheDay0PaywallWasShown_owesNothingUntilTheReminderDay() throws {
		let grantDate = try date(2026, 3, 2)
		var window = grantedWindow(at: grantDate)
		_ = window.markDay0Shown()

		XCTAssertNil(window.duePrompt(at: grantDate))
		XCTAssertNil(window.duePrompt(at: try day(6, after: grantDate)))
	}

	func testDuePrompt_onTheReminderDay_countsDownWhatIsLeft() throws {
		let grantDate = try date(2026, 3, 2)
		var window = grantedWindow(at: grantDate)
		_ = window.markDay0Shown()
		let record = try grantedRecord(in: window)

		XCTAssertEqual(
			window.duePrompt(at: try day(7, after: grantDate)),
			.reminder(days: 7, endsOn: record.expiresAt)
		)
	}

	/// A first launch on day 10 — granted, force-quit before the day-0 paywall appeared, away since.
	/// The window has to be explained before it is counted down, or the first thing the user is ever
	/// told about their free period is how little of it is left.
	func testDuePrompt_onTheReminderDayWithDay0NeverShown_explainsBeforeCountingDown() throws {
		let grantDate = try date(2026, 3, 2)
		let window = grantedWindow(at: grantDate)
		let record = try grantedRecord(in: window)

		XCTAssertEqual(window.phase(at: try day(10, after: grantDate)), .reminderDue(remaining: 4))
		XCTAssertEqual(
			window.duePrompt(at: try day(10, after: grantDate)),
			.day0(days: 14, endsOn: record.expiresAt)
		)
	}

	/// A user away from day 5 to day 16 gets no reminder at all: expiry wins, and a paywall
	/// promising days that are already gone is worse than the wall it precedes.
	func testDuePrompt_afterExpiry_owesNothingSoTheReminderNeverFiresLate() throws {
		let grantDate = try date(2026, 3, 2)
		let window = grantedWindow(at: grantDate)

		XCTAssertNil(window.duePrompt(at: try day(14, after: grantDate)))
		XCTAssertNil(window.duePrompt(at: try day(40, after: grantDate)))
	}

	/// The offer states the window the user was actually granted, not the one the dashboard is
	/// handing out today — the same freeze the phase arithmetic honours.
	func testDuePrompt_offersTheGrantedWindow_notTheThresholdsInForceToday() throws {
		let grantDate = try date(2026, 3, 2)
		let window = grantedWindow(
			at: grantDate,
			thresholds: FreeAccessThresholds(grantDays: 7, reminderOnDay: 3)
		)
		let record = try grantedRecord(in: window)

		XCTAssertEqual(window.duePrompt(at: grantDate), .day0(days: 7, endsOn: record.expiresAt))
	}

	func testMarkDay0Shown_calledTwice_reportsNoSecondChange() throws {
		var window = grantedWindow(at: try date(2026, 3, 2))

		let first = window.markDay0Shown()
		let second = window.markDay0Shown()

		XCTAssertNotNil(first)
		XCTAssertNil(second)
	}

	/// The Keychain mirror outlives app deletion and `simctl erase`, so a record in the shape that
	/// predates the day-0 marker is one a running app can still meet. It must read as "not shown
	/// yet"; throwing would discard the anchor, and with it the resume-don't-restart guarantee.
	func testRecord_decodedWithoutTheDay0Marker_readsAsNotShown() throws {
		let grantDate = try date(2026, 3, 2)
		let record = FreeAccessWindow.record(grantedAt: grantDate, thresholds: .standard, calendar: calendar)
		var fields = try XCTUnwrap(
			JSONSerialization.jsonObject(with: try JSONEncoder().encode(record)) as? [String: Any]
		)
		XCTAssertNotNil(fields.removeValue(forKey: "day0Shown"))

		let decoded = try JSONDecoder().decode(
			FreeAccessWindow.Record.self,
			from: try JSONSerialization.data(withJSONObject: fields)
		)

		XCTAssertFalse(decoded.day0Shown)
		XCTAssertEqual(decoded.grantedAt.timeIntervalSinceReferenceDate,
					   record.grantedAt.timeIntervalSinceReferenceDate,
					   accuracy: 0.001)
		XCTAssertFalse(decoded.reminderShown)
	}

	// MARK: - Monotonic clamp

	func testPhase_whenTheDeviceClockRollsBack_clampsToTheObservedFloor() throws {
		let grantDate = try date(2026, 3, 2)
		var window = grantedWindow(at: grantDate)
		let observed = window.observe(at: try day(10, after: grantDate))
		XCTAssertNotNil(observed)

		// The user winds the device back to the grant day to buy themselves 10 more days.
		XCTAssertEqual(window.phase(at: grantDate), .reminderDue(remaining: 4))
		XCTAssertEqual(window.phase(at: try day(-30, after: grantDate)), .reminderDue(remaining: 4))
	}

	func testObserve_whenTheClockRollsBack_doesNotLowerTheFloor() throws {
		let grantDate = try date(2026, 3, 2)
		let dayTen = try day(10, after: grantDate)
		var window = grantedWindow(at: grantDate)
		let advanced = window.observe(at: dayTen)
		XCTAssertNotNil(advanced)

		let rolledBack = window.observe(at: try day(2, after: grantDate))

		XCTAssertNil(rolledBack)
		XCTAssertEqual(try grantedRecord(in: window).maxObservedDate, dayTen)
	}

	func testObserve_whenTheClockAdvances_returnsTheRecordToPersist() throws {
		let grantDate = try date(2026, 3, 2)
		let dayThree = try day(3, after: grantDate)
		var window = grantedWindow(at: grantDate)

		let record = try XCTUnwrap(window.observe(at: dayThree))

		XCTAssertEqual(record.maxObservedDate, dayThree)
	}

	func testPhase_afterAClampedRollback_stillExpiresOnTime() throws {
		let grantDate = try date(2026, 3, 2)
		var window = grantedWindowAfterReminder(at: grantDate)
		let advanced = window.observe(at: try day(10, after: grantDate))
		XCTAssertNotNil(advanced)

		// Winding the clock back cannot buy days, and it must not lose them either.
		XCTAssertEqual(window.phase(at: try day(13, after: grantDate)), .active(remaining: 1))
		XCTAssertEqual(window.phase(at: try day(14, after: grantDate)), .expired)
	}

	// MARK: - Frozen thresholds

	func testGrant_freezesTheThresholdsIntoTheRecord() throws {
		let grantDate = try date(2026, 3, 2, hour: 18)
		let window = grantedWindow(at: grantDate)
		let record = try grantedRecord(in: window)

		// Both frozen dates hang off the *grant day's* midnight rather than the grant instant, so
		// an evening grant does not cost the user an evening.
		XCTAssertEqual(record.expiresAt, try date(2026, 3, 16, hour: 0))
		XCTAssertEqual(record.reminderDueAt, try date(2026, 3, 9, hour: 0))
		XCTAssertEqual(record.maxObservedDate, grantDate)
		XCTAssertFalse(record.reminderShown)
	}

	func testPhase_whenTheOperatorShortensGrantDaysAfterAGrant_theOpenWindowIsUnaffected() throws {
		let grantDate = try date(2026, 3, 2)
		let window = grantedWindow(at: grantDate, thresholds: .standard)

		// The operator drops the window to 7 days. Had that been in force at grant time this user
		// would already be out of days...
		let shortened = FreeAccessThresholds(grantDays: 7, reminderOnDay: 3)
		let wouldHaveBeen = FreeAccessWindow.record(grantedAt: grantDate, thresholds: shortened, calendar: calendar)
		XCTAssertEqual(wouldHaveBeen.expiresAt, try date(2026, 3, 9, hour: 0))

		// ...but the record froze its own expiry, and `phase(at:)` takes no thresholds at all.
		XCTAssertEqual(window.phase(at: try day(10, after: grantDate)), .reminderDue(remaining: 4))
	}

	func testPhase_whenTheOperatorLengthensGrantDaysAfterAGrant_theOpenWindowIsNotExtended() throws {
		let grantDate = try date(2026, 3, 2)
		let window = grantedWindowAfterReminder(at: grantDate, thresholds: .standard)

		let lengthened = FreeAccessThresholds(grantDays: 21, reminderOnDay: 14)
		let wouldHaveBeen = FreeAccessWindow.record(grantedAt: grantDate, thresholds: lengthened, calendar: calendar)
		XCTAssertEqual(wouldHaveBeen.expiresAt, try date(2026, 3, 23, hour: 0))

		XCTAssertEqual(window.phase(at: try day(14, after: grantDate)), .expired)
	}

	// MARK: - Calendar and DST

	func testRecord_acrossADaylightSavingTransition_stillSpansFourteenCalendarDays() throws {
		var prague = Calendar(identifier: .gregorian)
		prague.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Prague"))
		// European clocks go forward on 2026-03-29, inside this window.
		let grantDate = try XCTUnwrap(prague.date(from: DateComponents(year: 2026, month: 3, day: 20, hour: 12)))

		let record = FreeAccessWindow.record(grantedAt: grantDate, thresholds: .standard, calendar: prague)

		// The user gets 14 whole calendar days: expiry lands on local midnight, not an hour early.
		let expectedExpiry = try XCTUnwrap(prague.date(from: DateComponents(year: 2026, month: 4, day: 3)))
		XCTAssertEqual(record.expiresAt, expectedExpiry)
		// Which is 14 * 24h minus the hour the transition swallowed — the proof that this is
		// calendar arithmetic and not a `14 * 86_400` interval.
		let elapsed = record.expiresAt.timeIntervalSince(prague.startOfDay(for: grantDate))
		XCTAssertEqual(elapsed, 14 * 24 * 60 * 60 - 60 * 60)
	}

	// MARK: - Reconciliation

	func testReconcile_whenBothStoresAreEmpty_isNil() {
		XCTAssertNil(FreeAccessWindow.reconcile(fast: nil, durable: nil))
	}

	func testReconcile_whenOnlyTheDurableStoreHoldsAnAnchor_resumesIt() throws {
		let grantDate = try date(2026, 3, 2)
		let durable = FreeAccessWindow.record(grantedAt: grantDate, thresholds: .standard, calendar: calendar)

		let reconciled = try XCTUnwrap(FreeAccessWindow.reconcile(fast: nil, durable: durable))

		XCTAssertEqual(reconciled.grantedAt, grantDate)
	}

	func testReconcile_whenBothStoresHoldAnchors_keepsTheEarliest() throws {
		let early = FreeAccessWindow.record(grantedAt: try date(2026, 3, 2), thresholds: .standard, calendar: calendar)
		let late = FreeAccessWindow.record(grantedAt: try date(2026, 5, 20), thresholds: .standard, calendar: calendar)

		// Both orderings: the winner is the earlier grant, never whichever store was read first.
		XCTAssertEqual(FreeAccessWindow.reconcile(fast: late, durable: early)?.grantedAt, early.grantedAt)
		XCTAssertEqual(FreeAccessWindow.reconcile(fast: early, durable: late)?.grantedAt, early.grantedAt)
	}

	func testReconcile_whenTheStoresDisagreeOnProgress_takesTheSaferSideOfEach() throws {
		let grantDate = try date(2026, 3, 2)
		var fast = FreeAccessWindow.record(grantedAt: grantDate, thresholds: .standard, calendar: calendar)
		var durable = fast
		fast.maxObservedDate = try day(9, after: grantDate)
		durable.maxObservedDate = try day(4, after: grantDate)
		durable.reminderShown = true

		let reconciled = try XCTUnwrap(FreeAccessWindow.reconcile(fast: fast, durable: durable))

		XCTAssertEqual(reconciled.maxObservedDate, fast.maxObservedDate)
		XCTAssertTrue(reconciled.reminderShown)
	}

	/// The monotonic floor bounds *rewinding*, not the total duration — and this pins the difference
	/// rather than letting the clamp read as more protection than it is.
	///
	/// Roll the clock back to before the grant and leave it there, and `maxObservedDate` never
	/// advances, so the window reports itself perpetually fresh. The user keeps access indefinitely.
	/// That is the accepted device-local limit the ticket records under "Clock rollback": defeating
	/// it needs an authority the device does not have, which is #557's DeviceCheck or a server.
	/// Documented here so the next reader does not mistake the clamp for a bound.
	func testPhase_whenTheClockIsRolledBackBeforeTheGrantAndLeftThere_doesNotExpire() throws {
		let grantDate = try date(2026, 3, 2)
		var window = FreeAccessWindow(calendar: calendar)
		window.settle(
			fast: FreeAccessWindow.record(grantedAt: grantDate, thresholds: .standard, calendar: calendar),
			durable: nil
		)

		let rolledBack = try XCTUnwrap(calendar.date(byAdding: .year, value: -1, to: grantDate))

		// Not `.expired`, and the floor refuses to move backwards, so this repeats every launch.
		XCTAssertEqual(window.phase(at: rolledBack), .active(remaining: 14))
		XCTAssertNil(window.observe(at: rolledBack), "the floor must never be lowered")
	}

	/// `day0Shown` merges conservatively too, and the failure it prevents is louder than the
	/// reminder's: day 0 outranks everything in `duePrompt(at:)`, so a marker dropped because the
	/// other store won the `grantedAt` tie re-offers "14 days free" to someone a week into their
	/// window. Found independently by two reviewers, which is why it is pinned here rather than
	/// left to the merge looking obviously right.
	func testReconcile_whenOnlyOneStoreSawTheDay0Paywall_keepsItShown() throws {
		let grantDate = try date(2026, 3, 2)
		var fast = FreeAccessWindow.record(grantedAt: grantDate, thresholds: .standard, calendar: calendar)
		let durable = fast
		fast.day0Shown = true

		// The marker sits on the *loser* of the tie — durable wins an exact `grantedAt` match — so
		// only the merge can carry it across.
		let reconciled = try XCTUnwrap(FreeAccessWindow.reconcile(fast: fast, durable: durable))

		XCTAssertTrue(reconciled.day0Shown, "the day-0 paywall would be offered a second time")
	}

	/// Progress belongs to a window, not to a device. A discarded anchor's monotonic floor must not
	/// be folded into the survivor: it can sit past the survivor's expiry and wall a user before
	/// their window has actually run out.
	func testReconcile_whenTheGrantsDiffer_keepsProgressWithItsOwnWindow() throws {
		let firstGrant = try date(2026, 3, 2)
		let fast = FreeAccessWindow.record(grantedAt: firstGrant, thresholds: .standard, calendar: calendar)
		// A later, discarded anchor that has been observed well past the first window's expiry.
		let laterGrant = try day(40, after: firstGrant)
		var durable = FreeAccessWindow.record(grantedAt: laterGrant, thresholds: .standard, calendar: calendar)
		durable.maxObservedDate = try day(50, after: firstGrant)

		let reconciled = try XCTUnwrap(FreeAccessWindow.reconcile(fast: fast, durable: durable))

		XCTAssertEqual(reconciled.grantedAt, firstGrant, "the earliest anchor must still win")
		XCTAssertEqual(
			reconciled.maxObservedDate,
			fast.maxObservedDate,
			"a discarded window's floor was merged in and would expire this one early"
		)

		var window = FreeAccessWindow(calendar: calendar)
		window.settle(fast: reconciled, durable: nil)
		XCTAssertEqual(window.phase(at: try day(3, after: firstGrant)), .active(remaining: 11))
	}

	/// The expiry stage is claimed once per *window*, and the claim rides the durable anchor — so a
	/// reinstall cannot make one window report its own expiry a second time.
	func testMarkExpiryReported_isClaimedOncePerWindow() throws {
		let grantDate = try date(2026, 3, 2)
		var window = FreeAccessWindow(calendar: calendar)
		window.settle(
			fast: FreeAccessWindow.record(grantedAt: grantDate, thresholds: .standard, calendar: calendar),
			durable: nil
		)

		let claimed = try XCTUnwrap(window.markExpiryReported())
		XCTAssertTrue(claimed.expiryReported)
		XCTAssertNil(window.markExpiryReported(), "the stage was claimed twice")

		// And it survives the round trip that a reinstall actually performs.
		let restored = try JSONDecoder().decode(
			FreeAccessWindow.Record.self,
			from: try JSONEncoder().encode(claimed)
		)
		var reinstalled = FreeAccessWindow(calendar: calendar)
		reinstalled.settle(fast: nil, durable: restored)
		XCTAssertNil(reinstalled.markExpiryReported(), "a reinstall re-reported one window's expiry")
	}

	// MARK: - An edited record cannot buy access

	/// The attack the tie-break alone does not reach: an early `grantedAt` wins outright under
	/// earliest-wins, so no tie is needed — and reconciliation then repairs the durable store from
	/// the winner, writing the forgery into the Keychain as authoritative.
	func testCredible_whenARecordClaimsMoreThanAnyOperatorCouldConfigure_rebuildsItFromItsOwnGrant() throws {
		let now = try date(2026, 3, 2)
		let forged = FreeAccessWindow.Record(
			grantedAt: try XCTUnwrap(calendar.date(byAdding: .year, value: -1, to: now)),
			expiresAt: try XCTUnwrap(calendar.date(byAdding: .year, value: 10, to: now)),
			reminderDueAt: now,
			maxObservedDate: now,
			reminderShown: false,
			day0Shown: false
		)

		let bounded = FreeAccessWindow.credible(forged, now: now, calendar: calendar)

		// The dates, not just the phase: asserting only `.expired` would also pass if the rebuild
		// produced something arbitrary that happened to be in the past.
		let firstDay = calendar.startOfDay(for: forged.grantedAt)
		XCTAssertEqual(bounded.grantedAt, forged.grantedAt, "the anchor's identity must survive")
		XCTAssertEqual(bounded.expiresAt, try XCTUnwrap(calendar.date(byAdding: .day, value: 14, to: firstDay)))
		XCTAssertEqual(bounded.reminderDueAt, try XCTUnwrap(calendar.date(byAdding: .day, value: 7, to: firstDay)))

		var window = FreeAccessWindow(calendar: calendar)
		window.settle(fast: bounded, durable: nil)
		XCTAssertEqual(window.phase(at: now), .expired, "an edited record bought access")
	}

	/// The test that actually pins "leaves a credible record alone".
	///
	/// Deliberately **not** a `.standard` record: the rebuild also uses `.standard`, so on that
	/// input the repair is the identity function and the assertion would hold even if every record
	/// were being rewritten. A reproducible non-standard window is the only input that can tell the
	/// difference.
	func testCredible_withAReproducibleNonStandardRecord_leavesItsFrozenDatesExactlyAsTheyWere() throws {
		let grantDate = try date(2026, 3, 2)
		let thresholds = FreeAccessThresholds(grantDays: 30, reminderOnDay: 15)
		let honest = FreeAccessWindow.record(grantedAt: grantDate, thresholds: thresholds, calendar: calendar)

		let bounded = FreeAccessWindow.credible(honest, now: try day(3, after: grantDate), calendar: calendar)

		XCTAssertEqual(bounded.expiresAt, honest.expiresAt, "a 30-day window was silently rewritten to 14")
		XCTAssertEqual(bounded.reminderDueAt, honest.reminderDueAt)
	}

	/// Winding the feature down must not hand out a window. `grantDays: 0` describes one that
	/// expired the day it was granted; rebuilding that into the standard fourteen days would turn
	/// switching the feature off into switching it on.
	func testCredible_withAZeroDayWindow_leavesItExpiredRatherThanGrantingFourteen() throws {
		let grantDate = try date(2026, 3, 2)
		let wound = FreeAccessWindow.record(
			grantedAt: grantDate,
			thresholds: FreeAccessThresholds(grantDays: 0, reminderOnDay: 0),
			calendar: calendar
		)

		let bounded = FreeAccessWindow.credible(wound, now: grantDate, calendar: calendar)

		var window = FreeAccessWindow(calendar: calendar)
		window.settle(fast: bounded, durable: nil)
		XCTAssertEqual(window.phase(at: grantDate), .expired, "winding the window down granted one")
	}

	/// A reminder on day 0 is legitimate, and every honest record written under it has
	/// `reminderDueAt` at the start of the grant day — i.e. *before* `grantedAt` for any grant not
	/// made at midnight. A bound comparing those two directly would reject all of them.
	func testCredible_whenTheReminderFallsOnTheGrantDay_doesNotRewriteHonestRecords() throws {
		let grantDate = try date(2026, 3, 2, hour: 18)
		let honest = FreeAccessWindow.record(
			grantedAt: grantDate,
			thresholds: FreeAccessThresholds(grantDays: 14, reminderOnDay: 0),
			calendar: calendar
		)

		let bounded = FreeAccessWindow.credible(honest, now: grantDate, calendar: calendar)

		XCTAssertEqual(bounded.reminderDueAt, honest.reminderDueAt)
		XCTAssertEqual(bounded.expiresAt, honest.expiresAt)
	}

	/// An honest traveller must not lose their window.
	///
	/// `Calendar.current` carries the device's time zone, so flying re-aligns midnight and a frozen
	/// expiry stops landing exactly on a day boundary. Reproduction then fails on equality even
	/// though the thresholds the record implies are perfectly ordinary — and rebuilding to
	/// `.standard` there would cut a deliberately-configured 30-day window down to 14 and persist
	/// that to both stores. Rebuilding with the record's *own* thresholds re-aligns it instead.
	func testCredible_whenTheTimeZoneMovedUnderAnHonestRecord_keepsItsLengthRatherThanTheDefault() throws {
		let grantDate = try date(2026, 3, 2)
		let honest = FreeAccessWindow.record(
			grantedAt: grantDate,
			thresholds: FreeAccessThresholds(grantDays: 30, reminderOnDay: 15),
			calendar: calendar
		)
		var tokyo = Calendar(identifier: .gregorian)
		tokyo.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))

		let bounded = FreeAccessWindow.credible(honest, now: grantDate, calendar: tokyo)

		// Re-aligned to the new midnight, so not byte-identical — but still the window they were
		// granted. `.standard` would land ~14 days out; the honest length is ~30.
		let days = bounded.expiresAt.timeIntervalSince(bounded.grantedAt) / 86_400
		XCTAssertGreaterThan(days, 25, "a 30-day window was rebuilt as the default 14")
	}

	/// Where the ceiling actually sits, which the decade-long forgery above cannot show.
	func testCredible_atTheThresholdCeiling_keepsTheLimitAndRebuildsBeyondIt() throws {
		let grantDate = try date(2026, 3, 2)
		let atLimit = FreeAccessWindow.record(
			grantedAt: grantDate,
			thresholds: FreeAccessThresholds(grantDays: FreeAccessWindow.maxCredibleGrantDays, reminderOnDay: 7),
			calendar: calendar
		)
		// Built by hand: `FreeAccessThresholds` now clamps on construction, so it cannot express an
		// over-cap window — which is the point of the clamp, and why a forged *record* is the only
		// way this state arises at all.
		let firstDay = calendar.startOfDay(for: grantDate)
		let overLimit = FreeAccessWindow.Record(
			grantedAt: grantDate,
			expiresAt: try XCTUnwrap(
				calendar.date(byAdding: .day, value: FreeAccessWindow.maxCredibleGrantDays + 1, to: firstDay)
			),
			reminderDueAt: try XCTUnwrap(calendar.date(byAdding: .day, value: 7, to: firstDay)),
			maxObservedDate: grantDate,
			reminderShown: false,
			day0Shown: false
		)

		XCTAssertEqual(
			FreeAccessWindow.credible(atLimit, now: grantDate, calendar: calendar).expiresAt,
			atLimit.expiresAt,
			"the ceiling itself must be allowed"
		)
		// Asserts the *direction*, not merely that something changed: a rebuild that lengthened the
		// window would also satisfy "not equal", and would be the failure this is guarding against.
		XCTAssertLessThan(
			FreeAccessWindow.credible(overLimit, now: grantDate, calendar: calendar).expiresAt,
			overLimit.expiresAt,
			"a window past the ceiling was honoured"
		)
	}

	/// The fast store is a plain plist and editable in an unencrypted backup; the Keychain copy is
	/// not. On an exact `grantedAt` tie the durable record must win, or an inflated `expiresAt`
	/// would both take effect and be written back over the durable store by the reconciliation
	/// repair — laundering the edit into the authoritative copy.
	func testReconcile_whenTheStoresTieOnGrantDate_prefersTheDurableRecord() throws {
		let grantDate = try date(2026, 3, 2)
		let durable = FreeAccessWindow.record(grantedAt: grantDate, thresholds: .standard, calendar: calendar)
		// Same identity, inflated expiry — what editing the plist in a backup would produce.
		let tampered = FreeAccessWindow.Record(
			grantedAt: durable.grantedAt,
			expiresAt: try day(900, after: grantDate),
			reminderDueAt: durable.reminderDueAt,
			maxObservedDate: durable.maxObservedDate,
			reminderShown: durable.reminderShown,
			day0Shown: durable.day0Shown
		)

		let reconciled = try XCTUnwrap(FreeAccessWindow.reconcile(fast: tampered, durable: durable))

		XCTAssertEqual(reconciled.expiresAt, durable.expiresAt, "a tampered fast record won the tie")
	}

	// MARK: - A grant stamped in the future

	/// The attack the monotonic floor made permanent: date the device forward, take the grant, put
	/// the clock back. `grantedAt` and the floor are both stamped in the future, and `phase(at:)`
	/// clamps to that floor precisely so a rollback cannot rewind a window — so without this repair
	/// the window stays open until real time catches up with the forged date.
	func testReanchor_whenTheGrantIsStampedFarInTheFuture_restartsItFromNow() throws {
		let realNow = try date(2026, 3, 2)
		let forged = try XCTUnwrap(calendar.date(byAdding: .year, value: 4, to: realNow))
		let record = FreeAccessWindow.record(grantedAt: forged, thresholds: .standard, calendar: calendar)

		let repaired = try XCTUnwrap(
			FreeAccessWindow.reanchoredIfGrantedInTheFuture(record, now: realNow, calendar: calendar)
		)

		XCTAssertEqual(repaired.grantedAt, realNow)
		XCTAssertEqual(repaired.maxObservedDate, realNow, "the forged floor would rebuild the same window")
		// The frozen duration is carried across, not re-read: still fourteen days, from now.
		XCTAssertEqual(repaired.expiresAt, try day(14, after: realNow, hour: 0))

		var window = FreeAccessWindow(calendar: calendar)
		window.settle(fast: repaired, durable: repaired)
		XCTAssertEqual(window.phase(at: try day(14, after: realNow)), .expired)
	}

	/// An ordinary record is left alone, and so is one a hair ahead — a clock corrected by NTP just
	/// after a grant must not be read as an attack.
	func testReanchor_whenTheGrantIsOrdinary_leavesItUntouched() throws {
		let now = try date(2026, 3, 2)
		let record = FreeAccessWindow.record(grantedAt: now, thresholds: .standard, calendar: calendar)

		XCTAssertNil(FreeAccessWindow.reanchoredIfGrantedInTheFuture(record, now: now, calendar: calendar))

		let slightlyAhead = FreeAccessWindow.record(
			grantedAt: now.addingTimeInterval(60),
			thresholds: .standard,
			calendar: calendar
		)
		XCTAssertNil(
			FreeAccessWindow.reanchoredIfGrantedInTheFuture(slightlyAhead, now: now, calendar: calendar)
		)
	}

	func testSettle_withAnEarlierDurableAnchor_resumesRatherThanRestarts() throws {
		let originalGrant = try date(2026, 3, 2)
		var durable = FreeAccessWindow.record(grantedAt: originalGrant, thresholds: .standard, calendar: calendar)
		durable.reminderShown = true
		var window = FreeAccessWindow(calendar: calendar)

		window.settle(fast: nil, durable: durable)

		// Day 13 of the *original* grant, not day 13 of a window that restarted here.
		XCTAssertFalse(window.canGrant)
		XCTAssertEqual(window.phase(at: try day(13, after: originalGrant)), .active(remaining: 1))
	}
}
