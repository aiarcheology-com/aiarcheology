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
