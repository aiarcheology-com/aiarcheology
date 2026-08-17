//
//  FindingShareLink.swift
//  AI Archeology
//
//  The shareable-finding link contract (AIA-0650): build one, parse one back.
//

import Foundation

/// Builds and parses the links that carry a finding out of the app and back into it (AIA-0650).
///
/// Deliberately free of UIKit, SwiftUI and Core Data so the contract can be round-tripped in a unit
/// test without a host app — the parser is the only thing standing between a stranger's URL and a
/// screen in this app, so it is the piece that most needs to be cheap to test exhaustively.
///
/// ## Why the payload lives in the fragment
/// Everything after `#` is **never transmitted to the server**. The same payload in a query string
/// would reach the hosting provider's request log, its cache key and the `Referer` of every outbound
/// click — a per-open upload of the finding's title, its author's name, its coordinates and the page
/// it was captured on. AGENTS §10 and this ticket's own acceptance criteria forbid exactly that, and
/// a static landing page has no use for server-side parameters anyway.
///
/// The cost is stated rather than hidden: a fragment is invisible to link-preview crawlers, so a
/// pasted link renders a generic card instead of a per-finding one. The shared *image* already
/// carries the finding visually, so this buys privacy with something we were not relying on.
///
/// ## What the link does not do
/// Associated Domains authenticates the **domain**, never the parameters. Every field here is
/// attacker-controllable by anyone willing to type a URL, so a parsed payload is *unverified content
/// from a stranger* and the UI that renders it must say so. ``page`` is the sharp edge — it is a
/// URL this app will offer to open — which is why it is restricted to `https` and stripped of
/// everything but scheme, host and path.
enum FindingShareLink {

	// MARK: - Contract constants

	/// The host that serves the landing page and the `apple-app-site-association` file.
	static let webHost = "link.aiarcheology.com"

	/// The single path universal links use. **Pinned without a trailing slash**, and the
	/// `apple-app-site-association` file must list this exact string.
	///
	/// iOS matches the association against the URL *as tapped*, before any HTTP redirect runs — so
	/// if the host redirects `/f` to `/f/` (which directory-style static hosting does by default),
	/// a link emitted as `/f` while the association lists `/f/` simply never opens the app, with no
	/// error anywhere. The landing page is therefore served from `f.html`, not `f/index.html`.
	static let path = "/f"

	/// The already-registered custom scheme (`MLBrowser-Info.plist`, `CFBundleURLTypes`), accepted on
	/// input and **never emitted**. It exists so the flow is testable and demoable before the web host
	/// is live, since universal links cannot work until the association file is served.
	static let customScheme = "com.aiarcheology.ios"

	/// The custom scheme's equivalent of ``path``. `com.aiarcheology.ios://f` parses as **host `f`
	/// with an empty path** — not path `/f` — so the two grammars are matched separately rather than
	/// through one path comparison that silently rejects the scheme form.
	static let customHost = "f"

	/// Schema version. A link from a newer app is not guessed at: the landing page shows only the
	/// App Store link, and the app declines to render a payload it may misread.
	static let version = "1"

	/// Ceiling for the full link. Not a URL limit — a courtesy to the destinations that carry it as
	/// text, several of which wrap or truncate long strings.
	static let maximumLength = 900

	/// Ceiling for the QR variant, which is far tighter than the text one and for a physical reason.
	///
	/// A fragment payload forces QR **byte** mode (`#`, `&`, `=` and lowercase all fall outside
	/// alphanumeric mode). At 900 characters that is roughly a version-22 symbol — about 105 modules
	/// across — and the card renders the code at 64pt on a 3× canvas, so 192px ÷ 105 ≈ 1.8px per
	/// module. Below roughly 3px per module a code stops surviving being photographed off a screen,
	/// which is the only way a reposted card is ever scanned. 250 characters lands near version 10
	/// (57 modules, ≈3.4px per module) and holds up.
	static let maximumCompactLength = 250

	private enum Key {
		static let version = "v"
		static let id = "i"
		static let title = "t"
		static let detectionClass = "c"
		static let confidence = "p"
		static let coordinate = "g"
		static let page = "u"
		static let author = "a"
		static let date = "d"
	}

	/// Per-field caps on the *decoded* value, applied on the way in as well as on the way out. A
	/// hostile link can otherwise hand the UI a megabyte of text in a field the card renders.
	private enum Limit {
		static let title = 80
		static let compactTitle = 40
		static let detectionClass = 60
		static let author = 60
		static let page = 400
	}

	// MARK: - Payload

	/// A geographic point that has already been validated as renderable.
	struct Coordinate: Equatable, Sendable {
		let latitude: Double
		let longitude: Double

		/// Fails rather than clamping: a coordinate outside the real range is a malformed link, and
		/// clamping would silently drop a pin somewhere the sender never was.
		init?(latitude: Double, longitude: Double) {
			guard latitude.isFinite, longitude.isFinite,
			      (-90...90).contains(latitude), (-180...180).contains(longitude)
			else { return nil }
			self.latitude = latitude
			self.longitude = longitude
		}
	}

	/// The finding, reduced to what fits in a link. Every field except ``title`` is optional because
	/// every field except the title is optional on a `Finding` too.
	struct Payload: Equatable, Sendable {
		/// The originating finding's identifier, used for **one** purpose: looking it up in the
		/// recipient's own store. A match means the recipient already owns this finding — typically
		/// the sender testing their own link — and the app opens the real finding rather than showing
		/// its owner a stranger's-eye read-only card of their own work.
		///
		/// It identifies nothing outside this app: a random UUID reveals less than the title and
		/// author name already in the same link.
		let id: UUID?
		let title: String
		let detectionClass: String?
		/// Whole percent, `0...100`. Stored as the integer that travels, not the `0...1` Double the
		/// model produces, so the link never carries more precision than it renders.
		let confidencePercent: Int?
		let coordinate: Coordinate?
		/// The page the finding was captured on — `https` only, and reduced to scheme + host + path.
		/// See ``sanitizedPage(_:)`` for why the query string is dropped.
		let page: URL?
		let author: String?
		/// Day precision. A finding's capture *time* is a movement record; the date alone is context.
		let date: DateComponents?

		init(
			id: UUID? = nil,
			title: String,
			detectionClass: String? = nil,
			confidencePercent: Int? = nil,
			coordinate: Coordinate? = nil,
			page: URL? = nil,
			author: String? = nil,
			date: DateComponents? = nil
		) {
			self.id = id
			self.title = title
			self.detectionClass = detectionClass
			self.confidencePercent = confidencePercent
			self.coordinate = coordinate
			self.page = page
			self.author = author
			self.date = date
		}
	}

	/// Which of the two links is being built.
	enum Variant {
		/// The link shared as text — carries every field that fits.
		case full
		/// The link encoded into the QR printed on the card. Drops ``Payload/page`` and shortens the
		/// title to stay scannable; both variants still resolve to the same finding.
		case compact

		var lengthLimit: Int {
			switch self {
			case .full: return maximumLength
			case .compact: return maximumCompactLength
			}
		}

		var titleLimit: Int {
			switch self {
			case .full: return Limit.title
			case .compact: return Limit.compactTitle
			}
		}
	}

	// MARK: - Build

	/// Builds the shareable link, dropping optional fields from the least important upwards until it
	/// fits ``Variant/lengthLimit``.
	///
	/// Returns `nil` only when even a title-and-version link cannot fit, which a non-empty title
	/// cannot cause — but it is expressed as a failure rather than an over-long link so a caller can
	/// never ship something unscannable by accident.
	static func url(for payload: Payload, variant: Variant = .full) -> URL? {
		// Least important first: these are dropped in order while the link is too long. `page` leads
		// because the card already shows the host, and the compact variant never carries it at all.
		var droppable: [String] = [Key.page, Key.author, Key.date, Key.detectionClass, Key.coordinate]
		if variant == .compact { droppable.removeAll { $0 == Key.page } }

		var dropped: Set<String> = variant == .compact ? [Key.page] : []

		while true {
			guard let candidate = assemble(payload, variant: variant, dropping: dropped) else { return nil }
			if candidate.absoluteString.count <= variant.lengthLimit { return candidate }
			guard let next = droppable.first(where: { dropped.contains($0).not }) else {
				// Everything droppable is gone and it still does not fit: the title alone is too long.
				// Fall back to a hard-truncated title rather than returning an over-long link.
				return assembleTruncated(payload, variant: variant, dropping: dropped)
			}
			dropped.insert(next)
		}
	}

	private static func assemble(_ payload: Payload, variant: Variant, dropping dropped: Set<String>) -> URL? {
		// The title is the one field with no optional form: a card with nothing written on it is the
		// blank screen this ticket's fourth acceptance criterion exists to prevent. Refusing here
		// rather than emitting a version-only link also keeps the builder and the parser honest —
		// `payload(from:)` rejects a titleless link, so emitting one would mean shipping a link this
		// app cannot itself read.
		guard sanitizedText(payload.title, limit: variant.titleLimit) != nil else { return nil }

		var pairs: [(String, String)] = [(Key.version, version)]

		func add(_ key: String, _ value: String?) {
			guard dropped.contains(key).not, let value, value.isEmpty.not else { return }
			pairs.append((key, value))
		}

		add(Key.id, payload.id?.uuidString)
		add(Key.title, sanitizedText(payload.title, limit: variant.titleLimit))
		add(Key.detectionClass, sanitizedText(payload.detectionClass, limit: Limit.detectionClass))
		add(Key.confidence, payload.confidencePercent.map(String.init))
		add(Key.coordinate, payload.coordinate.map(formatted))
		// Reduced again on the way out, even though `FindingShareSubject.linkPayload` already reduced
		// it. Not redundant: `Payload` is a plain struct that validates nothing, so "the page is
		// safe" was previously a property of one *caller* remembering to call `sanitizedPage`, and
		// this contract is the wrong place to hold a security property by convention. Reducing here
		// makes it true of every link this type can emit, whoever built the payload. The original bug
		// was invisible in tests because a round-trip check parses on the way back in — and the
		// parser sanitizes — so the emitted link carried the query string while the test passed.
		add(Key.page, payload.page.flatMap { sanitizedPage($0.absoluteString) }?.absoluteString)
		add(Key.author, sanitizedText(payload.author, limit: Limit.author))
		add(Key.date, payload.date.flatMap(formattedDate))

		let fragment = pairs
			.map { "\($0.0)=\(percentEncoded($0.1))" }
			.joined(separator: "&")

		var components = URLComponents()
		components.scheme = "https"
		components.host = webHost
		components.path = path
		components.percentEncodedFragment = fragment
		return components.url
	}

	/// Last resort when even a stripped link overruns: keep the version and a shortened title.
	private static func assembleTruncated(_ payload: Payload, variant: Variant, dropping dropped: Set<String>) -> URL? {
		let overhead = "https://\(webHost)\(path)#\(Key.version)=\(version)&\(Key.title)=".count
		let budget = variant.lengthLimit - overhead
		guard budget > 0, let cleaned = sanitizedText(payload.title, limit: variant.titleLimit) else { return nil }
		let fitted = fittingEncodedLength(cleaned, budget: budget)
		guard fitted.isEmpty.not else { return nil }
		return assemble(
			Payload(title: fitted),
			variant: variant,
			dropping: dropped
		)
	}

	/// Trims `text` until its **percent-encoded** form fits `budget`.
	///
	/// Budgeting by character count does not work here, and fails worst on exactly the titles that
	/// need trimming: one `Ω` becomes six characters once encoded and a single emoji can become
	/// twelve, so a character-count budget can overshoot the real limit several times over. Measured
	/// per grapheme so a multi-scalar cluster is never cut in half.
	private static func fittingEncodedLength(_ text: String, budget: Int) -> String {
		var fitted = ""
		for character in text {
			let candidate = fitted + String(character)
			guard percentEncoded(candidate).count <= budget else { break }
			fitted = candidate
		}
		return fitted
	}

	// MARK: - Parse

	/// Parses a link produced by ``url(for:variant:)``, or returns `nil`.
	///
	/// Tolerant of *absent* data and hostile about *malformed* data: a missing optional field is
	/// simply absent from the result, while a value that cannot be trusted (an unparseable
	/// coordinate, a non-`https` page, a confidence outside `0...100`) is dropped rather than
	/// carried through in a degraded form. A link with no usable title is rejected outright, because
	/// a card with nothing on it is the blank screen this ticket's fourth acceptance criterion names.
	static func payload(from url: URL) -> Payload? {
		guard matches(url) else { return nil }
		guard let items = fragmentItems(of: url) else { return nil }

		// Duplicate keys are rejected rather than resolved. There is no correct answer to which of
		// two titles was meant, and "first wins" versus "last wins" is exactly the kind of quiet
		// disagreement that lets the app and the landing page render different things from one link.
		let keys = items.map(\.name)
		guard Set(keys).count == keys.count else { return nil }

		var fields: [String: String] = [:]
		for item in items {
			guard let value = item.value, value.isEmpty.not else { continue }
			fields[item.name] = value
		}

		guard fields[Key.version] == version else { return nil }
		guard let title = sanitizedText(fields[Key.title], limit: Limit.title) else { return nil }

		return Payload(
			id: fields[Key.id].flatMap(UUID.init(uuidString:)),
			title: title,
			detectionClass: sanitizedText(fields[Key.detectionClass], limit: Limit.detectionClass),
			confidencePercent: fields[Key.confidence].flatMap(parseConfidence),
			coordinate: fields[Key.coordinate].flatMap(CoordinateText.parse),
			page: fields[Key.page].flatMap(sanitizedPage),
			author: sanitizedText(fields[Key.author], limit: Limit.author),
			date: fields[Key.date].flatMap(parseDate)
		)
	}

	/// Whether `url` is one this app should even look at. Everything else — including every Clerk
	/// OAuth callback on the same custom scheme — is ignored, which is what keeps a scene-level
	/// `onOpenURL` from stealing URLs that belong to someone else.
	static func matches(_ url: URL) -> Bool {
		guard let scheme = url.scheme?.lowercased() else { return false }
		switch scheme {
		case "https":
			return url.host?.lowercased() == webHost && normalizedPath(url.path) == path
		case customScheme:
			// The custom form is `com.aiarcheology.ios://f#…`: host `f`, empty path.
			return url.host?.lowercased() == customHost && normalizedPath(url.path).isEmpty
		default:
			return false
		}
	}

	/// Collapses a trailing slash so `/f` and `/f/` compare equal *inside the app*. The association
	/// file cannot do this — iOS matches the tapped URL literally — which is why ``path`` is pinned
	/// and the host is configured not to redirect between the two forms.
	private static func normalizedPath(_ raw: String) -> String {
		guard raw.count > 1, raw.hasSuffix("/") else { return raw }
		return String(raw.dropLast())
	}

	/// Reads the fragment **without letting Foundation decode it first**.
	///
	/// `URLComponents.fragment` returns a percent-*decoded* string, so splitting that on `&` and `=`
	/// mis-splits any value whose own text contains one — a title of "Rome & Byzantium" becomes two
	/// fields. Taking `percentEncodedFragment` and handing it back to `URLComponents` as a query
	/// makes Apple's per-item decoder do the splitting, which is the same code path `queryItems`
	/// uses and is correct by construction.
	private static func fragmentItems(of url: URL) -> [URLQueryItem]? {
		guard let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedFragment,
		      raw.isEmpty.not
		else { return nil }
		return URLComponents(string: "?" + raw)?.queryItems
	}

	// MARK: - Field encoding & validation

	/// The characters safe to leave unescaped in a fragment value.
	///
	/// `CharacterSet.urlQueryAllowed` is **not** a safe default here: it permits `&`, `=`, `+`, `?`
	/// and `#`, so encoding a title with it emits a string that breaks the very parser on the other
	/// end of this file. Each is removed for a concrete reason — `&` and `=` are the separators, `#`
	/// would start a second fragment, `?` confuses the query re-parse in ``fragmentItems(of:)``, and
	/// `+` is read as a space by enough third-party parsers to be worth escaping for the landing
	/// page's benefit.
	private static let valueAllowed: CharacterSet = CharacterSet.urlQueryAllowed
		.subtracting(CharacterSet(charactersIn: "&=+?#"))

	private static func percentEncoded(_ value: String) -> String {
		value.addingPercentEncoding(withAllowedCharacters: valueAllowed) ?? ""
	}

	/// Trims, strips characters that have no business in a label, and caps the length.
	///
	/// Control characters and the Unicode bidirectional overrides are removed rather than escaped:
	/// they render as nothing while reordering everything after them, which is how a title can be
	/// made to display something other than what it contains. Returns `nil` for anything that is
	/// empty once cleaned, so callers can treat "absent" and "blank" identically.
	private static func sanitizedText(_ raw: String?, limit: Int) -> String? {
		guard let raw else { return nil }
		let cleaned = raw.unicodeScalars
			.filter { scalar in
				CharacterSet.controlCharacters.contains(scalar).not
					&& bidiControls.contains(scalar).not
			}
			.reduce(into: "") { $0.unicodeScalars.append($1) }
			.trimmingCharacters(in: .whitespacesAndNewlines)
		guard cleaned.isEmpty.not else { return nil }
		return cleaned.count <= limit ? cleaned : String(cleaned.prefix(limit))
	}

	/// LRE, RLE, PDF, LRO, RLO, LRI, RLI, FSI, PDI — the overrides that let text render in an order
	/// other than the one it is stored in.
	private static let bidiControls = CharacterSet(charactersIn: "\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}")

	private static func parseConfidence(_ raw: String) -> Int? {
		guard let value = Int(raw), (0...100).contains(value) else { return nil }
		return value
	}

	/// Reduces a captured page URL to the least that still identifies it.
	///
	/// **`https` only, and query plus fragment are dropped.** A browsed URL's query string is where
	/// session tokens, one-time links, search terms and account identifiers live, and this URL is
	/// about to be posted somewhere public by a user who is thinking about a photograph. `http` is
	/// refused outright rather than upgraded, and a URL carrying embedded credentials is refused
	/// entirely rather than stripped, because a link that needed a password is not one to hand on.
	///
	/// The honest cost: a page that only resolves *with* its query — a search result, a paginated
	/// view — will not reproduce for the recipient. The landing page says so.
	///
	/// **Internal, not private, and that is load-bearing.** The builder emits ``Payload/page``
	/// verbatim, so the reduction has to happen before a `Payload` exists — otherwise a browsed URL's
	/// query string travels inside the emitted link and is only dropped again when the *recipient*
	/// parses it, which is far too late to have protected anything. `FindingShareSubject.linkPayload`
	/// is the one place a raw browsed URL enters this contract, and it calls this.
	static func sanitizedPage(_ raw: String) -> URL? {
		guard raw.count <= Limit.page,
		      var components = URLComponents(string: raw),
		      components.scheme?.lowercased() == "https",
		      let host = components.host, host.isEmpty.not,
		      components.user == nil, components.password == nil
		else { return nil }
		components.query = nil
		components.fragment = nil
		components.user = nil
		components.password = nil
		return components.url
	}

	private static func formatted(_ coordinate: Coordinate) -> String {
		// Five decimals is ~1m — finer than a hand-typed coordinate ever justifies, and it keeps the
		// QR variant short.
		String(format: "%.5f,%.5f", coordinate.latitude, coordinate.longitude)
	}

	private static func formattedDate(_ components: DateComponents) -> String? {
		guard let year = components.year, let month = components.month, let day = components.day else { return nil }
		return String(format: "%04d-%02d-%02d", year, month, day)
	}

	/// Parses `yyyy-MM-dd` and rejects dates that do not exist.
	///
	/// Built by hand rather than with a formatter so the result is independent of the device's
	/// calendar, locale and time zone — a link written in one region must read identically in
	/// another. The round-trip through `Calendar` is what rejects the 30th of February, which a
	/// range check on each component alone would happily accept.
	private static func parseDate(_ raw: String) -> DateComponents? {
		let parts = raw.split(separator: "-", omittingEmptySubsequences: false)
		guard parts.count == 3,
		      let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
		      parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
		      (1...9999).contains(year)
		else { return nil }

		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
		let candidate = DateComponents(year: year, month: month, day: day)
		guard let date = calendar.date(from: candidate) else { return nil }

		let realized = calendar.dateComponents([.year, .month, .day], from: date)
		guard realized.year == year, realized.month == month, realized.day == day else { return nil }
		return candidate
	}
}

// MARK: - Free-text coordinates

/// Turns the finding's hand-typed `gps_` field into a point, when it can.
///
/// The field is a plain `TextField` with no validation anywhere in the app, so its contents are
/// whatever the user typed — a decimal pair, a pair with hemisphere letters, degree symbols, prose,
/// or nothing. Parsing is therefore best-effort by design: a value it cannot read means the link
/// carries no coordinate and the recipient sees no map, which is the common case rather than the
/// exceptional one.
enum CoordinateText {

	/// Accepts `48.8, 19.53`, `48.8 19.53`, `48.8N, 19.53E`, `N48.8 E19.53` and the degree-suffixed
	/// forms of each. Anything else yields `nil`.
	static func parse(_ raw: String) -> FindingShareLink.Coordinate? {
		let normalized = raw
			.replacingOccurrences(of: "°", with: " ")
			.replacingOccurrences(of: ";", with: ",")
			.trimmingCharacters(in: .whitespacesAndNewlines)
		guard normalized.isEmpty.not else { return nil }

		let tokens = normalized
			.split(whereSeparator: { $0 == "," || $0.isWhitespace })
			.map(String.init)
		guard tokens.count == 2 else { return nil }

		guard let first = component(tokens[0], positive: "N", negative: "S"),
		      let second = component(tokens[1], positive: "E", negative: "W")
		else { return nil }

		return FindingShareLink.Coordinate(latitude: first, longitude: second)
	}

	/// Reads one signed magnitude, with an optional hemisphere letter on either side.
	///
	/// A hemisphere letter and an explicit sign together (`-48.8N`) is refused rather than resolved:
	/// the two disagree about which side of the equator the user meant, and guessing puts a pin in
	/// the wrong hemisphere with no indication anything was wrong.
	private static func component(_ token: String, positive: Character, negative: Character) -> Double? {
		var body = token.uppercased()
		var hemisphere: Character?

		if let last = body.last, last == positive || last == negative {
			hemisphere = last
			body.removeLast()
		} else if let first = body.first, first == positive || first == negative {
			hemisphere = first
			body.removeFirst()
		}

		body = body.trimmingCharacters(in: .whitespaces)
		guard body.isEmpty.not else { return nil }
		// `Double("1e5")`, `Double("inf")` and `Double("nan")` all succeed; none is a coordinate.
		guard body.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" }) else { return nil }
		guard let magnitude = Double(body), magnitude.isFinite else { return nil }

		guard let hemisphere else { return magnitude }
		guard magnitude >= 0 else { return nil }
		return hemisphere == positive ? magnitude : -magnitude
	}
}
