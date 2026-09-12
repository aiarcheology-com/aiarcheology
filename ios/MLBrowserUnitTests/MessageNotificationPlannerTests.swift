//
//  MessageNotificationPlannerTests.swift
//  AI ArcheologyTests
//
//  Local-notification scheduling plan + the coordinator that applies it (AIA-0115, S7).
//

import XCTest
@testable import ML_Browser

// MARK: - Planner (pure)

final class MessageNotificationPlannerTests: XCTestCase {

	private let now = Date(timeIntervalSince1970: 1_780_000_000)

	private func msg(
		_ id: String,
		notify: Bool = true,
		revision: Int = 0,
		activeFrom: Date? = nil,
		expiresAt: Date? = nil
	) -> AppMessage {
		AppMessage(
			id: id,
			title: "T-\(id)",
			body: "B-\(id)",
			surfaces: [.inApp],
			notify: notify,
			activeFrom: activeFrom,
			expiresAt: expiresAt,
			revision: revision
		)
	}

	private func notificationID(_ id: String) -> String {
		MessageNotificationPlanner.notificationID(for: id)
	}

	private func plan(
		desired: [AppMessage],
		notifiedState: [String: Int] = [:],
		pending: Set<String> = [],
		delivered: Set<String> = []
	) -> MessageNotificationPlanner.Plan {
		MessageNotificationPlanner.plan(
			desired: desired,
			notifiedState: notifiedState,
			pending: pending,
			delivered: delivered,
			now: now
		)
	}

	func testPlan_newMessage_isScheduledAndRecorded() {
		let result = plan(desired: [msg("m1")])
		XCTAssertEqual(result.schedule.map(\.message.id), ["m1"])
		XCTAssertEqual(result.schedule.first?.fireDate, now, "no activeFrom → fire now")
		XCTAssertEqual(result.recordNotified, ["m1": 0])
	}

	func testPlan_revisionBump_reNotifies() {
		let result = plan(desired: [msg("m1", revision: 2)], notifiedState: ["m1": 1])
		XCTAssertEqual(result.schedule.map(\.message.id), ["m1"])
		XCTAssertEqual(result.recordNotified, ["m1": 2])
	}

	func testPlan_sameRevision_doesNotReNotify_andKeepsPending() {
		let result = plan(
			desired: [msg("m1", revision: 0)],
			notifiedState: ["m1": 0],
			pending: [notificationID("m1")]
		)
		XCTAssertTrue(result.schedule.isEmpty, "already notified at this revision")
		XCTAssertTrue(result.recordNotified.isEmpty)
		XCTAssertTrue(result.cancelPending.isEmpty, "still eligible → its pending notification stays")
	}

	func testPlan_futureActiveFrom_firesAtActiveFrom() {
		let future = now.addingTimeInterval(3600)
		let result = plan(desired: [msg("m1", activeFrom: future)])
		XCTAssertEqual(result.schedule.first?.fireDate, future)
	}

	func testPlan_midWindow_firesNow() {
		let result = plan(desired: [msg("m1", activeFrom: now.addingTimeInterval(-3600))])
		XCTAssertEqual(result.schedule.first?.fireDate, now, "already active → fire now, not in the past")
	}

	func testPlan_expired_isExcludedAndItsPendingCancelled() {
		let expired = msg("m1", expiresAt: now.addingTimeInterval(-1))
		let result = plan(desired: [expired], pending: [notificationID("m1")])
		XCTAssertTrue(result.schedule.isEmpty)
		XCTAssertEqual(result.cancelPending, [notificationID("m1")])
	}

	func testPlan_notifyFalse_isExcludedAndItsPendingCancelled() {
		let result = plan(desired: [msg("m1", notify: false)], pending: [notificationID("m1")])
		XCTAssertTrue(result.schedule.isEmpty)
		XCTAssertEqual(result.cancelPending, [notificationID("m1")])
	}

	func testPlan_capsAtSixteen_byDeterministicPriority_reportsDropped() {
		// 18 messages, all activeFrom nil → priority is by id; zero-padded ids make the cut stable.
		let desired = (0..<18).map { msg(String(format: "m%02d", $0)) }
		let result = plan(desired: desired.shuffled())

		XCTAssertEqual(result.schedule.count, MessageNotificationPlanner.scheduleCap)
		XCTAssertEqual(
			result.schedule.map(\.message.id),
			(0..<16).map { String(format: "m%02d", $0) },
			"the 16 lowest ids win the cap, in order"
		)
		XCTAssertEqual(result.droppedByCap, ["m16", "m17"])
		XCTAssertEqual(Set(result.recordNotified.keys).count, 16, "only scheduled messages are recorded")
	}

	/// The cap bounds the TOTAL kept set, not just this pass's additions: 16 already-pending plus
	/// 16 freshly published must not accumulate 32 pending requests (P4 review).
	func testPlan_capBoundsTotal_cancellingEvictedPending_andForgettingTheirRevisions() {
		// 16 old messages (already notified, pending) + 16 new ones with LOWER priority ids —
		// the new ones win the cap; the old ones are evicted.
		let old = (16..<32).map { msg(String(format: "m%02d", $0)) }
		let new = (0..<16).map { msg(String(format: "m%02d", $0)) }
		let oldNotified = Dictionary(uniqueKeysWithValues: old.map { ($0.id, 0) })
		let result = plan(
			desired: old + new,
			notifiedState: oldNotified,
			pending: Set(old.map { notificationID($0.id) })
		)

		XCTAssertEqual(result.schedule.count, 16, "only the kept newcomers schedule")
		XCTAssertEqual(
			result.cancelPending,
			Set(old.map { notificationID($0.id) }),
			"evicted-but-eligible pending requests are cancelled — total stays at the cap"
		)
		XCTAssertEqual(
			result.forgetNotified,
			Set(old.map(\.id)),
			"evicted messages forget their notified revision so re-entering the cap reschedules them"
		)
	}

	func testPlan_cancelsPending_forRetractedMessage() {
		let result = plan(desired: [], pending: [notificationID("gone")])
		XCTAssertEqual(result.cancelPending, [notificationID("gone")])
	}

	func testPlan_removesDelivered_forRetractedMessage() {
		let result = plan(desired: [], delivered: [notificationID("gone")])
		XCTAssertEqual(result.removeDelivered, [notificationID("gone")])
	}

	func testPlan_ignoresForeignNotificationIDs() {
		let result = plan(desired: [], pending: ["com.other.feature.x"], delivered: ["com.other.feature.y"])
		XCTAssertTrue(result.cancelPending.isEmpty)
		XCTAssertTrue(result.removeDelivered.isEmpty)
	}

	func testNotificationID_roundTrips() {
		XCTAssertEqual(
			MessageNotificationPlanner.messageID(fromNotificationID: notificationID("welcome.v2")),
			"welcome.v2",
			"a message id containing dots survives the round-trip"
		)
		XCTAssertNil(MessageNotificationPlanner.messageID(fromNotificationID: "com.other.feature.x"))
	}
}

// MARK: - Coordinator (with the recording no-op scheduler)

@MainActor
final class MessageNotificationCoordinatorTests: XCTestCase {

	private var suiteName: String!
	private var defaults: UserDefaults!

	override func setUp() async throws {
		try await super.setUp()
		suiteName = "MessageNotificationCoordinatorTests.\(UUID().uuidString)"
		defaults = UserDefaults(suiteName: suiteName)
	}

	override func tearDown() async throws {
		defaults.removePersistentDomain(forName: suiteName)
		defaults = nil
		suiteName = nil
		try await super.tearDown()
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
			foregroundNotification: Notification.Name("MessageNotificationCoordinatorTests.foreground")
		)
	}

	@discardableResult
	private func makeCoordinator(
		center: MessageCenterState,
		scheduler: NoOpUserNotificationScheduler
	) -> MessageNotificationCoordinator {
		MessageNotificationCoordinator(messageCenter: center, scheduler: scheduler, languageCode: "en")
	}

	private func notificationID(_ id: String) -> String {
		MessageNotificationPlanner.notificationID(for: id)
	}

	/// One notify-worthy informational inApp message.
	private let notifyJSON = #"""
	[{"id":"m1","title":"Hello","body":"Body","surfaces":["inApp"],"notify":true}]
	"""#

	func testSync_schedulesNotifiableMessage_andRecordsRevision() async {
		let center = makeMessageCenter(json: notifyJSON)
		let scheduler = NoOpUserNotificationScheduler()
		let coordinator = makeCoordinator(center: center, scheduler: scheduler)

		await coordinator.sync()

		let scheduled = await scheduler.scheduledIDs
		XCTAssertEqual(scheduled, [notificationID("m1")])
		XCTAssertEqual(center.notifiedRevisions(), ["m1": 0], "the scheduled revision is persisted")
	}

	func testSync_retraction_cancelsPendingAndRemovesDelivered() async {
		// No notify-worthy messages, but a stale notification lingers in both places → both cleaned.
		let center = makeMessageCenter(json: "[]")
		let scheduler = NoOpUserNotificationScheduler()
		await scheduler.seed(pending: [notificationID("gone")], delivered: [notificationID("gone")])
		let coordinator = makeCoordinator(center: center, scheduler: scheduler)

		await coordinator.sync()

		let cancelled = await scheduler.cancelledPending
		let removed = await scheduler.removedDelivered
		let scheduled = await scheduler.scheduledIDs
		XCTAssertEqual(cancelled, [notificationID("gone")])
		XCTAssertEqual(removed, [notificationID("gone")])
		XCTAssertTrue(scheduled.isEmpty)
	}

	func testSync_requestsAuthorization_onlyWhenSomethingToNotify() async {
		let withMessages = makeMessageCenter(json: notifyJSON)
		let schedulerA = NoOpUserNotificationScheduler()
		let coordinatorA = makeCoordinator(center: withMessages, scheduler: schedulerA)
		await coordinatorA.sync()
		let requestedWithMessages = await schedulerA.authorizationRequestCount
		XCTAssertEqual(requestedWithMessages, 1, "desired non-empty → request provisional auth")

		let empty = makeMessageCenter(json: "[]")
		let schedulerB = NoOpUserNotificationScheduler()
		let coordinatorB = makeCoordinator(center: empty, scheduler: schedulerB)
		await coordinatorB.sync()
		let requestedEmpty = await schedulerB.authorizationRequestCount
		XCTAssertEqual(requestedEmpty, 0, "nothing to notify → never request auth")
	}

	func testSync_backgroundPath_neverRequestsAuthorization_butStillSchedules() async {
		let center = makeMessageCenter(json: notifyJSON)
		let scheduler = NoOpUserNotificationScheduler()
		let coordinator = makeCoordinator(center: center, scheduler: scheduler)

		await coordinator.sync(allowAuthorizationRequest: false)

		let requested = await scheduler.authorizationRequestCount
		let scheduled = await scheduler.scheduledIDs
		XCTAssertEqual(requested, 0, "background sync must not request authorization")
		XCTAssertEqual(scheduled, [notificationID("m1")], "but it still reconciles the schedule")
	}

	/// A rejected system add must NOT record the revision as notified — the next sync retries it
	/// instead of silently never delivering (P4 review).
	func testSync_rejectedSchedule_isNotRecorded_andRetriesNextSync() async {
		let center = makeMessageCenter(json: notifyJSON)
		let scheduler = NoOpUserNotificationScheduler()
		await scheduler.failSchedules(1)
		let coordinator = makeCoordinator(center: center, scheduler: scheduler)

		await coordinator.sync()
		XCTAssertEqual(center.notifiedRevisions(), [:], "rejected add leaves no notified record")

		await coordinator.sync()
		let scheduled = await scheduler.scheduledIDs
		XCTAssertEqual(scheduled, [notificationID("m1")], "the retry lands once the system accepts")
		XCTAssertEqual(center.notifiedRevisions(), ["m1": 0])
	}
}
