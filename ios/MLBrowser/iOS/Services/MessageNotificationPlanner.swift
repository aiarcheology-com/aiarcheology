//
//  MessageNotificationPlanner.swift
//  AI Archeology
//
//  Pure local-notification scheduling plan for remote in-app messages (AIA-0115, S7).
//  SDK-free and not @MainActor (Harmonize services rule): every schedule/cancel/re-notify decision
//  is unit-testable in isolation, mirroring MessageReplyPatchBuilder — the real UNUserNotification
//  wiring lives behind the thin scheduling adapter.
//

import Foundation

/// Computes what local notifications to schedule, cancel, and clear for the current set of
/// notify-worthy messages.
///
/// The caller feeds in the already-gated `desired` set (``MessageCenterState/notifiableMessages()``:
/// notify == true, version-matched, seen/replied/sign-in gates applied, expired excluded). This
/// planner then applies the notification-specific rules:
///
/// - **Schedule** a message only when it is not expired at `now` and its `revision` differs from the
///   one already notified (a fresh message never-notified, or an edited message whose revision
///   bumped). fireDate is `max(now, activeFrom ?? now)` so a future `activeFrom` schedules ahead.
/// - **Cap** the schedule at ``scheduleCap`` (far under iOS's 64-pending limit) using a deterministic
///   priority — activeFrom ascending (nil == now), ties by id — and report the overflow ids in
///   ``Plan/droppedByCap`` so the caller can log them (this type logs nothing).
/// - **Cancel / clear** any pending or delivered notification whose message is no longer in the
///   effective desired set (retracted, expired, replied, seen, signed-out, flag off).
enum MessageNotificationPlanner {

	/// Notification identifier namespace. The message id is appended verbatim, so the pending/
	/// delivered filters and the tap handler can recover it with ``messageID(fromNotificationID:)``.
	static let identifierPrefix = "com.aiarcheology.message."

	/// Hard cap on messages scheduled in one pass. Well under iOS's 64-pending-notification limit,
	/// which the app shares with any other feature that schedules notifications.
	static let scheduleCap = 16

	/// A single message to (re)schedule, with the resolved fire instant.
	struct Scheduled: Equatable {
		let message: AppMessage
		let fireDate: Date
	}

	/// The computed notification plan. All fields empty == nothing to do.
	struct Plan: Equatable {
		/// Messages to (re)schedule, in deterministic priority order (already capped).
		var schedule: [Scheduled] = []
		/// Pending notification ids to remove (message no longer desired, or evicted by the cap).
		var cancelPending: Set<String> = []
		/// Delivered (Notification Center) ids to remove (message no longer desired).
		var removeDelivered: Set<String> = []
		/// The revision recorded as notified for each message scheduled this pass.
		var recordNotified: [String: Int] = [:]
		/// Notified-state entries to forget: still-eligible messages evicted by the cap. Without
		/// this, an evicted message re-entering the cap at an unchanged revision would look
		/// already-notified and never reschedule.
		var forgetNotified: Set<String> = []
		/// Ids dropped because the total kept set hit ``scheduleCap`` — reported for the caller to log.
		var droppedByCap: [String] = []
	}

	/// The notification identifier for a message id.
	static func notificationID(for messageID: String) -> String {
		identifierPrefix + messageID
	}

	/// The message id encoded in a notification identifier, or `nil` when the identifier is foreign
	/// (belongs to some other notification the app may schedule in future).
	static func messageID(fromNotificationID identifier: String) -> String? {
		guard identifier.hasPrefix(identifierPrefix) else { return nil }
		return String(identifier.dropFirst(identifierPrefix.count))
	}

	/// - Parameters:
	///   - desired: notify-worthy messages, already gated by the caller.
	///   - notifiedState: message id → revision already scheduled a notification for.
	///   - pending: message-notification ids currently pending in iOS.
	///   - delivered: message-notification ids currently in Notification Center.
	///   - now: the reference instant (injected; never read the clock here).
	static func plan(
		desired: [AppMessage],
		notifiedState: [String: Int],
		pending: Set<String>,
		delivered: Set<String>,
		now: Date
	) -> Plan {
		// Effective desired: defensively re-apply the notification-specific gates the caller is
		// expected to have applied (notify, expiry). A message that fails these is treated as
		// retracted for cancel/clear purposes below.
		let eligible = desired.filter { message in
			guard message.notify else { return false }
			if let expiry = message.expiresAt, now >= expiry { return false }
			return true
		}
		let eligibleIDs = Set(eligible.map(\.id))

		// Deterministic priority over the WHOLE eligible set: activeFrom ascending (nil == now),
		// ties by id. The cap bounds the total kept set — new candidates plus already-pending
		// requests together — never just this pass's additions, so pending can't accumulate past
		// the cap across successive publishes.
		let prioritized = eligible.sorted { lhs, rhs in
			let lhsFrom = lhs.activeFrom ?? now
			let rhsFrom = rhs.activeFrom ?? now
			if lhsFrom != rhsFrom { return lhsFrom < rhsFrom }
			return lhs.id < rhs.id
		}
		let kept = prioritized.prefix(scheduleCap)
		let keptIDs = Set(kept.map(\.id))

		var plan = Plan()
		// (Re)schedule kept messages with a bumped/unseen revision; an already-notified message at
		// the same revision stays scheduled and is not re-added.
		for message in kept where notifiedState[message.id] != message.revision {
			let fireDate = max(now, message.activeFrom ?? now)
			plan.schedule.append(Scheduled(message: message, fireDate: fireDate))
			plan.recordNotified[message.id] = message.revision
		}
		plan.droppedByCap = prioritized.dropFirst(scheduleCap).map(\.id)
		// A still-eligible message evicted by the cap must forget its notified revision, so that
		// re-entering the cap later (older campaigns ending) reschedules it.
		plan.forgetNotified = Set(plan.droppedByCap.filter { notifiedState[$0] != nil })

		// Cancel any pending request whose message is no longer KEPT — retraction, expiry, and cap
		// eviction all clean the pending schedule, keeping total pending ≤ the cap.
		plan.cancelPending = pending.filter { identifier in
			guard let id = messageID(fromNotificationID: identifier) else { return false }
			return !keptIDs.contains(id)
		}
		// Delivered cleanup stays eligibility-based: a delivered notification is only yanked from
		// Notification Center when its message is truly gone, not when it merely lost a cap slot.
		plan.removeDelivered = delivered.filter { identifier in
			guard let id = messageID(fromNotificationID: identifier) else { return false }
			return !eligibleIDs.contains(id)
		}

		return plan
	}
}
