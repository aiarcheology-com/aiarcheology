//
//  AppMessage.swift
//  AI Archeology
//
//  Remote in-app messaging payload model + tolerant decode (AIA-0115).
//  Pure value types: Sendable, no UI, no @MainActor — safe to decode off the main actor.
//

import Foundation
import OSLog

/// A single remotely-delivered message that the app can surface on one or more UI surfaces
/// (login, paywall, in-app, about).
///
/// **Payload schema** (JSON array of message objects; unknown keys ignored):
/// ```json
/// [{
///   "id": "welcome",                     // required, ≤100 chars, unique (first wins)
///   "title": "Hello",                    // required, ≤200 chars
///   "body": "Body text",                 // required, ≤4000 chars
///                                        // every char cap is also a byte cap of 4× that count
///   "surfaces": ["login", "inApp"],      // required; login/paywall/inApp/aboutApp/settings — unknown values dropped, empty ⇒ message dropped
///   "localized": {                        // optional per-language title/body overrides —
///     "cs": { "title": "Ahoj", "body": "…" }   // same caps as the fields they replace
///   },
///   "style": "info",                     // optional: "info" | "warning" | "success" tints the card; unknown ⇒ default look
///   "notify": true,                       // optional, default false
///   "activeFrom": "2026-01-01T00:00:00Z", // optional ISO 8601 (fractional seconds optional)
///   "expiresAt": "2026-02-01T00:00:00Z",  // optional ISO 8601; nil ⇒ never expires
///   "minAppVersion": "1.2.0",            // optional dotted-numeric lower bound (inclusive)
///   "maxAppVersion": "2.0.0",            // optional dotted-numeric upper bound (inclusive)
///   "buttons": [{ "id": "ok", "label": "OK" }], // optional, ≤8, label ≤60 chars
///   "url": "https://…",                  // optional
///   "revision": 3                         // optional, default 0
/// }]
/// ```
///
/// Decoding is **tolerant and element-wise**: see ``decodeMessages(from:)``. A malformed message
/// is dropped without affecting its siblings; the whole predicate/localization surface is pure and
/// takes `now` / `appVersion` / `languageCode` as inputs so behaviour is fully testable.
struct AppMessage: Equatable, Sendable {
	/// Per-language override for the top-level `title`/`body`. Either field may be absent.
	struct LocalizedContent: Equatable, Sendable {
		var title: String?
		var body: String?
	}

	/// A tappable action attached to a message.
	struct MessageButton: Equatable, Sendable {
		var id: String
		var label: String
	}

	var id: String
	var title: String
	var body: String
	var localized: [String: LocalizedContent]
	var surfaces: Set<MessageSurface>
	/// Raw style token as published; surfaces consume it via ``messageStyle`` (unknown ⇒ `nil`).
	var style: String?
	var notify: Bool
	var activeFrom: Date?
	var expiresAt: Date?
	var minAppVersion: String?
	var maxAppVersion: String?
	var buttons: [MessageButton]
	var url: String?
	var revision: Int

	init(
		id: String,
		title: String,
		body: String,
		localized: [String: LocalizedContent] = [:],
		surfaces: Set<MessageSurface>,
		style: String? = nil,
		notify: Bool = false,
		activeFrom: Date? = nil,
		expiresAt: Date? = nil,
		minAppVersion: String? = nil,
		maxAppVersion: String? = nil,
		buttons: [MessageButton] = [],
		url: String? = nil,
		revision: Int = 0
	) {
		self.id = id
		self.title = title
		self.body = body
		self.localized = localized
		self.surfaces = surfaces
		self.style = style
		self.notify = notify
		self.activeFrom = activeFrom
		self.expiresAt = expiresAt
		self.minAppVersion = minAppVersion
		self.maxAppVersion = maxAppVersion
		self.buttons = buttons
		self.url = url
		self.revision = revision
	}

	// MARK: - Predicates (pure; inject `now` / version / language — never read the clock here)

	/// Whether the message is inside its active window at `now`.
	/// `activeFrom == nil` ⇒ already active; `expiresAt == nil` ⇒ never expires. The expiry is
	/// exclusive: at exactly `expiresAt` the message is no longer active.
	func isActive(at now: Date) -> Bool {
		if let from = activeFrom, now < from { return false }
		if let expiry = expiresAt, now >= expiry { return false }
		return true
	}

	/// Whether `version` satisfies both version bounds. Missing bounds pass. A bound with any
	/// non-numeric dotted component is *failed open* (ignored) rather than blocking the message.
	/// Comparison is component-wise numeric, so "1.10" > "1.9" and "1.0.7" < "1.10".
	func matchesVersion(_ version: String) -> Bool {
		if let minV = minAppVersion, let order = Self.compareVersions(version, minV), order < 0 {
			return false
		}
		if let maxV = maxAppVersion, let order = Self.compareVersions(version, maxV), order > 0 {
			return false
		}
		return true
	}

	/// Localized title for `languageCode`, narrowing through
	/// ``localizationCandidates(for:)`` and falling back to the top-level `title`.
	func localizedTitle(for languageCode: String) -> String {
		for key in Self.localizationCandidates(for: languageCode) {
			if let title = localized[key]?.title { return title }
		}
		return title
	}

	/// Localized body for `languageCode`, narrowing through
	/// ``localizationCandidates(for:)`` and falling back to the top-level `body`.
	///
	/// Resolved independently of the title: a partial override translates one field and leaves the
	/// other in the source language.
	func localizedBody(for languageCode: String) -> String {
		for key in Self.localizationCandidates(for: languageCode) {
			if let body = localized[key]?.body { return body }
		}
		return body
	}

	/// The visual accent a message asks for. Tolerant like the rest of the schema: an unknown or
	/// absent `style` yields `nil` (the default card look) rather than dropping the message.
	enum MessageStyle: String, Sendable {
		case info
		case warning
		case success
	}

	/// The typed style token, or `nil` for the default look.
	var messageStyle: MessageStyle? {
		style.flatMap(MessageStyle.init(rawValue:))
	}

	/// Localized body rendered as inline Markdown (links, bold, italic — no block syntax). Parsing
	/// failure falls back to the literal text, so a malformed body degrades, never disappears.
	func attributedBody(for languageCode: String) -> AttributedString {
		let body = localizedBody(for: languageCode)
		let options = AttributedString.MarkdownParsingOptions(
			interpretedSyntax: .inlineOnlyPreservingWhitespace
		)
		return (try? AttributedString(markdown: body, options: options)) ?? AttributedString(body)
	}

	/// True when the message carries at least one button.
	var isInteractive: Bool { !buttons.isEmpty }

	/// The language tag message content localizes to on this device — the single default for every
	/// presentation site (banner, About/Settings rows, notifications).
	///
	/// This is the **most specific** tag the device reports (`zh-Hant-HK`, `pt-BR`, `en-US`), not
	/// the bare language. Lookup narrows it through ``localizationCandidates(for:)``, so a payload
	/// that only carries `"zh"` still matches while one that carries `"zh-Hant"` finally can too.
	///
	/// The script here may be one Foundation *inferred* rather than one the user chose (a device
	/// set to plain Chinese reports `zh-Hans`). That is deliberate at this end: it gives generic
	/// Chinese a sensible Simplified default. It also means a Latin-script device produces a tag
	/// like `cs-Latn`, which simply misses and falls through to `cs`.
	static var deviceLanguageCode: String {
		let language = Locale.current.language
		guard let base = language.languageCode?.identifier else { return "en" }
		var tag = base
		if let script = language.script?.identifier { tag += "-\(script)" }
		if let region = language.region?.identifier { tag += "-\(region)" }
		return tag
	}

	/// `localized` keys to try for a language tag, most specific first.
	///
	/// `zh-Hant-HK` → `["zh-Hant-HK", "zh-HK", "zh-Hant", "zh"]`; `pt-BR` → `["pt-BR", "pt"]`;
	/// a bare `cs` yields only itself, so existing single-code payloads behave exactly as before.
	///
	/// This is RFC 4647 lookup — drop one trailing subtag at a time — plus one addition: when a
	/// script sits between the language and the region, `language-region` is also tried, and tried
	/// *before* the script-generic form. Truncation alone would step from `zh-Hant-HK` straight to
	/// `zh-Hant` and silently skip a `zh-HK` key, which the app's own string catalog ships.
	///
	/// Deliberately parsed from the **written** subtags rather than `Locale.Language`'s components:
	/// Foundation fills in a likely script (`cs` → `cs-Latn`, `zh` → `zh-Hans`), and inventing key
	/// forms nobody writes would make the documented contract a fiction.
	static func localizationCandidates(for tag: String) -> [String] {
		let parts = tag.split(separator: "-").map(String.init)
		guard let base = parts.first else { return [tag] }

		// Longest prefix to shortest: the whole tag, then each shorter one, down to the language.
		var candidates = (1...parts.count).reversed().map { parts[0..<$0].joined(separator: "-") }

		// BCP-47 shapes are unambiguous: a script subtag is 4 letters, a region 2 letters or
		// 3 digits. So a 3-part tag's trailing region can be lifted next to the language.
		if parts.count >= 3, let region = parts.last, isRegionSubtag(region) {
			candidates.insert("\(base)-\(region)", at: 1)
		}

		var seen = Set<String>()
		return candidates.filter { seen.insert($0).inserted }
	}

	private static func isRegionSubtag(_ subtag: String) -> Bool {
		(subtag.count == 2 && subtag.allSatisfy(\.isLetter))
			|| (subtag.count == 3 && subtag.allSatisfy(\.isNumber))
	}

	// MARK: - Version comparison

	/// Component-wise numeric comparison of two dotted versions. Returns `-1`/`0`/`1`, or `nil`
	/// if either side has a non-numeric component (the caller treats `nil` as fail-open).
	private static func compareVersions(_ lhs: String, _ rhs: String) -> Int? {
		guard let lhsParts = numericComponents(lhs), let rhsParts = numericComponents(rhs) else {
			return nil
		}
		let count = max(lhsParts.count, rhsParts.count)
		for index in 0..<count {
			let left = index < lhsParts.count ? lhsParts[index] : 0
			let right = index < rhsParts.count ? rhsParts[index] : 0
			if left != right { return left < right ? -1 : 1 }
		}
		return 0
	}

	/// Splits a dotted version into integer components, or `nil` if any component isn't numeric.
	private static func numericComponents(_ version: String) -> [Int]? {
		var result: [Int] = []
		for part in version.split(separator: ".", omittingEmptySubsequences: false) {
			guard let value = Int(part) else { return nil }
			result.append(value)
		}
		return result
	}
}

/// The UI surfaces a message may target. The raw string is the wire value; unknown wire values are
/// silently dropped from a message's surface set during decode.
enum MessageSurface: String, CaseIterable, Sendable {
	case login
	case paywall
	case inApp
	case aboutApp
	case settings
}

// MARK: - Tolerant decoding

extension AppMessage {

	/// Field-size sanity caps. A message violating any cap is dropped rather than truncated.
	///
	/// Each text field is bounded twice. The character cap bounds what the reader sees; the byte
	/// cap bounds what we allocate, persist, and Markdown-parse — a single `Character` is an
	/// extended grapheme cluster and can carry unboundedly many scalars (combining marks, ZWJ
	/// sequences), so counting characters alone bounds neither memory nor parse cost. The 4×
	/// multiplier admits any ordinary text: every Unicode scalar is at most 4 UTF-8 bytes, so
	/// only deliberately-degenerate clusters exceed it.
	private enum Limit {
		static let id = 100
		static let title = 200
		static let body = 4000
		static let buttons = 8
		static let buttonLabel = 60

		static let bytesPerCharacter = 4

		/// Upper bound on elements decoded from one payload. A runaway guard, not a product limit:
		/// real campaigns run to tens, and the dashboard imposes no practical size limit, so a
		/// mis-pasted payload is the only way to approach it. Every element is parsed on the main
		/// actor, and the survivors are re-filtered and re-sorted on every foreground, dismiss and
		/// boundary tick — so the cost of an unbounded array is paid repeatedly, not once.
		static let messages = 200
	}

	/// True when `text` is within a field's character cap *and* its derived byte cap.
	///
	/// The byte check runs first because it is O(1) on Swift's UTF-8 storage, whereas `count`
	/// grapheme-breaks the whole string — so a degenerate value is rejected without walking it.
	private static func withinCap(_ text: String, characters: Int) -> Bool {
		text.utf8.count <= characters * Limit.bytesPerCharacter && text.count <= characters
	}

	/// Decodes a JSON array of messages, tolerantly and element-wise.
	///
	/// - Malformed JSON, or a top-level value that isn't an array, yields `[]`.
	/// - Each element is decoded independently: a bad element (missing `id`/`title`/`body`, a
	///   wrong-typed field, a size-cap violation, or zero valid surfaces) is **dropped** without
	///   affecting the others.
	/// - Unknown surface strings are dropped from a message's set; a message left with no valid
	///   surface is dropped.
	/// - Duplicate `id`s keep the **first** occurrence.
	/// - At most ``Limit/messages`` elements are examined; anything beyond is never parsed, and the
	///   truncation is logged.
	static func decodeMessages(from json: String) -> [AppMessage] {
		guard let data = json.data(using: .utf8),
			  let top = try? JSONSerialization.jsonObject(with: data),
			  let array = top as? [Any] else {
			return []
		}

		// Bound the parse itself, not just the output: elements past the cap are never examined.
		// Logged rather than dropped in silence — a truncated payload otherwise looks like a
		// complete one, and the operator would be left wondering where message 201 went.
		if array.count > Limit.messages {
			LoggingPolicy.debug(
				"App messages: payload carried \(array.count) elements, capped at \(Limit.messages) — "
					+ "\(array.count - Limit.messages) never parsed",
				logger: .state
			)
		}

		var result: [AppMessage] = []
		var seenIDs = Set<String>()
		for element in array.prefix(Limit.messages) {
			guard let message = parse(element) else { continue }
			guard seenIDs.insert(message.id).inserted else { continue } // duplicate id ⇒ first wins
			result.append(message)
		}
		return result
	}

	/// Builds one `AppMessage` from a decoded JSON value, or `nil` if it is malformed in any way.
	private static func parse(_ object: Any) -> AppMessage? {
		guard let dict = object as? [String: Any] else { return nil }

		// Required fields.
		guard let id = dict["id"] as? String, !id.isEmpty,
			  let title = dict["title"] as? String,
			  let body = dict["body"] as? String else {
			return nil
		}
		guard withinCap(id, characters: Limit.id),
			  withinCap(title, characters: Limit.title),
			  withinCap(body, characters: Limit.body) else {
			return nil
		}

		// Surfaces: required; unknown values dropped, empty ⇒ drop the message.
		guard let rawSurfaces = dict["surfaces"] as? [Any] else { return nil }
		var surfaces = Set<MessageSurface>()
		for entry in rawSurfaces {
			if let raw = entry as? String, let surface = MessageSurface(rawValue: raw) {
				surfaces.insert(surface)
			}
		}
		guard !surfaces.isEmpty else { return nil }

		// Optional scalar fields — present-but-wrong-type drops the message.
		guard let style = optionalString(dict["style"]),
			  let url = optionalString(dict["url"]),
			  let minAppVersion = optionalString(dict["minAppVersion"]),
			  let maxAppVersion = optionalString(dict["maxAppVersion"]) else {
			return nil
		}
		guard let notify = optionalBool(dict["notify"]),
			  let revision = optionalInt(dict["revision"]) else {
			return nil
		}
		guard let activeFrom = optionalDate(dict["activeFrom"]),
			  let expiresAt = optionalDate(dict["expiresAt"]) else {
			return nil
		}
		// An impossible window (starts at or after its own expiry) is malformed: it could never
		// render, yet its notification would still be scheduled for after the expiry.
		if let from = activeFrom.value, let expiry = expiresAt.value, from >= expiry {
			return nil
		}

		// Localized overrides.
		guard let localized = parseLocalized(dict["localized"]) else { return nil }

		// Buttons.
		guard let buttons = parseButtons(dict["buttons"]) else { return nil }

		return AppMessage(
			id: id,
			title: title,
			body: body,
			localized: localized,
			surfaces: surfaces,
			style: style.value,
			notify: notify,
			activeFrom: activeFrom.value,
			expiresAt: expiresAt.value,
			minAppVersion: minAppVersion.value,
			maxAppVersion: maxAppVersion.value,
			buttons: buttons,
			url: url.value,
			revision: revision
		)
	}

	// MARK: Optional-field helpers
	//
	// Each returns `nil` to mean "reject the whole message" (present but wrong type) and a wrapped
	// `.value` (possibly itself nil) to mean "absent/null, use the default". `Absent` distinguishes
	// those two outcomes without an ambiguous double-optional at the call site.

	/// A successfully-resolved optional field: either absent/null or a concrete value.
	private struct Absent<Value> { var value: Value? }

	private static func optionalString(_ raw: Any?) -> Absent<String>? {
		guard let raw, !(raw is NSNull) else { return Absent(value: nil) }
		guard let string = raw as? String else { return nil }
		return Absent(value: string)
	}

	private static func optionalBool(_ raw: Any?) -> Bool? {
		guard let raw, !(raw is NSNull) else { return false }
		return raw as? Bool
	}

	private static func optionalInt(_ raw: Any?) -> Int? {
		guard let raw, !(raw is NSNull) else { return 0 }
		return raw as? Int
	}

	private static func optionalDate(_ raw: Any?) -> Absent<Date>? {
		guard let raw, !(raw is NSNull) else { return Absent(value: nil) }
		guard let string = raw as? String, let date = parseISO8601(string) else { return nil }
		return Absent(value: date)
	}

	private static func parseLocalized(_ raw: Any?) -> [String: LocalizedContent]? {
		guard let raw, !(raw is NSNull) else { return [:] }
		guard let dict = raw as? [String: Any] else { return nil }
		var result: [String: LocalizedContent] = [:]
		for (language, value) in dict {
			guard let entry = value as? [String: Any] else { return nil }
			guard let title = optionalString(entry["title"]),
				  let body = optionalString(entry["body"]) else {
				return nil
			}
			// An override is what actually renders on a matching device, so it carries the same
			// caps as the field it replaces — otherwise `localized` is a hole straight through
			// them, and `attributedBody` Markdown-parses an unbounded string on every render.
			guard withinCap(title.value ?? "", characters: Limit.title),
				  withinCap(body.value ?? "", characters: Limit.body) else {
				return nil
			}
			result[language] = LocalizedContent(title: title.value, body: body.value)
		}
		return result
	}

	private static func parseButtons(_ raw: Any?) -> [MessageButton]? {
		guard let raw, !(raw is NSNull) else { return [] }
		guard let array = raw as? [Any], array.count <= Limit.buttons else { return nil }
		var result: [MessageButton] = []
		var seenIDs = Set<String>()
		for entry in array {
			// Button ids flow into SwiftUI `ForEach` identity and into the Clerk reply record,
			// so they get the same treatment as message ids: bounded, unique, or the message drops.
			guard let dict = entry as? [String: Any],
				  let id = dict["id"] as? String,
				  !id.isEmpty, withinCap(id, characters: Limit.buttonLabel),
				  seenIDs.insert(id).inserted,
				  let label = dict["label"] as? String,
				  withinCap(label, characters: Limit.buttonLabel) else {
				return nil
			}
			result.append(MessageButton(id: id, label: label))
		}
		return result
	}

	/// Parses an ISO 8601 timestamp, accepting both fractional-seconds and plain forms.
	private static func parseISO8601(_ string: String) -> Date? {
		let formatter = ISO8601DateFormatter()
		formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		if let date = formatter.date(from: string) { return date }
		formatter.formatOptions = [.withInternetDateTime]
		return formatter.date(from: string)
	}
}
