//
//  AppMessageTests.swift
//  AI ArcheologyTests
//
//  Remote in-app messaging model + tolerant decode (AIA-0115).
//

import XCTest
@testable import ML_Browser

final class AppMessageTests: XCTestCase {

	// MARK: Decode — happy path

	/// A fully-populated element round-trips every field, including localized overrides,
	/// surfaces, buttons, and both version bounds.
	func testDecodeMessages_fullyPopulatedElement_mapsEveryField() {
		let json = """
		[{
			"id": "welcome",
			"title": "Hello",
			"body": "Body text",
			"surfaces": ["login", "inApp"],
			"localized": { "cs": { "title": "Ahoj", "body": "Telo" } },
			"style": "info",
			"notify": true,
			"activeFrom": "1970-01-01T00:00:01Z",
			"expiresAt": "1970-01-01T00:00:10Z",
			"minAppVersion": "1.2.0",
			"maxAppVersion": "2.0.0",
			"buttons": [{ "id": "ok", "label": "OK" }],
			"url": "https://example.com",
			"revision": 3
		}]
		"""
		let messages = AppMessage.decodeMessages(from: json)

		XCTAssertEqual(messages.count, 1)
		let message = messages[0]
		XCTAssertEqual(message.id, "welcome")
		XCTAssertEqual(message.title, "Hello")
		XCTAssertEqual(message.body, "Body text")
		XCTAssertEqual(message.surfaces, [.login, .inApp])
		XCTAssertEqual(message.localized["cs"], AppMessage.LocalizedContent(title: "Ahoj", body: "Telo"))
		XCTAssertEqual(message.style, "info")
		XCTAssertTrue(message.notify)
		XCTAssertEqual(message.activeFrom, Date(timeIntervalSince1970: 1))
		XCTAssertEqual(message.expiresAt, Date(timeIntervalSince1970: 10))
		XCTAssertEqual(message.minAppVersion, "1.2.0")
		XCTAssertEqual(message.maxAppVersion, "2.0.0")
		XCTAssertEqual(message.buttons, [AppMessage.MessageButton(id: "ok", label: "OK")])
		XCTAssertEqual(message.url, "https://example.com")
		XCTAssertEqual(message.revision, 3)
	}

	/// Optional fields absent ⇒ documented defaults (empty overrides, notify false, revision 0,
	/// nil dates/versions/url).
	func testDecodeMessages_minimalElement_appliesDefaults() {
		let json = """
		[{ "id": "m", "title": "T", "body": "B", "surfaces": ["paywall"] }]
		"""
		let message = decodeOne(json)
		XCTAssertEqual(message.surfaces, [.paywall])
		XCTAssertTrue(message.localized.isEmpty)
		XCTAssertNil(message.style)
		XCTAssertFalse(message.notify)
		XCTAssertNil(message.activeFrom)
		XCTAssertNil(message.expiresAt)
		XCTAssertNil(message.minAppVersion)
		XCTAssertNil(message.maxAppVersion)
		XCTAssertTrue(message.buttons.isEmpty)
		XCTAssertNil(message.url)
		XCTAssertEqual(message.revision, 0)
	}

	// MARK: Decode — tolerance

	func testDecodeMessages_malformedJSON_returnsEmpty() {
		XCTAssertEqual(AppMessage.decodeMessages(from: "{ not json"), [])
	}

	func testDecodeMessages_nonArrayTopLevel_returnsEmpty() {
		XCTAssertEqual(AppMessage.decodeMessages(from: #"{ "id": "m" }"#), [])
		XCTAssertEqual(AppMessage.decodeMessages(from: "42"), [])
	}

	/// A bad element between two good ones is dropped without harming its siblings.
	func testDecodeMessages_badElementAmongGood_dropsOnlyTheBadOne() {
		let json = """
		[
			{ "id": "a", "title": "A", "body": "B", "surfaces": ["login"] },
			{ "id": "b", "title": "B", "surfaces": ["login"] },
			{ "id": "c", "title": "C", "body": "B", "surfaces": ["login"] }
		]
		"""
		XCTAssertEqual(AppMessage.decodeMessages(from: json).map(\.id), ["a", "c"])
	}

	func testDecodeMessages_missingRequiredField_dropsElement() {
		let missingID = #"[{ "title": "T", "body": "B", "surfaces": ["login"] }]"#
		let missingTitle = #"[{ "id": "m", "body": "B", "surfaces": ["login"] }]"#
		let missingBody = #"[{ "id": "m", "title": "T", "surfaces": ["login"] }]"#
		XCTAssertEqual(AppMessage.decodeMessages(from: missingID), [])
		XCTAssertEqual(AppMessage.decodeMessages(from: missingTitle), [])
		XCTAssertEqual(AppMessage.decodeMessages(from: missingBody), [])
	}

	func testDecodeMessages_wrongTypedField_dropsElement() {
		let numericTitle = #"[{ "id": "m", "title": 7, "body": "B", "surfaces": ["login"] }]"#
		let stringRevision = #"[{ "id": "m", "title": "T", "body": "B", "surfaces": ["login"], "revision": "3" }]"#
		let badDate = #"[{ "id": "m", "title": "T", "body": "B", "surfaces": ["login"], "expiresAt": "not-a-date" }]"#
		XCTAssertEqual(AppMessage.decodeMessages(from: numericTitle), [])
		XCTAssertEqual(AppMessage.decodeMessages(from: stringRevision), [])
		XCTAssertEqual(AppMessage.decodeMessages(from: badDate), [])
	}

	/// Unknown surface strings drop from the set; the message survives with its valid surfaces.
	func testDecodeMessages_unknownSurface_droppedFromSet() {
		let json = #"[{ "id": "m", "title": "T", "body": "B", "surfaces": ["login", "bogus", "aboutApp"] }]"#
		XCTAssertEqual(decodeOne(json).surfaces, [.login, .aboutApp])
	}

	/// A message whose surfaces reduce to empty (all unknown, or literally empty) is dropped.
	func testDecodeMessages_zeroValidSurfaces_dropsElement() {
		let allUnknown = #"[{ "id": "m", "title": "T", "body": "B", "surfaces": ["bogus"] }]"#
		let empty = #"[{ "id": "m", "title": "T", "body": "B", "surfaces": [] }]"#
		let missing = #"[{ "id": "m", "title": "T", "body": "B" }]"#
		XCTAssertEqual(AppMessage.decodeMessages(from: allUnknown), [])
		XCTAssertEqual(AppMessage.decodeMessages(from: empty), [])
		XCTAssertEqual(AppMessage.decodeMessages(from: missing), [])
	}

	func testDecodeMessages_duplicateID_keepsFirstOccurrence() {
		let json = """
		[
			{ "id": "dup", "title": "First", "body": "B", "surfaces": ["login"] },
			{ "id": "dup", "title": "Second", "body": "B", "surfaces": ["login"] }
		]
		"""
		let messages = AppMessage.decodeMessages(from: json)
		XCTAssertEqual(messages.count, 1)
		XCTAssertEqual(messages[0].title, "First")
	}

	// MARK: Decode — element cap

	/// The payload is bounded in element count, keeping the first `messages` in payload order —
	/// the same first-wins rule duplicate ids follow.
	func testDecodeMessages_elementCap_keepsTheFirstNInOrder() {
		let elements = (0..<250).map {
			#"{"id":"m\#($0)","title":"T","body":"B","surfaces":["inApp"]}"#
		}
		let messages = AppMessage.decodeMessages(from: "[\(elements.joined(separator: ","))]")

		XCTAssertEqual(messages.count, 200, "capped")
		XCTAssertEqual(messages.first?.id, "m0")
		XCTAssertEqual(messages.last?.id, "m199", "the cap keeps the head of the payload, not the tail")
	}

	/// A payload exactly at the cap is untouched — the bound is inclusive.
	func testDecodeMessages_elementCapBoundary_isAccepted() {
		let elements = (0..<200).map {
			#"{"id":"m\#($0)","title":"T","body":"B","surfaces":["inApp"]}"#
		}
		XCTAssertEqual(AppMessage.decodeMessages(from: "[\(elements.joined(separator: ","))]").count, 200)
	}

	/// Elements past the cap are never parsed: a malformed element beyond it cannot affect the
	/// outcome, which is what makes the cap a bound on *parse cost* and not just on output size.
	func testDecodeMessages_elementsPastTheCap_areNeverParsed() {
		let good = (0..<200).map {
			#"{"id":"m\#($0)","title":"T","body":"B","surfaces":["inApp"]}"#
		}
		let poison = #"{"id":"m0","title":"T","body":"B","surfaces":["inApp"]}"#  // duplicate id
		let messages = AppMessage.decodeMessages(from: "[\((good + [poison]).joined(separator: ","))]")

		XCTAssertEqual(messages.count, 200)
		XCTAssertEqual(messages.map(\.id).filter { $0 == "m0" }.count, 1)
	}

	// MARK: Decode — size caps

	func testDecodeMessages_sizeCapViolations_dropElement() {
		XCTAssertEqual(AppMessage.decodeMessages(from: element(id: String(repeating: "x", count: 101))), [])
		XCTAssertEqual(AppMessage.decodeMessages(from: element(title: String(repeating: "x", count: 201))), [])
		XCTAssertEqual(AppMessage.decodeMessages(from: element(body: String(repeating: "x", count: 4001))), [])

		let nineButtons = (0..<9).map { #"{ "id": "b\#($0)", "label": "L" }"# }.joined(separator: ",")
		XCTAssertEqual(AppMessage.decodeMessages(from: element(buttons: "[\(nineButtons)]")), [])

		let longLabel = #"[{ "id": "big", "label": "\#(String(repeating: "x", count: 61))" }]"#
		XCTAssertEqual(AppMessage.decodeMessages(from: element(buttons: longLabel)), [])
	}

	/// A `Character` is an extended grapheme cluster with no byte bound, so the character cap alone
	/// does not bound memory or Markdown-parse cost. A body of 4000 ZWJ family emoji is exactly at
	/// the character cap and 100 KB of UTF-8 — the byte cap is what rejects it.
	func testDecodeMessages_withinCharacterCapButOversizedInBytes_dropsElement() {
		let cluster = "👨‍👩‍👧‍👦"  // one Character, 25 UTF-8 bytes
		XCTAssertEqual(cluster.count, 1, "precondition: one grapheme cluster")
		XCTAssertEqual(cluster.utf8.count, 25, "precondition: 25 bytes")

		let fatBody = String(repeating: cluster, count: 4000)
		XCTAssertEqual(fatBody.count, 4000, "at the character cap")
		XCTAssertEqual(fatBody.utf8.count, 100_000, "far past the byte cap")
		XCTAssertEqual(AppMessage.decodeMessages(from: element(body: fatBody)), [])

		let fatTitle = String(repeating: cluster, count: 200)
		XCTAssertEqual(fatTitle.count, 200)
		XCTAssertEqual(AppMessage.decodeMessages(from: element(title: fatTitle)), [])

		// The same hole through the localized override.
		let json = #"[{"id":"m1","title":"T","body":"B","surfaces":["inApp"],"localized":{"cs":{"body":"\#(fatBody)"}}}]"#
		XCTAssertTrue(AppMessage.decodeMessages(from: json).isEmpty)
	}

	/// The byte cap is 4× the character cap, so ordinary text at any scalar width still fits:
	/// 4000 four-byte emoji is exactly 16 000 bytes and must be accepted.
	func testDecodeMessages_multiByteTextAtTheByteCapBoundary_isAccepted() {
		let scalar = "😀"  // one Character, one scalar, 4 UTF-8 bytes
		XCTAssertEqual(scalar.utf8.count, 4, "precondition: the widest a scalar gets")

		let body = String(repeating: scalar, count: 4000)
		XCTAssertEqual(body.utf8.count, 16_000, "exactly at the byte cap")
		XCTAssertEqual(decodeOne(element(body: body)).body.count, 4000)
	}

	/// A localized override replaces the field it overrides at render time, so it must not be a
	/// way around that field's cap (P5 review): the override is what `attributedBody` parses.
	func testDecodeMessages_oversizedLocalizedOverride_dropsElement() {
		let longTitle = String(repeating: "x", count: 201)
		let longBody = String(repeating: "x", count: 4001)
		let cases = [
			#"[{"id":"m1","title":"T","body":"B","surfaces":["inApp"],"localized":{"cs":{"title":"\#(longTitle)"}}}]"#,
			#"[{"id":"m1","title":"T","body":"B","surfaces":["inApp"],"localized":{"cs":{"body":"\#(longBody)"}}}]"#
		]
		for json in cases {
			XCTAssertTrue(AppMessage.decodeMessages(from: json).isEmpty, "should drop: oversized override")
		}
	}

	/// The override caps are the same numbers as the top-level ones, inclusive.
	func testDecodeMessages_localizedOverrideAtCapBoundary_isAccepted() {
		let maxTitle = String(repeating: "x", count: 200)
		let maxBody = String(repeating: "x", count: 4000)
		let json = #"""
		[{"id":"m1","title":"T","body":"B","surfaces":["inApp"],"localized":{"cs":{"title":"\#(maxTitle)","body":"\#(maxBody)"}}}]
		"""#
		let message = decodeOne(json)
		XCTAssertEqual(message.localizedTitle(for: "cs").count, 200)
		XCTAssertEqual(message.localizedBody(for: "cs").count, 4000)
	}

	/// The caps admit values exactly at the boundary.
	/// An impossible window — activation at or after its own expiry — is malformed: it could
	/// never render, but its notification would still fire after the expiry (P4 review).
	func testDecodeMessages_activeFromAtOrAfterExpiry_dropsTheMessage() {
		let cases = [
			// starts after expiry
			#"[{"id":"m1","title":"T","body":"B","surfaces":["inApp"],"activeFrom":"2026-08-08T00:00:00Z","expiresAt":"2026-08-01T00:00:00Z"}]"#,
			// starts exactly at expiry (window is empty: expiry is exclusive)
			#"[{"id":"m1","title":"T","body":"B","surfaces":["inApp"],"activeFrom":"2026-08-01T00:00:00Z","expiresAt":"2026-08-01T00:00:00Z"}]"#
		]
		for json in cases {
			XCTAssertTrue(AppMessage.decodeMessages(from: json).isEmpty, "should drop: \(json)")
		}
	}

	/// Button ids get the same rigor as message ids (AIA-0115 review): they are ForEach identity
	/// and the Clerk reply `choice`, so an empty, oversized, or duplicate id drops the message.
	func testDecodeMessages_badButtonIDs_dropTheMessage() {
		let longID = String(repeating: "x", count: 61)
		let cases = [
			#"[{"id":"m1","title":"T","body":"B","surfaces":["inApp"],"buttons":[{"id":"","label":"OK"}]}]"#,
			#"[{"id":"m1","title":"T","body":"B","surfaces":["inApp"],"buttons":[{"id":"\#(longID)","label":"OK"}]}]"#,
			#"[{"id":"m1","title":"T","body":"B","surfaces":["inApp"],"buttons":[{"id":"yes","label":"Y"},{"id":"yes","label":"Y2"}]}]"#
		]
		for json in cases {
			XCTAssertTrue(AppMessage.decodeMessages(from: json).isEmpty, "should drop: \(json)")
		}
	}

	func testDecodeMessages_sizeCapBoundaries_areAccepted() {
		XCTAssertEqual(decodeOne(element(id: String(repeating: "x", count: 100))).id.count, 100)
		XCTAssertEqual(decodeOne(element(title: String(repeating: "x", count: 200))).title.count, 200)
		XCTAssertEqual(decodeOne(element(body: String(repeating: "x", count: 4000))).body.count, 4000)

		let eightButtons = (0..<8).map { #"{ "id": "b\#($0)", "label": "L" }"# }.joined(separator: ",")
		XCTAssertEqual(decodeOne(element(buttons: "[\(eightButtons)]")).buttons.count, 8)

		let maxLabel = #"[{ "id": "big", "label": "\#(String(repeating: "x", count: 60))" }]"#
		XCTAssertEqual(decodeOne(element(buttons: maxLabel)).buttons.first?.label.count, 60)
	}

	// MARK: Decode — ISO 8601 date forms

	func testDecodeMessages_acceptsBothISO8601Forms() {
		let plain = #"[{ "id": "m", "title": "T", "body": "B", "surfaces": ["login"], "activeFrom": "1970-01-01T00:00:01Z" }]"#
		let fractional = #"[{ "id": "m", "title": "T", "body": "B", "surfaces": ["login"], "activeFrom": "1970-01-01T00:00:01.500Z" }]"#
		XCTAssertEqual(decodeOne(plain).activeFrom, Date(timeIntervalSince1970: 1))
		XCTAssertEqual(decodeOne(fractional).activeFrom, Date(timeIntervalSince1970: 1.5))
	}

	// MARK: Active window

	func testIsActive_noBounds_alwaysActive() {
		let message = makeMessage()
		XCTAssertTrue(message.isActive(at: Date(timeIntervalSince1970: 0)))
		XCTAssertTrue(message.isActive(at: Date(timeIntervalSince1970: 9_999)))
	}

	func testIsActive_nilExpiry_neverExpires() {
		let message = makeMessage(activeFrom: Date(timeIntervalSince1970: 100), expiresAt: nil)
		XCTAssertTrue(message.isActive(at: Date(timeIntervalSince1970: 1_000_000)))
	}

	func testIsActive_beforeActiveFrom_isInactive() {
		let message = makeMessage(activeFrom: Date(timeIntervalSince1970: 100))
		XCTAssertFalse(message.isActive(at: Date(timeIntervalSince1970: 99)))
	}

	func testIsActive_afterExpiry_isInactive() {
		let message = makeMessage(expiresAt: Date(timeIntervalSince1970: 100))
		XCTAssertFalse(message.isActive(at: Date(timeIntervalSince1970: 101)))
	}

	/// `activeFrom` is inclusive, `expiresAt` is exclusive.
	func testIsActive_boundaries_activeFromInclusive_expiryExclusive() {
		let message = makeMessage(
			activeFrom: Date(timeIntervalSince1970: 100),
			expiresAt: Date(timeIntervalSince1970: 200)
		)
		XCTAssertTrue(message.isActive(at: Date(timeIntervalSince1970: 100)), "activeFrom boundary is active")
		XCTAssertTrue(message.isActive(at: Date(timeIntervalSince1970: 199)))
		XCTAssertFalse(message.isActive(at: Date(timeIntervalSince1970: 200)), "expiry boundary is inactive")
	}

	// MARK: Version matching

	func testMatchesVersion_withinBounds_matches() {
		let message = makeMessage(minAppVersion: "1.2.0", maxAppVersion: "2.0.0")
		XCTAssertTrue(message.matchesVersion("1.5.0"))
		XCTAssertTrue(message.matchesVersion("1.2.0"), "min bound is inclusive")
		XCTAssertTrue(message.matchesVersion("2.0.0"), "max bound is inclusive")
	}

	func testMatchesVersion_belowMin_doesNotMatch() {
		let message = makeMessage(minAppVersion: "1.2.0")
		XCTAssertFalse(message.matchesVersion("1.1.9"))
	}

	func testMatchesVersion_aboveMax_doesNotMatch() {
		let message = makeMessage(maxAppVersion: "2.0.0")
		XCTAssertFalse(message.matchesVersion("2.0.1"))
	}

	func testMatchesVersion_missingBounds_alwaysMatches() {
		let message = makeMessage()
		XCTAssertTrue(message.matchesVersion("0.0.1"))
		XCTAssertTrue(message.matchesVersion("999.999.999"))
	}

	/// Comparison is numeric per component, so multi-digit segments order correctly ("1.10" > "1.9").
	func testMatchesVersion_multiDigitComponents_compareNumerically() {
		let minOnly = makeMessage(minAppVersion: "1.9")
		XCTAssertTrue(minOnly.matchesVersion("1.10"))
		XCTAssertFalse(minOnly.matchesVersion("1.8"))

		let maxOnly = makeMessage(maxAppVersion: "1.9")
		XCTAssertFalse(maxOnly.matchesVersion("1.10"))
		XCTAssertTrue(maxOnly.matchesVersion("1.9"))
	}

	/// A non-numeric bound component fails open — that bound is ignored rather than blocking.
	func testMatchesVersion_nonNumericBound_isIgnored() {
		XCTAssertTrue(makeMessage(minAppVersion: "1.x").matchesVersion("0.0.1"))
		XCTAssertTrue(makeMessage(maxAppVersion: "abc").matchesVersion("9.9.9"))
	}

	// MARK: Localization

	func testLocalized_override_winsOverTopLevel() {
		let message = makeMessage(
			title: "Hello",
			body: "World",
			localized: ["cs": AppMessage.LocalizedContent(title: "Ahoj", body: "Svete")]
		)
		XCTAssertEqual(message.localizedTitle(for: "cs"), "Ahoj")
		XCTAssertEqual(message.localizedBody(for: "cs"), "Svete")
	}

	// MARK: Localization — candidate narrowing

	/// The candidate chain, most specific first — the key order operators write against.
	func testLocalizationCandidates_narrowMostSpecificFirst() {
		XCTAssertEqual(AppMessage.localizationCandidates(for: "zh-Hant-HK"), ["zh-Hant-HK", "zh-HK", "zh-Hant", "zh"])
		XCTAssertEqual(AppMessage.localizationCandidates(for: "pt-BR"), ["pt-BR", "pt"])
		XCTAssertEqual(AppMessage.localizationCandidates(for: "cs"), ["cs"], "a bare tag yields only itself")
	}

	/// Candidates come from the **written** subtags. `Locale.Language` fills in a likely script
	/// (`cs` → `cs-Latn`, `zh` → `zh-Hans`), and keying on that would invent forms no operator
	/// writes — so a bare tag must not sprout a script candidate.
	func testLocalizationCandidates_ignoreForeignInferredScript() {
		XCTAssertEqual(Locale.Language(identifier: "cs").script?.identifier, "Latn", "precondition: Foundation infers")
		XCTAssertFalse(AppMessage.localizationCandidates(for: "cs").contains("cs-Latn"))
		XCTAssertFalse(AppMessage.localizationCandidates(for: "zh").contains("zh-Hans"))
	}

	/// The bug this fixes: the app ships `zh-Hans` / `zh-Hant` / `zh-HK`, but resolution used the
	/// bare language, so a payload keyed the way the catalog is named could never match.
	func testLocalized_scriptQualifiedKey_isReachable() {
		let message = makeMessage(
			title: "Maintenance",
			body: "Sync is unavailable.",
			localized: [
				"zh-Hans": AppMessage.LocalizedContent(title: "计划维护", body: "无法同步。"),
				"zh-Hant": AppMessage.LocalizedContent(title: "計劃維護", body: "無法同步。")
			]
		)
		XCTAssertEqual(message.localizedTitle(for: "zh-Hans-CN"), "计划维护")
		XCTAssertEqual(message.localizedTitle(for: "zh-Hant-TW"), "計劃維護")
		XCTAssertEqual(message.localizedTitle(for: "en-US"), "Maintenance", "no Chinese match ⇒ source text")
	}

	/// A region key beats a script key for the same device, and a bare `zh` payload still serves
	/// every Chinese device — the pre-existing behaviour operators may already rely on.
	func testLocalized_regionBeatsScript_andBareLanguageStillMatches() {
		let both = makeMessage(
			localized: [
				"zh-HK": AppMessage.LocalizedContent(title: "香港", body: nil),
				"zh-Hant": AppMessage.LocalizedContent(title: "繁體", body: nil)
			]
		)
		XCTAssertEqual(both.localizedTitle(for: "zh-Hant-HK"), "香港")

		let bare = makeMessage(localized: ["zh": AppMessage.LocalizedContent(title: "中文", body: nil)])
		XCTAssertEqual(bare.localizedTitle(for: "zh-Hans-CN"), "中文")
		XCTAssertEqual(bare.localizedTitle(for: "zh-Hant-HK"), "中文")
	}

	func testLocalized_missingLanguage_fallsBackToTopLevel() {
		let message = makeMessage(title: "Hello", body: "World")
		XCTAssertEqual(message.localizedTitle(for: "cs"), "Hello")
		XCTAssertEqual(message.localizedBody(for: "cs"), "World")
	}

	/// A partial override (title only) falls back to the top-level body, and vice versa.
	func testLocalized_partialOverride_fallsBackPerField() {
		let message = makeMessage(
			title: "Hello",
			body: "World",
			localized: [
				"de": AppMessage.LocalizedContent(title: "Hallo", body: nil),
				"fr": AppMessage.LocalizedContent(title: nil, body: "Monde")
			]
		)
		XCTAssertEqual(message.localizedTitle(for: "de"), "Hallo")
		XCTAssertEqual(message.localizedBody(for: "de"), "World")
		XCTAssertEqual(message.localizedTitle(for: "fr"), "Hello")
		XCTAssertEqual(message.localizedBody(for: "fr"), "Monde")
	}

	// MARK: isInteractive

	func testIsInteractive_reflectsButtonPresence() {
		XCTAssertFalse(makeMessage().isInteractive)
		XCTAssertTrue(makeMessage(buttons: [AppMessage.MessageButton(id: "ok", label: "OK")]).isInteractive)
	}

	// MARK: messageStyle

	func testMessageStyle_mapsKnownTokens_unknownIsNil() {
		func styled(_ style: String?) -> AppMessage {
			AppMessage(id: "m", title: "T", body: "B", surfaces: [.login], style: style)
		}
		XCTAssertEqual(styled("info").messageStyle, .info)
		XCTAssertEqual(styled("warning").messageStyle, .warning)
		XCTAssertEqual(styled("success").messageStyle, .success)
		XCTAssertNil(styled("urgent").messageStyle, "unknown token degrades to the default look")
		XCTAssertNil(styled(nil).messageStyle)
	}

	// MARK: attributedBody

	func testAttributedBody_parsesInlineLinkAndBold() {
		let message = makeMessage(body: "See **the** [docs](https://example.com) now")
		let attributed = message.attributedBody(for: "en")
		XCTAssertEqual(String(attributed.characters), "See the docs now", "markdown syntax is consumed")
		XCTAssertEqual(
			attributed.runs.compactMap(\.link),
			[URL(string: "https://example.com")],
			"the link survives as an attribute on its run"
		)
	}

	func testAttributedBody_plainText_passesThroughLiterally() {
		let body = "Plain text. 100% unformatted, line\nbreak preserved."
		let attributed = makeMessage(body: body).attributedBody(for: "en")
		XCTAssertEqual(String(attributed.characters), body)
		XCTAssertTrue(attributed.runs.compactMap(\.link).isEmpty)
	}

	func testAttributedBody_parsesTheLocalizedOverride() {
		let message = makeMessage(
			body: "top [a](https://a.example)",
			localized: ["cs": AppMessage.LocalizedContent(title: nil, body: "cs [b](https://b.example)")]
		)
		XCTAssertEqual(String(message.attributedBody(for: "cs").characters), "cs b")
		XCTAssertEqual(
			message.attributedBody(for: "cs").runs.compactMap(\.link),
			[URL(string: "https://b.example")]
		)
	}

	// MARK: - Helpers

	/// Decodes `json` and returns its single message, failing the test if that is not the shape.
	private func decodeOne(_ json: String, file: StaticString = #filePath, line: UInt = #line) -> AppMessage {
		let messages = AppMessage.decodeMessages(from: json)
		guard messages.count == 1, let message = messages.first else {
			XCTFail("expected exactly one message, got \(messages.count)", file: file, line: line)
			return makeMessage()
		}
		return message
	}

	/// Builds a one-element JSON array, overriding just the fields a test cares about.
	private func element(
		id: String = "m",
		title: String = "T",
		body: String = "B",
		buttons: String = "[]"
	) -> String {
		"""
		[{
			"id": "\(id)",
			"title": "\(title)",
			"body": "\(body)",
			"surfaces": ["login"],
			"buttons": \(buttons)
		}]
		"""
	}

	/// Builds an `AppMessage` value directly for predicate/localization tests.
	private func makeMessage(
		title: String = "T",
		body: String = "B",
		localized: [String: AppMessage.LocalizedContent] = [:],
		activeFrom: Date? = nil,
		expiresAt: Date? = nil,
		minAppVersion: String? = nil,
		maxAppVersion: String? = nil,
		buttons: [AppMessage.MessageButton] = []
	) -> AppMessage {
		AppMessage(
			id: "m",
			title: title,
			body: body,
			localized: localized,
			surfaces: [.login],
			activeFrom: activeFrom,
			expiresAt: expiresAt,
			minAppVersion: minAppVersion,
			maxAppVersion: maxAppVersion,
			buttons: buttons
		)
	}
}
