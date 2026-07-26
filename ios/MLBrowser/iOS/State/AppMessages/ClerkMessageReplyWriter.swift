//
//  ClerkMessageReplyWriter.swift
//  AI Archeology
//
//  The thin Clerk adapter for message-reply storage (AIA-0115).
//

import Foundation
import ClerkKit

/// Reads and writes `unsafeMetadata.messageReplies` on the signed-in Clerk user.
///
/// Kept deliberately thin: all retention/duplicate logic lives in ``MessageReplyPatchBuilder``;
/// this type only maps between the pure ``MessageReply`` values and Clerk's `JSON`, using
/// `updateMetadata` — a server-side deep merge-patch, so sibling metadata and unnamed reply
/// entries survive every write, and `JSON.null` removes exactly the named key.
///
/// `unsafeMetadata` is user-writable by definition; replies gate nothing (AGENTS §10 stays
/// intact — the ids and choices written here contain no content beyond the operator's own
/// campaign vocabulary).
@MainActor
final class ClerkMessageReplyWriter: MessageReplyWriting {

	/// Thrown when the write races a sign-out. Reporting success here would let the coordinator
	/// clear outbox entries that were never delivered — silent data loss.
	struct NoSignedInUser: Error {}

	private static let metadataKey = "messageReplies"

	/// ISO 8601 with fractional seconds — matches the ticket's documented reply schema.
	private static let isoFormatter: ISO8601DateFormatter = {
		let formatter = ISO8601DateFormatter()
		formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		return formatter
	}()

	func serverReplies() -> [String: MessageReply] {
		guard let map = Clerk.shared.user?.unsafeMetadata?[Self.metadataKey]?.objectValue else {
			return [:]
		}
		var replies: [String: MessageReply] = [:]
		for (id, value) in map {
			// Tolerant parse: entries that don't match the schema are omitted, which the builder
			// treats as untouchable — they are never counted, rewritten, or tombstoned.
			guard let object = value.objectValue,
				  let choice = object["choice"]?.stringValue,
				  let atString = object["at"]?.stringValue,
				  let at = Self.parseDate(atString) else {
				continue
			}
			replies[id] = MessageReply(
				choice: choice,
				at: at,
				appVersion: object["appVersion"]?.stringValue ?? ""
			)
		}
		return replies
	}

	func write(_ patch: MessageReplyPatchBuilder.Patch) async throws {
		guard let user = Clerk.shared.user else { throw NoSignedInUser() }
		var entries: [String: JSON] = [:]
		for (id, reply) in patch.upsert {
			entries[id] = .object([
				"choice": .string(reply.choice),
				"at": .string(Self.isoFormatter.string(from: reply.at)),
				"appVersion": .string(reply.appVersion)
			])
		}
		for id in patch.remove {
			entries[id] = .null
		}
		try await user.updateMetadata(unsafeMetadata: .object([Self.metadataKey: .object(entries)]))
	}

	private static func parseDate(_ string: String) -> Date? {
		if let date = isoFormatter.date(from: string) { return date }
		let plain = ISO8601DateFormatter()
		plain.formatOptions = [.withInternetDateTime]
		return plain.date(from: string)
	}
}
