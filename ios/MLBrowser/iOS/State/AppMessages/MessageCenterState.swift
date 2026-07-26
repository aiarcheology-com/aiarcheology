//
//  MessageCenterState.swift
//  AI Archeology
//
//  Remote in-app messaging — visibility pipeline, presentation ownership, and
//  account-scoped persistence (AIA-0115).
//

import Combine
import Foundation

/// Owns *which* remotely-delivered ``AppMessage`` is shown *where*, and the per-account
/// "seen" / "replied" state that gates it.
///
/// `ObservableObject` (not `@Observable`) on purpose: the surfaces observe it as an
/// `@EnvironmentObject`, matching ``AnalyticsState``/`Settings`. `@MainActor` because every
/// architecture `*State` must be (Harmonize `testStateObjectsAreMainActor`) and every mutation
/// drives UI.
///
/// The pure decode/predicate surface lives on ``AppMessage``; this class is the stateful
/// orchestration around it: it re-evaluates visibility on every trigger (feature-flag snapshot
/// change, a boundary timer at the next activeFrom/expiresAt instant, and app foreground), splits
/// the payload per surface, applies the seen/replied/sign-in gates, and never leaves a retracted
/// message on screen.
///
/// Every input that varies behaviour — the clock, identity, the server-side replied set, the app
/// version and language — is injected, so the whole pipeline is deterministic under test. The
/// account realm is resolved *at access time* (never cached), so switching users A→B→A reads each
/// realm's own sets without an explicit reset.
@MainActor
final class MessageCenterState: ObservableObject {

	/// One recorded reply, queued for the Clerk write. Persisted as JSON under the account realm
	/// so a reply survives relaunch until it is delivered.
	struct OutboxEntry: Codable, Equatable {
		let messageID: String
		let buttonID: String
		let timestamp: Date
		/// App version at reply time. Optional so entries persisted before this field decode;
		/// the delivery path falls back to the current version.
		var appVersion: String?
	}

	/// The message currently owned by an alert surface (login / paywall / inApp). A single global
	/// slot: only one alert message is ever on screen, and `presentNextIfNeeded` no-ops while it is
	/// non-nil. Cleared on dismiss/reply and whenever re-evaluation finds it no longer visible.
	@Published private(set) var presented: AppMessage?

	/// The ordered, currently-visible messages for the `aboutApp` surface, rendered inline rather
	/// than as an alert. Exempt from seen-gating; interactive messages are always excluded here.
	@Published private(set) var aboutMessages: [AppMessage] = []

	/// The ordered, currently-visible messages for the `settings` surface — same inline semantics
	/// as ``aboutMessages`` (seen-exempt, informational only), rendered atop the Settings form.
	@Published private(set) var settingsMessages: [AppMessage] = []

	/// Optional hook fired after a reply is recorded locally, carrying the message and the tapped
	/// button. ``MessageReplyCoordinator`` drains the outbox to Clerk through this.
	var onReplyRecorded: (@MainActor (AppMessage, AppMessage.MessageButton) -> Void)?

	/// Observers fired on every app-foreground re-evaluation. Exists so outbox delivery can retry on
	/// foreground by riding this class's observer instead of duplicating one. Multiple subscribers
	/// (reply delivery today) register via ``addForegroundSyncObserver(_:)``.
	private var foregroundSyncObservers: [@MainActor () -> Void] = []

	/// Observers fired at the end of every ``reevaluate(using:)`` — after visibility is recomputed —
	/// so notification scheduling always follows a fresh visibility pass. Registered via
	/// ``addReevaluationObserver(_:)``.
	private var reevaluationObservers: [@MainActor () -> Void] = []

	// MARK: Injected dependencies

	private let featureFlags: FeatureFlagsState
	private let userContext: @MainActor () -> (userID: String?, isSignedIn: Bool)
	private let serverRepliedIDs: @MainActor () -> Set<String>
	private let defaults: UserDefaults
	private let now: () -> Date
	private let appVersion: String
	private let notificationCenter: NotificationCenter

	// MARK: Derived, recomputed state

	/// Every message decoded from the latest snapshot, regardless of window/version. Retained only
	/// to compute the boundary timer's next wake instant.
	private var allDecoded: [AppMessage] = []
	/// Currently-visible, gated, sorted messages per alert surface.
	private var queues: [MessageSurface: [AppMessage]] = [:]

	/// True once at least one snapshot has arrived *after* construction — i.e. a refresh/auto-poll
	/// completed. A notification tap that lands before this stays buffered; draining it earlier
	/// would resolve against the empty launch snapshot and drop a valid message.
	private var hasReceivedRefreshedSnapshot = false
	/// A message id from a tapped notification, buffered until a surface can present it.
	private var pendingTappedMessageID: String?

	// MARK: Lifetime-scoped tasks / observers

	private var featureFlagObservation: AnyCancellable?
	private var foregroundObservation: AnyCancellable?
	private var boundaryTask: Task<Void, Never>?
	private var boundaryGeneration = 0
	private var backstopTask: Task<Void, Never>?
	private var backstopGeneration = 0

	/// The alert surfaces, in the fixed order used to resolve a tapped notification's message.
	/// `aboutApp` and `settings` are deliberately absent: they render inline and never own
	/// `presented`. This list also gates `notifiableMessages()` — a message no alert surface can
	/// present must not be notified, or its tap resolves to nothing.
	private static let alertSurfaces: [MessageSurface] = [.login, .paywall, .inApp]

	/// The furthest ahead the boundary timer will schedule a single sleep. Longer boundaries are
	/// picked up by the next foreground/refresh trigger instead; this only bounds the wake latency
	/// and keeps the nanosecond conversion well clear of overflow.
	private static let maxBoundaryHorizon: TimeInterval = 60 * 60 * 24 * 7

	/// How long an unresolved buffered tap is held before it is discarded.
	private static let pendingTapBackstop: TimeInterval = 15

	/// Upper bound on each persisted per-realm id list (seen, locally-replied). Campaigns accrete
	/// for the life of the install, so these need a ceiling; see ``appendCapped(_:to:)``.
	private static let maxPersistedIDs = 500

	init(
		featureFlags: FeatureFlagsState,
		userContext: @escaping @MainActor () -> (userID: String?, isSignedIn: Bool),
		serverRepliedIDs: @escaping @MainActor () -> Set<String>,
		defaults: UserDefaults = .standard,
		now: @escaping () -> Date = { Date() },
		appVersion: String = AppEnvironment.shortVersion ?? "0",
		notificationCenter: NotificationCenter = .default,
		// Injected (not defaulted to the UIKit constant) so this file needs no UIKit import —
		// `*State` types stay UI-framework-free (ArchitectureTests ratchet, AGENTS §7). The
		// composition root passes `UIApplication.willEnterForegroundNotification`.
		foregroundNotification: Notification.Name
	) {
		self.featureFlags = featureFlags
		self.userContext = userContext
		self.serverRepliedIDs = serverRepliedIDs
		self.defaults = defaults
		self.now = now
		self.appVersion = appVersion
		self.notificationCenter = notificationCenter

		// Seed from the synchronously-available snapshot so the first frame is correct; this seed is
		// NOT a "refresh completed" — `hasReceivedRefreshedSnapshot` stays false until a live change.
		reevaluate()

		// Re-evaluate on every genuine snapshot change (dropFirst: the current value was just seeded).
		// Auto-poll republishes without any call of ours, so this is what makes a message edit live.
		featureFlagObservation = featureFlags.$snapshot
			.dropFirst()
			.sink { [weak self] snapshot in
				guard let self else { return }
				self.hasReceivedRefreshedSnapshot = true
				// Use the delivered value, not `featureFlags.snapshot`: `@Published` publishes in
				// `willSet`, so the stored property still holds the *old* value inside this closure.
				self.reevaluate(using: snapshot)
			}

		// Foreground re-evaluation: a message may have activated/expired while backgrounded, and the
		// boundary timer is suspended there. UIKit posts this notification on the main thread, so the
		// sink is already main-actor isolated — assume it rather than schedule an extra hop (AGENTS §4).
		foregroundObservation = notificationCenter
			.publisher(for: foregroundNotification)
			.sink { [weak self] _ in
				MainActor.assumeIsolated {
					guard let self else { return }
					self.reevaluate()
					self.foregroundSyncObservers.forEach { $0() }
				}
			}
	}

	deinit {
		// The two `AnyCancellable`s cancel themselves as this object is torn down; the boundary and
		// backstop tasks are `Sendable`, so they are the only things a nonisolated deinit may touch.
		boundaryTask?.cancel()
		backstopTask?.cancel()
	}

	// MARK: - Observers

	/// Registers an observer fired on every app-foreground re-evaluation (reply delivery uses this).
	func addForegroundSyncObserver(_ observer: @escaping @MainActor () -> Void) {
		foregroundSyncObservers.append(observer)
	}

	/// Registers an observer fired after every visibility recompute (notification scheduling uses this).
	func addReevaluationObserver(_ observer: @escaping @MainActor () -> Void) {
		reevaluationObservers.append(observer)
	}

	// MARK: - Queries

	/// The head of `surface`'s gated, sorted queue, or `nil` when nothing is visible there.
	func nextMessage(for surface: MessageSurface) -> AppMessage? {
		queues[surface]?.first
	}

	#if DEBUG
	/// Test-only: the full ordered id list for a surface's queue, so ordering can be asserted beyond
	/// the head. Not part of the production API.
	func testOnlyQueueIDs(for surface: MessageSurface) -> [String] {
		(queues[surface] ?? []).map(\.id)
	}
	#endif

	// MARK: - Presentation intents

	/// Presents the head of `surface`'s queue, unless a message is already on screen.
	///
	/// Assigns only when there is something to present: `@Published` fires on *every* willSet,
	/// equal or not, and the banner modifier re-enters this via `objectWillChange` — a
	/// nil-over-nil assignment would spin that feedback edge into an endless publish loop that
	/// keeps the run loop busy (caught by the S8 UI suite: every XCUITest query timed out).
	func presentNextIfNeeded(for surface: MessageSurface) {
		guard presented == nil, let next = nextMessage(for: surface) else { return }
		presented = next
		let queued = (queues[surface]?.count ?? 1) - 1
		LoggingPolicy.debug(
			"App messages: presenting '\(next.id)' on \(surface.rawValue), \(queued) queued behind",
			logger: .state
		)
	}

	/// Clears a presented message that does not target `surface` — called by the banner modifier
	/// when the mounted surface changes (e.g. sign-in moves login → inApp). Without this, a
	/// login-only banner would ride along onto a surface it never targeted. Not marked seen: the
	/// message returns the next time its own surface mounts. A notification-tap queue jump is
	/// unaffected — taps present within a stable surface, and once the surface changes the same
	/// targeting rule should apply.
	func reconcilePresented(for surface: MessageSurface) {
		guard let current = presented, !current.surfaces.contains(surface) else { return }
		LoggingPolicy.debug(
			"App messages: cleared presented '\(current.id)' (does not target \(surface.rawValue))",
			logger: .state
		)
		presented = nil
	}

	/// Dismisses the presented message. An informational (non-interactive) message is marked *seen*
	/// so it does not return; an interactive one dismissed without a reply is left un-seen so it can
	/// re-present until the user actually replies.
	func dismissPresented() {
		guard let message = presented else { return }
		if !message.isInteractive {
			markSeen(message.id)
		}
		LoggingPolicy.debug(
			"App messages: dismissed '\(message.id)'\(message.isInteractive ? "" : " (marked seen)")",
			logger: .state
		)
		presented = nil
		reevaluate()
	}

	/// Records the user's reply to the presented interactive message: marks it replied locally,
	/// appends a persisted outbox entry, clears the slot, and fires ``onReplyRecorded`` (the actual
	/// Clerk write is a later step). A `buttonID` that is not one of the message's buttons is ignored.
	func recordReply(buttonID: String) {
		guard let message = presented,
			  let button = message.buttons.first(where: { $0.id == buttonID }) else {
			return
		}
		markRepliedLocally(message.id)
		appendOutbox(OutboxEntry(
			messageID: message.id,
			buttonID: buttonID,
			timestamp: now(),
			appVersion: appVersion
		))
		LoggingPolicy.debug(
			"App messages: recorded reply '\(buttonID)' for '\(message.id)'",
			logger: .state
		)
		presented = nil
		onReplyRecorded?(message, button)
		reevaluate()
	}

	// MARK: - Notification-tap buffering

	/// Buffers the id of a message a user tapped in a notification, to be presented once a surface is
	/// available. In-memory only; a backstop discards it if nothing resolves it in time.
	func presentMessage(id: String) {
		pendingTappedMessageID = id
		scheduleBackstop(for: id)
	}

	/// Called by the UI when `surface` becomes available. If a refreshed snapshot has arrived and the
	/// buffered id resolves to a currently-visible message on *any* alert surface, that message jumps
	/// the queue and is presented. Before the first refreshed snapshot the id stays buffered; once a
	/// snapshot has arrived but the id is unknown, it is dropped.
	func drainPendingTap(for surface: MessageSurface) {
		guard let id = pendingTappedMessageID else { return }
		// Hold the tap until content has actually loaded — resolving against the empty launch
		// snapshot would drop a valid message.
		guard hasReceivedRefreshedSnapshot else { return }

		pendingTappedMessageID = nil
		backstopTask?.cancel()

		if let message = visibleAlertMessage(withID: id) {
			LoggingPolicy.debug("App messages: presenting tapped '\(message.id)' (queue jump)", logger: .state)
			presented = message
		} else {
			LoggingPolicy.debug("App messages: dropping buffered tap; id no longer visible.", logger: .state)
		}
	}

	// MARK: - Re-evaluation (internal test seam; also the trigger target)

	/// Recomputes the whole visibility pipeline from the current snapshot: flag gate → decode →
	/// active-window → version → per-surface split → seen/replied/sign-in gates → sort. Clears a
	/// presented message that is no longer visible, and reschedules the boundary timer.
	///
	/// Internal (not private) purely so tests can fire a trigger deterministically instead of racing
	/// the real timer.
	func reevaluate() {
		reevaluate(using: featureFlags.snapshot)
	}

	private func reevaluate(using snapshot: FeatureFlagSnapshot) {
		// Notification scheduling always follows a visibility recompute — fire on every exit path
		// (including the flag-off early return). At init no observers are registered yet, so this
		// no-ops until the coordinator subscribes.
		defer { reevaluationObservers.forEach { $0() } }
		guard snapshot.isAppMessagingEnabled else {
			allDecoded = []
			queues = [:]
			aboutMessages = []
			settingsMessages = []
			clearPresentedIfRetracted()
			scheduleBoundaryTimer()
			return
		}

		let nowDate = now()
		allDecoded = AppMessage.decodeMessages(from: snapshot.appMessagesJSON)
		let liveMessages = allDecoded.filter { $0.isActive(at: nowDate) && $0.matchesVersion(appVersion) }

		let seen = seenMessageIDs()
		let replied = repliedMessageIDs()
		let isSignedIn = userContext().isSignedIn

		var nextQueues: [MessageSurface: [AppMessage]] = [:]
		for surface in Self.alertSurfaces {
			let visible = liveMessages.filter {
				$0.surfaces.contains(surface)
					&& isVisibleOnAlertSurface($0, surface: surface, seen: seen, replied: replied, isSignedIn: isSignedIn)
			}
			nextQueues[surface] = Self.sorted(visible)
		}
		let queuesChanged = nextQueues != queues
		queues = nextQueues

		// Assign only on change for the same reason as `presentNextIfNeeded`: every reevaluation
		// (foreground, timer, snapshot) would otherwise publish an identical array and churn the
		// observers.
		let about = Self.sorted(liveMessages.filter { $0.surfaces.contains(.aboutApp) && !$0.isInteractive })
		if aboutMessages != about {
			aboutMessages = about
		}
		let inSettings = Self.sorted(liveMessages.filter { $0.surfaces.contains(.settings) && !$0.isInteractive })
		if settingsMessages != inSettings {
			settingsMessages = inSettings
		}

		LoggingPolicy.debug(
			"App messages: decoded \(allDecoded.count), live \(liveMessages.count) — "
				+ "inApp \(queues[.inApp]?.count ?? 0), paywall \(queues[.paywall]?.count ?? 0), "
				+ "login \(queues[.login]?.count ?? 0), about \(aboutMessages.count), "
				+ "settings \(settingsMessages.count)",
			logger: .state
		)

		// `queues` is a plain var, so a queue-only change (a mid-session publish while nothing is
		// presented) would otherwise emit NO signal and the banner would wait for the next
		// foreground. Loop-safe: the modifier's re-entry lands in `presentNextIfNeeded`, which
		// assigns only when it actually presents.
		if queuesChanged {
			objectWillChange.send()
		}

		clearPresentedIfRetracted()
		scheduleBoundaryTimer()
	}

	/// Whether `message` should show on an alert surface given the current gates. Informational
	/// messages hide once seen; interactive messages require sign-in, are always hidden on `login`
	/// (pre-auth, display-only), and hide once replied (server ∪ local).
	private func isVisibleOnAlertSurface(
		_ message: AppMessage,
		surface: MessageSurface,
		seen: Set<String>,
		replied: Set<String>,
		isSignedIn: Bool
	) -> Bool {
		guard message.isInteractive else {
			return !seen.contains(message.id)
		}
		if surface == .login { return false }
		guard isSignedIn else { return false }
		return !replied.contains(message.id)
	}

	/// Per-surface ordering: `activeFrom` ascending (a nil `activeFrom` sorts first, as `distantPast`),
	/// ties broken by `id` so the order is total and stable.
	private static func sorted(_ messages: [AppMessage]) -> [AppMessage] {
		messages.sorted { lhs, rhs in
			let lhsFrom = lhs.activeFrom ?? .distantPast
			let rhsFrom = rhs.activeFrom ?? .distantPast
			if lhsFrom != rhsFrom { return lhsFrom < rhsFrom }
			return lhs.id < rhs.id
		}
	}

	/// Clears `presented` when it is no longer in any alert surface's visible set (retracted,
	/// expired, flag turned off, or newly seen/replied) — never leave a stale message on screen.
	private func clearPresentedIfRetracted() {
		guard let current = presented else { return }
		if visibleAlertMessage(withID: current.id) == nil {
			LoggingPolicy.debug(
				"App messages: cleared presented '\(current.id)' (retracted, expired, or gated away)",
				logger: .state
			)
			presented = nil
		}
	}

	/// The currently-visible message with `id` on any alert surface, or `nil`.
	private func visibleAlertMessage(withID id: String) -> AppMessage? {
		for surface in Self.alertSurfaces {
			if let match = queues[surface]?.first(where: { $0.id == id }) {
				return match
			}
		}
		return nil
	}

	// MARK: - Notification eligibility (S7)

	/// The messages eligible for a local notification: the same gates as the alert pipeline but
	/// without the per-surface split, and *including* not-yet-active (future `activeFrom`) messages
	/// so a notification can be scheduled ahead of time. Expired messages are excluded. Requires
	/// `notify == true`, a version match, and the seen (informational) / replied-and-signed-in
	/// (interactive) gates. Realm-scoped like every other accessor; the planner (``MessageNotificationPlanner``)
	/// consumes this. Reads `allDecoded`, which ``reevaluate(using:)`` keeps in step with the flag.
	func notifiableMessages() -> [AppMessage] {
		let nowDate = now()
		let seen = seenMessageIDs()
		let replied = repliedMessageIDs()
		let isSignedIn = userContext().isSignedIn
		return allDecoded.filter { message in
			guard message.notify, message.matchesVersion(appVersion) else { return false }
			// Only a message that some alert surface can actually present is notifiable. The
			// inline surfaces (aboutApp, settings) never own `presented`, so `drainPendingTap`
			// cannot resolve them: notifying one opens the app to nothing.
			guard message.surfaces.contains(where: { Self.alertSurfaces.contains($0) }) else {
				return false
			}
			if let expiry = message.expiresAt, nowDate >= expiry { return false }
			if message.isInteractive {
				guard isSignedIn else { return false }
				return !replied.contains(message.id)
			}
			return !seen.contains(message.id)
		}
	}

	// MARK: - Boundary timer

	/// The earliest `activeFrom`/`expiresAt` strictly after `now()` across all decoded messages, or
	/// `nil` when none remain. Internal so a test can assert the *scheduling decision* without waiting
	/// on a real sleep.
	func nextBoundaryDate() -> Date? {
		let nowDate = now()
		var earliest: Date?
		for message in allDecoded {
			for candidate in [message.activeFrom, message.expiresAt] {
				guard let candidate, candidate > nowDate else { continue }
				earliest = earliest.map { min($0, candidate) } ?? candidate
			}
		}
		return earliest
	}

	/// (Re)schedules a single wake at the next boundary. A generation token means a stale timer that
	/// already passed its sleep is a no-op — correctness never depends on this firing (foreground and
	/// snapshot triggers cover the same ground); it only trims latency.
	private func scheduleBoundaryTimer() {
		boundaryTask?.cancel()
		boundaryGeneration &+= 1
		let generation = boundaryGeneration

		guard let boundary = nextBoundaryDate() else {
			boundaryTask = nil
			return
		}
		let seconds = boundary.timeIntervalSince(now())
		guard seconds > 0 else {
			boundaryTask = nil
			return
		}
		let nanos = UInt64(min(seconds, Self.maxBoundaryHorizon) * 1_000_000_000)

		boundaryTask = Task { [weak self] in
			try? await Task.sleep(nanoseconds: nanos)
			guard let self, !Task.isCancelled, self.boundaryGeneration == generation else { return }
			self.reevaluate()
		}
	}

	// MARK: - Pending-tap backstop

	/// Discards a buffered tap that never resolved, so a tap for a message that is pulled before any
	/// surface appears cannot linger and surprise the user later.
	private func scheduleBackstop(for id: String) {
		backstopTask?.cancel()
		backstopGeneration &+= 1
		let generation = backstopGeneration
		let nanos = UInt64(Self.pendingTapBackstop * 1_000_000_000)

		backstopTask = Task { [weak self] in
			try? await Task.sleep(nanoseconds: nanos)
			guard let self, !Task.isCancelled, self.backstopGeneration == generation else { return }
			if self.pendingTappedMessageID == id {
				self.pendingTappedMessageID = nil
			}
		}
	}

	// MARK: - Account-scoped persistence
	//
	// The realm is resolved at every access (never cached), so a user switch reads the other
	// realm's sets immediately and A→B→A restores A's state without any explicit reset.

	private var realm: String { userContext().userID ?? "anon" }

	/// The identity the persistence realm currently resolves to. ``MessageReplyCoordinator``
	/// captures this before an async write and skips outbox removal when it changed mid-flight —
	/// otherwise a user switch during the write would clear entries from the *new* account's realm.
	func currentUserID() -> String? { userContext().userID }

	private func key(_ suffix: String) -> String { "appMessages.\(realm).\(suffix)" }

	/// Ids of informational messages the user has dismissed, in the current realm.
	func seenMessageIDs() -> Set<String> {
		Set(defaults.stringArray(forKey: key("seenIDs")) ?? [])
	}

	/// Ids the user has replied to on THIS device, in the current realm.
	func locallyRepliedMessageIDs() -> Set<String> {
		Set(defaults.stringArray(forKey: key("locallyRepliedIDs")) ?? [])
	}

	/// The revision a local notification was last scheduled for, per message id, in the current realm.
	/// A bumped `revision` (or a missing id) re-notifies; persisted so that survives relaunch (S7).
	func notifiedRevisions() -> [String: Int] {
		guard let data = defaults.data(forKey: key("notifiedRevisions")),
			  let revisions = try? JSONDecoder().decode([String: Int].self, from: data) else {
			return [:]
		}
		return revisions
	}

	/// Persists the notified-revision map for the current realm.
	func setNotifiedRevisions(_ revisions: [String: Int]) {
		if let data = try? JSONEncoder().encode(revisions) {
			defaults.set(data, forKey: key("notifiedRevisions"))
		}
	}

	/// The persisted, not-yet-delivered reply outbox for the current realm.
	func pendingOutbox() -> [OutboxEntry] {
		guard let data = defaults.data(forKey: key("outbox")),
			  let entries = try? JSONDecoder().decode([OutboxEntry].self, from: data) else {
			return []
		}
		return entries
	}

	/// The authoritative replied set: local ∪ server (server consulted only while signed in, which is
	/// the only state in which interactive messages are eligible anyway).
	private func repliedMessageIDs() -> Set<String> {
		var replied = locallyRepliedMessageIDs()
		if userContext().isSignedIn {
			replied.formUnion(serverRepliedIDs())
		}
		return replied
	}

	private func markSeen(_ id: String) {
		appendCapped(id, to: "seenIDs")
	}

	private func markRepliedLocally(_ id: String) {
		appendCapped(id, to: "locallyRepliedIDs")
	}

	/// Appends `id` to a persisted id list, newest last, keeping at most ``maxPersistedIDs``.
	///
	/// Reads go through `Set`, so order is only ever an eviction policy: dropping the front drops
	/// the marks made longest ago. That bounds a device that accumulates campaigns for years. An
	/// evicted id can only resurface if that message is *still live* in the payload after
	/// `maxPersistedIDs` later marks — at which point re-showing it once is the benign outcome.
	private func appendCapped(_ id: String, to suffix: String) {
		var ids = defaults.stringArray(forKey: key(suffix)) ?? []
		guard !ids.contains(id) else { return }
		ids.append(id)
		if ids.count > Self.maxPersistedIDs {
			ids = Array(ids.suffix(Self.maxPersistedIDs))
		}
		defaults.set(ids, forKey: key(suffix))
	}

	private func appendOutbox(_ entry: OutboxEntry) {
		var entries = pendingOutbox()
		entries.append(entry)
		if let data = try? JSONEncoder().encode(entries) {
			defaults.set(data, forKey: key("outbox"))
		}
	}

	/// Removes delivered (or already-server-side) entries after a successful drain. Realm-scoped
	/// like every other accessor, so a user switch mid-flight cannot cross-clear the other realm.
	func removeFromOutbox(messageIDs: Set<String>) {
		guard !messageIDs.isEmpty else { return }
		let remaining = pendingOutbox().filter { !messageIDs.contains($0.messageID) }
		if let data = try? JSONEncoder().encode(remaining) {
			defaults.set(data, forKey: key("outbox"))
		}
	}
}
