//
//  SupportLogMetadata.swift
//  SupportLogFormat
//
//  The sealed triage header carried inside a `.aialog` payload (AIA-0643).
//

import Foundation

/// What a sealed log says about itself, carried as the payload's first line.
///
/// A **fixed set of named fields, never an open dictionary.** A `[String: String]` would be an
/// unbounded surface on the exact type whose job is to bound what leaves the device, and the first
/// person to put a page URL in it would defeat the ticket. This mirrors the named-field allowlist
/// discipline `SupportRequest` and `DeviceInfo.information()` already use.
///
/// Sealed, not cleartext: ``redacted`` states which choice the user made, and in the clear that
/// would announce it to anyone who sees the file.
public struct SupportLogMetadata: Codable, Equatable, Sendable {
	/// Marketing version, e.g. `1.0.7`.
	public let app: String
	/// Build number.
	public let build: String
	/// When the export was produced, ISO 8601 with a `Z` offset. A string rather than a `Date` so
	/// no `JSONEncoder.dateEncodingStrategy` sits between the two ends of the format.
	public let date: String
	/// `true` when `LogRedactor` ran over the payload — i.e. the user did **not** ask for raw data.
	public let redacted: Bool

	public init(app: String, build: String, date: String, redacted: Bool) {
		self.app = app
		self.build = build
		self.date = date
		self.redacted = redacted
	}

	/// The one timestamp format, so both ends agree without a shared strategy setting.
	public static func timestamp(for instant: Date) -> String {
		let formatter = ISO8601DateFormatter()
		formatter.formatOptions = [.withInternetDateTime]
		formatter.timeZone = TimeZone(secondsFromGMT: 0)
		return formatter.string(from: instant)
	}

	/// Encodes to a single line containing no newline byte.
	///
	/// The newline check is not paranoia about the current encoder — it is a guard against
	/// `.prettyPrinted` being added later, which is one autocomplete away and would silently turn
	/// the envelope's positional split into a truncation that drops most of the metadata and
	/// prepends the rest to the log.
	func encodedLine() throws -> Data {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys]
		let encoded = try encoder.encode(self)
		guard encoded.contains(0x0A) == false else {
			throw SupportLogEnvelope.FormatError.metadataContainsNewline
		}
		return encoded
	}

	init(encodedLine: Data) throws {
		do {
			self = try JSONDecoder().decode(SupportLogMetadata.self, from: encodedLine)
		} catch {
			throw SupportLogEnvelope.FormatError.malformedMetadata
		}
	}
}
