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

	private func makeStore(account: String) -> (FindingsSyncLedgerStore, URL) {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		return (FindingsSyncLedgerStore(accountIdentifier: account, directory: directory), directory)
	}

	func testAFindingTheCloudHasNeverSeenIsOwed() {
		let ledger = FindingsSyncLedger()
		XCTAssertTrue(ledger.needsUpload(id: UUID(), localModifiedAt: 1_000))
	}

	func testAFindingTheCloudConfirmedAtTheSameTimestampIsNotOwedAgain() {
		// The case that would otherwise re-upload every finding on every trigger, for ever.
		let id = UUID()
		var ledger = FindingsSyncLedger()
		ledger.uploaded[id.uuidString] = 1_000
		XCTAssertFalse(ledger.needsUpload(id: id, localModifiedAt: 1_000))
		XCTAssertTrue(ledger.needsUpload(id: id, localModifiedAt: 1_001))
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
		ledger.parked[id.uuidString] = ParkedUpload(code: "quota_exceeded", modifiedAt: 1_000)
		XCTAssertFalse(ledger.needsUpload(id: id, localModifiedAt: 1_000))
		XCTAssertTrue(ledger.needsUpload(id: id, localModifiedAt: 1_001))
	}

	func testOneAccountsLedgerIsInvisibleToAnother() async {
		// A shared device. If a single ledger served both, the second account's client would
		// believe the first account's findings were already backed up, and would read its cursor.
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
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
		let store = FindingsSyncLedgerStore(accountIdentifier: "user_2abcSECRETid", directory: directory)
		await store.save(FindingsSyncLedger())

		let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
		XCTAssertFalse(names.isEmpty)
		for name in names {
			XCTAssertFalse(name.contains("user_2abcSECRETid"), "the account id is in \(name)")
		}
	}

	func testACorruptLedgerIsDiscardedRatherThanTrusted() async throws {
		let (store, directory) = makeStore(account: "user_corrupt")
		await store.save(FindingsSyncLedger(schemaVersion: 1, cursor: "9.z", uploaded: ["A": 3]))
		let file = try XCTUnwrap(
			try FileManager.default.contentsOfDirectory(atPath: directory.path).first { $0.hasPrefix("ledger-") }
		)
		try Data("not json".utf8).write(to: directory.appendingPathComponent(file))

		let recovered = await store.loadLedger()
		XCTAssertNil(recovered.cursor)
		XCTAssertTrue(recovered.uploaded.isEmpty)
	}

	func testACorruptLedgerDoesNotTakeUnsentDeletesWithIt() async throws {
		// Losing the ledger costs a re-upload, which the Worker absorbs. Losing an unsent delete
		// resurrects a finding the user removed — for this app, site coordinates coming back after
		// someone chose to delete them. That is why they are separate files.
		let (store, directory) = makeStore(account: "user_deletes")
		let doomed = UUID()
		await store.enqueueDelete(PendingDelete(id: doomed, modifiedAt: 500))
		await store.save(FindingsSyncLedger(schemaVersion: 1, cursor: "9.z", uploaded: [:]))

		let ledgerFile = try XCTUnwrap(
			try FileManager.default.contentsOfDirectory(atPath: directory.path).first { $0.hasPrefix("ledger-") }
		)
		try Data("not json".utf8).write(to: directory.appendingPathComponent(ledgerFile))

		let survivors = await store.loadPendingDeletes()
		XCTAssertEqual(survivors.map(\.id), [doomed])
	}

	func testADeleteIsForgottenOnlyOnceTheCloudHasIt() async {
		let (store, _) = makeStore(account: "user_ack")
		let first = UUID()
		let second = UUID()
		await store.enqueueDelete(PendingDelete(id: first, modifiedAt: 1))
		await store.enqueueDelete(PendingDelete(id: second, modifiedAt: 2))

		await store.removePendingDelete(first)
		let remaining = await store.loadPendingDeletes()
		XCTAssertEqual(remaining.map(\.id), [second])
	}

	func testEnqueueingTheSameDeleteTwiceKeepsOneEntry() async {
		let (store, _) = makeStore(account: "user_repeat")
		let id = UUID()
		await store.enqueueDelete(PendingDelete(id: id, modifiedAt: 1))
		await store.enqueueDelete(PendingDelete(id: id, modifiedAt: 9))

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
