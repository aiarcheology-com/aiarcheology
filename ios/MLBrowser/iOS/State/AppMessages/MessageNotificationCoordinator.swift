//
//  MessageNotificationCoordinator.swift
//  AI Archeology
//
//  Keeps scheduled local notifications in step with the notify-worthy message set (AIA-0115, S7).
//

import Foundation

/// Drives local message notifications: on every visibility recompute it re-derives the notify-worthy
/// set, runs ``MessageNotificationPlanner``, and applies the result through the scheduling seam —
/// scheduling new/edited messages, cancelling pending notifications for retracted ones, and clearing
/// Notification Center. The background app-refresh task calls ``sync(allowAuthorizationRequest:)``
/// directly.
///
/// `@MainActor` and deliberately not an `ObservableObject`: nothing renders from it; it is container-
/// owned plumbing like ``MessageReplyCoordinator`` and ``TargetingCoordinator``.
@MainActor
final class MessageNotificationCoordinator {

	private let messageCenter: MessageCenterState
	private let scheduler: UserNotificationScheduling
	private let languageCode: String
	private let now: () -> Date

	/// Serializes syncs so two recomputes in quick succession (e.g. a targeting retarget that
	/// re-evaluates then republishes) never race the scheduler.
	private var syncTask: Task<Void, Never>?

	init(
		messageCenter: MessageCenterState,
		scheduler: UserNotificationScheduling,
		languageCode: String = AppMessage.deviceLanguageCode,
		now: @escaping () -> Date = { Date() }
	) {
		self.messageCenter = messageCenter
		self.scheduler = scheduler
		self.languageCode = languageCode
		self.now = now

		// Every visibility recompute (snapshot change, boundary timer, foreground, dismiss/reply,
		// targeting retarget) is followed by a notification sync. The foreground path also runs
		// through reevaluate, so this one hook covers it.
		messageCenter.addReevaluationObserver { [weak self] in self?.syncSoon() }
	}

	deinit {
		// `syncTask` is Sendable, so the nonisolated deinit may cancel it (mirrors MessageCenterState).
		syncTask?.cancel()
	}

	/// Kicks a serialized sync from a main-actor app context (the reevaluation observer). Chains
	/// after any in-flight sync rather than racing it.
	func syncSoon(allowAuthorizationRequest: Bool = true) {
		let previous = syncTask
		syncTask = Task { [weak self] in
			await previous?.value
			await self?.performSync(allowAuthorizationRequest: allowAuthorizationRequest)
		}
	}

	/// Awaitable entry point (the background refresh). Chains through the same serialization as
	/// ``syncSoon(allowAuthorizationRequest:)`` — no sync may bypass the chain and interleave with
	/// another across the scheduler awaits.
	func sync(allowAuthorizationRequest: Bool = true) async {
		let previous = syncTask
		let task = Task { [weak self] in
			await previous?.value
			await self?.performSync(allowAuthorizationRequest: allowAuthorizationRequest)
		}
		syncTask = task
		await task.value
	}

	/// Reconciles scheduled notifications with the current notify-worthy set.
	///
	/// - Parameter allowAuthorizationRequest: whether this sync may request provisional authorization.
	///   Foreground syncs pass `true` (and only actually request when there is something to notify);
	///   the background refresh path passes `false` so a background wake never triggers an auth
	///   request.
	private func performSync(allowAuthorizationRequest: Bool) async {
		let desired = messageCenter.notifiableMessages()
		// The notified-state realm is resolved at access time; a user switch across the awaits
		// below must not write this sync's plan into the other account's realm.
		let syncingUserID = messageCenter.currentUserID()

		// Ask for authorization only when there is actually something to notify — never at a plain
		// launch with no notify messages.
		if allowAuthorizationRequest, !desired.isEmpty {
			await scheduler.requestProvisionalAuthorizationIfNeeded()
		}

		let pending = await scheduler.pendingMessageNotificationIDs()
		let delivered = await scheduler.deliveredMessageNotificationIDs()
		let notifiedState = messageCenter.notifiedRevisions()

		let plan = MessageNotificationPlanner.plan(
			desired: desired,
			notifiedState: notifiedState,
			pending: pending,
			delivered: delivered,
			now: now()
		)

		if !plan.cancelPending.isEmpty {
			await scheduler.cancelPending(ids: plan.cancelPending)
		}
		if !plan.removeDelivered.isEmpty {
			await scheduler.removeDelivered(ids: plan.removeDelivered)
		}
		// Record a revision as notified only when the system actually accepted the request — a
		// rejected add must retry on the next sync, not vanish silently.
		var accepted: [String: Int] = [:]
		for entry in plan.schedule {
			let ok = await scheduler.schedule(
				id: MessageNotificationPlanner.notificationID(for: entry.message.id),
				title: entry.message.localizedTitle(for: languageCode),
				body: entry.message.localizedBody(for: languageCode),
				fireDate: entry.fireDate
			)
			if ok, let revision = plan.recordNotified[entry.message.id] {
				accepted[entry.message.id] = revision
			}
		}
		if !accepted.isEmpty || !plan.forgetNotified.isEmpty {
			// Guard the realm: if the account changed mid-sync, drop the write — the next sync
			// under the new account recomputes from its own state.
			if messageCenter.currentUserID() == syncingUserID {
				var next = notifiedState.merging(accepted) { _, new in new }
				for id in plan.forgetNotified {
					next.removeValue(forKey: id)
				}
				messageCenter.setNotifiedRevisions(next)
			}
		}
		if !plan.schedule.isEmpty || !plan.cancelPending.isEmpty || !plan.removeDelivered.isEmpty {
			LoggingPolicy.debug(
				"App messages: notification sync — scheduled \(plan.schedule.count), "
					+ "cancelled \(plan.cancelPending.count), removed delivered \(plan.removeDelivered.count)",
				logger: .state
			)
		}
		if !plan.droppedByCap.isEmpty {
			LoggingPolicy.debug(
				"Message notifications dropped by \(MessageNotificationPlanner.scheduleCap)-cap: \(plan.droppedByCap.joined(separator: ", "))",
				logger: .state
			)
		}
	}
}
