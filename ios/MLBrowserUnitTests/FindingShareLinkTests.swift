//
//  FindingShareLinkTests.swift
//  MLBrowserUnitTests
//
//  The share-link contract (AIA-0650). The parser is the app's only boundary against a
//  stranger's URL, so these lean on hostile input rather than the happy path.
//

import XCTest
@testable import ML_Browser

final class FindingShareLinkTests: XCTestCase {

	// MARK: - Helpers

	private func makePayload(
		id: UUID? = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301"),
		title: String = "Roman wall",
		detectionClass: String? = "stone_wall",
		confidencePercent: Int? = 87,
		coordinate: FindingShareLink.Coordinate? = FindingShareLink.Coordinate(latitude: 48.8, longitude: 19.53),
		page: URL? = URL(string: "https://example.org/ruins"),
		author: String? = "V. Slavík",
		date: DateComponents? = DateComponents(year: 2026, month: 8, day: 17)
	) -> FindingShareLink.Payload {
		FindingShareLink.Payload(
			id: id,
			title: title,
			detectionClass: detectionClass,
			confidencePercent: confidencePercent,
			coordinate: coordinate,
			page: page,
			author: author,
			date: date
		)
	}

	private func roundTrip(
		_ payload: FindingShareLink.Payload,
		variant: FindingShareLink.Variant = .full,
		file: StaticString = #filePath,
		line: UInt = #line
	) throws -> FindingShareLink.Payload {
		let url = try XCTUnwrap(FindingShareLink.url(for: payload, variant: variant), file: file, line: line)
		return try XCTUnwrap(FindingShareLink.payload(from: url), file: file, line: line)
	}

	// MARK: - Round trip

	func test_roundTrip_preservesEveryField() throws {
		let original = makePayload()
		let parsed = try roundTrip(original)
		XCTAssertEqual(parsed, original)
	}

	func test_roundTrip_withOnlyATitle() throws {
		let original = FindingShareLink.Payload(title: "Just a title")
		XCTAssertEqual(try roundTrip(original), original)
	}

	/// The payload lives after `#`, which is what keeps it off the wire. If this ever regresses to a
	/// query string the leak is silent, so it is asserted structurally rather than by inspection.
	func test_payloadTravelsInTheFragment_neverTheQuery() throws {
		let url = try XCTUnwrap(FindingShareLink.url(for: makePayload()))
		let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

		XCTAssertNil(components.query, "the payload must not be in the query string")
		XCTAssertEqual(components.path, "/f")
		XCTAssertEqual(components.host, "link.aiarcheology.com")
		let fragment = try XCTUnwrap(components.percentEncodedFragment)
		XCTAssertTrue(fragment.contains("t="))
		XCTAssertTrue(fragment.contains("a="))
	}

	/// The emitted path must equal the string the association file lists, with no trailing slash.
	/// iOS matches the tapped URL before any redirect, so a mismatch here never opens the app.
	func test_emittedPathIsPinnedWithoutATrailingSlash() throws {
		let url = try XCTUnwrap(FindingShareLink.url(for: makePayload()))
		XCTAssertTrue(url.absoluteString.hasPrefix("https://link.aiarcheology.com/f#"))
		XCTAssertFalse(url.absoluteString.contains("/f/"))
	}

	// MARK: - Hostile values

	/// The separators, the fragment marker, and the characters `CharacterSet.urlQueryAllowed` would
	/// have let through unescaped. A naive encoder emits a link that breaks its own parser here.
	func test_roundTrip_titleContainingSeparatorsAndReservedCharacters() throws {
		let original = FindingShareLink.Payload(title: "A & B = C + D # E ? F / G % H")
		XCTAssertEqual(try roundTrip(original).title, "A & B = C + D # E ? F / G % H")
	}

	func test_roundTrip_titleWithEmojiAndRightToLeftText() throws {
		let original = FindingShareLink.Payload(title: "🏛️ جدار روماني قديم", author: "أحمد")
		let parsed = try roundTrip(original)
		XCTAssertEqual(parsed.title, "🏛️ جدار روماني قديم")
		XCTAssertEqual(parsed.author, "أحمد")
	}

	/// Bidi overrides render as nothing while reordering everything after them — the trick that makes
	/// a label display something other than what it holds. They are stripped, not escaped.
	func test_bidiOverridesAreStrippedFromText() throws {
		let original = FindingShareLink.Payload(title: "safe\u{202E}gnp.exe")
		let parsed = try roundTrip(original)
		XCTAssertFalse(parsed.title.unicodeScalars.contains { $0.value == 0x202E })
		XCTAssertEqual(parsed.title, "safegnp.exe")
	}

	func test_controlCharactersAreStrippedFromText() throws {
		let original = FindingShareLink.Payload(title: "line\u{0000}one\ntwo")
		let parsed = try roundTrip(original)
		XCTAssertFalse(parsed.title.unicodeScalars.contains { $0.value == 0 })
	}

	func test_titleOfOnlyWhitespaceIsRejected() {
		let url = FindingShareLink.url(for: FindingShareLink.Payload(title: "   \n  "))
		XCTAssertNil(url, "a link with no renderable title must not be built")
	}

	// MARK: - Page URL sanitising

	/// The query string is where session tokens and search terms live, and this URL is about to be
	/// posted somewhere public.
	func test_pageQueryAndFragmentAreStripped() throws {
		let original = makePayload(page: URL(string: "https://example.org/a/b?session=secret&q=hi#frag"))
		let parsed = try roundTrip(original)
		XCTAssertEqual(parsed.page?.absoluteString, "https://example.org/a/b")
	}

	/// The test above passes even when the **emitted** link still contains the secret, because a
	/// round trip parses on the way back in and the parser sanitizes. That is exactly how the real
	/// bug hid: the builder shipped `?session=secret` inside a link posted to social media, and it
	/// was only dropped again when the *recipient* read it — long after the exposure.
	///
	/// So this asserts on the emitted string itself, and does it with a `Payload` constructed
	/// **directly** rather than through the mapping that sanitizes, so the guarantee belongs to this
	/// type rather than to a caller's discipline.
	func test_emittedLinkNeverCarriesThePagesQueryString() throws {
		let payload = FindingShareLink.Payload(
			title: "Roman wall",
			page: URL(string: "https://example.org/a/b?session=secret&token=abc123#frag")
		)
		let url = try XCTUnwrap(FindingShareLink.url(for: payload))
		let emitted = url.absoluteString

		XCTAssertFalse(emitted.contains("session"), "a session token must never leave in a shared link")
		XCTAssertFalse(emitted.contains("secret"))
		XCTAssertFalse(emitted.contains("token"))
		XCTAssertFalse(emitted.contains("abc123"))
		// The percent-encoded forms must be absent too, which is what the raw substring check above
		// would miss if the value were escaped rather than removed.
		XCTAssertFalse(emitted.contains("%3Fsession"))
		XCTAssertEqual(try XCTUnwrap(FindingShareLink.payload(from: url)).page?.absoluteString,
		               "https://example.org/a/b")
	}

	/// A non-`https` page must be dropped at emission too, not merely refused on the way back in.
	func test_emittedLinkNeverCarriesANonHTTPSPage() throws {
		for raw in ["http://example.org/x", "javascript:alert(1)", "file:///etc/passwd"] {
			let payload = FindingShareLink.Payload(title: "X", page: URL(string: raw))
			let url = try XCTUnwrap(FindingShareLink.url(for: payload))
			XCTAssertFalse(url.absoluteString.contains("&u="), "\(raw) must not be emitted")
		}
	}

	func test_nonHTTPSPagesAreRejected() throws {
		for raw in [
			"http://example.org/insecure",
			"javascript:alert(1)",
			"file:///etc/passwd",
			"data:text/html;base64,PHNjcmlwdD4=",
			"com.aiarcheology.ios://f"
		] {
			let parsed = try roundTrip(makePayload(page: URL(string: raw)))
			XCTAssertNil(parsed.page, "\(raw) must not survive as a page URL")
		}
	}

	func test_pageWithEmbeddedCredentialsIsRejected() throws {
		let parsed = try roundTrip(makePayload(page: URL(string: "https://user:pass@example.org/x")))
		XCTAssertNil(parsed.page)
	}

	// MARK: - Numeric and date validation

	func test_confidenceOutsideZeroToOneHundredIsDropped() throws {
		for raw in ["-1", "101", "1e3", "NaN", "abc", "87.5"] {
			let url = try XCTUnwrap(URL(string: "https://link.aiarcheology.com/f#v=1&t=X&p=\(raw)"))
			let parsed = try XCTUnwrap(FindingShareLink.payload(from: url))
			XCTAssertNil(parsed.confidencePercent, "\(raw) must not parse as a confidence")
		}
	}

	func test_confidenceBoundsAreInclusive() throws {
		for value in [0, 100] {
			let url = try XCTUnwrap(URL(string: "https://link.aiarcheology.com/f#v=1&t=X&p=\(value)"))
			XCTAssertEqual(FindingShareLink.payload(from: url)?.confidencePercent, value)
		}
	}

	/// A range check on each component accepts the 30th of February; the calendar round trip does not.
	func test_impossibleCalendarDatesAreRejected() throws {
		for raw in ["2026-02-30", "2026-13-01", "2026-00-10", "2026-8-17", "not-a-date", "20260817"] {
			let url = try XCTUnwrap(URL(string: "https://link.aiarcheology.com/f#v=1&t=X&d=\(raw)"))
			let parsed = try XCTUnwrap(FindingShareLink.payload(from: url))
			XCTAssertNil(parsed.date, "\(raw) must not parse as a date")
		}
	}

	func test_leapDayParses() throws {
		let url = try XCTUnwrap(URL(string: "https://link.aiarcheology.com/f#v=1&t=X&d=2024-02-29"))
		XCTAssertEqual(FindingShareLink.payload(from: url)?.date?.day, 29)
	}

	// MARK: - Coordinates

	func test_coordinateOutOfRangeIsDropped() throws {
		for raw in ["91,0", "-91,0", "0,181", "0,-181", "nan,0", "inf,0", "1e5,0"] {
			let url = try XCTUnwrap(URL(string: "https://link.aiarcheology.com/f#v=1&t=X&g=\(raw)"))
			let parsed = try XCTUnwrap(FindingShareLink.payload(from: url))
			XCTAssertNil(parsed.coordinate, "\(raw) must not parse as a coordinate")
		}
	}

	func test_freeTextCoordinateForms() {
		let expected = FindingShareLink.Coordinate(latitude: 48.8, longitude: 19.53)
		for raw in ["48.8, 19.53", "48.8 19.53", "48.8,19.53", "48.8°, 19.53°", "48.8N, 19.53E", "N48.8 E19.53"] {
			XCTAssertEqual(CoordinateText.parse(raw), expected, "failed for \(raw)")
		}
	}

	func test_southernAndWesternHemispheresAreNegated() {
		XCTAssertEqual(
			CoordinateText.parse("33.9S, 18.4W"),
			FindingShareLink.Coordinate(latitude: -33.9, longitude: -18.4)
		)
	}

	/// A sign and a hemisphere letter disagree about which side of the equator was meant. Guessing
	/// drops a pin in the wrong hemisphere silently, so it is refused.
	func test_conflictingSignAndHemisphereIsRefused() {
		XCTAssertNil(CoordinateText.parse("-48.8N, 19.53E"))
	}

	func test_proseAndEmptyCoordinatesYieldNothing() {
		for raw in ["", "   ", "somewhere near the river", "48.8", "48.8, 19.53, 100", "N, E"] {
			XCTAssertNil(CoordinateText.parse(raw), "\(raw) must not parse")
		}
	}

	// MARK: - Grammar matching

	func test_customSchemeFormIsAccepted() throws {
		// `com.aiarcheology.ios://f` is host `f` with an EMPTY path — not path `/f`. A single
		// path comparison would reject the whole scheme form.
		let url = try XCTUnwrap(URL(string: "com.aiarcheology.ios://f#v=1&t=Roman%20wall"))
		XCTAssertTrue(FindingShareLink.matches(url))
		XCTAssertEqual(FindingShareLink.payload(from: url)?.title, "Roman wall")
	}

	func test_trailingSlashIsToleratedOnInput() throws {
		let url = try XCTUnwrap(URL(string: "https://link.aiarcheology.com/f/#v=1&t=X"))
		XCTAssertTrue(FindingShareLink.matches(url))
	}

	/// A scene-level `onOpenURL` sees every URL the app is handed, including Clerk's OAuth callback
	/// on this same custom scheme. Anything not ours must pass straight through.
	func test_foreignURLsAreIgnored() throws {
		for raw in [
			"com.aiarcheology.ios://sso-callback?code=abc",
			"com.aiarcheology.ios://oauth/callback#access_token=xyz",
			"https://link.aiarcheology.com/other#v=1&t=X",
			"https://aiarcheology.com/f#v=1&t=X",
			"https://evil.example/f#v=1&t=X",
			"https://link.aiarcheology.com.evil.example/f#v=1&t=X",
			"http://link.aiarcheology.com/f#v=1&t=X"
		] {
			let url = try XCTUnwrap(URL(string: raw))
			XCTAssertFalse(FindingShareLink.matches(url), "\(raw) must not match")
			XCTAssertNil(FindingShareLink.payload(from: url), "\(raw) must not parse")
		}
	}

	func test_hostMatchingIsCaseInsensitive() throws {
		let url = try XCTUnwrap(URL(string: "https://LINK.AIARCHEOLOGY.COM/f#v=1&t=X"))
		XCTAssertTrue(FindingShareLink.matches(url))
	}

	// MARK: - Malformed links (acceptance criterion 4)

	func test_malformedLinksParseToNothingRatherThanCrashing() throws {
		for raw in [
			"https://link.aiarcheology.com/f",
			"https://link.aiarcheology.com/f#",
			"https://link.aiarcheology.com/f#v=1",
			"https://link.aiarcheology.com/f#t=X",
			"https://link.aiarcheology.com/f#v=2&t=X",
			"https://link.aiarcheology.com/f#v=1&t=",
			"https://link.aiarcheology.com/f#=====",
			"https://link.aiarcheology.com/f#%%%%",
			"https://link.aiarcheology.com/f#v=1&t=A&t=B"
		] {
			let url = try XCTUnwrap(URL(string: raw))
			XCTAssertNil(FindingShareLink.payload(from: url), "\(raw) must not produce a payload")
		}
	}

	/// There is no correct answer to which of two titles was meant, and a first-wins/last-wins split
	/// between the app and the landing page would render two different things from one link.
	func test_duplicateKeysAreRejected() throws {
		let url = try XCTUnwrap(URL(string: "https://link.aiarcheology.com/f#v=1&t=Real&t=Fake&a=X"))
		XCTAssertNil(FindingShareLink.payload(from: url))
	}

	func test_unknownKeysAreIgnored() throws {
		let url = try XCTUnwrap(URL(string: "https://link.aiarcheology.com/f#v=1&t=X&zz=1&yy=2"))
		XCTAssertEqual(FindingShareLink.payload(from: url)?.title, "X")
	}

	// MARK: - Length budgets

	func test_fullLinkStaysWithinItsBudgetForAMaximalPayload() throws {
		let payload = makePayload(
			title: String(repeating: "Ω", count: 200),
			detectionClass: String(repeating: "c", count: 200),
			page: URL(string: "https://example.org/" + String(repeating: "p", count: 300)),
			author: String(repeating: "å", count: 200)
		)
		let url = try XCTUnwrap(FindingShareLink.url(for: payload, variant: .full))
		XCTAssertLessThanOrEqual(url.absoluteString.count, FindingShareLink.maximumLength)
		XCTAssertNotNil(FindingShareLink.payload(from: url), "a trimmed link must still parse")
	}

	/// Validated at the cap rather than at an example: a short happy-path payload always fits and
	/// would hide the sizing bug this budget exists to prevent.
	func test_compactLinkStaysWithinTheQRBudgetForAMaximalPayload() throws {
		let payload = makePayload(
			title: String(repeating: "Ω", count: 200),
			detectionClass: String(repeating: "c", count: 200),
			page: URL(string: "https://example.org/" + String(repeating: "p", count: 300)),
			author: String(repeating: "å", count: 200)
		)
		let url = try XCTUnwrap(FindingShareLink.url(for: payload, variant: .compact))
		XCTAssertLessThanOrEqual(url.absoluteString.count, FindingShareLink.maximumCompactLength)
		XCTAssertNotNil(FindingShareLink.payload(from: url))
	}

	/// Both variants must land on the same finding — that is what makes it safe for them to differ.
	func test_compactAndFullVariantsIdentifyTheSameFinding() throws {
		let payload = makePayload()
		let full = try XCTUnwrap(FindingShareLink.url(for: payload, variant: .full))
		let compact = try XCTUnwrap(FindingShareLink.url(for: payload, variant: .compact))

		XCTAssertEqual(FindingShareLink.payload(from: full)?.id, payload.id)
		XCTAssertEqual(FindingShareLink.payload(from: compact)?.id, payload.id)
	}

	func test_compactVariantDropsThePageURL() throws {
		let compact = try XCTUnwrap(FindingShareLink.url(for: makePayload(), variant: .compact))
		XCTAssertNil(FindingShareLink.payload(from: compact)?.page)
	}

	func test_overlongFieldsAreTruncatedRatherThanRejected() throws {
		let parsed = try roundTrip(makePayload(title: String(repeating: "a", count: 500), page: nil, author: nil))
		XCTAssertEqual(parsed.title.count, 80)
	}
}
