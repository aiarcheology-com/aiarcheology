//
//  FreeAccessAnchorServiceTests.swift
//  AI ArcheologyTests
//
//  The reconciliation contract between the fast and durable anchor stores (AIA-0556).
//

import XCTest
@testable import ML_Browser

final class FreeAccessAnchorServiceTests: XCTestCase {

	/// A durable store whose reads and writes can be made to fail on demand — something a real
	/// Keychain cannot be persuaded to do, and the only way to exercise the fail-closed grant.
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

		func deleteRecord() throws {
			record = nil
		}
	}

	private enum TestFailure: Error { case anchorNotGranted }

	private let calendar: Calendar = {
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = .gmt
		return calendar
	}()

	private var storeName = ""
	private var defaults: UserDefaults?
	private var keychain: KeychainFreeAccessAnchorService?

	override func setUpWithError() throws {
		try super.setUpWithError()
		// Both stores get a per-test name. For the Keychain that is not tidiness: items survive app
		// deletion and `simctl erase` by design, so a test writing under the production name would
		// pass once and then fail on every later run on this simulator, forever.
		storeName = "com.aiarcheology.ios.tests.freeAccess.\(UUID().uuidString)"
		defaults = UserDefaults(suiteName: storeName)
		keychain = KeychainFreeAccessAnchorService(serviceName: storeName)
	}

	override func tearDownWithError() throws {
		try keychain?.deleteRecord()
		keychain = nil
		defaults?.removePersistentDomain(forName: storeName)
		defaults = nil
		try super.tearDownWithError()
	}

	// MARK: - Helpers

	private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 18) throws -> Date {
		try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)))
	}

	private func day(_ offset: Int, after start: Date, hour: Int = 9) throws -> Date {
		let shifted = try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: start))
		return try XCTUnwrap(calendar.date(bySettingHour: hour, minute: 0, second: 0, of: shifted))
	}

	private func makeService(
		durableStore: FreeAccessAnchorDurableStore? = nil,
		thresholds: FreeAccessThresholds = .standard,
		now: Date
	) throws -> FreeAccessAnchorService {
		let store: FreeAccessAnchorDurableStore = try durableStore ?? XCTUnwrap(keychain)
		return FreeAccessAnchorService(
			defaults: try XCTUnwrap(defaults),
			durableStore: store,
			thresholds: thresholds,
			calendar: calendar,
			now: { now }
		)
	}

	private func grantedRecord(in window: FreeAccessWindow) throws -> FreeAccessWindow.Record {
		guard case let .granted(record) = window.anchor else {
			XCTFail("Expected a granted anchor, found \(window.anchor).")
			throw TestFailure.anchorNotGranted
		}
		return record
	}

	private func storedFastRecord() throws -> Data? {
		try XCTUnwrap(defaults).data(forKey: FreeAccessAnchorService.defaultsKey)
	}

	/// Grants and asserts it happened, so a test's arrange step stays one line and the `inout`
	/// argument never lands inside an assertion autoclosure.
	private func grantOrFail(_ service: FreeAccessAnchorService, _ window: inout FreeAccessWindow) throws {
		let granted = try service.grant(&window)
		XCTAssertTrue(granted, "Expected the arrange-step grant to succeed.")
	}

	// MARK: - Granting

	func testReconciledWindow_withBothStoresEmpty_permitsAGrant() throws {
		let service = try makeService(now: date(2026, 3, 2))

		let window = service.reconciledWindow()

		XCTAssertTrue(window.canGrant)
		XCTAssertEqual(window.anchor, .absent)
	}

	func testGrant_writesTheAnchorToBothStores() throws {
		let grantDate = try date(2026, 3, 2)
		let service = try makeService(now: grantDate)
		var window = service.reconciledWindow()

		let granted = try service.grant(&window)

		XCTAssertTrue(granted)
		XCTAssertEqual(service.phase(of: window), .active(remaining: 14))
		let durable = try XCTUnwrap(XCTUnwrap(keychain).loadRecord())
		XCTAssertEqual(durable.grantedAt, grantDate)
		XCTAssertNotNil(try storedFastRecord())
	}

	func testGrant_beforeReconciliation_isRefused() throws {
		let service = try makeService(now: date(2026, 3, 2))
		// A window straight out of `init` has read neither store. Granting here would write a new
		// anchor over a Keychain copy nobody has looked at — the reinstall farm itself.
		var window = FreeAccessWindow(calendar: calendar)

		let granted = try service.grant(&window)

		XCTAssertFalse(granted)
		XCTAssertEqual(window.anchor, .reconciling)
		XCTAssertNil(try XCTUnwrap(keychain).loadRecord())
		XCTAssertNil(try storedFastRecord())
	}

	func testGrant_whenAnAnchorAlreadyExists_isRefused() throws {
		let grantDate = try date(2026, 3, 2)
		let granting = try makeService(now: grantDate)
		var first = granting.reconciledWindow()
		try grantOrFail(granting, &first)

		let later = try makeService(now: day(5, after: grantDate))
		var second = later.reconciledWindow()
		let regranted = try later.grant(&second)

		XCTAssertFalse(regranted)
		XCTAssertEqual(try XCTUnwrap(XCTUnwrap(keychain).loadRecord()).grantedAt, grantDate)
	}

	// MARK: - Fail closed

	func testGrant_whenTheDurableWriteFails_doesNotGrant() throws {
		let durableStore = StubDurableStore()
		durableStore.writeError = FreeAccessAnchorError.keychain(errSecIO)
		let service = try makeService(durableStore: durableStore, now: date(2026, 3, 2))
		var window = service.reconciledWindow()

		do {
			_ = try service.grant(&window)
			XCTFail("Expected the grant to fail closed when the durable write fails.")
		} catch {
			XCTAssertEqual(error as? FreeAccessAnchorError, .keychain(errSecIO))
		}

		// A UserDefaults-only grant is a farmable grant, so neither store may show one — and the
		// window must still be grantable once the Keychain works again.
		XCTAssertTrue(window.canGrant)
		XCTAssertEqual(service.phase(of: window), .notGranted)
		XCTAssertNil(durableStore.record)
		XCTAssertNil(try storedFastRecord())
	}

	func testReconciledWindow_whenTheDurableReadFailsAndNoFastRecordExists_forbidsGranting() throws {
		let durableStore = StubDurableStore()
		durableStore.readError = FreeAccessAnchorError.keychain(errSecIO)
		let service = try makeService(durableStore: durableStore, now: date(2026, 3, 2))

		let window = service.reconciledWindow()

		// An unreadable Keychain is not proof that no anchor exists — and an absent fast record is
		// exactly the shape a reinstall leaves behind, because deleting the app destroys the container.
		XCTAssertFalse(window.canGrant)
		XCTAssertEqual(window.anchor, .reconciling)
	}

	/// The other branch, and the one that wrongly walled a legitimate user. A surviving fast record
	/// proves the app container was never destroyed, so this cannot be a reinstall; a Keychain that
	/// momentarily would not answer must not cost a mid-window user their remaining days.
	func testReconciledWindow_whenTheDurableReadFailsButTheFastRecordSurvived_honoursTheWindow() throws {
		let grantDate = try date(2026, 3, 2)
		let fast = FreeAccessWindow.record(grantedAt: grantDate, thresholds: .standard, calendar: calendar)
		try XCTUnwrap(defaults).set(JSONEncoder().encode(fast), forKey: FreeAccessAnchorService.defaultsKey)
		let durableStore = StubDurableStore()
		durableStore.readError = FreeAccessAnchorError.keychain(errSecIO)
		let service = try makeService(durableStore: durableStore, now: day(3, after: grantDate))

		let window = service.reconciledWindow()

		XCTAssertEqual(try grantedRecord(in: window).grantedAt, grantDate)
		XCTAssertEqual(service.phase(of: window), .active(remaining: 11))
		// Honouring a record can never itself hand one out: `canGrant` is only ever true for `.absent`.
		XCTAssertFalse(window.canGrant)
	}

	/// The forward-dated repair must apply on the unreadable-Keychain path too.
	///
	/// Found by two PR reviewers: the repair originally ran only after a *successful* durable read,
	/// so a forged fast anchor was honoured whenever the Keychain failed to answer — reinstating the
	/// unbounded window the repair exists to end. That is not a rare accident to wait for; it is a
	/// condition an attacker can arrange.
	/// The wiring, not the mechanism.
	///
	/// Every other test of the credibility bound calls `FreeAccessWindow.credible` directly, which
	/// proves the rule and nothing about whether it is actually applied — delete the bound from this
	/// service and all of them stay green. The previous version of this fix failed in exactly that
	/// gap: a correct mechanism that a load path walked straight past. These two drive a forged
	/// record through `reconciledWindow()` on both branches instead.
	func testReconciledWindow_whenTheFastRecordClaimsAnUncappedWindow_boundsItBeforeItCanWin() throws {
		let now = try date(2026, 3, 2)
		let honest = FreeAccessWindow.record(grantedAt: now, thresholds: .standard, calendar: calendar)
		// Backdated to win earliest-wins, claiming five years — well past the threshold ceiling.
		let backdated = try XCTUnwrap(calendar.date(byAdding: .day, value: -30, to: now))
		// Hand-built: `FreeAccessThresholds` clamps, so only a forged record can claim this.
		let forgedFirstDay = calendar.startOfDay(for: backdated)
		let forged = FreeAccessWindow.Record(
			grantedAt: backdated,
			expiresAt: try XCTUnwrap(calendar.date(byAdding: .day, value: 365 * 5, to: forgedFirstDay)),
			maxObservedDate: backdated,
			day0Shown: false
		)
		try XCTUnwrap(defaults).set(JSONEncoder().encode(forged), forKey: FreeAccessAnchorService.defaultsKey)
		let service = try makeService(durableStore: StubDurableStore(record: honest), now: now)

		let window = service.reconciledWindow()

		// It still wins the grant-date comparison; it just no longer buys anything by it, because a
		// standard window from thirty days ago expired sixteen days ago.
		XCTAssertEqual(service.phase(of: window), .expired, "an uncapped fast record bought access")
	}

	/// The same, on the branch where there is no durable copy to check it against — which is the
	/// branch an attacker would rather be on.
	func testReconciledWindow_whenTheDurableReadFailsAndTheFastRecordIsUncapped_boundsItAnyway() throws {
		let now = try date(2026, 3, 2)
		let backdated = try XCTUnwrap(calendar.date(byAdding: .day, value: -30, to: now))
		// Hand-built: `FreeAccessThresholds` clamps, so only a forged record can claim this.
		let forgedFirstDay = calendar.startOfDay(for: backdated)
		let forged = FreeAccessWindow.Record(
			grantedAt: backdated,
			expiresAt: try XCTUnwrap(calendar.date(byAdding: .day, value: 365 * 5, to: forgedFirstDay)),
			maxObservedDate: backdated,
			day0Shown: false
		)
		try XCTUnwrap(defaults).set(JSONEncoder().encode(forged), forKey: FreeAccessAnchorService.defaultsKey)
		let durableStore = StubDurableStore()
		durableStore.readError = FreeAccessAnchorError.keychain(errSecIO)
		let service = try makeService(durableStore: durableStore, now: now)

		let window = service.reconciledWindow()

		XCTAssertEqual(service.phase(of: window), .expired, "an unreadable Keychain waived the bound")
	}

	/// A future-dated fast record must be **refused** here, not re-anchored.
	///
	/// This test previously asserted the opposite, and was wrong. Re-anchoring a forged grant to
	/// `now` is the right repair everywhere the durable store can be read — it costs its author
	/// nothing they could not have had honestly. On this path it *manufactures*: the Keychain may
	/// hold a spent anchor that would have refused them, and an unreadable Keychain is exactly the
	/// condition an attacker arranges to hide one. Forging a future date and provoking a read error
	/// would have minted a fresh fourteen days out of an expired window.
	func testReconciledWindow_whenTheDurableReadFailsAndTheFastRecordIsFutureDated_refusesToMintAWindow() throws {
		let realNow = try date(2026, 3, 2)
		let forged = try XCTUnwrap(calendar.date(byAdding: .year, value: 4, to: realNow))
		let fast = FreeAccessWindow.record(grantedAt: forged, thresholds: .standard, calendar: calendar)
		try XCTUnwrap(defaults).set(JSONEncoder().encode(fast), forKey: FreeAccessAnchorService.defaultsKey)
		let durableStore = StubDurableStore()
		durableStore.readError = FreeAccessAnchorError.keychain(errSecIO)
		let service = try makeService(durableStore: durableStore, now: realNow)

		let window = service.reconciledWindow()

		// Unsettled: no access, and — just as important — no grant either, because `canGrant` is
		// false while reconciling. The next launch that can read the Keychain resolves it properly.
		XCTAssertEqual(window.anchor, .reconciling)
		XCTAssertFalse(window.canGrant, "a forged future record opened the door to a fresh grant")
		XCTAssertNil(durableStore.record, "nothing may be written to the store that just failed")
	}

	/// A fast record that is already spent still settles — the user is walled by their *window*
	/// having run out, not by the Keychain being unreadable, and either way no new one is granted.
	func testReconciledWindow_whenTheDurableReadFailsAndTheFastRecordIsExpired_doesNotRegrant() throws {
		let grantDate = try date(2026, 3, 2)
		let fast = FreeAccessWindow.record(grantedAt: grantDate, thresholds: .standard, calendar: calendar)
		try XCTUnwrap(defaults).set(JSONEncoder().encode(fast), forKey: FreeAccessAnchorService.defaultsKey)
		let durableStore = StubDurableStore()
		durableStore.readError = FreeAccessAnchorError.keychain(errSecIO)
		let service = try makeService(durableStore: durableStore, now: day(20, after: grantDate))

		var window = service.reconciledWindow()
		let regranted = try service.grant(&window)

		XCTAssertFalse(regranted)
		XCTAssertEqual(service.phase(of: window), .expired)
	}

	// MARK: - Reinstall

	func testReconciledWindow_whenUserDefaultsWasClearedButTheKeychainSurvived_resumesRatherThanRestarts() throws {
		let grantDate = try date(2026, 3, 2)
		let firstInstall = try makeService(now: grantDate)
		var window = firstInstall.reconciledWindow()
		try grantOrFail(firstInstall, &window)

		// Delete the app: the UserDefaults container goes, the Keychain item does not.
		try XCTUnwrap(defaults).removePersistentDomain(forName: storeName)
		XCTAssertNil(try storedFastRecord())

		// Reinstall on day 13 of the original window.
		let reinstalled = try makeService(now: day(13, after: grantDate))
		var resumed = reinstalled.reconciledWindow()
		let regranted = try reinstalled.grant(&resumed)

		XCTAssertFalse(resumed.canGrant)
		XCTAssertFalse(regranted)
		XCTAssertEqual(try grantedRecord(in: resumed).grantedAt, grantDate)
		XCTAssertEqual(reinstalled.phase(of: resumed), .active(remaining: 1))
		XCTAssertEqual(resumed.phase(at: try day(14, after: grantDate)), .expired)
		// The fast path is repaired too, so the next launch does not depend on the Keychain again.
		XCTAssertNotNil(try storedFastRecord())
	}

	func testReconciledWindow_whenTheKeychainHoldsTheEarlierAnchor_keepsTheEarlierOne() throws {
		let earlyGrant = try date(2026, 3, 2)
		let lateGrant = try date(2026, 5, 20)
		let durableStore = StubDurableStore(
			record: FreeAccessWindow.record(grantedAt: earlyGrant, thresholds: .standard, calendar: calendar)
		)
		// Seed the fast path with a *newer* anchor — the shape a farm attempt would leave behind.
		let fast = FreeAccessWindow.record(grantedAt: lateGrant, thresholds: .standard, calendar: calendar)
		try XCTUnwrap(defaults).set(JSONEncoder().encode(fast), forKey: FreeAccessAnchorService.defaultsKey)
		let service = try makeService(durableStore: durableStore, now: lateGrant)

		let window = service.reconciledWindow()

		XCTAssertEqual(try grantedRecord(in: window).grantedAt, earlyGrant)
		XCTAssertEqual(service.phase(of: window), .expired)
	}

	func testReconciledWindow_whenTheKeychainLostTheAnchor_repairsTheMirrorFromUserDefaults() throws {
		let grantDate = try date(2026, 3, 2)
		let durableStore = StubDurableStore()
		let fast = FreeAccessWindow.record(grantedAt: grantDate, thresholds: .standard, calendar: calendar)
		try XCTUnwrap(defaults).set(JSONEncoder().encode(fast), forKey: FreeAccessAnchorService.defaultsKey)
		let service = try makeService(durableStore: durableStore, now: day(3, after: grantDate))

		_ = service.reconciledWindow()

		XCTAssertEqual(durableStore.record?.grantedAt, grantDate)
	}

	// MARK: - Frozen thresholds

	func testReconciledWindow_whenTheOperatorShortensGrantDaysMidWindow_doesNotExpireTheOpenWindow() throws {
		let grantDate = try date(2026, 3, 2)
		let granting = try makeService(now: grantDate)
		var window = granting.reconciledWindow()
		try grantOrFail(granting, &window)

		// 14 → 7. A user who already holds 14 days keeps all of them.
		let shortened = try makeService(
			thresholds: FreeAccessThresholds(grantDays: 7),
			now: day(10, after: grantDate)
		)
		let resumed = shortened.reconciledWindow()

		XCTAssertEqual(shortened.phase(of: resumed), .active(remaining: 4))
	}

	func testReconciledWindow_whenTheOperatorLengthensGrantDaysMidWindow_doesNotExtendTheOpenWindow() throws {
		let grantDate = try date(2026, 3, 2)
		let granting = try makeService(now: grantDate)
		var window = granting.reconciledWindow()
		try grantOrFail(granting, &window)

		// 14 → 21 buys the open window nothing: its expiry was frozen at grant time.
		let lengthened = try makeService(
			thresholds: FreeAccessThresholds(grantDays: 21),
			now: day(14, after: grantDate)
		)
		let resumed = lengthened.reconciledWindow()

		XCTAssertEqual(lengthened.phase(of: resumed), .expired)
	}

	// MARK: - Progress

	func testObserve_advancesTheMonotonicFloorInBothStores() throws {
		let grantDate = try date(2026, 3, 2)
		let dayTen = try day(10, after: grantDate)
		let granting = try makeService(now: grantDate)
		var window = granting.reconciledWindow()
		try grantOrFail(granting, &window)

		let later = try makeService(now: dayTen)
		var resumed = later.reconciledWindow()
		later.observe(&resumed)

		XCTAssertEqual(try XCTUnwrap(XCTUnwrap(keychain).loadRecord()).maxObservedDate, dayTen)

		// A device wound back to the grant day now buys nothing.
		let rolledBack = try makeService(now: grantDate)
		XCTAssertEqual(rolledBack.phase(of: rolledBack.reconciledWindow()), .active(remaining: 4))
	}

	/// The day-0 marker is written through both stores, so the paywall that explains the window is
	/// shown once per *window* rather than once per launch.
	func testMarkDay0Shown_persistsSoTheWindowIsExplainedOncePerWindow() throws {
		let grantDate = try date(2026, 3, 2)
		let granting = try makeService(now: grantDate)
		var window = granting.reconciledWindow()
		try grantOrFail(granting, &window)

		let daySeven = try makeService(now: day(7, after: grantDate))
		var resumed = daySeven.reconciledWindow()
		XCTAssertNotNil(daySeven.duePrompt(for: resumed))
		daySeven.markDay0Shown(&resumed)

		XCTAssertNil(daySeven.duePrompt(for: resumed))
		let relaunched = try makeService(now: day(7, after: grantDate))
		XCTAssertNil(relaunched.duePrompt(for: relaunched.reconciledWindow()))
	}

	// MARK: - Keychain round trip

	func testKeychainService_savesUpdatesAndDeletesTheRecord() throws {
		let store = try XCTUnwrap(keychain)
		let first = FreeAccessWindow.record(grantedAt: try date(2026, 3, 2), thresholds: .standard, calendar: calendar)

		XCTAssertNil(try store.loadRecord())

		try store.saveRecord(first)
		XCTAssertEqual(try store.loadRecord(), first)

		var updated = first
		updated.day0Shown = true
		try store.saveRecord(updated)
		XCTAssertEqual(try store.loadRecord()?.day0Shown, true)

		try store.deleteRecord()
		XCTAssertNil(try store.loadRecord())
	}

	func testKeychainService_underADifferentServiceName_seesADifferentItem() throws {
		let store = try XCTUnwrap(keychain)
		let record = FreeAccessWindow.record(grantedAt: try date(2026, 3, 2), thresholds: .standard, calendar: calendar)
		try store.saveRecord(record)

		// The injectable name is what keeps a test run from poisoning the shared simulator.
		let other = KeychainFreeAccessAnchorService(serviceName: "\(storeName).other")
		XCTAssertNil(try other.loadRecord())
	}
}
