//
//  SentryEventSignature.swift
//  AI Archeology
//
//  Builds a stable signature for deduplicating near-identical Sentry events.
//  Intentionally does NOT import Sentry; callers should extract required fields.
//

import Foundation
import CryptoKit

struct SentryEventSignatureInput: Sendable {
	var errorType: String?
	var message: String?
	var topFrames: [String] // already truncated (e.g., top 5)
}

enum SentryEventSignatureBuilder {
	
	/// Returns a stable 16-byte (hex) signature, or nil if the event does not contain
	/// enough information to be meaningfully deduplicated.
	static func signatureHex(from input: SentryEventSignatureInput) -> String? {
		let normalizedMessage = normalizeMessage(input.message)
		
		let normalizedFrames = input.topFrames
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }
		
		let normalizedType = (input.errorType?.trimmingCharacters(in: .whitespacesAndNewlines)).nilIfEmpty
		
		guard normalizedType != nil || normalizedMessage != nil || !normalizedFrames.isEmpty else {
			return nil
		}
		
		var parts: [String] = []
		if let normalizedType { parts.append("t:\(normalizedType)") }
		if let normalizedMessage { parts.append("m:\(normalizedMessage)") }
		if !normalizedFrames.isEmpty { parts.append("f:" + normalizedFrames.joined(separator: "|")) }
		
		let canonical = parts.joined(separator: "\n")
		let digest = SHA256.hash(data: Data(canonical.utf8))
		
		// Truncate to 16 bytes for compactness.
		let truncated = digest.prefix(16)
		return truncated.map { String(format: "%02x", $0) }.joined()
	}
	
	// MARK: - Redaction / Normalization
	
	private static func normalizeMessage(_ message: String?) -> String? {
		guard var s = message?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
			return nil
		}
		
		// UUIDs
		s = s.replacingOccurrences(
			of: #"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#,
			with: "<uuid>",
			options: .regularExpression
		)
		
		// ISO-8601-ish timestamps (e.g. 2025-12-22T10:11:12Z, with optional millis/offset)
		s = s.replacingOccurrences(
			of: #"\b\d{4}-\d{2}-\d{2}[T\s]\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})?\b"#,
			with: "<ts>",
			options: .regularExpression
		)
		
		// Unix epoch seconds/millis (10-13 digits)
		s = s.replacingOccurrences(
			of: #"\b\d{10,13}\b"#,
			with: "<epoch>",
			options: .regularExpression
		)
		
		// Long hex (likely IDs / hashes / addresses). Keep small hex tokens intact.
		s = s.replacingOccurrences(
			of: #"(?i)\b0x[0-9a-f]{8,}\b"#,
			with: "0x<hex>",
			options: .regularExpression
		)
		s = s.replacingOccurrences(
			of: #"(?i)\b[0-9a-f]{16,}\b"#,
			with: "<hex>",
			options: .regularExpression
		)
		
		// Collapse whitespace
		s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
		
		// Limit size to avoid hashing huge payloads.
		if s.count > 500 {
			s = String(s.prefix(500))
		}
		
		return s
	}
}

private extension Optional where Wrapped == String {
	var nilIfEmpty: String? {
		guard let self, !self.isEmpty else { return nil }
		return self
	}
}


