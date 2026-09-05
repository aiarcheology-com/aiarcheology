//
//  FindingsSyncTests.swift
//  MLBrowserUnitTests
//
//  AIA-727: the rules that decide what is owed to the cloud, and what is owed to the user.
//

import CoreData
import XCTest
@testable import ML_Browser

/// The ledger's rules, in isolation from the network.
///
/// These are the decisions that lose or duplicate a user's fieldwork if they are wrong, so they are
/// tested as arithmetic rather than only through a full sync.
final class FindingsSyncLedgerTests: XCTestCase {

	/// Every directory a test asked for, removed when it ends. The test host is the app itself and
	/// shares its container, so without this each run left one `tmp/<UUID>` of ledger files behind
	/// per test -- harmless, but indistinguishable at a glance from an import that leaked.
	private var scratchDirectories: [URL] = []

	override func tearDown() async throws {
		for directory in scratchDirectories { try? FileManager.default.removeItem(at: directory) }
		scratchDirectories = []
		try await super.tearDown()
	}

	private func makeStore(account: String) -> (FindingsSyncLedgerStore, URL) {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		scratchDirectories.append(directory)
		return (FindingsSyncLedgerStore(accountIdentifier: account, directory: directory), directory)
	}

	func testAFindingThisAccountCreatedHereIsOwed() {
		let id = UUID()
		var ledger = FindingsSyncLedger()
		ledger.owned.insert(id.uuidString)
		XCTAssertTrue(ledger.needsUpload(id: id, localModifiedAt: 1_000))
	}

	func testAFindingThisAccountNeitherMadeNorSentIsNotUploadedOnAGuess() {
		// The shared-device case. The local store may hold work belonging to whoever used the app
		// last, and an account that has never seen a finding has no business copying it into its
		// own cloud storage without being told to.
		let ledger = FindingsSyncLedger()
		XCTAssertFalse(ledger.needsUpload(id: UUID(), localModifiedAt: 1_000))
	}

	func testAgreeingToBackUpOneFindingSaysNothingAboutAnother() {
		// This used to be a single "already answered" flag for the whole account, which meant one
		// yes authorised every finding that ever appeared on the device afterwards -- including
		// another account's.
		let agreed = UUID()
		let stranger = UUID()
		var ledger = FindingsSyncLedger()
		ledger.owned.insert(agreed.uuidString)
		XCTAssertTrue(ledger.needsUpload(id: agreed, localModifiedAt: 1_000))
		XCTAssertFalse(ledger.needsUpload(id: stranger, localModifiedAt: 1_000))
	}

	func testAFindingTheCloudConfirmedAtTheSameTimestampIsNotOwedAgain() {
		// The case that would otherwise re-upload every finding on every trigger, for ever.
		let id = UUID()
		var ledger = FindingsSyncLedger()
		ledger.uploaded[id.uuidString] = 1_000
		XCTAssertFalse(ledger.needsUpload(id: id, localModifiedAt: 1_000))
		XCTAssertTrue(ledger.needsUpload(id: id, localModifiedAt: 1_001))
		// Having sent it once is itself provenance: no further consent is needed to send an edit.
		XCTAssertTrue(ledger.mayUpload(id: id))
	}

	func testADeclinedFindingIsNeverOwed() {
		// Declining has to be persisted, or the outbox re-derives the finding and asks again on
		// every launch — and on a shared device that is a prompt to upload someone else's work.
		let id = UUID()
		var ledger = FindingsSyncLedger()
		ledger.excluded.insert(id.uuidString)
		XCTAssertFalse(ledger.needsUpload(id: id, localModifiedAt: 9_999))
	}

	func testEditingAParkedFindingMakesItOwedAgain() {
		// Parking is not permanent: the user has changed the thing the cloud refused.
		let id = UUID()
		var ledger = FindingsSyncLedger()
		ledger.owned.insert(id.uuidString)
		ledger.parked[id.uuidString] = ParkedUpload(code: "quota_exceeded", modifiedAt: 1_000)
		XCTAssertFalse(ledger.needsUpload(id: id, localModifiedAt: 1_000))
		XCTAssertTrue(ledger.needsUpload(id: id, localModifiedAt: 1_001))
	}

	func testOneAccountsLedgerIsInvisibleToAnother() async {
		// A shared device. If a single ledger served both, the second account's client would
		// believe the first account's findings were already backed up, and would read its cursor.
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		scratchDirectories.append(directory)
		let first = FindingsSyncLedgerStore(accountIdentifier: "user_first", directory: directory)
		let second = FindingsSyncLedgerStore(accountIdentifier: "user_second", directory: directory)

		var ledger = FindingsSyncLedger()
		ledger.cursor = "42.abc"
		ledger.uploaded["A"] = 7
		await first.save(ledger)

		let other = await second.loadLedger()
		XCTAssertNil(other.cursor)
		XCTAssertTrue(other.uploaded.isEmpty)
		let mine = await first.loadLedger()
		XCTAssertEqual(mine.cursor, "42.abc")
	}

	func testTheAccountIdIsNotSpelledIntoAFilename() async throws {
		// It identifies a person, and filenames are the least protected thing an app writes.
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		scratchDirectories.append(directory)
		let store = FindingsSyncLedgerStore(accountIdentifier: "user_2abcSECRETid", directory: directory)
		await store.save(FindingsSyncLedger())

		let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
		XCTAssertFalse(names.isEmpty)
		for name in names {
			XCTAssertFalse(name.contains("user_2abcSECRETid"), "the account id is in \(name)")
		}
	}

	func testACorruptLedgerIsDiscardedButFailsSafeRatherThanOpenly() async throws {
		// Renamed from ...IsDiscardedRatherThanTrusted at AIA-0755. Discarding the cache is right;
		// discarding it QUIETLY was the bug. Two of these fields are not cache, and the old test
		// passed without noticing either.
		let (store, directory) = makeStore(account: "user_corrupt")
		var stored = FindingsSyncLedger(schemaVersion: 1, cursor: "9.z", uploaded: ["A": 3])
		stored.backUpEnabled = false
		await store.save(stored)
		let file = try XCTUnwrap(
			try FileManager.default.contentsOfDirectory(atPath: directory.path).first { $0.hasPrefix("ledger-") }
		)
		try Data("not json".utf8).write(to: directory.appendingPathComponent(file))

		let recovered = await store.loadLedger()
		XCTAssertNil(recovered.cursor)
		XCTAssertTrue(recovered.uploaded.isEmpty)
		XCTAssertFalse(
			recovered.backUpEnabled,
			"an unreadable ledger is not consent: resetting to the default turned the user's 'do not back up' back into 'do'"
		)
		XCTAssertTrue(
			recovered.holdsUnknownCloudCopies,
			"the account may still hold cloud copies this ledger can no longer name"
		)
	}

	/// A ledger from a build this one does not know takes the same fail-safe. It is the same guard,
	/// and pinning it is what stops a future schema bump from quietly shipping the OPPOSITE -- every
	/// device in the field silently resuming uploads on first launch.
	func testALedgerFromAnUnknownSchemaAlsoFailsSafe() async throws {
		let (store, directory) = makeStore(account: "user_future")
		await store.save(FindingsSyncLedger())
		let file = try XCTUnwrap(
			try FileManager.default.contentsOfDirectory(atPath: directory.path).first { $0.hasPrefix("ledger-") }
		)
		// A REAL ledger with only the version changed. A hand-written fixture that happens to be
		// missing a non-optional key fails to decode at all and takes the same fail-safe branch for
		// the wrong reason -- which is what the first version of this test did.
		var object = try XCTUnwrap(
			JSONSerialization.jsonObject(with: JSONEncoder().encode(FindingsSyncLedger())) as? [String: Any]
		)
		object["schemaVersion"] = FindingsSyncLedger.currentSchemaVersion + 1
		let data = try JSONSerialization.data(withJSONObject: object)
		XCTAssertNoThrow(try JSONDecoder().decode(FindingsSyncLedger.self, from: data), "the fixture must decode")
		try data.write(to: directory.appendingPathComponent(file))

		let recovered = await store.loadLedger()
		XCTAssertFalse(recovered.backUpEnabled)
		XCTAssertTrue(recovered.holdsUnknownCloudCopies)
	}

	/// The other half of the corrupt-ledger bug: with `uploaded` gone, nothing could tell a
	/// signed-out delete which account owned the cloud copy, so no tombstone was written and the
	/// finding came back on the next sign-in -- for this app, site coordinates reappearing after
	/// someone chose to remove them.
	func testAnAccountWithAnUnreadableLedgerStillGetsATombstone() async throws {
		let (store, directory) = makeStore(account: "user_unreadable")
		await store.save(FindingsSyncLedger(schemaVersion: 1, uploaded: ["A": 3]))
		let file = try XCTUnwrap(
			try FileManager.default.contentsOfDirectory(atPath: directory.path).first { $0.hasPrefix("ledger-") }
		)
		try Data("not json".utf8).write(to: directory.appendingPathComponent(file))

		XCTAssertFalse(
			FindingsSyncLedgerStore.accountsHolding(UUID(), in: directory).isEmpty,
			"a ledger that will not decode names nothing, so it must be treated as naming everything"
		)
	}

	/// And it keeps getting one after the reset ledger has been written back over the corrupt file,
	/// which is the state the account actually spends its time in.
	func testAnAccountWhoseLedgerWasResetStillGetsATombstone() async throws {
		let (store, directory) = makeStore(account: "user_reset")
		await store.save(FindingsSyncLedger(schemaVersion: 1, uploaded: ["A": 3]))
		let file = try XCTUnwrap(
			try FileManager.default.contentsOfDirectory(atPath: directory.path).first { $0.hasPrefix("ledger-") }
		)
		try Data("not json".utf8).write(to: directory.appendingPathComponent(file))

		// Exactly what a cycle does: load (which resets), then save the result back.
		let recovered = await store.loadLedger()
		await store.save(recovered)

		XCTAssertFalse(
			FindingsSyncLedgerStore.accountsHolding(UUID(), in: directory).isEmpty,
			"the flag is what carries the warning across the save that replaces the corrupt file"
		)
	}

	/// The flag has to be able to go away again, or the account writes conservative tombstones for
	/// ever. This pins only that `accountsHolding` honours a cleared flag; WHEN the coordinator
	/// clears it -- at the end of a complete walk of the index -- is pinned in
	/// `FindingsSyncCycleTests`.
	func testAnAccountStopsGettingBlanketTombstonesOnceItsLedgerIsRebuilt() async throws {
		let (store, directory) = makeStore(account: "user_rebuilt")
		let held = UUID()
		var rebuilt = FindingsSyncLedger()
		rebuilt.holdsUnknownCloudCopies = false
		rebuilt.uploaded = [held.uuidString: 3]
		await store.save(rebuilt)

		XCTAssertEqual(
			FindingsSyncLedgerStore.accountsHolding(held, in: directory).count, 1,
			"a rebuilt ledger still names the findings it actually holds"
		)
		XCTAssertTrue(
			FindingsSyncLedgerStore.accountsHolding(UUID(), in: directory).isEmpty,
			"and stops claiming the ones it does not -- otherwise every delete keeps costing a phantom tombstone"
		)
	}

	func testACorruptLedgerDoesNotTakeUnsentDeletesWithIt() async throws {
		// Losing the ledger costs a re-upload, which the Worker absorbs. Losing an unsent delete
		// resurrects a finding the user removed — for this app, site coordinates coming back after
		// someone chose to delete them. That is why they are separate files.
		let (store, directory) = makeStore(account: "user_deletes")
		let doomed = UUID()
		try await store.enqueueDelete(PendingDelete(id: doomed, modifiedAt: 500))
		await store.save(FindingsSyncLedger(schemaVersion: 1, cursor: "9.z", uploaded: [:]))

		let ledgerFile = try XCTUnwrap(
			try FileManager.default.contentsOfDirectory(atPath: directory.path).first { $0.hasPrefix("ledger-") }
		)
		try Data("not json".utf8).write(to: directory.appendingPathComponent(ledgerFile))

		let survivors = await store.loadPendingDeletes()
		XCTAssertEqual(survivors.map(\.id), [doomed])
	}

	func testADeleteIsForgottenOnlyOnceTheCloudHasIt() async throws {
		let (store, _) = makeStore(account: "user_ack")
		let first = UUID()
		let second = UUID()
		try await store.enqueueDelete(PendingDelete(id: first, modifiedAt: 1))
		try await store.enqueueDelete(PendingDelete(id: second, modifiedAt: 2))

		await store.removePendingDelete(first)
		let remaining = await store.loadPendingDeletes()
		XCTAssertEqual(remaining.map(\.id), [second])
	}

	func testEnqueueingTheSameDeleteTwiceKeepsOneEntry() async throws {
		let (store, _) = makeStore(account: "user_repeat")
		let id = UUID()
		try await store.enqueueDelete(PendingDelete(id: id, modifiedAt: 1))
		try await store.enqueueDelete(PendingDelete(id: id, modifiedAt: 9))

		let pending = await store.loadPendingDeletes()
		XCTAssertEqual(pending.count, 1)
		XCTAssertEqual(pending.first?.modifiedAt, 9)
	}
}

/// The wire's units.
final class FindingsSyncTimestampTests: XCTestCase {

	func testTimestampsAreTruncatedToWholeMilliseconds() {
		// `willSave()` stamps a `Date` with sub-millisecond precision and the wire carries integers.
		// Comparing a local 1000.7 against a stored 1000 is a difference that never closes: the
		// finding would be re-uploaded on every single trigger.
		let date = Date(timeIntervalSince1970: 1.0007)
		XCTAssertEqual(FindingsSyncCoordinator.milliseconds(date), 1_000)
	}

	func testAnEarlierDateIsNeverRoundedUpPastALaterOne() {
		let earlier = Date(timeIntervalSince1970: 1.0009)
		let later = Date(timeIntervalSince1970: 1.0011)
		XCTAssertLessThan(FindingsSyncCoordinator.milliseconds(earlier), FindingsSyncCoordinator.milliseconds(later))
	}
}
