//
//  UserNotificationScheduling.swift
//  AI Archeology
//
//  The scheduling seam for local message notifications (AIA-0115, S7). The pure decision layer
//  (MessageNotificationPlanner) computes what to do; this thin adapter performs it against
//  UNUserNotificationCenter. Sendable and NOT @MainActor (Harmonize services rule) — the center
//  APIs are thread-safe, and keeping this off the main actor lets the coordinator await it.
//

import Foundation
import UserNotifications

/// The notification operations the coordinator needs. A protocol so tests and previews swap in
/// ``NoOpUserNotificationScheduler`` instead of touching the real UNUserNotificationCenter.
protocol UserNotificationScheduling: Sendable {
	/// Requests provisional notification authorization, at most once per process and only while the
	/// status is still undetermined. Provisional auth is delivered quietly, so this never prompts.
	func requestProvisionalAuthorizationIfNeeded() async
	/// Pending (not-yet-fired) message-notification ids, filtered to this feature's namespace.
	func pendingMessageNotificationIDs() async -> Set<String>
	/// Delivered (in Notification Center) message-notification ids, filtered to this feature's namespace.
	func deliveredMessageNotificationIDs() async -> Set<String>
	/// Schedules (or replaces) a notification with the given identifier to fire at `fireDate`.
	/// Returns whether the system accepted the request — the caller records the notified revision
	/// only on success, so a rejected add is retried on the next sync instead of silently lost.
	func schedule(id: String, title: String, body: String, fireDate: Date) async -> Bool
	/// Removes pending notifications by identifier.
	func cancelPending(ids: Set<String>) async
	/// Removes delivered notifications by identifier.
	func removeDelivered(ids: Set<String>) async
}

/// The real adapter over `UNUserNotificationCenter`. An `actor` (not @MainActor) so the once-per-
/// process authorization guard is race-free without a lock, and heavy center calls stay off the
/// main actor.
actor UNUserNotificationCenterScheduler: UserNotificationScheduling {

	private let center: UNUserNotificationCenter
	/// Guards the authorization request to at most once per process (see protocol contract).
	private var hasRequestedAuthorization = false

	init(center: UNUserNotificationCenter = .current()) {
		self.center = center
	}

	func requestProvisionalAuthorizationIfNeeded() async {
		guard !hasRequestedAuthorization else { return }
		hasRequestedAuthorization = true
		let settings = await center.notificationSettings()
		// Only request while undetermined — never re-prompt a user who already decided.
		guard settings.authorizationStatus == .notDetermined else { return }
		_ = try? await center.requestAuthorization(options: [.alert, .sound, .badge, .provisional])
	}

	func pendingMessageNotificationIDs() async -> Set<String> {
		let requests = await center.pendingNotificationRequests()
		return Self.messageIDs(from: requests.map(\.identifier))
	}

	func deliveredMessageNotificationIDs() async -> Set<String> {
		let delivered = await center.deliveredNotifications()
		return Self.messageIDs(from: delivered.map(\.request.identifier))
	}

	func schedule(id: String, title: String, body: String, fireDate: Date) async -> Bool {
		let content = UNMutableNotificationContent()
		content.title = title
		content.body = body
		content.sound = .default
		// Non-repeating time-interval trigger; must be strictly positive, so clamp to ≥1s for a
		// message whose fireDate is already due.
		let interval = max(1, fireDate.timeIntervalSinceNow)
		let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
		let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
		do {
			// A same-identifier add replaces the existing request, so re-scheduling is idempotent.
			try await center.add(request)
			return true
		} catch {
			LoggingPolicy.warning(
				"Message notification add rejected for \(id): \(error.localizedDescription)",
				logger: .state
			)
			return false
		}
	}

	func cancelPending(ids: Set<String>) async {
		center.removePendingNotificationRequests(withIdentifiers: Array(ids))
	}

	func removeDelivered(ids: Set<String>) async {
		center.removeDeliveredNotifications(withIdentifiers: Array(ids))
	}

	/// Keeps only identifiers in this feature's namespace, so we never touch notifications another
	/// part of the app scheduled.
	private static func messageIDs(from identifiers: [String]) -> Set<String> {
		Set(identifiers.filter { MessageNotificationPlanner.messageID(fromNotificationID: $0) != nil })
	}
}

/// Records calls in memory instead of touching UNUserNotificationCenter — used by tests (which
/// assert the recorded calls) and previews. An `actor` for the same reason the real adapter is one.
actor NoOpUserNotificationScheduler: UserNotificationScheduling {

	private(set) var authorizationRequestCount = 0
	private(set) var scheduledIDs: [String] = []
	private(set) var scheduled: [(id: String, title: String, body: String, fireDate: Date)] = []
	private(set) var cancelledPending: Set<String> = []
	private(set) var removedDelivered: Set<String> = []
	private var pending: Set<String> = []
	private var delivered: Set<String> = []

	/// Seed the pending/delivered sets a sync will read (test setup).
	func seed(pending: Set<String> = [], delivered: Set<String> = []) {
		self.pending = pending
		self.delivered = delivered
	}

	func requestProvisionalAuthorizationIfNeeded() async {
		authorizationRequestCount += 1
	}

	func pendingMessageNotificationIDs() async -> Set<String> { pending }
	func deliveredMessageNotificationIDs() async -> Set<String> { delivered }

	/// Set to make the next N schedule calls report rejection (test setup).
	private var failNextSchedules = 0

	func failSchedules(_ count: Int) {
		failNextSchedules = count
	}

	func schedule(id: String, title: String, body: String, fireDate: Date) async -> Bool {
		if failNextSchedules > 0 {
			failNextSchedules -= 1
			return false
		}
		scheduledIDs.append(id)
		scheduled.append((id: id, title: title, body: body, fireDate: fireDate))
		pending.insert(id)
		return true
	}

	func cancelPending(ids: Set<String>) async {
		cancelledPending.formUnion(ids)
		pending.subtract(ids)
	}

	func removeDelivered(ids: Set<String>) async {
		removedDelivered.formUnion(ids)
		delivered.subtract(ids)
	}
}
