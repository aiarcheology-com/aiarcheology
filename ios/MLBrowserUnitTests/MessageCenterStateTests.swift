//
//  MessageCenterStateTests.swift
//  AI ArcheologyTests
//
//  Visibility pipeline, presentation ownership, and account-scoped persistence for the
//  remote in-app messaging state (AIA-0115).
//

import Combine
import XCTest
@testable import ML_Browser

@MainActor
final class MessageCenterStateTests: XCTestCase {

	// A fixed reference instant; every message window is expressed relative to it so the tests are
	// independent of wall-clock time.
	private let base = Date(timeIntervalSince1970: 1_780_000_000)
	private var suiteName: String!
	private var defaults: UserDefaults!
	private var clock: Clock!
	private var identity: Identity!
	private var serverReplied: Set<String> = []

	override func setUp() async throws {
		try await super.setUp()
		suiteName = "MessageCenterStateTests.\(UUID().uuidString)"
		defaults = UserDefaults(suiteName: suiteName)
		clock = Clock(base)
		identity = Identity(userID: "userA", isSignedIn: true)
		serverReplied = []
	}

	override func tearDown() async throws {
		defaults.removePersistentDomain(forName: suiteName)
		defaults = nil
		clock = nil
		identity = nil
		suiteName = nil
		try await super.tearDown()
	}

	// MARK: - Filter matrix

	func testReevaluate_flagOff_yieldsNoMessages() {
		let sut = makeSUT(json: payload(msg(id: "m1", surfaces: ["inApp", "aboutApp"])), flagEnabled: false)
		XCTAssertNil(sut.nextMessage(for: .inApp))
		XCTAssertTrue(sut.aboutMessages.isEmpty)
	}

	func testReevaluate_activeWindow_gatesOnNow() {
		let sut = makeSUT(json: payload(msg(id: "m1", surfaces: ["inApp"], activeFrom: base.addingTimeInterval(3600))))
		XCTAssertNil(sut.nextMessage(for: .inApp), "before activeFrom → not visible")

		clock.now = base.addingTimeInterval(7200)
		sut.reevaluate()
		XCTAssertEqual(sut.nextMessage(for: .inApp)?.id, "m1", "after activeFrom → visible")
	}

	func testReevaluate_expiry_excludesExpired() {
		let sut = makeSUT(json: payload(msg(id: "m1", surfaces: ["inApp"], expiresAt: base.addingTimeInterval(100))))
		XCTAssertEqual(sut.nextMessage(for: .inApp)?.id, "m1")

		clock.now = base.addingTimeInterval(200)
		sut.reevaluate()
		XCTAssertNil(sut.nextMessage(for: .inApp))
	}

	func testReevaluate_versionBounds_excludeOutOfRange() {
		let json = payload(
			msg(id: "tooNew", surfaces: ["inApp"], minVersion: "2.0.0"),
			msg(id: "tooOld", surfaces: ["inApp"], maxVersion: "1.0.0"),
			msg(id: "inRange", surfaces: ["inApp"], minVersion: "1.0.0", maxVersion: "2.0.0")
		)
		let sut = makeSUT(json: json, appVersion: "1.5.0")
		XCTAssertEqual(sut.nextMessage(for: .inApp)?.id, "inRange")
	}

	func testReevaluate_perSurfaceSplit() {
		let sut = makeSUT(json: payload(msg(id: "m1", surfaces: ["paywall", "inApp"])))
		XCTAssertEqual(sut.nextMessage(for: .paywall)?.id, "m1")
		XCTAssertEqual(sut.nextMessage(for: .inApp)?.id, "m1")
		XCTAssertNil(sut.nextMessage(for: .login))
	}

	func testReevaluate_login_neverShowsInteractive_evenWhenSignedIn() {
		identity.isSignedIn = true
		let sut = makeSUT(json: payload(msg(id: "m1", surfaces: ["login"], buttons: true)))
		XCTAssertNil(sut.nextMessage(for: .login), "login is pre-auth, display-only")
	}

	func testReevaluate_signedOut_excludesInteractiveEverywhere() {
		let json = payload(msg(id: "m1", surfaces: ["paywall", "inApp"], buttons: true))

		identity.isSignedIn = false
		let signedOut = makeSUT(json: json)
		XCTAssertNil(signedOut.nextMessage(for: .paywall))
		XCTAssertNil(signedOut.nextMessage(for: .inApp))

		identity.isSignedIn = true
		let signedIn = makeSUT(json: json)
		XCTAssertEqual(signedIn.nextMessage(for: .paywall)?.id, "m1")
		XCTAssertEqual(signedIn.nextMessage(for: .inApp)?.id, "m1")
	}

	func testReevaluate_seen_excludesInformationalOnAlertSurfaces() {
		let sut = makeSUT(json: payload(msg(id: "m1", surfaces: ["inApp"])))
		sut.presentNextIfNeeded(for: .inApp)
		sut.dismissPresented() // informational → marks seen

		XCTAssertNil(sut.nextMessage(for: .inApp))
		XCTAssertTrue(sut.seenMessageIDs().contains("m1"))
	}

	func testReevaluate_replied_excludesInteractive_serverAndLocal() {
		let json = payload(
			msg(id: "server", surfaces: ["inApp"], buttons: true),
			msg(id: "local", surfaces: ["inApp"], buttons: true)
		)

		serverReplied = ["server"]
		let sut = makeSUT(json: json)
		// The server-replied one is already gone; only "local" remains.
		XCTAssertEqual(sut.nextMessage(for: .inApp)?.id, "local")

		sut.presentNextIfNeeded(for: .inApp)
		sut.recordReply(buttonID: "ok") // local reply for "local"
		XCTAssertNil(sut.nextMessage(for: .inApp), "both server- and local-replied are excluded")
	}

	func testReevaluate_aboutApp_exemptFromSeen_andExcludesInteractive() {
		let json = payload(
			msg(id: "info", surfaces: ["aboutApp"]),
			msg(id: "interactive", surfaces: ["aboutApp"], buttons: true)
		)
		let sut = makeSUT(json: json)
		XCTAssertEqual(sut.aboutMessages.map(\.id), ["info"], "interactive excluded on aboutApp")

		// Mark "info" seen via an alert surface would need it there; instead seed the seen set directly
		// through a dismiss on a parallel alert message is not applicable — assert seen-exemption by
		// persisting a seen id and re-evaluating.
		defaults.set(["info"], forKey: "appMessages.userA.seenIDs")
		sut.reevaluate()
		XCTAssertEqual(sut.aboutMessages.map(\.id), ["info"], "aboutApp is exempt from seen-gating")
	}

	// MARK: - Ordering

	func testOrdering_activeFromAscending_nilFirst_tieById() {
		let json = payload(
			msg(id: "late", surfaces: ["inApp"], activeFrom: base.addingTimeInterval(200)),
			msg(id: "b", surfaces: ["inApp"]),                                   // nil activeFrom → first
			msg(id: "a", surfaces: ["inApp"]),                                   // nil activeFrom, tie by id → before "b"
			msg(id: "early", surfaces: ["inApp"], activeFrom: base.addingTimeInterval(100))
		)
		// Past every activeFrom: ordering is only observable on *visible* messages — a future
		// activeFrom excludes a message outright (testReevaluate_activeWindow_gatesOnNow).
		clock.now = base.addingTimeInterval(300)
		let sut = makeSUT(json: json)
		XCTAssertEqual(sut.testOnlyQueueIDs(for: .inApp), ["a", "b", "early", "late"])
	}

	func testNextMessage_returnsHead() {
		let json = payload(
			msg(id: "second", surfaces: ["inApp"], activeFrom: base.addingTimeInterval(100)),
			msg(id: "first", surfaces: ["inApp"])
		)
		let sut = makeSUT(json: json)
		XCTAssertEqual(sut.nextMessage(for: .inApp)?.id, "first")
	}

	func testPresentNextIfNeeded_noOpsWhenAlreadyPresented() {
		let json = payload(
			msg(id: "first", surfaces: ["inApp"]),
			msg(id: "second", surfaces: ["inApp"], activeFrom: base.addingTimeInterval(100))
		)
		let sut = makeSUT(json: json)
		sut.presentNextIfNeeded(for: .inApp)
		XCTAssertEqual(sut.presented?.id, "first")
		sut.presentNextIfNeeded(for: .inApp) // must not replace the on-screen message
		XCTAssertEqual(sut.presented?.id, "first")
	}

	// MARK: - Dismiss / reply

	func testDismiss_informational_marksSeenPersistedAndRealmScoped() {
		let sut = makeSUT(json: payload(msg(id: "m1", surfaces: ["inApp"])))
		sut.presentNextIfNeeded(for: .inApp)
		sut.dismissPresented()

		XCTAssertNil(sut.presented)
		XCTAssertEqual(defaults.stringArray(forKey: "appMessages.userA.seenIDs"), ["m1"])
	}

	func testDismiss_interactive_doesNotMarkSeen() {
		identity.isSignedIn = true
		let sut = makeSUT(json: payload(msg(id: "m1", surfaces: ["inApp"], buttons: true)))
		sut.presentNextIfNeeded(for: .inApp)
		sut.dismissPresented() // dismissed without replying

		XCTAssertNil(sut.presented)
		XCTAssertFalse(sut.seenMessageIDs().contains("m1"))
		XCTAssertEqual(sut.nextMessage(for: .inApp)?.id, "m1", "un-replied interactive can re-present")
	}

	func testRecordReply_recordsOutboxLocalRepliedClearsPresented_andFiresHook() {
		identity.isSignedIn = true
		let sut = makeSUT(json: payload(msg(id: "m1", surfaces: ["inApp"], buttons: true)))

		var hookMessageID: String?
		var hookButtonID: String?
		sut.onReplyRecorded = { message, button in
			hookMessageID = message.id
			hookButtonID = button.id
		}

		sut.presentNextIfNeeded(for: .inApp)
		sut.recordReply(buttonID: "ok")

		XCTAssertNil(sut.presented)
		XCTAssertTrue(sut.locallyRepliedMessageIDs().contains("m1"))
		XCTAssertEqual(sut.pendingOutbox().map(\.messageID), ["m1"])
		XCTAssertEqual(sut.pendingOutbox().first?.buttonID, "ok")
		XCTAssertEqual(sut.pendingOutbox().first?.timestamp, base)
		XCTAssertEqual(hookMessageID, "m1")
		XCTAssertEqual(hookButtonID, "ok")
	}

	func testRecordReply_unknownButton_isIgnored() {
		identity.isSignedIn = true
		let sut = makeSUT(json: payload(msg(id: "m1", surfaces: ["inApp"], buttons: true)))
		sut.presentNextIfNeeded(for: .inApp)
		sut.recordReply(buttonID: "does-not-exist")

		XCTAssertEqual(sut.presented?.id, "m1", "invalid button id is a no-op")
		XCTAssertTrue(sut.pendingOutbox().isEmpty)
		XCTAssertFalse(sut.locallyRepliedMessageIDs().contains("m1"))
	}

	// MARK: - Retraction

	func testRetraction_expiryMidPresentation_clearsPresented() {
		let sut = makeSUT(json: payload(msg(id: "m1", surfaces: ["inApp"], expiresAt: base.addingTimeInterval(100))))
		sut.presentNextIfNeeded(for: .inApp)
		XCTAssertEqual(sut.presented?.id, "m1")

		clock.now = base.addingTimeInterval(200)
		sut.reevaluate()
		XCTAssertNil(sut.presented, "an expired message must not stay on screen")
	}

	func testRetraction_removedFromPayload_clearsPresentedOnNextSnapshot() async {
		let provider = MutableFlagProvider(
			initial: snapshot(json: payload(msg(id: "m1", surfaces: ["inApp"])))
		)
		let flags = FeatureFlagsState(provider: provider)
		let sut = makeSUT(featureFlags: flags)

		sut.presentNextIfNeeded(for: .inApp)
		XCTAssertEqual(sut.presented?.id, "m1")

		let cleared = expectation(description: "presented cleared after retraction")
		let cancellable = sut.$presented.dropFirst().sink { if $0 == nil { cleared.fulfill() } }
		provider.emit(snapshot(json: "[]")) // message pulled from the payload
		await fulfillment(of: [cleared], timeout: 2)
		cancellable.cancel()

		XCTAssertNil(sut.presented)
	}

	// MARK: - Account scoping

	func testAccountScoping_seenUnderAInvisibleUnderB_visibleAgainUnderA() {
		let json = payload(msg(id: "m1", surfaces: ["inApp"]))

		identity.userID = "userA"
		let sutA = makeSUT(json: json)
		sutA.presentNextIfNeeded(for: .inApp)
		sutA.dismissPresented()
		XCTAssertNil(sutA.nextMessage(for: .inApp), "seen under A")

		identity.userID = "userB"
		sutA.reevaluate() // realm is resolved per-access, so the switch takes effect immediately
		XCTAssertEqual(sutA.nextMessage(for: .inApp)?.id, "m1", "unseen under B")

		identity.userID = "userA"
		sutA.reevaluate()
		XCTAssertNil(sutA.nextMessage(for: .inApp), "still seen back under A")
	}

	// MARK: - Notification-tap buffering

	func testPendingTap_bufferedBeforeSnapshot_resolvesAfterRefresh() async {
		let provider = MutableFlagProvider(initial: snapshot(json: ""))
		let flags = FeatureFlagsState(provider: provider)
		let sut = makeSUT(featureFlags: flags)

		sut.presentMessage(id: "m1")
		sut.drainPendingTap(for: .inApp)
		XCTAssertNil(sut.presented, "no refreshed snapshot yet → stays buffered")

		await emitAndAwait(provider, flags, snapshot: snapshot(json: payload(msg(id: "m1", surfaces: ["inApp"]))))

		sut.drainPendingTap(for: .inApp)
		XCTAssertEqual(sut.presented?.id, "m1")
	}

	func testPendingTap_unknownIdAfterSnapshot_isDropped() async {
		let provider = MutableFlagProvider(initial: snapshot(json: ""))
		let flags = FeatureFlagsState(provider: provider)
		let sut = makeSUT(featureFlags: flags)

		await emitAndAwait(provider, flags, snapshot: snapshot(json: payload(msg(id: "m1", surfaces: ["inApp"]))))

		sut.presentMessage(id: "unknown")
		sut.drainPendingTap(for: .inApp)
		XCTAssertNil(sut.presented, "an unknown id after a snapshot is dropped silently")
	}

	func testPendingTap_queueJump_presentsTappedNotHead() async {
		let provider = MutableFlagProvider(initial: snapshot(json: ""))
		let flags = FeatureFlagsState(provider: provider)
		let sut = makeSUT(featureFlags: flags)

		// Both immediately active (a future activeFrom would exclude "tapped" from the visible set
		// entirely); "tapped" sits behind "head" via the id tie-break, so the jump is observable.
		let json = payload(
			msg(id: "head", surfaces: ["inApp"]),
			msg(id: "tapped", surfaces: ["inApp"])
		)
		await emitAndAwait(provider, flags, snapshot: snapshot(json: json))
		XCTAssertEqual(sut.nextMessage(for: .inApp)?.id, "head", "precondition: head is first in the queue")

		sut.presentMessage(id: "tapped")
		sut.drainPendingTap(for: .inApp)
		XCTAssertEqual(sut.presented?.id, "tapped", "a tapped message jumps the queue")
	}

	/// A queue-only change (a mid-session publish while nothing is presented) must emit a signal —
	/// `queues` is a plain var, so without the explicit send the banner would wait for the next
	/// foreground (P4 review; the ticket requires delivery within one poll interval).
	func testSnapshotChange_addingAMessage_emitsObjectWillChange() async {
		let provider = MutableFlagProvider(initial: snapshot(json: ""))
		let flags = FeatureFlagsState(provider: provider)
		let sut = makeSUT(featureFlags: flags)

		var signals = 0
		let cancellable = sut.objectWillChange.sink { signals += 1 }
		defer { cancellable.cancel() }

		await emitAndAwait(provider, flags, snapshot: snapshot(json: payload(msg(id: "m1", surfaces: ["inApp"]))))
		XCTAssertGreaterThan(signals, 0, "a queue-affecting publish must wake observers")
		XCTAssertEqual(sut.nextMessage(for: .inApp)?.id, "m1")
	}

	/// A presented message that does not target the newly mounted surface is evicted (not marked
	/// seen), so a login-only banner cannot ride through sign-in onto the app (P4 review).
	func testReconcilePresented_clearsMessageNotTargetingTheNewSurface() {
		let sut = makeSUT(json: payload(msg(id: "login-only", surfaces: ["login"])))
		sut.presentNextIfNeeded(for: .login)
		XCTAssertEqual(sut.presented?.id, "login-only")

		sut.reconcilePresented(for: .inApp)
		XCTAssertNil(sut.presented, "login-only content must not survive onto inApp")
		XCTAssertFalse(sut.seenMessageIDs().contains("login-only"), "eviction is not a dismissal")

		sut.reconcilePresented(for: .login)
		sut.presentNextIfNeeded(for: .login)
		XCTAssertEqual(sut.presented?.id, "login-only", "it returns when its own surface mounts")
	}

	// MARK: - Boundary timer scheduling decision

	func testNextBoundaryDate_returnsEarliestStrictlyFutureInstant() {
		let json = payload(
			msg(id: "past", surfaces: ["inApp"], activeFrom: base.addingTimeInterval(-100)),
			msg(id: "soon", surfaces: ["inApp"], expiresAt: base.addingTimeInterval(50)),
			msg(id: "later", surfaces: ["inApp"], activeFrom: base.addingTimeInterval(500))
		)
		let sut = makeSUT(json: json)
		XCTAssertEqual(sut.nextBoundaryDate(), base.addingTimeInterval(50))

		clock.now = base.addingTimeInterval(100) // the 50s boundary is now in the past
		XCTAssertEqual(sut.nextBoundaryDate(), base.addingTimeInterval(500))
	}

	// MARK: - Test helpers

	// MARK: - Notifiable set
	//
	// `notifiableMessages()` is the input to the notification planner; the planner's own tests
	// hand it a `desired` array, so these are the only cover for the gates inside it (P5 review).

	/// An inline-only message must never be notified: `aboutApp`/`settings` never own `presented`,
	/// so the tap has nothing to resolve to and the app opens to nothing.
	func testNotifiable_inlineOnlySurfaces_areNotNotifiable() {
		let json = payload(
			msg(id: "aboutOnly", surfaces: ["aboutApp"], notify: true),
			msg(id: "settingsOnly", surfaces: ["settings"], notify: true),
			msg(id: "bothInlineAndAlert", surfaces: ["settings", "inApp"], notify: true)
		)
		let sut = makeSUT(json: json)
		XCTAssertEqual(sut.notifiableMessages().map(\.id), ["bothInlineAndAlert"])
	}

	func testNotifiable_requiresTheNotifyFlag() {
		let json = payload(
			msg(id: "silent", surfaces: ["inApp"]),
			msg(id: "loud", surfaces: ["inApp"], notify: true)
		)
		XCTAssertEqual(makeSUT(json: json).notifiableMessages().map(\.id), ["loud"])
	}

	func testNotifiable_excludesExpired_butIncludesFutureActiveFrom() {
		let json = payload(
			msg(id: "expired", surfaces: ["inApp"], notify: true, expiresAt: base.addingTimeInterval(-1)),
			// Scheduled-but-not-yet-live is deliberately kept: the planner fires it AT `activeFrom`.
			msg(id: "future", surfaces: ["inApp"], notify: true, activeFrom: base.addingTimeInterval(3600))
		)
		XCTAssertEqual(makeSUT(json: json).notifiableMessages().map(\.id), ["future"])
	}

	func testNotifiable_excludesOutOfVersionRange() {
		let json = payload(
			msg(id: "tooNew", surfaces: ["inApp"], notify: true, minVersion: "2.0.0"),
			msg(id: "inRange", surfaces: ["inApp"], notify: true, maxVersion: "2.0.0")
		)
		XCTAssertEqual(makeSUT(json: json).notifiableMessages().map(\.id), ["inRange"])
	}

	/// A dismissed informational message stops being notifiable — otherwise dismissing in-app
	/// would leave its notification to fire later anyway.
	func testNotifiable_excludesSeenInformational() {
		let sut = makeSUT(json: payload(msg(id: "m1", surfaces: ["inApp"], notify: true)))
		XCTAssertEqual(sut.notifiableMessages().map(\.id), ["m1"])

		sut.presentNextIfNeeded(for: .inApp)
		sut.dismissPresented()
		XCTAssertTrue(sut.notifiableMessages().isEmpty, "seen ⇒ no longer notifiable")
	}

	/// Interactive messages gate on *replied*, not seen, and require a signed-in user — the same
	/// rule the visibility pipeline applies, so a notification can never outlive its banner.
	func testNotifiable_interactive_gatesOnRepliedAndSignIn() {
		identity.isSignedIn = false
		let sut = makeSUT(json: payload(msg(id: "m1", surfaces: ["inApp"], buttons: true, notify: true)))
		XCTAssertTrue(sut.notifiableMessages().isEmpty, "signed out ⇒ interactive is not notifiable")

		identity.isSignedIn = true
		XCTAssertEqual(sut.notifiableMessages().map(\.id), ["m1"])

		// The visibility queues were built while signed out; re-derive them so the interactive
		// message is presentable and `recordReply` has something to attach to.
		sut.reevaluate()
		sut.presentNextIfNeeded(for: .inApp)
		sut.recordReply(buttonID: "ok")
		XCTAssertTrue(sut.notifiableMessages().isEmpty, "replied ⇒ no longer notifiable")
	}

	// MARK: - Persistence bounds

	/// The seen list is capped, newest-wins, so a long-lived install cannot grow it forever.
	func testMarkSeen_isCappedToTheNewestEntries() {
		let sut = makeSUT(json: payload(msg(id: "m1", surfaces: ["inApp"])))
		let overflowing = (0..<520).map { "old-\($0)" }
		defaults.set(overflowing, forKey: "appMessages.userA.seenIDs")

		sut.presentNextIfNeeded(for: .inApp)
		sut.dismissPresented()

		let stored = defaults.stringArray(forKey: "appMessages.userA.seenIDs") ?? []
		XCTAssertEqual(stored.count, 500, "capped")
		XCTAssertEqual(stored.last, "m1", "the newest mark is kept")
		XCTAssertFalse(stored.contains("old-0"), "the oldest marks are evicted first")
		XCTAssertTrue(stored.contains("old-519"))
	}

	private func makeSUT(json: String, flagEnabled: Bool = true, appVersion: String = "1.5.0") -> MessageCenterState {
		let provider = StaticFeatureFlagProvider(
			overrides: [.isAppMessagingEnabled: flagEnabled],
			appMessagesJSON: json
		)
		return makeSUT(featureFlags: FeatureFlagsState(provider: provider), appVersion: appVersion)
	}

	private func makeSUT(featureFlags: FeatureFlagsState, appVersion: String = "1.5.0") -> MessageCenterState {
		MessageCenterState(
			featureFlags: featureFlags,
			userContext: { [identity] in (identity!.userID, identity!.isSignedIn) },
			serverRepliedIDs: { [weak self] in self?.serverReplied ?? [] },
			defaults: defaults,
			now: { [clock] in clock!.now },
			appVersion: appVersion,
			foregroundNotification: Notification.Name("MessageCenterStateTests.foreground")
		)
	}

	/// Emits a new snapshot through the mutable provider and waits until `FeatureFlagsState`
	/// republishes it — by which point the SUT's own (earlier) subscription has already re-evaluated.
	private func emitAndAwait(
		_ provider: MutableFlagProvider,
		_ flags: FeatureFlagsState,
		snapshot: FeatureFlagSnapshot
	) async {
		let refreshed = expectation(description: "snapshot republished")
		let cancellable = flags.$snapshot.dropFirst().sink { _ in refreshed.fulfill() }
		provider.emit(snapshot)
		await fulfillment(of: [refreshed], timeout: 2)
		cancellable.cancel()
	}

	private func snapshot(json: String) -> FeatureFlagSnapshot {
		FeatureFlagSnapshot(values: [.isAppMessagingEnabled: true], appMessagesJSON: json)
	}

	private static let isoFormatter: ISO8601DateFormatter = {
		let formatter = ISO8601DateFormatter()
		formatter.formatOptions = [.withInternetDateTime]
		return formatter
	}()

	private func iso(_ date: Date) -> String { Self.isoFormatter.string(from: date) }

	/// Builds one message JSON object with the given fields. `title`/`body` are constant; only what a
	/// test varies is exposed.
	private func msg(
		id: String,
		surfaces: [String],
		buttons: Bool = false,
		notify: Bool = false,
		activeFrom: Date? = nil,
		expiresAt: Date? = nil,
		minVersion: String? = nil,
		maxVersion: String? = nil
	) -> String {
		var fields = [
			"\"id\":\"\(id)\"",
			"\"title\":\"T\"",
			"\"body\":\"B\"",
			"\"surfaces\":[\(surfaces.map { "\"\($0)\"" }.joined(separator: ","))]"
		]
		if buttons { fields.append("\"buttons\":[{\"id\":\"ok\",\"label\":\"OK\"}]") }
		if notify { fields.append("\"notify\":true") }
		if let activeFrom { fields.append("\"activeFrom\":\"\(iso(activeFrom))\"") }
		if let expiresAt { fields.append("\"expiresAt\":\"\(iso(expiresAt))\"") }
		if let minVersion { fields.append("\"minAppVersion\":\"\(minVersion)\"") }
		if let maxVersion { fields.append("\"maxAppVersion\":\"\(maxVersion)\"") }
		return "{\(fields.joined(separator: ","))}"
	}

	private func payload(_ objects: String...) -> String { "[\(objects.joined(separator: ","))]" }
}

// MARK: - Test doubles

/// A mutable clock the tests advance by hand.
private final class Clock {
	var now: Date
	init(_ now: Date) { self.now = now }
}

/// Mutable identity so a single SUT can observe an account switch at re-evaluation time.
private final class Identity {
	var userID: String?
	var isSignedIn: Bool
	init(userID: String?, isSignedIn: Bool) {
		self.userID = userID
		self.isSignedIn = isSignedIn
	}
}

/// A provider whose values change after construction, standing in for ConfigCat's auto-poll
/// landing new config with no call from us (mirrors `FeatureFlagsTests`' private helper).
private final class MutableFlagProvider: FeatureFlagProviding, @unchecked Sendable {
	private let lock = NSLock()
	private var snapshot: FeatureFlagSnapshot
	private let stream: AsyncStream<Void>
	private let continuation: AsyncStream<Void>.Continuation

	init(initial: FeatureFlagSnapshot) {
		snapshot = initial
		(stream, continuation) = AsyncStream<Void>.makeStream(
			of: Void.self,
			bufferingPolicy: .bufferingNewest(1)
		)
	}

	func currentSnapshot() -> FeatureFlagSnapshot {
		lock.lock()
		defer { lock.unlock() }
		return snapshot
	}

	func refresh() async {}

	func changes() -> AsyncStream<Void> { stream }

	func setUser(id: String, custom: [String: String]) {}
	func clearUser() {}

	func emit(_ next: FeatureFlagSnapshot) {
		lock.lock()
		snapshot = next
		lock.unlock()
		continuation.yield()
	}
}
