//
//  MessageReplyTests.swift
//  AI ArcheologyTests
//
//  Merge-patch computation and outbox delivery for message replies (AIA-0115).
//

import XCTest
@testable import ML_Browser

final class MessageReplyPatchBuilderTests: XCTestCase {

	private let base = Date(timeIntervalSince1970: 1_780_000_000)

	private func outboxEntry(
		_ id: String,
		button: String = "yes",
		at offset: TimeInterval = 0,
		appVersion: String? = "1.0.7"
	) -> MessageCenterState.OutboxEntry {
		.init(messageID: id, buttonID: button, timestamp: base.addingTimeInterval(offset), appVersion: appVersion)
	}

	private func reply(_ choice: String = "yes", at offset: TimeInterval = 0, version: String = "1.0.0") -> MessageReply {
		MessageReply(choice: choice, at: base.addingTimeInterval(offset), appVersion: version)
	}

	func test_newEntries_areUpserted_withOutboxFields() {
		let plan = MessageReplyPatchBuilder.plan(
			outbox: [outboxEntry("m1", button: "no", at: 5)],
			serverReplies: [:],
			appVersion: "9.9.9"
		)
		XCTAssertEqual(plan.patch.upsert, ["m1": MessageReply(choice: "no", at: base.addingTimeInterval(5), appVersion: "1.0.7")])
		XCTAssertTrue(plan.patch.remove.isEmpty)
		XCTAssertEqual(plan.settledOutboxIDs, ["m1"])
	}

	/// Entries persisted before the appVersion field decode as nil and fall back to the current version.
	func test_legacyOutboxEntry_fallsBackToCurrentVersion() {
		let plan = MessageReplyPatchBuilder.plan(
			outbox: [outboxEntry("m1", appVersion: nil)],
			serverReplies: [:],
			appVersion: "2.0.0"
		)
		XCTAssertEqual(plan.patch.upsert["m1"]?.appVersion, "2.0.0")
	}

	/// The duplicate guard: an id already server-side is settled without a rewrite — first reply
	/// wins across devices, and a Restore-Defaults resurrection cannot double-write.
	func test_duplicate_isSettledWithoutRewrite() {
		let plan = MessageReplyPatchBuilder.plan(
			outbox: [outboxEntry("m1")],
			serverReplies: ["m1": reply()],
			appVersion: "1.0.7"
		)
		XCTAssertTrue(plan.patch.isEmpty)
		XCTAssertEqual(plan.settledOutboxIDs, ["m1"])
	}

	func test_multipleOutboxEntriesForOneID_newestWins() {
		let plan = MessageReplyPatchBuilder.plan(
			outbox: [outboxEntry("m1", button: "old", at: 0), outboxEntry("m1", button: "new", at: 10)],
			serverReplies: [:],
			appVersion: "1.0.7"
		)
		XCTAssertEqual(plan.patch.upsert["m1"]?.choice, "new")
	}

	/// Retention: the merged map is capped at the newest N; overflow becomes tombstones. Replies
	/// are never pruned by expiry/retraction — only by the cap (G1 decision).
	func test_retention_tombstonesOldestBeyondCap() {
		var server: [String: MessageReply] = [:]
		for index in 0..<20 {
			server["old\(index)"] = reply(at: TimeInterval(index))
		}
		let plan = MessageReplyPatchBuilder.plan(
			outbox: [outboxEntry("fresh", at: 100)],
			serverReplies: server,
			appVersion: "1.0.7"
		)
		XCTAssertEqual(plan.patch.upsert.keys.sorted(), ["fresh"])
		XCTAssertEqual(plan.patch.remove, ["old0"], "the single oldest entry is tombstoned to stay at 20")
		XCTAssertEqual(plan.settledOutboxIDs, ["fresh"])
	}

	/// A brand-new entry that is itself beyond the cap must not be written *and* tombstoned —
	/// the cut drops it from the upsert too.
	func test_retention_dropsNewEntryThatFallsOutsideCap() {
		var server: [String: MessageReply] = [:]
		for index in 0..<20 {
			server["s\(index)"] = reply(at: TimeInterval(100 + index))
		}
		let plan = MessageReplyPatchBuilder.plan(
			outbox: [outboxEntry("ancient", at: -50)],
			serverReplies: server,
			appVersion: "1.0.7"
		)
		XCTAssertNil(plan.patch.upsert["ancient"], "an entry older than the whole cap window is not written")
		XCTAssertFalse(plan.patch.remove.contains("ancient"))
	}

	func test_emptyOutbox_yieldsEmptyPlan() {
		let plan = MessageReplyPatchBuilder.plan(outbox: [], serverReplies: ["m1": reply()], appVersion: "1")
		XCTAssertTrue(plan.patch.isEmpty)
		XCTAssertTrue(plan.settledOutboxIDs.isEmpty)
	}
}

@MainActor
final class MessageReplyCoordinatorTests: XCTestCase {

	private var suiteName: String!
	private var defaults: UserDefaults!

	override func setUp() async throws {
		try await super.setUp()
		suiteName = "MessageReplyCoordinatorTests.\(UUID().uuidString)"
		defaults = UserDefaults(suiteName: suiteName)
	}

	override func tearDown() async throws {
		defaults.removePersistentDomain(forName: suiteName)
		defaults = nil
		suiteName = nil
		try await super.tearDown()
	}

	private final class FakeWriter: MessageReplyWriting {
		var server: [String: MessageReply] = [:]
		var written: [MessageReplyPatchBuilder.Patch] = []
		var failNextWrite = false

		func serverReplies() -> [String: MessageReply] { server }

		func write(_ patch: MessageReplyPatchBuilder.Patch) async throws {
			if failNextWrite {
				failNextWrite = false
				throw URLError(.notConnectedToInternet)
			}
			written.append(patch)
			for (id, reply) in patch.upsert { server[id] = reply }
			for id in patch.remove { server.removeValue(forKey: id) }
		}
	}

	private func makeMessageCenter(json: String) -> MessageCenterState {
		let provider = StaticFeatureFlagProvider(
			overrides: [.isAppMessagingEnabled: true],
			appMessagesJSON: json
		)
		return MessageCenterState(
			featureFlags: FeatureFlagsState(provider: provider),
			userContext: { (userID: "userA", isSignedIn: true) },
			serverRepliedIDs: { [] },
			defaults: defaults,
			appVersion: "1.5.0",
			foregroundNotification: Notification.Name("MessageReplyCoordinatorTests.foreground")
		)
	}

	private let interactiveJSON = #"""
	[{"id":"m1","title":"T","body":"B","surfaces":["inApp"],"buttons":[{"id":"yes","label":"Yes"}]}]
	"""#

	/// Waits until the coordinator's async drain settles by polling the main actor (no fixed
	/// sleeps — AGENTS §15): the drain is a handful of main-actor hops, so this converges fast.
	private func settle(until condition: @escaping () -> Bool) async {
		for _ in 0..<200 where !condition() {
			await Task.yield()
		}
		XCTAssertTrue(condition(), "drain did not settle")
	}

	func test_reply_drainsOutboxToWriter_andClearsIt() async {
		let center = makeMessageCenter(json: interactiveJSON)
		let writer = FakeWriter()
		let coordinator = MessageReplyCoordinator(
			messageCenter: center, writer: writer, isSignedIn: { true }, appVersion: "1.5.0"
		)
		_ = coordinator

		center.presentNextIfNeeded(for: .inApp)
		center.recordReply(buttonID: "yes")

		await settle { writer.server["m1"] != nil && center.pendingOutbox().isEmpty }
		XCTAssertEqual(writer.written.count, 1)
		XCTAssertEqual(writer.server["m1"]?.choice, "yes")
	}

	func test_writeFailure_keepsOutbox_thenForegroundRetryDelivers() async {
		let center = makeMessageCenter(json: interactiveJSON)
		let writer = FakeWriter()
		writer.failNextWrite = true
		let coordinator = MessageReplyCoordinator(
			messageCenter: center, writer: writer, isSignedIn: { true }, appVersion: "1.5.0"
		)

		center.presentNextIfNeeded(for: .inApp)
		center.recordReply(buttonID: "yes")
		await settle { !writer.failNextWrite }
		XCTAssertEqual(center.pendingOutbox().count, 1, "failed delivery keeps the outbox entry")
		XCTAssertNil(writer.server["m1"])

		coordinator.drainSoon() // stands in for the foreground hook, which calls exactly this
		await settle { center.pendingOutbox().isEmpty }
		XCTAssertEqual(writer.server["m1"]?.choice, "yes")
	}

	func test_signedOut_leavesOutboxUntouched() async {
		let center = makeMessageCenter(json: interactiveJSON)
		let writer = FakeWriter()
		let coordinator = MessageReplyCoordinator(
			messageCenter: center, writer: writer, isSignedIn: { false }, appVersion: "1.5.0"
		)
		_ = coordinator

		center.presentNextIfNeeded(for: .inApp)
		XCTAssertNotNil(center.presented)
		// Interactive requires sign-in for *presentation*; this exercises the coordinator's own
		// guard directly regardless.
		// `recordReply` fires `onReplyRecorded`, which is the coordinator's own drain trigger — so
		// this drives the real path and leaves exactly one drain to await. (An extra explicit
		// `drainSoon()` here would enqueue a second, unreferenced task and reopen the race.)
		center.recordReply(buttonID: "yes")
		// Await the drain itself: a "nothing was written" assertion is only meaningful once the
		// drain has actually run and taken its signed-out early return.
		await coordinator.drainTask?.value
		XCTAssertTrue(writer.written.isEmpty)
		XCTAssertFalse(center.pendingOutbox().isEmpty, "the reply waits in the outbox for sign-in")
	}

	/// An id already on the server settles the outbox without a write (the AIA-0303 reset case).
	func test_serverDuplicate_clearsOutboxWithoutWrite() async {
		let center = makeMessageCenter(json: interactiveJSON)
		let writer = FakeWriter()
		writer.server["m1"] = MessageReply(choice: "yes", at: .distantPast, appVersion: "1.0.0")
		let coordinator = MessageReplyCoordinator(
			messageCenter: center, writer: writer, isSignedIn: { true }, appVersion: "1.5.0"
		)
		_ = coordinator

		center.presentNextIfNeeded(for: .inApp)
		center.recordReply(buttonID: "yes")

		await settle { center.pendingOutbox().isEmpty }
		XCTAssertTrue(writer.written.isEmpty, "duplicate settles without a network write")
	}
}
