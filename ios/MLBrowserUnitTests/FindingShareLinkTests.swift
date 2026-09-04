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
		locationText: String? = nil,
		box: FindingShareLink.Box? = nil,
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
			locationText: locationText,
			box: box,
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

	/// `Payload` validates nothing on construction, so the builder is the boundary. An out-of-range
	/// confidence emitted here would be dropped by our own parser and rendered by the landing page —
	/// the two ends disagreeing about one link, which is the failure both implementations forbid.
	func test_emittedLinkNeverCarriesAnOutOfRangeConfidence() throws {
		for value in [-1, 101, 9999, Int.max, Int.min] {
			let payload = FindingShareLink.Payload(title: "X", confidencePercent: value)
			let url = try XCTUnwrap(FindingShareLink.url(for: payload))
			XCTAssertFalse(url.absoluteString.contains("&p="), "p=\(value) must not be emitted")
		}
	}

	/// A `DateComponents` for the 30th of February formats perfectly happily. Emitting it would put a
	/// date on the landing page that this app refuses to read back.
	func test_emittedLinkNeverCarriesAnImpossibleDate() throws {
		for components in [
			DateComponents(year: 2026, month: 2, day: 30),
			DateComponents(year: 2026, month: 13, day: 1),
			DateComponents(year: 2026, month: 0, day: 10),
			DateComponents(year: 2026, month: 6)
		] {
			let payload = FindingShareLink.Payload(title: "X", date: components)
			let url = try XCTUnwrap(FindingShareLink.url(for: payload))
			XCTAssertFalse(url.absoluteString.contains("&d="), "\(components) must not be emitted")
		}
	}

	/// A real date still travels — the guard above must not have made the field unusable.
	func test_emittedLinkCarriesARealDate() throws {
		let payload = FindingShareLink.Payload(title: "X", date: DateComponents(year: 2024, month: 2, day: 29))
		let url = try XCTUnwrap(FindingShareLink.url(for: payload))
		XCTAssertTrue(url.absoluteString.contains("d=2024-02-29"))
	}

	/// The parse is bounded before any work happens: the custom scheme is registered app-wide, so any
	/// app on the device can hand this one a URL, and the parse runs on the main actor.
	func test_oversizedLinksAreRefusedBeforeParsing() throws {
		let huge = "https://link.aiarcheology.com/f#v=1&t=" + String(repeating: "a", count: 5000)
		let url = try XCTUnwrap(URL(string: huge))
		XCTAssertTrue(FindingShareLink.matches(url), "it is still ours")
		XCTAssertNil(FindingShareLink.payload(from: url), "but it must not be parsed")
	}

	func test_tooManyFieldsIsRefused() throws {
		let pairs = (0..<200).map { "k\($0)=v" }.joined(separator: "&")
		let url = try XCTUnwrap(URL(string: "https://link.aiarcheology.com/f#v=1&t=X&" + pairs))
		XCTAssertNil(FindingShareLink.payload(from: url))
	}

	/// Digits only. `Int("+5")` succeeds where the landing page's regex refuses, and a wire format
	/// whose two implementations disagree about `+5` is a wire format with a hole in it.
	func test_confidenceAcceptsPlainDigitsOnly() throws {
		for raw in ["+5", " 5", "5 ", "٥"] {
			let url = try XCTUnwrap(URL(string: "https://link.aiarcheology.com/f#v=1&t=X&p=\(raw)"))
			let parsed = FindingShareLink.payload(from: url)
			XCTAssertNil(parsed?.confidencePercent, "\(raw) must not parse as a confidence")
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

	/// The wire form accepts exactly one spelling, and it is the one the builder emits.
	///
	/// Found by Copilot on the PR: `g=+48.8,+19.53` parsed in the app (the link's `g` went through the
	/// LENIENT parser meant for the hand-typed GPS field) and was refused by the landing page's strict
	/// regex, so one link showed a map in the app and no location on the web. A wire format is a
	/// contract between two programs; the leniency belongs only where a person is typing.
	func test_wireCoordinateAcceptsOnlyPlainDecimals() throws {
		for raw in ["+48.8,+19.53", "48.8N,19.53E", "N48.8,E19.53", "48.8°,19.53°", " 48.8,19.53",
		            "48.8 ,19.53", "0x30,0x10", "1e1,2e1", "48.8,,19.53", "48.8", "٤٨.٨,١٩.٥"] {
			let url = try XCTUnwrap(URL(string: "https://link.aiarcheology.com/f#v=1&t=X&g=\(raw)"
				.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? ""))
			XCTAssertNil(FindingShareLink.payload(from: url)?.coordinate, "g=\(raw) must not parse on the wire")
		}
	}

	/// The paired positive case, so the test above cannot pass merely because `g` stopped working.
	func test_wireCoordinateAcceptsWhatTheBuilderEmits() throws {
		for raw in ["48.80000,19.53000", "-33.85680,151.21530", "0,0", "-0.5,-0.5", "90,-180"] {
			let url = try XCTUnwrap(URL(string: "https://link.aiarcheology.com/f#v=1&t=X&g=\(raw)"))
			XCTAssertNotNil(FindingShareLink.payload(from: url)?.coordinate, "g=\(raw) must parse")
		}
	}

	/// A round trip must still work: the builder writes `%.5f,%.5f`, which the stricter reader takes.
	func test_wireCoordinateRoundTripsFromAHandTypedGPSField() throws {
		// "+48.8N" style input is what a PERSON may type; it is canonicalised on the way out.
		let coordinate = try XCTUnwrap(CoordinateText.parse("48.8N, 19.53E"))
		let parsed = try roundTrip(makePayload(coordinate: coordinate))
		XCTAssertEqual(parsed.coordinate?.latitude ?? 0, 48.8, accuracy: 0.00001)
		XCTAssertEqual(parsed.coordinate?.longitude ?? 0, 19.53, accuracy: 0.00001)
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

	/// Inverted deliberately in AIA-0657. The QR used to drop the page unconditionally, which made
	/// the one artifact that survives a repost — a code printed into an image — the one carrying no
	/// way back to the page.
	func test_compactVariantKeepsThePageURL() throws {
		let compact = try XCTUnwrap(FindingShareLink.url(for: makePayload(), variant: .compact))
		XCTAssertEqual(FindingShareLink.payload(from: compact)?.page?.absoluteString, "https://example.org/ruins")
	}

	func test_overlongFieldsAreTruncatedRatherThanRejected() throws {
		let parsed = try roundTrip(makePayload(title: String(repeating: "a", count: 500), page: nil, author: nil))
		XCTAssertEqual(parsed.title.count, 80)
	}

	// MARK: - The bounding box (AIA-0657)

	private func makeBox(
		x: Double = 0.125, y: Double = 0.25, width: Double = 0.5, height: Double = 0.375
	) throws -> FindingShareLink.Box {
		try XCTUnwrap(FindingShareLink.Box(x: x, y: y, width: width, height: height))
	}

	func test_boxRoundTrips() throws {
		let box = try makeBox()
		let parsed = try roundTrip(makePayload(box: box))
		XCTAssertEqual(parsed.box, box)
	}

	func test_boxOutsideTheUnitSquareIsRefusedRatherThanClamped() {
		XCTAssertNil(FindingShareLink.Box(x: -0.1, y: 0.2, width: 0.3, height: 0.3))
		XCTAssertNil(FindingShareLink.Box(x: 0.8, y: 0.2, width: 0.3, height: 0.3), "x + width > 1")
		XCTAssertNil(FindingShareLink.Box(x: 0.2, y: 0.8, width: 0.3, height: 0.3), "y + height > 1")
		XCTAssertNil(FindingShareLink.Box(x: 0.2, y: 0.2, width: 0, height: 0.3), "zero area")
		XCTAssertNil(FindingShareLink.Box(x: .nan, y: 0.2, width: 0.3, height: 0.3))
		XCTAssertNil(FindingShareLink.Box(x: 0.2, y: 0.2, width: .infinity, height: 0.3))
	}

	/// `.zero` is what `Finding.normalizedBox` returns for a row saved before boxes were stored, so
	/// the refusal above is the common path rather than a hostile-input path.
	func test_zeroBoxIsRefused() {
		XCTAssertNil(FindingShareLink.Box(x: 0, y: 0, width: 0, height: 0))
	}

	func test_boxWireFormIsRejectedWhenMalformed() throws {
		let cases = [
			"0.1,0.2,0.3",                    // three components
			"0.1,0.2,0.3,0.4,0.5",            // five
			"+0.1,0.2,0.3,0.4",               // leading plus, which our own emitter never writes
			"1e-1,0.2,0.3,0.4",               // exponent
			"0.1, 0.2,0.3,0.4",               // whitespace
			"0.1,0.2,0.3,٤"                   // non-ASCII digit
		]
		for wire in cases {
			let url = try XCTUnwrap(URL(string: "https://link.aiarcheology.com/f#v=1&t=X&b=\(wire)"))
			XCTAssertNil(FindingShareLink.payload(from: url)?.box, "accepted a malformed box: \(wire)")
		}
	}

	/// The rounding case a plain `%.4f` would have shipped: a box that touches the right edge
	/// exactly, whose two halves each round *up* to the wire grid. Naively that emits
	/// `0.5000,0.5001` — a sum of 1.0001, which this type's own parser refuses — so the builder
	/// would have produced a link the app cannot read back.
	///
	/// Quantizing the extent toward the interior is what closes it. Exact wire values are
	/// deliberately not asserted: whether `0.49995 * 10000` lands just above or just below the
	/// halfway point is a property of binary floating point, not of this contract. The invariant is.
	func test_boxQuantizationNeverEmitsWhatTheParserWouldReject() throws {
		let box = try makeBox(x: 0.49995, y: 0.1, width: 0.50005, height: 0.2)
		let url = try XCTUnwrap(FindingShareLink.url(for: makePayload(box: box)))
		let parsed = try XCTUnwrap(FindingShareLink.payload(from: url))
		let carried = try XCTUnwrap(parsed.box, "the box was dropped instead of being quantized")

		XCTAssertLessThanOrEqual(carried.x + carried.width, 1, "emitted a box its own parser rejects")
		XCTAssertEqual(carried.x, box.x, accuracy: 1e-4)
		XCTAssertEqual(carried.width, box.width, accuracy: 1e-4)
	}

	/// The edge the quantization protects, stated directly: a box flush against the far corner
	/// survives the round trip rather than being dropped for being a hair over after rounding.
	func test_aBoxFlushAgainstTheFarCornerSurvives() throws {
		let box = try makeBox(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
		let parsed = try roundTrip(makePayload(box: box))
		XCTAssertEqual(parsed.box, box)
	}

	// MARK: - Page detail (AIA-0657)

	private static let geoportal = "https://geoportal.example.cz/geoprohlizec/?wmcid=5556&x=-556000&y=-1160000&s=1000"

	func test_fullDetailKeepsAGeoportalQuery() throws {
		let payload = makePayload(page: URL(string: Self.geoportal))
		let url = try XCTUnwrap(FindingShareLink.url(for: payload, pageDetail: .full))
		XCTAssertEqual(FindingShareLink.payload(from: url)?.page?.absoluteString, Self.geoportal)
	}

	func test_fullDetailKeepsAnOpenStreetMapFragment() throws {
		let osm = "https://www.openstreetmap.org/#map=15/48.8000/19.5300"
		let payload = makePayload(page: URL(string: osm))
		let url = try XCTUnwrap(FindingShareLink.url(for: payload, pageDetail: .full))
		XCTAssertEqual(FindingShareLink.payload(from: url)?.page?.absoluteString, osm)
	}

	func test_siteOnlyDetailStillReducesToSchemeHostAndPath() throws {
		let payload = makePayload(page: URL(string: Self.geoportal))
		let url = try XCTUnwrap(FindingShareLink.url(for: payload, pageDetail: .siteOnly))
		XCTAssertEqual(
			FindingShareLink.payload(from: url)?.page?.absoluteString,
			"https://geoportal.example.cz/geoprohlizec/"
		)
	}

	/// The default matters as much as the behaviour: a caller that forgets to pass a detail must emit
	/// the narrower link, never the wider one.
	func test_pageDetailDefaultsToSiteOnly() throws {
		let payload = makePayload(page: URL(string: Self.geoportal))
		let url = try XCTUnwrap(FindingShareLink.url(for: payload))
		XCTAssertEqual(
			FindingShareLink.payload(from: url)?.page?.absoluteString,
			"https://geoportal.example.cz/geoprohlizec/"
		)
	}

	func test_credentialParametersAreStrippedFromTheQuery() throws {
		let raw = "https://portal.example.org/view?x=1&access_token=abc123&X-Api-Key=k9&layer=orto&X-Amz-Signature=deadbeef"
		let page = try XCTUnwrap(FindingShareLink.sanitizedPage(raw, detail: .full))
		XCTAssertEqual(page.absoluteString, "https://portal.example.org/view?x=1&layer=orto")
	}

	/// OAuth's implicit flow puts the token in the fragment, which `.full` otherwise preserves.
	func test_credentialParametersAreStrippedFromTheFragment() throws {
		let raw = "https://portal.example.org/view#access_token=abc123&zoom=15"
		let page = try XCTUnwrap(FindingShareLink.sanitizedPage(raw, detail: .full))
		XCTAssertEqual(page.absoluteString, "https://portal.example.org/view#zoom=15")
	}

	/// The other half of the same rule: a fragment that is not key/value pairs is left exactly alone
	/// rather than re-encoded, which is what keeps OSM's `#map=…` intact.
	func test_aNonPairFragmentIsNotRewritten() throws {
		let raw = "https://portal.example.org/atlas#section/3/detail"
		let page = try XCTUnwrap(FindingShareLink.sanitizedPage(raw, detail: .full))
		XCTAssertEqual(page.absoluteString, raw)
	}

	func test_credentialNamesDoNotEatInnocentParameters() throws {
		let raw = "https://portal.example.org/view?keyword=rampart&wmsid=42&code=CZ0100"
		let page = try XCTUnwrap(FindingShareLink.sanitizedPage(raw, detail: .full))
		XCTAssertEqual(page.absoluteString, raw, "substring matching must not eat keyword/wmsid/code")
	}

	func test_httpAndEmbeddedCredentialsAreRefusedOutright() {
		XCTAssertNil(FindingShareLink.sanitizedPage("http://portal.example.org/view", detail: .full))
		XCTAssertNil(FindingShareLink.sanitizedPage("https://user:pass@portal.example.org/view", detail: .full))
	}

	/// The cap used to be applied to the *raw* string before the query was stripped, so a long
	/// portal URL produced no page at all — the links this ticket exists to fix were the ones
	/// silently losing their address entirely.
	func test_aLongPageStillYieldsAReducedAddressRatherThanNothing() throws {
		let raw = "https://portal.example.org/view?" + String(repeating: "q=1&", count: 150)
		XCTAssertGreaterThan(raw.count, 500)
		let reduced = try XCTUnwrap(FindingShareLink.sanitizedPage(raw, detail: .siteOnly))
		XCTAssertEqual(reduced.absoluteString, "https://portal.example.org/view")
	}

	// MARK: - Drop order and the two-form address (AIA-0657)

	/// The address is the last thing standing. Squeezed hard, the link sheds coordinate, date,
	/// class/confidence, box, author and finally the id — and still carries a title and a page.
	func test_theAddressOutlivesEveryOtherOptionalField() throws {
		let payload = makePayload(
			title: String(repeating: "T", count: 40),
			box: try makeBox(),
			page: URL(string: "https://portal.example.org/" + String(repeating: "p", count: 200)),
			author: String(repeating: "A", count: 60)
		)
		let url = try XCTUnwrap(FindingShareLink.url(for: payload, variant: .compact, pageDetail: .full))
		let parsed = try XCTUnwrap(FindingShareLink.payload(from: url))

		XCTAssertNotNil(parsed.page, "the address must be the last field standing")
		XCTAssertFalse(parsed.title.isEmpty)
		XCTAssertNil(parsed.coordinate)
		XCTAssertNil(parsed.date)
	}

	/// When the full address will not fit, it is *reduced* rather than dropped — the floor the
	/// ticket insists on keeping: a host still names the service the finding came from.
	func test_anOverlongAddressDegradesToItsHostRatherThanDisappearing() throws {
		let long = "https://portal.example.org/view?" + String(repeating: "abc=123&", count: 60)
		let payload = makePayload(title: "Rampart", page: URL(string: long))
		let url = try XCTUnwrap(FindingShareLink.url(for: payload, variant: .compact, pageDetail: .full))
		let page = try XCTUnwrap(FindingShareLink.payload(from: url)?.page)

		XCTAssertEqual(page.absoluteString, "https://portal.example.org/view")
		XCTAssertLessThanOrEqual(url.absoluteString.count, FindingShareLink.maximumCompactLength)
	}

	/// The property the composer's wording depends on: what the QR carries is never *more* than what
	/// the preview showed. Same origin, never longer, never a different site.
	func test_theCompactAddressIsNeverWiderThanTheFullOne() throws {
		let pages = [
			"https://ags.example.cz/av/",
			Self.geoportal,
			"https://portal.example.org/view?" + String(repeating: "abc=123&", count: 60)
		]
		for raw in pages {
			let payload = makePayload(title: String(repeating: "T", count: 40), page: URL(string: raw))
			let full = try XCTUnwrap(FindingShareLink.url(for: payload, variant: .full, pageDetail: .full))
			let compact = try XCTUnwrap(FindingShareLink.url(for: payload, variant: .compact, pageDetail: .full))

			let fullPage = try XCTUnwrap(FindingShareLink.payload(from: full)?.page)
			// Asserted, not skipped. "The compact link happened to drop the page" is exactly the case
			// this property most needs a verdict on, and `continue` gave it a pass.
			let compactPage = try XCTUnwrap(
				FindingShareLink.payload(from: compact)?.page,
				"the QR dropped the address entirely for \(raw)"
			)

			XCTAssertEqual(compactPage.host, fullPage.host, "the QR must not name a different site")
			XCTAssertLessThanOrEqual(
				compactPage.absoluteString.count,
				fullPage.absoluteString.count,
				"the QR carried a wider address than the sender was shown"
			)
			XCTAssertTrue(
				fullPage.absoluteString.hasPrefix(compactPage.absoluteString),
				"the QR's address is not a reduction of the shown one: \(compactPage)"
			)
		}
	}

	/// The budget is arithmetic on an assembled string, so it is asserted against the assembled
	/// string — at the cap, in both variants, with the largest page the contract accepts.
	func test_noEmittedLinkExceedsItsVariantBudget() throws {
		let payload = makePayload(
			title: String(repeating: "Ω", count: 80),
			detectionClass: String(repeating: "c", count: 60),
			box: try makeBox(),
			page: URL(string: "https://portal.example.org/view?" + String(repeating: "ab=12&", count: 90)),
			author: String(repeating: "å", count: 60)
		)
		for (variant, limit) in [
			(FindingShareLink.Variant.full, FindingShareLink.maximumLength),
			(FindingShareLink.Variant.compact, FindingShareLink.maximumCompactLength)
		] {
			let url = try XCTUnwrap(FindingShareLink.url(for: payload, variant: variant, pageDetail: .full))
			XCTAssertLessThanOrEqual(url.absoluteString.count, limit, "\(variant) overran its budget")
			XCTAssertNotNil(FindingShareLink.payload(from: url), "\(variant) emitted a link it cannot parse")
		}
	}

	/// The no-coordinate case is the primary one — `gps_` is hand-typed and usually empty — so it
	/// must not be degraded by anything this ticket added.
	func test_aLinkWithoutGpsCarriesEverythingElse() throws {
		let box = try makeBox()
		let payload = makePayload(coordinate: nil, box: box, page: URL(string: Self.geoportal))
		let url = try XCTUnwrap(FindingShareLink.url(for: payload, pageDetail: .full))
		let parsed = try XCTUnwrap(FindingShareLink.payload(from: url))

		XCTAssertNil(parsed.coordinate)
		XCTAssertEqual(parsed.box, box)
		XCTAssertEqual(parsed.page?.absoluteString, Self.geoportal)
		XCTAssertEqual(parsed.author, payload.author)
		XCTAssertEqual(parsed.id, payload.id)
	}

	// MARK: - Regressions found in review (AIA-0657)

	/// A full address over its cap must **reduce**, not vanish.
	///
	/// `sanitizedPage` used to return `nil` on length alone. The builder omits a `nil` page, the
	/// shortened link then fits comfortably, and the ladder in `url(for:variant:pageDetail:)` never
	/// fires — so the longest portal addresses, the ones this ticket exists for, produced links
	/// carrying no address at all. Found by two independent reviewers.
	func test_anAddressOverTheFullCapReducesRatherThanDisappearing() throws {
		let long = "https://portal.example.org/view?" + String(repeating: "q=1&", count: 150)
		XCTAssertGreaterThan(long.count, 600, "the fixture must exceed the full-form cap")

		let payload = makePayload(title: "Rampart", page: URL(string: long))
		let url = try XCTUnwrap(FindingShareLink.url(for: payload, pageDetail: .full))
		let page = try XCTUnwrap(
			FindingShareLink.payload(from: url)?.page,
			"an over-long address was dropped instead of reduced"
		)
		XCTAssertEqual(page.absoluteString, "https://portal.example.org/view")
	}

	/// The same hole one level up: the emission mapping must not hand the builder a `nil` page that
	/// no ladder can recover.
	func test_theEmittedPayloadStillCarriesAnAddressWhenTheFullFormIsTooLong() throws {
		let long = "https://portal.example.org/view?" + String(repeating: "q=1&", count: 150)
		let reduced = try XCTUnwrap(FindingShareLink.sanitizedPage(long, detail: .full))
		XCTAssertEqual(reduced.absoluteString, "https://portal.example.org/view")
	}

	/// One bare flag must not switch the whole credential sieve off.
	///
	/// `?debug&access_token=…` is ordinary in hand-built portal URLs, and the valueless item used to
	/// make the strip bail out and return everything unchanged — token included.
	func test_aValuelessQueryItemDoesNotDisableTheCredentialStrip() throws {
		let raw = "https://portal.example.org/view?debug&access_token=abc123&layer=orto"
		let page = try XCTUnwrap(FindingShareLink.sanitizedPage(raw, detail: .full))
		XCTAssertFalse(page.absoluteString.contains("access_token"), "the token survived beside a bare flag")
		XCTAssertTrue(page.absoluteString.contains("debug"), "the bare flag itself is not a credential")
		XCTAssertTrue(page.absoluteString.contains("layer=orto"))
	}

	/// A percent-encoded parameter *name* must not smuggle a credential past the list.
	func test_aPercentEncodedCredentialNameIsStillRecognised() throws {
		let raw = "https://portal.example.org/view?access%5Ftoken=abc123&x=1"
		let page = try XCTUnwrap(FindingShareLink.sanitizedPage(raw, detail: .full))
		XCTAssertFalse(page.absoluteString.lowercased().contains("abc123"), "an encoded name hid the token")
		XCTAssertTrue(page.absoluteString.contains("x=1"))
	}

	/// The spellings the exact list cannot reach.
	func test_awsAndSessionKeyNamesAreStripped() throws {
		let raw = "https://portal.example.org/view?AWSAccessKeyId=AKIA1&session_key=s1&bbox=1,2,3,4"
		let page = try XCTUnwrap(FindingShareLink.sanitizedPage(raw, detail: .full))
		XCTAssertFalse(page.absoluteString.contains("AKIA1"))
		XCTAssertFalse(page.absoluteString.contains("s1"))
		XCTAssertTrue(page.absoluteString.contains("bbox=1,2,3,4"))
	}

	/// A detection in the last thousandth of a page is a small detection, not an absent one. Rounding
	/// the origin to nearest carried `x` to 1.0 here, leaving no room for any width and dropping the
	/// box entirely.
	func test_aSliverAgainstTheFarEdgeStillTravels() throws {
		let box = try XCTUnwrap(FindingShareLink.Box(x: 0.99995, y: 0, width: 0.00005, height: 0.1))
		let url = try XCTUnwrap(FindingShareLink.url(for: makePayload(box: box)))
		let carried = try XCTUnwrap(
			FindingShareLink.payload(from: url)?.box,
			"a sliver against the far edge was quantized out of existence"
		)
		XCTAssertLessThanOrEqual(carried.x + carried.width, 1)
		XCTAssertGreaterThan(carried.width, 0)
	}

	/// The floor of the address ladder: when even the path will not fit, the host alone still names
	/// the service the finding came from — the degraded case the ticket forbids losing.
	func test_theAddressLadderBottomsOutAtTheHost() throws {
		let deepPath = "https://portal.example.org/" + String(repeating: "segment/", count: 60)
		let payload = makePayload(title: String(repeating: "T", count: 40), page: URL(string: deepPath))
		let url = try XCTUnwrap(FindingShareLink.url(for: payload, variant: .compact, pageDetail: .full))
		let page = try XCTUnwrap(FindingShareLink.payload(from: url)?.page)

		XCTAssertEqual(page.host, "portal.example.org")
		XCTAssertLessThanOrEqual(url.absoluteString.count, FindingShareLink.maximumCompactLength)
	}

	// MARK: - The location travels as written (AIA-0836)

	/// The reported bug: a finding whose location is in a projected coordinate system arrived with no
	/// location at all.
	///
	/// `ags.cuzk.cz` prefills S-JTSK — projected metres, a system name, a parenthesised EPSG code and
	/// a colon that is not a storage tag. `CoordinateText.parse` reads degrees and nothing else, so
	/// `coordinate` is legitimately nil here and cannot be anything else: -830000 is not a latitude.
	/// The text is what has to survive.
	func test_aProjectedCoordinateSystemTravelsAsWrittenEvenThoughItIsNotDegrees() throws {
		let written = "S-JTSK (EPSG:5514): -830000.1968993, -1027969.1358175"
		let payload = makePayload(coordinate: nil, locationText: written)
		let parsed = try roundTrip(payload)

		XCTAssertEqual(parsed.locationText, written, "the recipient must see what the sender's card showed")
		XCTAssertNil(parsed.coordinate, "projected metres are not degrees and must not be read as a pin")
	}

	/// Degrees and text travel together: the pin still works, and the recipient still sees the
	/// sender's own notation rather than a reformatting of it.
	func test_aReadableCoordinateKeepsBothItsPinAndItsWording() throws {
		let payload = makePayload(
			coordinate: FindingShareLink.Coordinate(latitude: 47.94123, longitude: 18.709545),
			locationText: "leaflet: 47.94123, 18.709545"
		)
		let parsed = try roundTrip(payload)

		XCTAssertEqual(parsed.coordinate?.latitude ?? 0, 47.94123, accuracy: 0.00001)
		XCTAssertEqual(parsed.locationText, "leaflet: 47.94123, 18.709545")
	}

	/// Under pressure the location outlives the date, the class, the confidence and the box.
	///
	/// It ranked second on the shed ladder when first written — dropped before all four — which for a
	/// finding on a map page discards the thing the finding is largely about. A long page URL is
	/// exactly the case that applies the pressure, and exactly the case where the location came from
	/// the map in the first place.
	func test_theLocationTextOutlivesTheOtherOptionalFields() throws {
		let payload = makePayload(
			coordinate: nil,
			locationText: "S-JTSK (EPSG:5514): -831425.5856845, -1028149.4515314",
			box: try makeBox(),
			page: URL(string: "https://ags.cuzk.cz/av/" + String(repeating: "p", count: 190))
		)
		let url = try XCTUnwrap(FindingShareLink.url(for: payload, variant: .compact, pageDetail: .full))
		let parsed = try XCTUnwrap(FindingShareLink.payload(from: url))

		XCTAssertNotNil(parsed.locationText, "the location went before the fields it outranks")
		XCTAssertNil(parsed.date)
		XCTAssertNil(parsed.detectionClass)
		XCTAssertLessThanOrEqual(url.absoluteString.count, FindingShareLink.maximumCompactLength)
	}

	/// An over-long location is **dropped, not shortened** — the one field where truncation lies.
	///
	/// Every other text field degrades acceptably: a clipped title is still recognisably that title.
	/// What `prefix(_:)` removes from a coordinate is the trailing digits, so a shortened value still
	/// parses, still looks like a location, and is somewhere else entirely. A gap the recipient can
	/// see beats a plausible wrong answer they cannot.
	func test_anOverLongLocationIsDroppedRatherThanShortenedIntoADifferentPlace() throws {
		let tooLong = "Web Mercator (EPSG:3857): 1134425.9924799, 6045439.9357442 near the old mill by the ford"
		XCTAssertGreaterThan(tooLong.count, 80, "fixture must exceed the cap to test anything")

		let parsed = try roundTrip(makePayload(coordinate: nil, locationText: tooLong))

		XCTAssertNil(parsed.locationText, "a shortened coordinate is a different coordinate")
	}

	/// …and when the degrees did parse, dropping the over-long text leaves them carrying the place,
	/// so the recipient gets the real location rather than nothing.
	func test_whenTheTextIsTooLongTheDegreesStillCarryThePlace() throws {
		let payload = makePayload(
			coordinate: FindingShareLink.Coordinate(latitude: 48.8, longitude: 19.53),
			locationText: String(repeating: "x", count: 200)
		)
		let parsed = try roundTrip(payload)

		XCTAssertNil(parsed.locationText)
		XCTAssertEqual(parsed.coordinate?.latitude ?? 0, 48.8, accuracy: 0.00001)
	}

	/// The text is a stranger's free text that this app renders, so it is capped and cleaned like
	/// every other rendered field rather than trusted for being "just a coordinate".
	func test_aHostileLocationTextIsStripped() throws {
		// Inside the cap, so this exercises the cleaning rather than the refusal above: a bidi
		// override renders as nothing while reordering everything after it, which is how a location
		// can be made to display digits in an order it does not hold.
		let payload = makePayload(locationText: "48.8, 19.53\u{202E}\u{0000}")
		let parsed = try roundTrip(payload)
		let text = try XCTUnwrap(parsed.locationText)

		XCTAssertEqual(text, "48.8, 19.53")
		XCTAssertFalse(text.unicodeScalars.contains { $0.value == 0x202E })
	}

	// MARK: - The id survives every link (AIA-0836)

	/// Every UUID costs 22 characters on the wire and comes back the same UUID.
	///
	/// Random rather than fixed input, and asserted over many: the codec is a byte copy, so the way
	/// it breaks is a byte order or a padding rule that happens to be an identity for the one UUID a
	/// fixture pins. `+` and `/` in particular only appear for some byte patterns, and they are the
	/// two characters base64url has to rewrite.
	func test_everyIdRoundTripsThroughTwentyTwoCharacters() throws {
		for _ in 0..<500 {
			let id = UUID()
			let url = try XCTUnwrap(FindingShareLink.url(for: makePayload(id: id), variant: .full, pageDetail: .full))
			let field = try XCTUnwrap(
				url.absoluteString
					.split(separator: "#").last?
					.split(separator: "&")
					.first(where: { $0.hasPrefix("i=") })
					.map { String($0.dropFirst(2)) }
			)

			XCTAssertEqual(field.count, 22, "\(id) did not encode to 22 characters")
			// Unreserved throughout, so percent-encoding cannot inflate the saving back away.
			XCTAssertNil(field.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=").union(.whitespaces)))
			XCTAssertEqual(FindingShareLink.payload(from: url)?.id, id)
		}
	}

	/// The 36-character form still parses, so links already sitting in internal TestFlight builds
	/// keep their id rather than importing as duplicates.
	func test_aLinkCarryingTheOldUUIDStringStillParses() throws {
		let id = try XCTUnwrap(UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301"))
		let url = try XCTUnwrap(URL(string: "https://\(FindingShareLink.webHost)\(FindingShareLink.path)#v=1&i=\(id.uuidString)&t=Roman%20wall"))

		XCTAssertEqual(FindingShareLink.payload(from: url)?.id, id)
	}

	/// An id has exactly one wire form: the aliases base64 would otherwise accept are refused.
	///
	/// 16 bytes is 128 bits and 22 base64 characters carry 132, so the final character has 4 bits
	/// Foundation ignores — `…A`, `…B` and `…P` in that position all decode to the same UUID. None of
	/// them decodes to a *different* id, so this is not a duplicate-row bug today; it is pinned
	/// because the id is a finding's identity here, and an identity with sixteen spellings is one a
	/// later dedupe could compare as text and get wrong.
	func test_anIdHasExactlyOneWireForm() throws {
		let id = try XCTUnwrap(UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301"))
		let canonical = try XCTUnwrap(
			FindingShareLink.url(for: makePayload(id: id), variant: .full, pageDetail: .full)
				.map(\.absoluteString)?
				.split(separator: "#").last?
				.split(separator: "&")
				.first(where: { $0.hasPrefix("i=") })
				.map { String($0.dropFirst(2)) }
		)
		XCTAssertEqual(FindingShareLink.payload(from: try link(id: canonical))?.id, id, "the canonical form must parse")

		// The aliases are *derived*, not guessed. The 22nd character carries 6 bits of which only the
		// top 2 belong to the UUID, so its aliases are the sixteen characters sharing those two bits
		// — one aligned block of the alphabet. Picking letters by eye gives neighbours that decode to
		// a genuinely different id, which would assert the opposite of what this test claims.
		let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
		let last = try XCTUnwrap(canonical.last)
		let index = try XCTUnwrap(alphabet.firstIndex(of: last))
		let aliases = alphabet.indices
			.filter { $0 >> 4 == index >> 4 && $0 != index }
			.map { String(canonical.dropLast()) + String(alphabet[$0]) }
		XCTAssertEqual(aliases.count, 15, "each id should have exactly fifteen alternative spellings")

		for alias in aliases {
			XCTAssertNil(
				FindingShareLink.payload(from: try link(id: alias))?.id,
				"\(alias) is a second spelling of \(canonical) and must not parse"
			)
		}
	}

	/// A link carrying `id` in the `i=` field and nothing else optional.
	private func link(id: String) throws -> URL {
		try XCTUnwrap(URL(string: "https://\(FindingShareLink.webHost)\(FindingShareLink.path)#v=1&i=\(id)&t=Roman%20wall"))
	}

	/// A truncated base64url id is refused rather than accepted as a *different* finding.
	///
	/// `Data(base64Encoded:)` will happily decode a shorter string into fewer than 16 bytes, so
	/// without the length check this would import under an id nobody minted.
	func test_aTruncatedIdIsRefusedRatherThanSilentlyDifferent() throws {
		let url = try XCTUnwrap(URL(string: "https://\(FindingShareLink.webHost)\(FindingShareLink.path)#v=1&i=AbCdEfGhIjKl&t=Roman%20wall"))

		XCTAssertNil(FindingShareLink.payload(from: url)?.id)
		// And the rest of the link still reads — a bad id is not a bad link.
		XCTAssertEqual(FindingShareLink.payload(from: url)?.title, "Roman wall")
	}

	/// The guarantee this ticket exists for: the densest link the compact variant can produce still
	/// carries `i=`.
	///
	/// Before AIA-0836 the id was last on the shed ladder, so exactly this input — a long page URL
	/// with every optional field present — is what dropped it, and a printed card scanned twice
	/// produced two rows.
	func test_theCompactLinkKeepsItsIdUnderMaximumPressure() throws {
		let id = UUID()
		let payload = makePayload(
			id: id,
			title: String(repeating: "Long finding title ", count: 6),
			detectionClass: "stone_wall_with_a_very_long_class_name",
			coordinate: FindingShareLink.Coordinate(latitude: 48.123456, longitude: 19.987654),
			box: FindingShareLink.Box(x: 0.123456, y: 0.234567, width: 0.345678, height: 0.456789),
			page: URL(string: "https://portal.example.org/" + String(repeating: "segment/", count: 40) + "?q=" + String(repeating: "x", count: 120)),
			author: "A. Rather Long Author Name"
		)
		let url = try XCTUnwrap(FindingShareLink.url(for: payload, variant: .compact, pageDetail: .full))

		XCTAssertEqual(FindingShareLink.payload(from: url)?.id, id, "the id was shed under pressure")
		XCTAssertLessThanOrEqual(url.absoluteString.count, FindingShareLink.maximumCompactLength)
	}
}
