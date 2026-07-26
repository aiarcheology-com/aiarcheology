//
//  MessageReplyPatchBuilder.swift
//  AI Archeology
//
//  Pure merge-patch computation for message replies stored on the Clerk user (AIA-0115).
//  SDK-free and not @MainActor (Harmonize services rule): the Clerk `JSON` mapping lives in
//  the thin writer, so every retention/duplicate decision here is unit-testable in isolation.
//

import Foundation

/// One reply as stored under `unsafeMetadata.messageReplies.<messageID>` on the Clerk user:
/// `{ "choice": "yes", "at": "2026-07-23T09:12:00Z", "appVersion": "1.0.7" }`.
struct MessageReply: Equatable {
	let choice: String
	let at: Date
	let appVersion: String
}

/// Computes the minimal merge-patch to deliver locally-recorded replies to the server-side
/// `messageReplies` map.
///
/// Semantics (grill-agreed, G1-approved):
/// - **Duplicate guard:** an outbox entry whose id already exists server-side is *not* rewritten —
///   the first reply wins across devices (last-writer-wins only applies to genuinely concurrent
///   first writes, which the merge-patch resolves server-side).
/// - **Retention:** the merged map is capped at the **newest** `retentionLimit` entries by reply
///   time; overflow becomes explicit `nil` tombstones (the writer maps them to `JSON.null`, which
///   Clerk's merge-patch treats as key removal). Replies are never pruned by message expiry or
///   retraction — campaign end is exactly when the operator reads them.
/// - **Foreign entries are untouched:** only keys this patch names are affected. Server entries
///   that fail to parse are excluded from the retention count and never tombstoned — a malformed
///   map degrades to append-only rather than destructive.
enum MessageReplyPatchBuilder {

	/// Newest-N retention cap. ~80 bytes/entry keeps the worst case ≈ 1.6 KB, inside Clerk's
	/// single-digit-KB combined-metadata budget with headroom.
	static let retentionLimit = 20

	/// The computed write: entries to upsert, ids to remove. Empty == nothing to write.
	struct Patch: Equatable {
		var upsert: [String: MessageReply] = [:]
		var remove: Set<String> = []
		var isEmpty: Bool { upsert.isEmpty && remove.isEmpty }
	}

	/// Outbox ids that no longer need delivery (already server-side), reported separately so the
	/// caller can clear them from the outbox even when the patch itself is empty.
	struct Plan: Equatable {
		let patch: Patch
		/// Every outbox id this plan accounts for — delivered by the patch *or* already
		/// server-side. On a successful write the caller removes exactly these from the outbox.
		let settledOutboxIDs: Set<String>
	}

	/// - Parameters:
	///   - outbox: locally-recorded replies awaiting delivery, oldest first.
	///   - serverReplies: the parseable subset of the server-side map.
	///   - retentionLimit: overridable for tests only.
	static func plan(
		outbox: [MessageCenterState.OutboxEntry],
		serverReplies: [String: MessageReply],
		appVersion: String,
		retentionLimit: Int = MessageReplyPatchBuilder.retentionLimit
	) -> Plan {
		var settled: Set<String> = []
		var newEntries: [String: MessageReply] = [:]

		for entry in outbox {
			guard serverReplies[entry.messageID] == nil else {
				settled.insert(entry.messageID) // duplicate guard: first reply wins
				continue
			}
			// Several outbox entries for one id (possible after an interrupted drain): newest wins.
			if let existing = newEntries[entry.messageID], existing.at >= entry.timestamp {
				continue
			}
			newEntries[entry.messageID] = MessageReply(
				choice: entry.buttonID,
				at: entry.timestamp,
				appVersion: entry.appVersion ?? appVersion
			)
		}
		settled.formUnion(newEntries.keys)

		var merged = serverReplies.merging(newEntries) { _, new in new }
		var remove: Set<String> = []
		if merged.count > retentionLimit {
			// Oldest beyond the cap are tombstoned; ties broken by id so the cut is deterministic.
			let overflow = merged
				.sorted { lhs, rhs in
					if lhs.value.at != rhs.value.at { return lhs.value.at < rhs.value.at }
					return lhs.key < rhs.key
				}
				.prefix(merged.count - retentionLimit)
			for (key, _) in overflow {
				// Tombstone only keys that exist server-side; a new entry beyond the cap is
				// simply not written (a null for a key the server never held is noise).
				if serverReplies[key] != nil { remove.insert(key) }
				merged.removeValue(forKey: key)
				newEntries.removeValue(forKey: key)
			}
		}

		return Plan(patch: Patch(upsert: newEntries, remove: remove), settledOutboxIDs: settled)
	}
}
