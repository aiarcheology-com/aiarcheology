//
//  MessageReplyCoordinator.swift
//  AI Archeology
//
//  Delivers recorded message replies to the Clerk user record (AIA-0115).
//

import Foundation

/// The write surface for message replies. `@MainActor` because clerk-ios's `User.updateMetadata`
/// is main-actor bound; the *decision* layer (``MessageReplyPatchBuilder``) stays pure and
/// actor-free behind this seam, which is also where tests fake the server.
@MainActor
protocol MessageReplyWriting {
	/// The parseable subset of the server-side `messageReplies` map. Malformed or foreign
	/// entries are omitted here — the builder then leaves them untouched by construction.
	func serverReplies() -> [String: MessageReply]

	/// Applies the patch via Clerk's metadata merge-patch. Throws on any transport failure;
	/// the coordinator leaves the outbox intact and retries on the next occasion.
	func write(_ patch: MessageReplyPatchBuilder.Patch) async throws
}

/// The test/preview stand-in (like ``StaticFeatureFlagProvider``): an empty server, writes
/// succeed as no-ops. UI tests thus exercise the full reply flow deterministically — the outbox
/// drains and clears — without a configured Clerk instance (touching `Clerk.shared` there traps).
@MainActor
final class NoOpMessageReplyWriter: MessageReplyWriting {
	func serverReplies() -> [String: MessageReply] { [:] }
	func write(_ patch: MessageReplyPatchBuilder.Patch) async throws {}
}

/// Drains ``MessageCenterState``'s reply outbox to Clerk: immediately on every recorded reply,
/// and again on each app foreground (the retry path for offline/failed writes). Coalesces —
/// a drain that lands while one is in flight marks a re-run instead of racing it.
///
/// Deliberately not an `ObservableObject`: nothing observes delivery; the UI's source of truth
/// for "replied" is ``MessageCenterState``'s local mark, which is set before this runs.
@MainActor
final class MessageReplyCoordinator {

	private let messageCenter: MessageCenterState
	private let writer: MessageReplyWriting
	private let isSignedIn: @MainActor () -> Bool
	private let appVersion: String

	private var isDraining = false
	private var rerunRequested = false

	/// The drain kicked by the most recent ``drainSoon()``, retained so a test can await the exact
	/// completion. Polling a yield budget cannot distinguish "the drain ran and declined to write"
	/// from "the drain has not started yet", which makes a negative assertion pass vacuously.
	/// A coalesced re-run replaces this, so awaiting it covers only the drain it was read for.
	private(set) var drainTask: Task<Void, Never>?

	init(
		messageCenter: MessageCenterState,
		writer: MessageReplyWriting,
		isSignedIn: @escaping @MainActor () -> Bool,
		appVersion: String = AppEnvironment.shortVersion ?? "0"
	) {
		self.messageCenter = messageCenter
		self.writer = writer
		self.isSignedIn = isSignedIn
		self.appVersion = appVersion

		messageCenter.onReplyRecorded = { [weak self] _, _ in self?.drainSoon() }
		messageCenter.addForegroundSyncObserver { [weak self] in self?.drainSoon() }
	}

	/// Kicks an asynchronous drain, coalescing with one already in flight.
	func drainSoon() {
		if isDraining {
			rerunRequested = true
			return
		}
		drainTask = Task { await drain() }
	}

	private func drain() async {
		guard !isDraining else { return }
		isDraining = true
		defer {
			isDraining = false
			if rerunRequested {
				rerunRequested = false
				drainSoon()
			}
		}

		// Replies attach to the signed-in user's record; signed out, the outbox just waits.
		guard isSignedIn() else { return }
		let outbox = messageCenter.pendingOutbox()
		guard !outbox.isEmpty else { return }

		let plan = MessageReplyPatchBuilder.plan(
			outbox: outbox,
			serverReplies: writer.serverReplies(),
			appVersion: appVersion
		)
		// The realm is resolved at access time inside MessageCenterState, so a user switch during
		// the await below would otherwise aim the removal at the *new* account's outbox.
		let deliveringUserID = messageCenter.currentUserID()
		do {
			if !plan.patch.isEmpty {
				try await writer.write(plan.patch)
			}
			if messageCenter.currentUserID() == deliveringUserID {
				messageCenter.removeFromOutbox(messageIDs: plan.settledOutboxIDs)
			}
			LoggingPolicy.debug(
				"App messages: delivered \(plan.patch.upsert.count) replies, settled \(plan.settledOutboxIDs.count) outbox entries",
				logger: .state
			)
			// A mismatch self-heals: the delivering account's outbox keeps its entries, and the
			// duplicate guard settles them without a rewrite on that account's next drain.
		} catch {
			// Outbox intact → the next reply or foreground retries. Never surfaces to the user:
			// their reply is already recorded locally and the message stays answered on-device.
			LoggingPolicy.warning(
				"Message-reply delivery failed; will retry on next foreground. \(error.localizedDescription)",
				logger: .state
			)
		}
	}
}
